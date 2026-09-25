# syntax=docker/dockerfile:1
#
# Build:   sudo docker build -t marketmailer .
# Run:     sudo docker run --rm -p 443:443 \
#            -v marketmailer-data:/data \
#            -e MARKETMAILER_DB=/data/marketmailer.db \
#            marketmailer
#
# The app polls ESI market orders into SQLite. Pending migrations run
# automatically on boot. Discord is disabled by default; pass
# DISCORD_TOKEN to enable it (see lib/app.ex). Error events are appended
# to ./logs/errors.jsonl (wiped on every boot). Janice chart capture uses
# the Playwright runtime installed below and falls back to the static image
# when that runtime is unavailable.

FROM node:22-bookworm-slim AS playwright

ARG PLAYWRIGHT_VERSION=1.63.0
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
WORKDIR /opt/playwright
RUN npm init -y && npm install --save-exact playwright@${PLAYWRIGHT_VERSION}

FROM elixir:1.20

ENV MIX_ENV=prod \
	TERM=dumb \
	MARKETMAILER_DB=marketmailer.db \
	PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
	PLAYWRIGHT_EXECUTABLE=playwright \
	PATH=/opt/playwright/node_modules/.bin:/usr/local/bin:${PATH}

# Copy Node and the Playwright CLI from the Node image so the runtime does not
# depend on the host having Node installed.
COPY --from=playwright /usr/local/bin/node /usr/local/bin/node
COPY --from=playwright /opt/playwright /opt/playwright

# shared mix home so the non-root runtime user can see hex/rebar archives
ENV MIX_HOME=/usr/local/share/mix
RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app

# fetch dependencies first so this layer survives source edits
COPY mix.exs mix.lock ./
RUN mix deps.get

# Install Chromium and its system libraries in the final image.
RUN mkdir -p /ms-playwright \
	&& playwright install --with-deps chromium \
	&& rm -rf /var/lib/apt/lists/*

# compile the application
COPY . .
RUN mix compile

# drop privileges; MARKETMAILER_DB must point somewhere writable
RUN useradd --system --create-home app \
	&& chown -R app:app /app \
	&& mkdir -p /data \
	&& chown app:app /data
USER app

EXPOSE 443
CMD ["mix", "run", "--no-halt"]
