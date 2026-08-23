# syntax=docker/dockerfile:1
#
# Build:   sudo docker build -t marketmailer .
# Run:     sudo docker run --rm -p 443:443 \
#            -v marketmailer-data:/data \
#            -e MARKETMAILER_DB=/data/marketmailer.db \
#            marketmailer
#
# The app polls ESI market orders into SQLite. Pending migrations run
# automatically on boot. Discord/email are disabled by default; pass
# DISCORD_TOKEN / RESEND_TOKEN / EMAIL to enable them (see lib/app.ex).

FROM elixir:1.20

ENV MIX_ENV=prod \
	TERM=dumb \
	MARKETMAILER_DB=marketmailer.db

# shared mix home so the non-root runtime user can see hex/rebar archives
ENV MIX_HOME=/usr/local/share/mix
RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app

# fetch dependencies first so this layer survives source edits
COPY mix.exs mix.lock ./
RUN mix deps.get

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
