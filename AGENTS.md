# AGENTS.md

EVE Online market watcher: ESI market-order pollers write to a local SQLite
database; queries surface arbitrage opportunities ("best order" to flip into
the Jita buy wall). Discord bot and email digest features exist but are
currently disabled.

## Commands

```sh
mix setup            # deps.get + ecto.create + ecto.migrate
mix start            # setup + run --no-halt
iex -S mix run       # interactive with app started (migrates automatically)
mix compile          # compile; use --warnings-as-errors for strict mode
mix ecto.migrate     # manual migration run (also happens on every boot)
```

Docker: `sudo docker build -t marketmailer .` then see the header of the
`Dockerfile` for run examples.

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

## Disabled subsystems

All disabled by commented-out children in `lib/app.ex`; code and config stay
in place for one-line re-enables:

| Feature | Enable | Needs |
| --- | --- | --- |
| Discord bot | uncomment `{Nostrum.Bot, ...}` | `DISCORD_TOKEN` env |
| Email digest | uncomment `Marketmailer.MailWorker` | `RESEND_TOKEN`, `EMAIL` env |
| Region pollers | uncomment `Marketmailer.RegionManagerSupervisor` | nothing |

`.example.env` documents the env vars. Without them the app boots fine.

## Architecture map

- `lib/app.ex` - supervision tree + boot-time migration run (see policy above)
- `priv/repo/migrations` - schema migrations
- `lib/database.ex` - `Database` repo; `Etag.Database`, `Discord.Database`,
  `Market.Database` access modules
- `lib/names.ex` - `ESI.Names`, `ESI.SystemInfo`, `Universe.Database`
- `lib/esi.ex` - market orders fetch, etag/error-limit/maintenance handling
- `lib/manager.ex`, `lib/worker.ex`, `lib/supervisor.ex` - region/page worker
  tree (per-region GenServers, dynamic page scaling, exponential backoff)
- `lib/etag.ex` - warms the `:market_cache` ETS table from `etags`
- `lib/discord.ex` - nostrum consumer, slash commands, embed builders
- `lib/mailer.ex`, `lib/email.eex` - swoosh email worker (disabled)
- `lib/schema.ex` - ecto schemas (`Discord`, `Etag`, `Market`, `MarketView`)
