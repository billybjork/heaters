# -----------------------
# 1) Node stage: build JS assets
# -----------------------
FROM node:18-slim AS node_build

WORKDIR /app/assets

# Copy package manifests explicitly (no brace-expansion)
COPY ["assets/package.json", "assets/package-lock.json", "./"]
COPY assets/js           ./js
COPY assets/css          ./css
COPY assets/postcss.config.js ./

RUN mkdir -p ../priv/static/assets \
 && npm ci \
 && npm run deploy

# -----------------------
# 2) Elixir build stage: compile + release
# -----------------------
FROM hexpm/elixir:1.16.2-erlang-26.2.4-alpine-3.19.1 AS build

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /app

RUN apk add --no-cache build-base git

COPY mix.exs mix.lock ./
RUN mix local.hex --force \
  && mix local.rebar --force \
  && mix deps.get --only prod \
  && mix deps.compile

# Bring in compiled assets from the node stage
COPY --from=node_build /app/priv/static/assets ./priv/static/assets

COPY lib       ./lib
COPY config    ./config
COPY priv/repo ./priv/repo
RUN mix compile \
 && mix release --overwrite

# -----------------------
# 3) Runtime image: slim Elixir release container
# -----------------------
FROM alpine:3.19.1 AS app

# Install runtime dependencies
RUN apk add --no-cache \
      openssl \
      ca-certificates \
      libstdc++ \
      libgcc \
      ncurses \
    && update-ca-certificates

ENV PHX_SERVER=true
ENV PORT=4000
ENV MIX_ENV=prod

WORKDIR /app
COPY --from=build /app/_build/prod/rel/frontend ./

EXPOSE 4000

# Run migrations, then start the server
CMD ["sh", "-c", "/app/bin/frontend eval 'Frontend.Release.migrate()' && /app/bin/frontend start"]