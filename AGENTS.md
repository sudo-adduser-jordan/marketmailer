# AGENTS.md

EVE Online market watcher: ESI market-order pollers write to a local SQLite
database; queries surface arbitrage opportunities ("best order" to flip into
the Jita buy wall). The Discord bot feature exists but is currently disabled.

## Commands

```sh
mix setup            # deps.get + ecto.create + ecto.migrate
mix start            # setup + run --no-halt
task start           # dev poller detached (nohup, survives terminal close)
task start:live      # prod release detached (daemon, survives terminal close)
task live:update     # hot-upgrade running deployment without restart (auto VSN)
task release         # assemble the prod OTP release (Castle hot-upgrade support)
iex -S mix run       # interactive with app started (migrates automatically)
mix compile          # compile; use --warnings-as-errors for strict mode
mix ecto.migrate     # manual migration run (also happens on every boot)
```

Hot upgrades use Castle OTP releases (`{:castle, "~> 1.0"}`, release
`marketmailer`, `appup.exs` + `:appup` compiler): bump `mix.exs` version per
hot-upgradeable change (SemVer — patch = hot-loadable logic, minor =
feature/migration/`restart_emulator`, major = breaking state/ETS/DB shape),
add the appup entry (`mix castle.appup.gen`), list the shipped tarball in
`upgrade_from` (`tar:artifacts/...`), `mix release`, then
`bin/castle unpack/install/commit`. Restarts before `commit` return to the
previous permanent version; `restart_emulator` upgrades rely on the
systemd/OpenRC supervisor to restart the process. No version bump is needed
for changes delivered via restart instead of hot upgrade.

Docker: `sudo docker build -t marketmailer .` then see the header of the
`Dockerfile` for run examples.

## Live-process policy

Develop against a live running poller, not a cold boot — expiry timers,
ETS caches, and supervision state only exist in a running VM. The poller
is always on unless deliberately stopped (systemd user unit or OpenRC
service, see below).

- Before `mix test` / `mix run` / DB inspection, check for a poller:
  `ps aux | grep -F marketmailer`, `pgrep -af "mix.*(run|start)|iex.*mix|bin/marketmailer|beam.*marketmailer"`,
  `lsof priv/data/marketmailer.db`.
- If none exists, start one: `task start` for a manual detached dev
  run (`task start:live` for the detached prod release), or install the
  always-on unit: copy `marketmailer.service`
  to `~/.config/systemd/user/` (adjust paths), then create
  `~/.config/marketmailer/env` (needs `RELEASE_NODE`,
  `MARKETMAILER_DB`, `DISCORD_TOKEN`), then
  `systemctl --user daemon-reload && systemctl --user enable --now marketmailer`.
  OpenRC: copy `marketmailer.openrc` to `/etc/init.d/marketmailer`
  (chmod +x) and `marketmailer.openrc.conf.example` to
  `/etc/conf.d/marketmailer`, then `rc-update add marketmailer default`.
  The unit files in the repo are templates only — never enable/start them
  from the repo. Stop is the only intended off switch:
  `systemctl --user stop marketmailer` / `rc-service marketmailer stop`.
- Talk to the live node instead of booting a second one:
  `iex --sname debug --remsh marketmailer` for a remote shell on the
  mix-run poller (`_build/prod/rel/marketmailer/bin/marketmailer remote`
  for the release — it reads the deployment cookie itself). Upgrades go
  through Castle (`task live:update`, i.e. `bin/castle unpack/install/commit`
  with the auto-derived `mix.exs` version); the old rpc beam-push
  (`mix upgrade.hot`) and `recompile()` hot-loading are removed.
  No cookie setup exists: mix-run nodes share `~/.erlang.cookie`
  automatically. Hot upgrade keeps processes, ETS, and
  timers; state-shape changes (GenServer state, ETS tuple shapes) still
  need a poller restart.
- Safety while a poller runs: dev tests run fine alongside it — the suite
  uses stubbed ESI fixtures, `start_pollers: false`, and an isolated DB
  (`priv/data/test.db` default, per-suite tmp files). Read-only inspection of the
  live DB is fine (WAL mode allows concurrent readers); never write to it
  from dev/test tooling. `mix test.safe` allows a live poller when the
  test DB is isolated and refuses only on a DB collision
  (`MARKETMAILER_DB=priv/data/marketmailer.db` while a poller holds it).

`mix format` is aliased to `format --check-formatted` and never writes.
To actually format files: `mix format --no-check-formatted`.
Formatting uses Quokka + HendricksFormatter plugins (see `.formatter.exs`);
`hendricks_formatter.ex` lives in the repo root on purpose and is compiled via
`elixirc_paths`.

## Database policy

- **SQLite only** (`ecto_sqlite3`). File: `priv/data/marketmailer.db`
  (gitignored, `priv/data/.gitkeep` keeps the directory), override with
  `MARKETMAILER_DB` env var - useful for
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
- `lib/mix/tasks/` - `test.safe` (runs the suite in `MIX_ENV=test`;
  allows a live poller when the test DB is isolated, refuses only on DB
  collision)
- `marketmailer.service` (repo root) - always-on systemd user-unit template
  (never loaded from the repo); env file at `~/.config/marketmailer/env`
- `marketmailer.openrc` + `marketmailer.openrc.conf.example` - OpenRC
  service + conf templates (`/etc/init.d/marketmailer`, `/etc/conf.d/marketmailer`)
- `appup.exs` - Castle appup source (SemVer; bump `mix.exs` version + add an
  entry per hot-upgradeable change); `config/runtime.exs` - release runtime
  config resolved by Castle before boot/install; `artifacts/` - staged
  release tarballs for `tar:` upgrade baselines
