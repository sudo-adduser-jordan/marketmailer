defmodule Marketmailer.Log do
	@moduledoc """
	Structured JSON logging facade.

	Every log call emits a single JSON object (see `Marketmailer.Log.Format`)
	with a stable machine-readable `event` name plus caller-supplied structured
	fields, e.g.

			Marketmailer.Log.info("page_fetch_ok", %{
				region: 10000002,
				page: 7,
				status: 200,
				orders: 1_000,
				ttl_ms: 300_000,
				url: "https://esi.evetech.net/v1/markets/10000002/orders/?page=7"
			})

	Fields are flattened onto the JSON object; `event` and `message` are
	reserved keys. No sensitive credentials should ever be passed in `fields`.
	"""

	require Logger

	@doc "Log an info-level event."
	def info(event, fields \\ %{}, message \\ nil), do: emit(:info, event, fields, message)

	@doc "Log a warning-level event."
	def warning(event, fields \\ %{}, message \\ nil), do: emit(:warning, event, fields, message)

	@doc "Log an error-level event."
	def error(event, fields \\ %{}, message \\ nil), do: emit(:error, event, fields, message)

	defp emit(level, event, fields, message) do
		record =
			fields
			|> Map.new()
			|> Map.put(:event, event)
			|> maybe_put(:message, message)

		case level do
			:info -> Logger.info(record)
			:warning -> Logger.warning(record)
			:error -> Logger.error(record)
		end
	end

	defp maybe_put(map, _key, nil), do: map
	defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule Marketmailer.Log.Format do
	@moduledoc """
	Renders lib/logger events as pretty JSON, both sinks (config.exs and
	lib/app.ex):

		* console - `{Marketmailer.Log.Format, [pretty: true, color: true]}` -
			keys colored per level, values by type for terminal reading.
		* file - `{Marketmailer.Log.Format, [pretty: true, color: false]}` -
			plain records in `logs/errors.jsonl`.

	Records are 4-space indented, back-to-back (no blank line between them),
	with a stable field order: `level`, `commit`, `ts`, `pid`, `event`, domain
	fields (alphabetical), then `message` last.

	Values are normalized so encoding never crashes (atoms, pids, charlists,
	tuples, structs all become JSON-safe). Scalar escaping delegates to OTP's
	`:json.encode/1`, so strings are always correct UTF-8 JSON.
	"""

	@colors %{
		debug: 90,
		info: 32,
		notice: 36,
		warning: 33,
		error: 31,
		critical: 31,
		alert: 31,
		emergency: 31
	}

	# Terminal colors for value tokens, picked by JSON type so they contrast
	# with the per-level key colors (31/32/33/36/90) on a dark background.
	@value_colors %{
		string: 94,
		number: 35,
		boolean: 37,
		null: 90,
		container: 96
	}

	# Git commit baked in at compile time; every event carries it so logs are
	# tied to the exact source revision that produced them.
	@commit (case System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: File.cwd!(), stderr_to_stdout: true) do
						 {out, 0} -> String.trim(out)
						 _ -> "unknown"
					 end)

	# OTP calls Formatter:format(Event, FConfig): the second element of the
	# registered {Module, FConfig} tuple arrives here as `config`. The handlers
	# register per-sink options, e.g. [pretty: true, color: true|false].
	def format(event, config) when is_list(config), do: render(event, config)
	def format(event, _config), do: render(event, [])

	defp render(%{level: level, msg: _, meta: _} = event, opts) do
		color = if Keyword.get(opts, :color, false), do: Map.get(@colors, level, 36)
		json = event |> ordered_fields() |> encode(Keyword.get(opts, :pretty, true), color)
		[json, "\n"]
	end

	defp render(event, _opts) do
		[~s({"ts":"","level":"unknown","message":), inspect(event), "}\n"]
	end

	defp ordered_fields(%{level: level, msg: msg, meta: meta}) do
		{report, message, event} = split_message(msg)

		base =
			[
				{"level", Atom.to_string(level)},
				{"commit", @commit},
				{"ts", timestamp(meta[:time])},
				{"pid", normalize(meta[:pid])}
			] ++
				maybe_entry("event", event)

		domain =
			if is_map(report) do
				report
				|> Map.drop([:event, :message, "event", "message"])
				|> Enum.sort_by(fn {key, _value} -> key end)
				|> Enum.map(fn {key, value} -> {to_string(key), normalize(value)} end)
			else
				[]
			end

		base ++ domain ++ maybe_entry("message", message)
	end

	defp split_message({:report, report}) when is_map(report) do
		message = report[:message] || report["message"] || nil
		event = report[:event] || report["event"] || nil
		{report, if(!is_nil(message), do: normalize(message)), normalize(event)}
	end

	defp split_message({:report, other}), do: {nil, inspect(other), nil}
	defp split_message({:string, chardata}), do: {nil, chardata_to_string(chardata), nil}

	defp split_message({:format, format, args}), do: {nil, format |> :io_lib.format(args) |> chardata_to_string(), nil}

	defp split_message(other), do: {nil, inspect(other), nil}

	defp maybe_entry(_key, nil), do: []
	defp maybe_entry(key, value), do: [{key, value}]

	defp timestamp(time) when is_integer(time) do
		case DateTime.from_unix(time, :microsecond) do
			{:ok, dt} ->
				{y, mo, d} = Date.to_erl(dt)
				{h, mi, s} = Time.to_erl(dt)
				ms = div(elem(dt.microsecond, 0), 1000)

				:io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0BZ", [
					y,
					mo,
					d,
					h,
					mi,
					s,
					ms
				])
				|> IO.iodata_to_binary()

			_ ->
				""
		end
	end

	defp timestamp(_), do: ""

	defp chardata_to_string(bin) when is_binary(bin), do: bin
	defp chardata_to_string(chardata), do: IO.chardata_to_string(chardata)

	defp normalize(nil), do: nil
	defp normalize(true), do: true
	defp normalize(false), do: false
	defp normalize(number) when is_number(number), do: number
	defp normalize(atom) when is_atom(atom), do: Atom.to_string(atom)
	defp normalize(bin) when is_binary(bin), do: bin
	defp normalize(%DateTime{} = dt), do: DateTime.to_iso8601(dt, :extended)
	defp normalize(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt, :extended)
	defp normalize(%Date{} = date), do: Date.to_iso8601(date)
	defp normalize(%Time{} = time), do: Time.to_iso8601(time, :extended)
	defp normalize(%_{} = struct), do: struct |> Map.from_struct() |> normalize_map()
	defp normalize(pid) when is_pid(pid), do: inspect(pid)
	defp normalize(ref) when is_reference(ref), do: inspect(ref)

	defp normalize(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.map(&normalize/1)

	defp normalize(list) when is_list(list), do: normalize_list(list)
	defp normalize(map) when is_map(map), do: normalize_map(map)
	defp normalize(other), do: inspect(other)

	# Charlists (e.g. a charlist passed as a field value) become strings
	# instead of number arrays; everything else is a JSON array.
	defp normalize_list([]), do: []

	defp normalize_list([head | _] = list) do
		if is_integer(head) and List.ascii_printable?(list) do
			List.to_string(list)
		else
			Enum.map(list, &normalize/1)
		end
	end

	defp normalize_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), normalize(value)} end)

	defp encode(fields, true, color), do: pretty_fields(fields, 0, color)

	defp encode(fields, false, color) do
		fields
		|> Map.new()
		|> :json.encode()
		|> IO.iodata_to_binary()
		|> color_token(color)
	end

	defp pretty_fields([], _indent, _color), do: "{}"

	defp pretty_fields(fields, indent, color) do
		pad = indent_string(indent)
		inner = indent_string(indent + 1)

		entries =
			Enum.map_join(fields, ",\n", fn {key, value} ->
				[
					inner,
					color_token(json_string(to_string(key)), color),
					": ",
					color_token(pretty_value(value, indent + 1), value_color(value, color))
				]
			end)

		["{\n", entries, "\n", pad, "}"]
	end

	# Color for a value token, chosen by JSON type so keys and values never
	# share a color, and strings read differently from numbers. Returns nil
	# for plain sinks (color disabled).
	defp value_color(_value, nil), do: nil
	defp value_color(value, _color) when is_binary(value), do: @value_colors.string
	defp value_color(value, _color) when is_number(value), do: @value_colors.number
	defp value_color(true, _color), do: @value_colors.boolean
	defp value_color(false, _color), do: @value_colors.boolean
	defp value_color(nil, _color), do: @value_colors.null
	defp value_color(_value, _color), do: @value_colors.container

	# Keys carry the per-level ANSI color; value tokens their type color.
	# Braces, commas, colons and indentation stay plain.
	defp color_token(iodata, color) when is_integer(color) do
		[IO.ANSI.color(color), iodata, IO.ANSI.reset()]
	end

	defp color_token(iodata, _color), do: iodata

	defp pretty_value(map, _indent) when is_map(map) and map_size(map) == 0, do: "{}"

	defp pretty_value(map, indent) when is_map(map) do
		pad = indent_string(indent)
		inner = indent_string(indent + 1)

		entries =
			Enum.map_join(map, ",\n", fn {key, value} ->
				[inner, json_string(to_string(key)), ": ", pretty_value(value, indent + 1)]
			end)

		["{\n", entries, "\n", pad, "}"]
	end

	defp pretty_value([], _indent), do: "[]"

	defp pretty_value(list, indent) when is_list(list) do
		pad = indent_string(indent)
		inner = indent_string(indent + 1)
		entries = Enum.map_join(list, ",\n", fn value -> [inner, pretty_value(value, indent + 1)] end)
		["[\n", entries, "\n", pad, "]"]
	end

	defp pretty_value(value, _indent), do: json_string(value)

	defp indent_string(indent), do: :binary.copy("    ", indent)

	# `nil` is JSON null; :json.encode/1 would encode the atom as the string
	# "nil" instead.
	defp json_string(nil), do: "null"
	defp json_string(value), do: value |> :json.encode() |> IO.iodata_to_binary()
end
