# AGENTS.md

EVE Online market watcher: ESI market-order pollers write to a local SQLite
database; queries surface arbitrage opportunities ("best order" to flip into
the Jita buy wall). The Discord bot feature exists but is currently disabled.

## Commands

```sh
mix setup            # deps.get + ecto.create + ecto.migrate
mix start            # setup + run --no-halt
task live:start      # run the poller as a distributed node (attachable, hot-reloadable)
task live:attach     # attach to the live node (recompile() there hot-loads by hand)
mix upgrade.hot      # compile + hot-load beams into the live node (no restart)
iex -S mix run       # interactive with app started (migrates automatically)
mix compile          # compile; use --warnings-as-errors for strict mode
mix ecto.migrate     # manual migration run (also happens on every boot)
```

Docker: `sudo docker build -t marketmailer .` then see the header of the
`Dockerfile` for run examples.

## Live-process policy

Develop against a live running poller, not a cold boot — expiry timers,
ETS caches, and supervision state only exist in a running VM. The poller
is always on unless deliberately stopped (systemd user unit, see below).

- Before `mix test` / `mix run` / DB inspection, check for a poller:
  `ps aux | grep -F marketmailer`, `pgrep -af "mix.*(run|start)|iex.*mix"`,
  `lsof marketmailer.db`.
- If none exists, start one: `task live:start` for a manual distributed
  run, or install the always-on unit: copy `deploy/marketmailer.service`
  to `~/.config/systemd/user/` (adjust paths), copy `deploy/env.example`
  to `~/.config/marketmailer/env`, then
  `systemctl --user daemon-reload && systemctl --user enable --now marketmailer`.
  The unit file in the repo is a template only — never enable/start it
  from the repo. Stop is the only intended off switch:
  `systemctl --user stop marketmailer`.
- Talk to the live node instead of booting a second one:
  `task live:attach` for a remote shell (`recompile()` there hot-loads by
  hand), `mix upgrade.hot` to compile + rpc-load beams into it with no
  restart. Both need the shared cookie (`task live:cookie` creates
  `~/.config/marketmailer/cookie`, mode 600); the live node is
  `marketmailer@<hostname>` unless `MARKETMAILER_NODE` says otherwise.
  Hot reload keeps processes, ETS, and timers; state-shape changes
  (GenServer state, ETS tuple shapes) still need a poller restart.
- Safety while a poller runs: dev tests must still not hit live ESI or
  the live `marketmailer.db` — use stubbed ESI fixtures and a separate
  `MARKETMAILER_DB`. Read-only inspection of the live DB is fine
  (WAL mode allows concurrent readers); never write to it from dev/test
  tooling. `mix test.safe` refuses while a poller process is visible;
  bypass only via `MIX_ENV=test mix test` (isolated `test.db`,
  stubbed ESI, no pollers).

`mix format` is aliased to `format --check-formatted` and never writes.
To actually format files: `mix format --no-check-formatted`.
Formatting uses Quokka + HendricksFormatter plugins (see `.formatter.exs`);
`hendricks_formatter.ex` lives in the repo root on purpose and is compiled via
`elixirc_paths`.

## Database policy

- **SQLite only** (`ecto_sqlite3`). File: `marketmailer.db` at the working
  directory (gitignored), override with `MARKETMAILER_DB` env var - useful for
  mounting a Docker volume. WAL journal mode.
- **Standard Ecto migrations** live in `priv/repo/migrations`. `Marketmailer.
  Application.start/2` runs pending migrations on every boot before the
  supervision tree starts, so `mix run` and containers never need a separate
  migrate step; use `mix ecto.migrate` / `mix ecto.rollback` for manual control.
- To change the schema, add a new migration (`mix ecto.gen.migration <name>`).
- Databases created by the pre-migration bootstrap (tables but no
  `schema_migrations`) are detected at boot, dropped once, and rebuilt -
  data is derived cache and intentionally discarded.
- Gotcha: `insert_all/3` with a bare table name skips ecto type casting.
  Booleans must be coerced to `1`/`0` (see `Market.Database.upsert_orders`),
  and `on_conflict: :replace_all` is unavailable - list fields explicitly.

## EVE name resolution

Static data dumps are gone. Names resolve lazily from ESI into two cache
tables (`lib/names.ex`):

- `names(id, name)` - bulk `POST /v2/universe/names` for types/systems/stations
- `systems(system_id, name, security_status, region_name)` -
  system -> constellation -> region chain

Query SQL (`lib/getBestOrder.sql`, `lib/getItemsLessThan.sql`) LEFT JOINs these
tables; `Market.Database.backfill/1` detects unresolved columns, fetches the
missing ids, then re-runs the query once. Any new query must SELECT the raw id
columns (`system_id`, `location_id`, `type_id`) or backfill cannot see gaps.

Raw SQL files live in `lib/*.sql` and are loaded relative to `__DIR__`
(CWD-safe).

## Enabled subsystems

Both formerly-disabled features are now uncommented in `lib/app.ex`:

| Feature | Child in `lib/app.ex` | Needs |
| --- | --- | --- |
| Region pollers | `Marketmailer.RegionManagerSupervisor` | nothing |
| Discord bot | `{Marketmailer.BotSupervisor, ...}` (owns `Nostrum.Bot`) | `DISCORD_TOKEN` — if missing/invalid the bot is skipped with a warning, the rest of the app keeps running |

`.example.env` documents the env vars.

## Logging

Structured JSON logs (logging-sucks style: stable `event` names, flat
queryable fields, no sensitive data in fields). Everything funnels through
`Marketmailer.Log` (`lib/log.ex`):

- **Console** — every info/warning/error record as pretty JSON (4-space
  indent) with keys colored per level and values colored by type
  (strings/numbers/booleans) (`config.exs`,
  `:default_handler` level `:info`).
- **File** — warning-level events and above, plain pretty JSON to `./logs/errors.jsonl`
  (rotation: 5 × 10 MB, gz on rotate). `logs/` is removed and recreated on
  every boot.

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
- `lib/database.ex` - `Database` repo; `Etag.Database`, `Discord.Database`,
  `Market.Database` access modules
- `lib/names.ex` - `ESI.Names`, `ESI.SystemInfo`, `Universe.Database`
- `lib/esi.ex` - market orders fetch, etag/error-limit/maintenance handling
- `lib/manager.ex`, `lib/supervisor.ex`, `lib/worker.ex` - per-region fan-out
  (one `RegionManager` per region, one `PageWorker` per page; page 1 reports
  `X-Pages` and the manager starts/stops workers; each page polls on its own
  ESI TTL/ETag so unchanged pages stay cheap `304`s; persist failures report
  `:failed` instead of crashing)
- `lib/update_coordinator.ex` - region cycle tracker (sliding deadline per
  activity; timeout failures name the pending pages, not `page: nil`)
- `lib/etag.ex` - warms the `:market_cache` ETS table from `etags`
- `lib/discord.ex` - nostrum consumer, slash commands, embed builders
- `lib/schema.ex` - ecto schemas (`Discord`, `Etag`, `Market`, `MarketView`)
- `lib/mix/tasks/` - `test.safe` (live-poller guard), `upgrade.hot`
  (compile + rpc hot-load into the live node, no restart)
- `deploy/` - `marketmailer.service` template (always-on user unit, never
  loaded from the repo) + `env.example` for `~/.config/marketmailer/env`
