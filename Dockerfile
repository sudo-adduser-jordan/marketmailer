FROM node:22-bookworm-slim AS playwright

ARG PLAYWRIGHT_VERSION=1.63.0
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
WORKDIR /opt/playwright
RUN npm init -y && npm install --save-exact playwright@${PLAYWRIGHT_VERSION}

FROM elixir:1.20

ENV MIX_ENV=prod \
	TERM=dumb \
	MARKETMAILER_DB=/data/marketmailer.db \
	ERL_CRASH_DUMP=logs/erl_crash.dump \
	PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
	PATH=/opt/playwright/node_modules/.bin:/usr/local/bin:${PATH}

COPY --from=playwright /usr/local/bin/node /usr/local/bin/node
COPY --from=playwright /opt/playwright /opt/playwright

ENV MIX_HOME=/usr/local/share/mix
RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app

COPY mix.exs mix.lock ./
COPY config config/
RUN mix deps.get --only prod

RUN mkdir -p /ms-playwright \
	&& playwright install --with-deps chromium \
	&& rm -rf /var/lib/apt/lists/*

COPY . .
RUN mix release

RUN useradd --system --create-home app \
	&& chown -R app:app /app \
	&& mkdir -p /data /app/logs \
	&& chown app:app /data /app/logs
USER app

EXPOSE 443 4000
CMD ["/app/_build/prod/rel/marketmailer/bin/marketmailer", "foreground"]
