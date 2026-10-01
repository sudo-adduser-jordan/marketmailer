# Marketmailer

EVE Online market watcher. Region pollers fetch market orders from ESI into a
local SQLite database; queries surface arbitrage opportunities ("best order"
to flip into the Jita buy wall). A Discord bot broadcasts market updates.

## Prerequisites

- Elixir (see `mix.exs` for the version) with Mix
- Optional: Docker, for running containerized
- Optional: a Discord bot token, for bot features

## Quick start

```sh
cp .example.env .env   # then fill in values
task setup             # deps.get + ecto.create + ecto.migrate
task start             # setup + run --no-halt
```

Or with plain mix:

```sh
mix setup
mix start
```

Pending migrations run automatically on every boot, so containers and
`mix run` never need a separate migrate step. The database file is
`priv/data/marketmailer.db` (gitignored); override with
`MARKETMAILER_DB` (useful for mounting a Docker volume).

## Configuration

| Variable | Required | Description |
| --- | --- | --- |
| `DISCORD_TOKEN` | No | Enables the Discord bot. If missing/invalid the bot is skipped with a warning and the rest of the app keeps running. |
| `MARKETMAILER_DB` | No | Path to the SQLite file (default: `priv/data/marketmailer.db`). |

<!-- Invite the bot to your server: -->
<!-- https://discord.com/oauth2/authorize?client_id=1473196121630314689 -->

## Features

- **Region pollers** (`Marketmailer.RegionManagerSupervisor`) — poll ESI
  market orders per region with dynamic page scaling and exponential backoff.
- **Discord bot** (`Marketmailer.BotSupervisor`) — slash commands, embeds,
  and market-update broadcasts.
- **Name resolution** — type/system/station names resolve lazily from ESI
  into local cache tables; no static data dumps needed.

## Docker

```sh
docker build -t marketmailer .
docker run --rm -p 443:443 \
  -v marketmailer-data:/data \
  -e MARKETMAILER_DB=/data/marketmailer.db \
  marketmailer
```

Or `task docker:build` / `task docker:run`.

## Development

```sh
task compile:strict   # mix compile --warnings-as-errors
task format           # check only; task format:write to write
task test
task migrate          # manual migration run
```

Run `task` with no arguments to list all tasks. See `AGENTS.md` for
architecture, database, and logging internals.
