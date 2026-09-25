# Marketmailer command and broadcast TODO

Status: in progress. Tasks 1–4 are complete; task 5 is next.

## Decisions captured

- `/check_market` accepts a required **item-name string** and matches it case-insensitively.
- A market refresh is considered complete only after all expected pages for a region finish a refresh cycle.
- The list-market feature will get a real SQLite database view, not only a Discord presentation change.
- Captured Janice PNGs will be delivered as Discord attachments (`attachment://...`).
- Implementation will proceed one task at a time. Each task must pass its checks and receive its own commit before the next task starts.

## Execution rule

For every task:

1. Implement only that task.
2. Add/update focused tests.
3. Run formatting, compilation, and the relevant test suite.
4. Inspect `git diff` and `git status`.
5. Commit with the task's message below.
6. Stop and report the commit before beginning the next task.

Do not squash these commits.

## TODOs

- [x] **1. Add item-name lookup to `/check_market`** (commit `83bdde4`)
  - Add a required Discord string option named `item` to the `check_market` application command.
  - Extract and validate the option safely; trim whitespace and handle missing/malformed values.
  - Add a `Market.Database` API that resolves an exact, case-insensitive EVE item name through the `names` cache, backfills unresolved type names when possible, and returns one market item/order using the same shape consumed by `market_embed/1`.
  - Define the result as the best cached remote sell opportunity for the requested type; return `nil` when the type has no matching market order.
  - Add a specific `market_not_found_embed/1` instead of reusing the generic error message.
  - Keep the existing static thumbnail as the temporary fallback until task 3 is complete.
  - Test command-option extraction, case-insensitive matching, known items, unknown names, and names with no market orders.
  - Commit: `feat: add item lookup to check market`

- [x] **2. Add the SQL view for `/list_market`** (commit `af4e1cb`)
  - Add a standard Ecto migration that creates a SQLite view for rows undercutting the Jita buy wall, with a reversible `DROP VIEW` path.
  - Include the raw `type_id`, `system_id`, and `location_id` columns so the existing lazy EVE-name/system backfill still works.
  - Move the Jita-best-buy and remote-sell join/margin logic into the view; apply the top-100 limit in the consuming query so the view remains reusable.
  - Update `Market.Database.get_items_less_than_jita_buy/0` to read the view and retain backfill/retry behavior.
  - Add a view schema or typed row module if needed by the existing loader.
  - Test migration up/down, view rows, ordering/limit behavior, and unresolved-name backfill.
  - Commit: `feat: add market list database view`

- [x] **3. Capture and attach the Janice graph** (commit `e12ca4e`)
  - Add a supervised browser-capture module (using a pinned Playwright client) and install the required browser/runtime in the Docker image.
  - Navigate to `https://janice.e-351.com/i/<type_id>/market/2`, wait for the rendered chart/canvas rather than a fixed sleep, capture the chart element as PNG, and always close/clean up the browser page.
  - Put the capture behind a small injectable interface so command and broadcast code can be tested without a live browser.
  - Set the embed thumbnail URL to an `attachment://...` URL and pass the PNG binary as a Nostrum file map to `Interaction.create_response/2` or `Message.create/2`.
  - Respect Discord's interaction deadline: use a deferred response or an initial fallback response followed by an edit/follow-up when capture takes longer than the deadline.
  - On capture timeout/site failure, log a warning and use the existing static thumbnail; an existing market item should not be converted into a false “not found” result solely because Janice was unavailable.
  - Test success, timeout, capture failure, attachment naming, and thumbnail fallback paths.
  - Commit: `feat: capture Janice market charts`

- [x] **4. Coordinate completed region refresh cycles** (commit `a98ab69`)
  - Add a market-update coordinator (a supervised GenServer is preferred) separate from individual page workers.
  - Have page workers report terminal fetch results (`200`, `304`, and failures) to the coordinator after persistence.
  - Track the expected page set from `x-pages`; reset state safely when page counts change or workers restart.
  - Emit exactly one `region_refresh_complete` event per completed cycle. A cycle is successful when all expected pages return successfully and at least one page returned `200`; a `304`-only cycle is a successful poll but does not produce an update broadcast.
  - Define a bounded failure/deadline path so a permanently failing page cannot leave a cycle pending forever; include region/page/reason in the event without leaking sensitive data.
  - Test first completion, duplicate worker reports, page-count changes, all-304 cycles, mixed 200/304 cycles, and failure completion.
  - Commit: `feat: coordinate completed market refreshes`

- [ ] **5. Broadcast successful updates and failures to Discord**
  - Add a database function that returns all registered alert channels and a broadcaster/consumer path that sends through the active Nostrum bot.
  - On each completed successful region refresh, query the current best-order result and send the success market embed (including the captured graph attachment when available) to every registered channel.
  - On a failed refresh or when no market item can be produced, send a clear failure embed containing the region/page/reason.
  - Do not broadcast `304`-only cycles; do not crash ESI workers when Discord is disabled, unavailable, rate-limited, or has no registered channels.
  - Use `allowed_mentions: :none` for generated messages and handle/log API errors without leaking the Discord token.
  - Make broadcast delivery idempotent per completed cycle and avoid duplicate messages from retries.
  - Test success delivery, failure delivery, multiple channels, no channels, missing bot, API failure, and duplicate-cycle suppression with mocked Discord/database calls.
  - Commit: `feat: broadcast market updates to Discord`

- [ ] **6. Final integration verification**
  - Run the formatter in write mode, `mix compile --warnings-as-errors`, the full test suite, and the migration up/down checks.
  - Verify a clean `git status`, review all commits independently, and document any required Docker/environment setup in `.example.env` or the project README if task 3 introduces runtime requirements.
  - Do not create a catch-up “misc fixes” commit; fix any issue in the task that owns it and amend only that task's commit before proceeding.
  - Gate: `git log --oneline` shows the five task commits in order and the working tree is clean.
