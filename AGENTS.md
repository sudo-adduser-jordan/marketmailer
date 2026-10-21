# AGENTS.md

EVE Online market watcher: ESI market-order pollers write to a local SQLite
database; queries surface arbitrage opportunities ("best order" to flip into
the Jita buy wall). The Discord bot broadcasts the same data when
`DISCORD_TOKEN` is set (otherwise it is skipped with a warning and the rest
of the app keeps running).

## Commands

```sh
mix setup            # deps.get + ecto.create + ecto.migrate
task start           # kill every marketmailer process, rebuild the latest tree, and start it detached (never modifies the repo)
task stop            # kill every marketmailer process on this host (prod daemon + orphaned dev nodes)
task dev             # interactive shell with the app started (dev, shell-only; isolated priv/data/dev.db + :4001, coexists with prod)
task live:update     # hot-upgrade the running prod in two phases (prepare writes bump+appup, you commit, re-run applies on a clean tree); refuses when nothing runs or the tree is dirty; never leaves the daemon down
task release         # assemble the prod OTP release (Castle hot-upgrade support)
mix compile          # compile; use --warnings-as-errors for strict mode
mix ecto.migrate     # manual migration run (also happens on every boot)
```

Hot upgrades use Castle OTP releases (`{:castle, "~> 1.0"}`, release
`marketmailer`, `appup.exs` + `:appup` compiler). `task live:update` runs in
two phases and never upgrades on a dirty tree: prepare patch-bumps `mix.exs`
(a shipped version is frozen — same-version upgrades can never install) and
drafts the appup edge from the newest shipped baseline (`releases/*.tar.gz`,
gitignored local staging) via `mix castle.appup.gen`, verifies coverage, and
stops — commit `mix.exs` + `appup.exs`, then re-run to apply (build
`mix release --overwrite`, stage the tarball, `bin/castle
unpack/install/commit` against the live prod daemon, verify). The bump + edge
are always written before the commit that ships them; the upgrade itself never
dirties the tree, so a finished run ends clean. A tree with bump + edge already
committed upgrades in a single run. The task refuses with "run `task start`"
when nothing is running, and never leaves the daemon down — if the VM drops it
is restarted on the version just made permanent and the running version is
asserted. `mix.exs`
`upgrade_from` always excludes the version being built (self-relups are
rejected). Clean tree before `task live:update`: commit all feature work
first. If a run is interrupted, never re-run blindly — first inspect the
daemon version, the staged tarball, and tree state (a staged tarball with the
daemon still on the old version resumes the upgrade on re-run); finish or
revert the in-flight upgrade, and commit the bump + edge only for a version
verified on the daemon. The task prints per-stage elapsed times. SemVer —
patch = hot-loadable logic, minor =
feature/migration/`restart_emulator`, major = breaking state/ETS/DB shape.
Non-code dirt alone never bumps (docs need nothing; release config applies
at boot, so config-only changes need `task start`).
If appup coverage fails (migration, state-shape change), commit and restart
instead of hot upgrade. Restarts before `commit` return to the
previous permanent version; `restart_emulator` upgrades exit the emulator,
so re-run `task start` to come back up on the new version. No version bump is needed
for changes delivered via restart instead of hot upgrade.

Docker: `sudo docker build -t marketmailer .` then see the header of the
`Dockerfile` for run examples.

## Live-process policy

Develop against a live running poller, not a cold boot — expiry timers,
ETS caches, and supervision state only exist in a running VM. The poller
is the prod release daemon and is always on unless deliberately stopped
(`task start` / `task stop`); there is no detached dev poller — dev work
happens in `task dev` (interactive shell) or the test suite.

- Before `mix test` / DB inspection, check for the poller:
  `ps aux | grep -F marketmailer`, `pgrep -af "mix.*(run|start)|iex.*mix|bin/marketmailer|beam.*marketmailer"`,
  `lsof priv/data/marketmailer.db`.
- If none exists, start it: `task start` (prod release daemon, survives
  terminal close). `task start` is a clean restart every time: it kills
  every marketmailer process on this host (via `task stop`), rebuilds
  (`mix release --overwrite`), seeds a fresh prod DB from the in-project DB
  when the paths differ, and starts (restart delivery needs no version
  bump). `task stop` is the kill-all switch — it gracefully stops the prod
  daemon then sweeps orphaned release processes and a detached-dev
  node (no pid archaeology needed); the host-wide `epmd` and unrelated
  Erlang nodes (editor language servers) are left alone, as is a test suite
  under `_build/test`.
- Talk to the live node instead of booting a second one:
  `_build/prod/rel/marketmailer/bin/marketmailer remote`
  (it reads the deployment cookie itself). `task dev` boots a second,
  dev-env node on isolated defaults (`priv/data/dev.db`, `:4001`, no bot —
  see `config/dev.exs` and the `dev` task) so plain `task dev` is safe
  alongside the daemon — never point it at the live DB file while the
  daemon holds it (`MARKETMAILER_DEV_DB=priv/data/marketmailer.db` opts
  back in and is refused while the daemon runs). Upgrades go
  through Castle (`task live:update`, i.e. `bin/castle unpack/install/commit`
  with the auto-derived `mix.exs` version); the old rpc beam-push
  (`mix upgrade.hot`) and `recompile()` hot-loading are removed. It requires
  a living daemon and verifies one at the end (restarting on the new version
  if the VM dropped), so it never leaves the poller down.
  Hot upgrade keeps processes, ETS, and
  timers; state-shape changes (GenServer state, ETS tuple shapes) still
  need a poller restart (`task start` restarts a stale daemon onto the latest tree).
- Never run `bin/marketmailer remote` with non-TTY stdin (a pipe,
  `</dev/null`, or a capture in a script): it is `iex --remsh`, so stdin EOF
  halts the *remote* node — it kills the prod daemon and leaves no log
  record, no crash dump, and no `epmd` entry. Use
  `bin/marketmailer rpc "EXPR"` for one-shot evaluation on the live node
  (same cookie, no shell).
- Safety while a poller runs: dev tests run fine alongside it — the suite
  uses stubbed ESI fixtures, `start_pollers: false`, and an isolated DB
  (`priv/data/test.db` default, per-suite tmp files). Read-only inspection of the
  live DB is fine (WAL mode allows concurrent readers); never write to it
  from dev/test tooling. `mix test` allows a live poller when the
  test DB is isolated and refuses only on a DB collision
  (`MARKETMAILER_DB=priv/data/marketmailer.db` while a poller holds it).

`mix format` is aliased to `format --check-formatted` and never writes.
To actually format files: `mix format --no-check-formatted`.
Formatting uses Quokka + HendricksFormatter plugins (see `.formatter.exs`);
`hendricks_formatter.ex` lives in the repo root on purpose and is compiled via
`elixirc_paths`.

## Database policy

- **SQLite only** (`ecto_sqlite3`). Write file: `priv/data/marketmailer.db`
  (gitignored, `priv/data/.gitkeep` keeps the directory) — single-host
  prod uses the same in-project file via `MARKETMAILER_DB` in `.env`, and
  `task docker:run` bind-mounts `./priv/data` for containers. WAL journal mode.
- **Fetch -> write -> read.** ESI pollers write only to the single DB file.
  Broadcasts render from the same file via `Market.Database` (`lib/database.ex`),
  which never touches the network. All writes go through `Database.Writer`,
  which serializes them on `Database.Queue` (SQLite has a single writer) so
  they never contend on the database lock or get dropped by the connection
  pool, and retries a transient `Database busy`/pool error before surfacing
  a real failure. Reads keep the full connection pool.
- **Standard Ecto migrations** live in `priv/repo/migrations` and apply to the
  single DB. `Marketmailer.
  Application.start/2` runs pending migrations on every boot before the
  supervision tree starts, so `mix run` and containers never need a separate
  migrate step; use `mix ecto.migrate` / `mix ecto.rollback` for manual control.
- To change the schema, add a new migration (`mix ecto.gen.migration <name>`).
- Databases created by the pre-migration bootstrap (tables but no
  `schema_migrations`) are detected at boot, dropped once, and rebuilt -
  data is derived cache and intentionally discarded.
- SDE snapshots: `mix sde.import [BUILD]` downloads the official JSONL SDE
  into `priv/data/sde/<build>/` (gitignored), extracts only
  `types`/`mapSolarSystems`/`mapConstellations`/`mapRegions`/`npcStations`/
  `stationOperations`/`npcCorporations`/`mapPlanets`/`mapMoons`/`mapStars`,
  and streams them into the `names`/`systems`/`regions` tables (station names
  are composed, see EVE name resolution). `regions` holds `region_id` + name
  from `mapRegions.jsonl`; the poller list is derived from it at boot, so a
  region missing from a hardcoded id range can never be skipped silently
  (Exordium 10001004 was missed that way). Builds are dated: event items land
  in builds published after the event starts, so a stale import surfaces as
  `?`/`Type <id>` labels. `task setup` defaults to the latest build
  (`SDE_BUILD` pins one); refresh a live DB with
  `MARKETMAILER_DB=<db> MARKETMAILER_DEV_DB=<db> mix sde.import` (no build arg
  = latest) — in dev a bare `mix sde.import` targets `priv/data/dev.db`. A boot
  `sde_names_missing` warning reports unnamed types inside the top 100.
- Gotcha: `insert_all/3` with a bare table name skips ecto type casting.
  Booleans must be coerced to `1`/`0` (see `Market.Database.upsert_orders`),
  and `on_conflict: :replace_all` is unavailable - list fields explicitly.

## EVE name resolution

Names come only from the official JSONL SDE (`mix sde.import`) into two
tables — no ESI name fetching exists anywhere:

- `names(id, name)` - published type names from `types.jsonl` plus NPC
  station names composed as `{system} {planet-roman} [- Moon {n}] -
  {owner} [{operation}]` from `npcStations` + `stationOperations` +
  `npcCorporations` + `mapPlanets`/`mapMoons`/`mapStars` (star-orbiting:
  system only; `useOperationName=false`: owner alone). ~0.5% of stations
  orbit named celestials whose proper names are not in the SDE; those
  render in the generic form, which is still unique and unambiguous.
- `systems(system_id, name, security_status, region_name)` -
  system -> constellation -> region chain

Query SQL (`lib/getBestOrder.sql`, `lib/getItemsLessThan.sql`, the
`marketListView` migration) LEFT JOINs these tables. There is no
per-request backfill: unmatched 64-bit location ids (>= 10^12, player
structures — dynamic, never in the SDE) render as `Player Station` and
anything else unmatched renders as `?` (an SDE import gap). Any new
query must still SELECT the raw id columns (`system_id`, `location_id`,
`type_id`) so gaps stay visible instead of silently wrong.

Capital hulls that cannot enter high sec carry `names.is_capital_ship`,
set by `mix sde.import` from the SDE groupIDs 30 (Titan), 485 (Dreadnought),
547 (Carrier), 659 (Supercarrier), 883 (Capital Industrial Ship), 1538
(Force Auxiliary), 4594 (Lancer Dreadnought) and 5120 (Command Carrier), and
every Jita buy-wall query (`getBestOrder.sql`, `getMarketItem.sql`,
`suggestItems.sql`, the `marketListView` view) filters them out — they can
never be delivered or sold in Jita. Freighters and jump freighters can gate
into high sec and stay, as do capital modules, components, fighters and
blueprints. A fresh import defaults the flag to 0, so the filter only takes
effect after `mix sde.import` has run against the database.

Raw SQL files live in `lib/*.sql` and are loaded relative to `__DIR__`
(CWD-safe).

## Enabled subsystems

Both formerly-disabled features are now uncommented in `lib/app.ex`:

| Feature | Child in `lib/app.ex` | Needs |
| --- | --- | --- |
| Region pollers | `Marketmailer.RegionManagerSupervisor` | SDE seeded — one manager per `regions` row (`mix sde.import`); an empty table starts none and logs `regions_missing` |
| Discord bot | `{Discord.BotSupervisor, ...}` (owns `Nostrum.Bot`) | `DISCORD_TOKEN` — if missing/invalid the bot is skipped with a warning, the rest of the app keeps running |

`.example.env` documents the env vars.

Janice chart capture shells out to the `playwright` CLI on `$PATH`, so the
Chromium build in `~/.cache/ms-playwright` must match that CLI.
`task playwright:install` (a dep of `task setup`) installs the matching build
and is a no-op when already current — re-run it after any Playwright upgrade.
A stale build makes every chart request fall back to `janice-failed.png` and
logs `janice_browser_missing` with the expected path. The Docker image bundles
its own matched build under `/ms-playwright`.

## Logging

Structured JSON logs (logging-sucks style: stable `event` names, flat
queryable fields, no sensitive data in fields). Everything funnels through
`Marketmailer.Log` (`lib/log.ex`):

- **Console** — every info/warning/error record as pretty JSON (4-space
  indent) with keys colored per level and values colored by type
  (strings/numbers/booleans) (`config.exs`,
  `:default_handler` level `:info`).
- **File** — warning-level events and above, plain pretty JSON to
  `./logs/errors.jsonl` (rotation: 5 × 10 MB, gz on rotate). The sink path is
  `config :marketmailer, :error_log_path`; on every boot only that sink's
  file and rotation archives are removed and recreated, never the whole
  `logs/` directory. `config/test.exs` points the sink at `logs/test.jsonl`,
  so `mix test` can never delete or append to the live `logs/errors.jsonl`.
  `ERL_CRASH_DUMP=logs/erl_crash.dump` (`.env`, `Taskfile.yml`) now also
  survives restarts instead of being wiped at boot: delete a dump by hand
  once you have read it.

Records on both sinks are back-to-back (no blank line) and share a stable
field order: `level`, `commit`, `ts`, `pid`, `event`, then domain fields
(alphabetical), then `message` last. Every
event carries `ts` (RFC3339 ms UTC) and `commit` (git short hash baked in at
compile time). A startup marker (`app_start` info event) logs the boot
timestamp and commit. `Marketmailer.Log.Format` renders both sinks with OTP's
`:json` (no extra deps). Debug events are dropped by both sinks; the single
previous debug call (page counts) is now info-level. To query console output,
strip ANSI and collect each record (every record starts with `{` at column 0),
then pipe to jq:
`mix run 2>&1 | sed 's/\e\[[0-9;]*m//g' | awk '/^{/{if(r!=""){print r;r=""}r=$0;next}{r=r"\n"$0}END{if(r!="")print r}' | jq -c 'select(.level != "info")'`.

## Architecture map

- `lib/app.ex` - supervision tree + boot-time migration run (see policy above)
- `priv/repo/migrations` - schema migrations
- `lib/database.ex` - `Database` repo + `Database.Writer`/`Database.Queue`
  (serialized, retrying writes on one process);
  `Etag.Database`, `Discord.Database`, `Market.Database` (reads + writes)
- `lib/mix/tasks/sde_import.ex` - `mix sde.import`: official JSONL SDE bulk seed
  (types, regions, systems, composed NPC station names)
- `lib/esi.ex` - market orders fetch, etag/error-limit/maintenance handling
- `lib/manager.ex`, `lib/supervisor.ex`, `lib/worker.ex` - per-region fan-out
  and refresh cycles (one `RegionManager` per SDE region, i.e. per `regions`
  row read at boot; the started set is cached in `:persistent_term` so the
  Discord broadcast barrier always matches the running managers; one
  `PageWorker` per
  page; page 1 reports `X-Pages` and every report reconciles the worker set
  to exactly `1..count` — missing pages are started, pages above the count
  are stopped, so a stale/sparse `etags` table can never wedge a region;
  each page polls on its own ESI TTL/ETag so unchanged pages stay cheap
  `304`s; every region emits exactly one event per cycle, including a
  zero-order region and a page-1 failure, so the broadcast barrier always
  closes)
- `lib/etag.ex` - warms the `:market_cache` ETS table from `etags`
- `lib/discord.ex` - nostrum consumer, slash commands, embed builders,
  `Discord.Broadcaster` (starts only with the pollers; collects one report
  per configured region and broadcasts when every one has reported, logging
  `round_closed`, `broadcast_delivered`/`broadcast_no_channels` at info),
  `Discord.BotSupervisor`. The broadcast ships the exact `/list_market`
  message (`Discord.Embeds.market_list_message/1`: page 1 of `list_per_page`
  = 10 rows plus Prev/Next buttons), so the command and the broadcast can
  never drift apart; the pager re-queries the DB (page 2+ is live data, not
  the broadcast snapshot) and Discord expires message-component interactions
  15 minutes after the message is posted. Market embeds use the Jita IV -
  Moon 4 station icon (`types/52678`, the station's type: ESI serves no
  station-icon route). Rendered line lists are never dropped silently -
  `Discord.Embeds` marks overflow with a trailing `… +N more`.
- `lib/schema.ex` - ecto schemas (`Discord`, `Etag`, `Market`, `MarketView`)
- `lib/mix/tasks/` - `sde.import` (official JSONL SDE bulk seed),
  `chartdb` (schema diagram rebuild)
- `appup.exs` - Castle appup source (SemVer; bump `mix.exs` version + add an
  entry per hot-upgradeable change); `config/runtime.exs` - release runtime
  config resolved by Castle before boot/install; `releases/` - staged
  release tarballs for `tar:` upgrade baselines
