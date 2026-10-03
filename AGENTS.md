# AGENTS.md

EVE Online market watcher: ESI market-order pollers write to a local SQLite
database; queries surface arbitrage opportunities ("best order" to flip into
the Jita buy wall). The Discord bot feature exists but is currently disabled.

## Commands

```sh
mix setup            # deps.get + ecto.create + ecto.migrate
task start           # run latest tree as prod release detached (restarts when stale; never modifies the repo)
task dev             # interactive shell with the app started (dev, shell-only; isolated priv/data/dev.db + :4001, coexists with prod)
task live:update     # auto hot-upgrade when code changed (patch-bump + appup + release + unpack/install/commit); no-op otherwise
task release         # assemble the prod OTP release (Castle hot-upgrade support)
mix compile          # compile; use --warnings-as-errors for strict mode
mix ecto.migrate     # manual migration run (also happens on every boot)
```

Hot upgrades use Castle OTP releases (`{:castle, "~> 1.0"}`, release
`marketmailer`, `appup.exs` + `:appup` compiler). `task live:update` automates
the whole flow: no-op when the tree matches the newest shipped baseline
(`artifacts/*.tar.gz`, gitignored local staging); otherwise it patch-bumps
`mix.exs` (a shipped version is frozen — same-version upgrades can never
install), drafts the appup edge from that baseline (`mix castle.appup.gen`),
verifies coverage, builds (`mix release --overwrite`), stages the tarball,
then `bin/castle unpack/install/commit` if the prod daemon is running
(builds + tells you to run `task start` if it isn't). `mix.exs`
`upgrade_from` always excludes the version being built (self-relups are
rejected). SemVer — patch = hot-loadable logic, minor =
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
  terminal close). `task stop` stops everything on this host — the prod
  daemon plus any legacy detached-dev node (no pid archaeology needed) —
  and is the only intended off switch. `task start` always runs the
  current tree: it no-ops when the daemon already runs current code,
  otherwise it stops, rebuilds (`mix release --overwrite`), seeds a fresh
  prod DB from the in-project DB when the paths differ, and starts
  (restart delivery needs no version bump).
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
  (`mix upgrade.hot`) and `recompile()` hot-loading are removed.
  Hot upgrade keeps processes, ETS, and
  timers; state-shape changes (GenServer state, ETS tuple shapes) still
  need a poller restart (`task start` restarts a stale daemon onto the latest tree).
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
  (gitignored, `priv/data/.gitkeep` keeps the directory) — single-host
  prod uses the same in-project file via `MARKETMAILER_DB` in `.env`, and
  `task docker:run` bind-mounts `./priv/data` for containers. WAL journal mode.
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
- `appup.exs` - Castle appup source (SemVer; bump `mix.exs` version + add an
  entry per hot-upgradeable change); `config/runtime.exs` - release runtime
  config resolved by Castle before boot/install; `artifacts/` - staged
  release tarballs for `tar:` upgrade baselines
