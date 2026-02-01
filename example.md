# marketmailer

OTP application that continuously syncs EVE market data for many regions, using supervision, GenServers, ETS, and Postgres.

## Architecture overview
```sh
The system is a supervised tree:

- Each region has a dedicated worker GenServer.
- Managed by `RegionDynamicSupervisor`.
- Orchestrated by `RegionManager`.
- ETag caching backed by ETS and Postgres to efficiently poll and upsert market orders over time.
```
## Top-level application

**Marketmailer.Application**

```sh
- Starts the Ecto repo Marketmailer.Database (connection to Postgres).
- Starts a Registry for naming worker processes by region.
- Starts Marketmailer.RegionDynamicSupervisor (to manage region workers).
- Starts Marketmailer.RegionManager (to orchestrate which regions get workers).
```

### Supervision tree

```sh
- Repo (DB)
- Registry
- RegionDynamicSupervisor
- RegionManager
```

## Manager (orchestrator)

**Marketmailer.RegionManager**

```sh
- GenServer that knows the list of region IDs (@regions).
- On init, it sends itself {:start_workers, @regions}.
- In handle_info/2, it:
  - Takes [region | rest], starts a worker for region via the DynamicSupervisor.
  - Schedules another message {:start_workers, rest} in 100 ms.

**Effect:** workers are started gradually (throttled), not all at once, until every region has its own worker process.
```

### Region dynamic supervisor

**Marketmailer.RegionDynamicSupervisor**

```sh
- It doesn’t have a static child list; instead it exposes start_child(region_id).
- For each region, start_child/1 creates a Marketmailer.RegionWorker with that region ID.
- If a RegionWorker crashes (depending on restart settings), the DynamicSupervisor handles restarting it.

**This gives you one long-lived worker process per region, managed under OTP supervision.**
```

## Worker

**Marketmailer.RegionWorker**

```sh
a GenServer whose job is:
- Periodically fetch market orders for its region from ESI.
- Use ETag + If-None-Match to avoid unnecessary data transfers.
- Upsert orders into Postgres.
- Decide when to fetch next, based on HTTP Expires (TTL).
```

### Key flow

```sh
init/1:
- Stores the region_id in state, sends itself :work immediately.

handle_info(:work, state):
- Calls fetch_region(region_id) which returns a delay (ms) until the next check.
- Schedules the next :work using Process.send_after/3 with delay + 2000 (buffer).

fetch_region/1:
- Builds region URL.
- Calls fetch_page(url, region_id, 1).
- On success, returns TTL. On error, falls back to 60 seconds.

fetch_page/3:
- Looks up ETag for this URL in ETS/DB.
- Sends HTTP request with optional If-None-Match.
- If status 304:
  - No new data; compute TTL from headers and return.
- If status 200:
  - Extract new ETag, save it (ETS + DB).
  - Upsert all orders into DB.
  - If this is page 1, spawn parallel tasks to fetch pages 2..N.
  - Compute TTL and return.
```

### Polling logic

Each region worker implements a repeating fetch cycle:

```sh
- fetch → decide next fetch delay based on TTL → sleep → repeat.
```

### HTTP TTL and date parsing

**calculate_ttl/1**:
```sh
- Reads the Expires header.
- Parses it as an HTTP date.
- Computes milliseconds until expiry.
- Falls back to default (e.g., 5 minutes) if missing or invalid.
- Ensures a minimum delay (e.g., 30 seconds) to handle clock skew or expired dates.
```

This TTL influences the worker’s scheduling, dictating the polling cadence.

### ETag caching and ETS + DB

```sh
- Uses ETS table `:market_etags` to cache ETags in memory, keyed by URL.
- **get_etag_with_fallback/1**:
  - Checks ETS first.
  - If not found, queries Postgres via `Marketmailer.Database.get(Etag, url)`.
  - On DB hit, warms ETS and returns ETag.
- **save_etag/2**:
  - Writes ETag to ETS.
  - Upserts into Postgres (with conflict resolution) to persist across restarts.
```
**Benefits:**

```sh
- Fast in-memory lookups.
- Persistence via database.
```

## Database schemas

### Market schema

```sh
- Represents a market order record with fields like order_id, price, volume_total, etc.
```

### upsert_orders/3

```sh
- Normalizes incoming JSON maps (string keys → atoms).
- Adds inserted_at and updated_at timestamps.
- Inserts in chunks (`insert_all`) with `on_conflict` upsert keyed by `order_id`.
- Only updates a selected set of fields and `updated_at`, preserving original `inserted_at`.
```

### Etag schema

```sh
- Primary key is `url`.
- Stores the current etag string plus timestamps.
- Used by the ETag caching logic as the persistent store.
```

---

## Naming and introspection

```sh
Registry is used to give each RegionWorker a stable, named identifier:
- Name pattern: {:via, Registry, {Marketmailer.Registry, {:region, region_id}}}.
- Enables finding or sending messages to a specific region worker by its region ID.
```

---
