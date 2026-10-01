defmodule Mix.Tasks.Chartdb do
	@shortdoc "Rebuild assets/schema.svg from migrations (temp DB; live poller untouched)"

	@moduledoc """
	Regenerates the ChartDB-style schema diagram (`assets/schema.svg`) from
	the cumulative result of `priv/repo/migrations`, then ensures the
	`## Database schema` README section exists.

	The source of truth is the migrations, not any database file: a
	throwaway database is created under `System.tmp_dir!/0`, migrated `:up`
	with `all: true`, introspected (`sqlite_master` + `PRAGMA table_info`),
	and deleted. The live `priv/data/marketmailer.db` is never opened — the
	temporary path always wins over `MARKETMAILER_DB`, and the resolved file
	is asserted before any query — so this is safe alongside a live poller.
	The app supervision tree is never started.
	"""

	use Mix.Task

	@svg "assets/schema.svg"
	@readme "README.md"
	@top 90
	@gap 20
	@row_h 22
	@view_row_h 19
	@canvas_w 1240

	# Display slots: {x, width, tables}. Boxes stack from @top with @gap.
	@slots [
		{40, 280, ["market"]},
		{350, 260, ["names", "systems", "etags"]},
		{640, 260, ["discord", "marketListView"]},
		{930, 270, ["schema_migrations", :legend]}
	]

	# Logical foreign keys (no DB constraints; app-joined in lib/*.sql).
	@fks [
		{"market", "type_id", "names"},
		{"market", "location_id", "names"},
		{"market", "system_id", "systems"}
	]

	@legend_rows [
		{:bold, "bold = primary key"},
		{:plain, "* = NOT NULL"},
		{:plain, "→ = logical FK (no DB"},
		{:plain, "constraint; app-joined)"},
		{:plain, "dashed box = VIEW"},
		{:plain, "dashed line = VIEW reads"}
	]

	@impl true
	def run(_args) do
		tmp = Path.join(System.tmp_dir!(), "marketmailer-chartdb-#{:erlang.unique_integer([:positive])}.db")
		base = Application.get_env(:marketmailer, Database, [])
		Application.put_env(:marketmailer, Database, Keyword.put(base, :database, tmp))

		try do
			{:ok, schema, _started} =
				Ecto.Migrator.with_repo(Database, fn repo ->
					_ = Ecto.Migrator.run(repo, :up, all: true)
					introspect!(repo, tmp)
				end)

			File.write!(@svg, render(schema))
			ensure_readme!()
			Mix.shell().info("chartdb: wrote #{@svg} (#{length(schema.tables)} tables/views)")
		after
			for suffix <- ["", "-shm", "-wal", "-journal"], do: File.rm(tmp <> suffix)
		end
	end

	defp introspect!(repo, tmp) do
		%{rows: [[_seq, _name, file]]} = Ecto.Adapters.SQL.query!(repo, "PRAGMA database_list", [])

		if file != tmp do
			Mix.raise("chartdb: refusing — connected database is not the temp file (#{file})")
		end

		%{rows: objects} =
			Ecto.Adapters.SQL.query!(
				repo,
				"SELECT type, name FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY name",
				[]
			)

		tables =
			Enum.map(objects, fn [type, name] ->
				%{rows: cols} = Ecto.Adapters.SQL.query!(repo, ~s[PRAGMA table_info("#{name}")], [])

				columns =
					Enum.map(cols, fn [_cid, col, _type, notnull, _dflt, pk] ->
						%{name: col, pk?: pk == 1, notnull?: notnull == 1}
					end)

				%{name: name, view?: type == "view", columns: columns}
			end)

		%{rows: indexes} =
			Ecto.Adapters.SQL.query!(
				repo,
				"SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'market' AND name NOT LIKE 'sqlite_autoindex%'",
				[]
			)

		partial = Enum.count(indexes, fn [sql] -> sql =~ "WHERE" end)
		%{tables: tables, market_indexes: length(indexes), market_partial: partial}
	end

	defp render(%{tables: tables} = schema) do
		by_name = Map.new(tables, &{&1.name, &1})
		{boxes, bottom} = layout(by_name, schema)
		lane = bottom + 24
		strip_y = lane + 28
		strip_h = 120

		[
			header(schema, strip_y + strip_h + 40),
			Enum.map(boxes, &box_svg/1),
			arrows_svg(boxes, lane),
			strip_svg(schema, strip_y, strip_h),
			"</svg>\n"
		]
		|> IO.iodata_to_binary()
	end

	defp layout(by_name, schema) do
		Enum.reduce(@slots, {[], @top}, fn slot, {boxes, global_bottom} ->
			{slot_boxes, slot_bottom} = layout_slot(slot, by_name, schema)
			{boxes ++ slot_boxes, max(global_bottom, slot_bottom)}
		end)
	end

	defp layout_slot({x, w, names}, by_name, schema) do
		{boxes, bottom} =
			Enum.reduce(names, {[], @top}, fn name, {boxes, y} ->
				box = build_box(name, x, y, w, by_name, schema)
				{boxes ++ [box], y + box.h + @gap}
			end)

		{boxes, bottom - @gap}
	end

	defp build_box(:legend, x, y, w, _by_name, _schema) do
		rows_y = y + 40

		%{
			name: "legend",
			kind: :legend,
			title: "legend",
			subtitle: nil,
			x: x,
			y: y,
			w: w,
			h: rows_y - y + length(@legend_rows) * @row_h + 14,
			rows_y: rows_y,
			row_h: @row_h,
			cols: [],
			rows: @legend_rows,
			footers: []
		}
	end

	defp build_box(name, x, y, w, by_name, schema) do
		table = Map.fetch!(by_name, name)
		{title, subtitle, footers} = meta(name, schema)
		row_h = if table.view?, do: @view_row_h, else: @row_h
		rows_y = y + if subtitle, do: 56, else: 40
		rows = Enum.map(table.columns, &{label_style(table.name, &1), label_text(table.name, &1)})

		%{
			name: name,
			kind: :table,
			title: title,
			subtitle: subtitle,
			x: x,
			y: y,
			w: w,
			h: rows_y - y + length(rows) * row_h + length(footers) * 16 + 14,
			rows_y: rows_y,
			row_h: row_h,
			cols: Enum.map(table.columns, & &1.name),
			rows: rows,
			footers: footers,
			view?: table.view?
		}
	end

	defp meta("market", schema) do
		{"market", nil,
		 [
			 "#{schema.market_indexes} indexes (#{schema.market_partial} partial)",
			 "bool stored 1/0 (see",
			 "Market.Database)"
		 ]}
	end

	defp meta("names", _schema), do: {"names (lazy cache)", nil, ["no timestamps", "POST /v2/universe/names"]}
	defp meta("systems", _schema), do: {"systems (lazy cache)", nil, ["no timestamps"]}
	defp meta("etags", _schema), do: {"etags", nil, []}
	defp meta("discord", _schema), do: {"discord", nil, []}

	defp meta("marketListView", _schema) do
		{"marketListView", "VIEW (not a table)",
		 ["sell orders priced", "under Jita buy wall", "reads market +", "names + systems"]}
	end

	defp meta("schema_migrations", _schema), do: {"schema_migrations", nil, ["Ecto-managed"]}

	defp label_style(_table, %{pk?: true}), do: :bold
	defp label_style(_table, _col), do: :plain

	defp label_text(_table, %{name: n, pk?: true}), do: n <> " PK"

	defp label_text(table, %{name: n} = col) do
		suffix = if col.notnull?, do: " *", else: ""

		case Enum.find(@fks, fn {t, c, _} -> t == table and c == n end) do
			nil -> n <> suffix
			{_, _, dst} -> n <> " → " <> dst
		end
	end

	defp header(schema, canvas_h) do
		names =
			schema.tables
			|> Enum.reject(&(&1.name == "schema_migrations" or &1.view?))
			|> Enum.map_join(" / ", & &1.name)

		[
			~s(<svg xmlns="http://www.w3.org/2000/svg" width="#{@canvas_w}" height="#{canvas_h}" viewBox="0 0 #{@canvas_w} #{canvas_h}" font-family="sans-serif">\n),
			"  <defs>\n",
			~s(    <marker id="arrow" markerWidth="10" markerHeight="8" refX="9" refY="4" orient="auto">\n),
			~s(      <path d="M0,0 L10,4 L0,8 z" fill="#1e1e1e"/>\n),
			"    </marker>\n",
			~s(    <marker id="arrow-gray" markerWidth="10" markerHeight="8" refX="9" refY="4" orient="auto">\n),
			~s(      <path d="M0,0 L10,4 L0,8 z" fill="#868e96"/>\n),
			"    </marker>\n",
			"  </defs>\n",
			~s(  <rect width="#{@canvas_w}" height="#{canvas_h}" fill="#ffffff"/>\n),
			~s(  <text x="40" y="48" font-size="28" fill="#1e1e1e">Marketmailer — database schema</text>\n),
			~s(  <text x="40" y="70" font-size="13" fill="#555">),
			"priv/data/marketmailer.db (WAL, gitignored) • tables: #{names} • VIEW: marketListView",
			"</text>\n"
		]
	end

	defp box_svg(%{kind: :legend} = box) do
		[
			~s(  <rect x="#{box.x}" y="#{box.y}" width="#{box.w}" height="#{box.h}" rx="8" fill="#ffffff" stroke="#1e1e1e" stroke-width="2"/>\n),
			title_svg(box),
			rows_svg(box, "sans-serif")
		]
	end

	defp box_svg(box) do
		fill =
			%{
				"market" => "#d0ebff",
				"names" => "#fff3bf",
				"systems" => "#d3f9d8",
				"etags" => "#e5dbff",
				"discord" => "#f3d9fa",
				"marketListView" => "#ffecd2",
				"schema_migrations" => "#f1f3f5"
			}[box.name]

		dash = if box.view?, do: ~s( stroke-dasharray="8 4"), else: ""

		[
			~s(  <rect x="#{box.x}" y="#{box.y}" width="#{box.w}" height="#{box.h}" rx="8" fill="#{fill}" stroke="#1e1e1e" stroke-width="2"#{dash}/>\n),
			title_svg(box),
			if(box.subtitle,
				do:
					~s(  <text x="#{box.x + div(box.w, 2)}" y="#{box.y + 44}" font-size="12" fill="#555" text-anchor="middle">#{esc(box.subtitle)}</text>\n),
				else: []
			),
			rows_svg(box, "monospace"),
			footers_svg(box)
		]
	end

	defp title_svg(box) do
		~s(  <text x="#{box.x + div(box.w, 2)}" y="#{box.y + 28}" font-size="15" font-weight="bold" text-anchor="middle">#{esc(box.title)}</text>\n)
	end

	defp rows_svg(box, family) do
		Enum.with_index(box.rows, fn {style, text}, i ->
			weight = if style == :bold, do: ~s( font-weight="bold"), else: ""
			y = box.rows_y + i * box.row_h

			~s(  <text x="#{box.x + 16}" y="#{y}" font-size="13" font-family="#{family}"#{weight}>#{esc(text)}</text>\n)
		end)
	end

	defp footers_svg(box) do
		base = box.rows_y + length(box.rows) * box.row_h

		Enum.with_index(box.footers, fn text, i ->
			~s(  <text x="#{box.x + 16}" y="#{base + 6 + i * 16}" font-size="12" fill="#555">#{esc(text)}</text>\n)
		end)
	end

	defp arrows_svg(boxes, lane) do
		by_name = Map.new(boxes, &{&1.name, &1})

		fk =
			Enum.map(@fks, fn {src, col, dst} ->
				s = by_name[src]
				d = by_name[dst]
				y1 = row_base(s, Enum.find_index(s.cols, &(&1 == col))) - 4
				y2 = row_base(d, 0) - 4
				x1 = s.x + s.w
				x2 = d.x

				~s[  <path d="M#{x1},#{y1} C#{x1 + 16},#{y1} #{x2 - 14},#{y2} #{x2},#{y2}" marker-end="url(#arrow)"/>\n]
			end)

		view =
			for src <- ["names", "systems"] do
				s = by_name[src]
				v = by_name["marketListView"]
				y1 = s.y + div(s.h, 2)
				y2 = min(max(y1, v.y + 60), v.y + v.h - 30)

				~s[  <path d="M#{s.x + s.w},#{y1} H#{v.x - 2},#{y1} V#{y2} H#{v.x - 2}" marker-end="url(#arrow-gray)"/>\n]
			end

		m = by_name["market"]
		v = by_name["marketListView"]
		mcx = m.x + div(m.w, 2)
		vcx = v.x + div(v.w, 2)
		mid = div(mcx + vcx, 2)

		[
			~s(  <g stroke="#1e1e1e" stroke-width="2" fill="none">\n),
			fk,
			"  </g>\n",
			~s(  <g stroke="#868e96" stroke-width="2" stroke-dasharray="6 4" fill="none">\n),
			view,
			~s[  <path d="M#{mcx},#{m.y + m.h} V#{lane} H#{vcx} V#{v.y + v.h}" marker-end="url(#arrow-gray)"/>\n],
			"  </g>\n",
			~s[  <text x="#{mid}" y="#{lane - 6}" font-size="12" fill="#868e96" text-anchor="middle">VIEW reads market + caches</text>\n]
		]
	end

	defp row_base(box, i), do: box.rows_y + i * box.row_h

	defp strip_svg(schema, y, h) do
		cx = div(@canvas_w, 2)

		[
			~s(  <rect x="40" y="#{y}" width="#{@canvas_w - 80}" height="#{h}" rx="8" fill="#f1f3f5" stroke="#1e1e1e" stroke-width="2"/>\n),
			~s[  <text x="#{cx}" y="#{y + 28}" font-size="13" text-anchor="middle">Indexes: market (#{schema.market_indexes} total, #{schema.market_partial} partial) • Jita-buy (system_id = 30000142) • sell scan (is_buy_order = 0)</text>\n],
			~s[  <text x="#{cx}" y="#{y + 50}" font-size="13" text-anchor="middle">names/systems carry no timestamps; all other tables have inserted_at/updated_at. MarketView (lib/schema.ex) is a query struct, not a DB view.</text>\n],
			~s[  <text x="#{cx}" y="#{y + 72}" font-size="13" text-anchor="middle">Queries LEFT JOIN the lazy caches and backfill gaps from ESI, then re-run once (Market.Database). Read-only sqlite3 on the live WAL file is safe; never write.</text>\n],
			~s[  <text x="#{cx}" y="#{y + 94}" font-size="13" text-anchor="middle">* bool is_buy_order is stored 1/0 because insert_all skips Ecto casting (see Market.Database.upsert_orders).</text>\n]
		]
	end

	defp ensure_readme! do
		content = File.read!(@readme)

		if String.contains?(content, @svg) do
			:ok
		else
			section = """
			## Database schema

			![Database schema](#{@svg})

			Editable source: [docs/schema.excalidraw](docs/schema.excalidraw) —
			open in excalidraw.com or the VSCode Excalidraw extension, export SVG to
			`assets/` after edits.

			SQLite at `priv/data/marketmailer.db` (WAL, gitignored): `market` order
			cache, `etags` per-page ETag/Expires, lazy `names`/`systems` EVE caches,
			`discord` channel routing, plus the `marketListView` undercut view.
			`MarketView` (`lib/schema.ex`) is a query struct, not a DB view. Arrows
			are logical FKs joined by the app, not DB constraints.

			"""

			File.write!(@readme, String.replace(content, "## System design", section <> "## System design", global: false))
			Mix.shell().info("chartdb: added Database schema section to #{@readme}")
		end
	end

	defp esc(s) do
		s |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
	end
end
