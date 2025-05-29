# -----------------------
# 1) Node stage: build JS assets
# -----------------------
FROM node:18-slim AS node_build

WORKDIR /app/assets

# Copy only what we need for npm
COPY assets/package.json assets/package-lock.json ./
COPY assets/js     ./js
COPY assets/css    ./css
COPY assets/postcss.config.js ./postcss.config.js

# Ensure output dir exists for esbuild
RUN mkdir -p ../priv/static/assets

# Install deps & bundle
RUN npm ci
RUN npm run deploy

# -----------------------
# 2) Elixir build stage: compile + release
# -----------------------
FROM hexpm/elixir:1.16.2-erlang-26.2.4-alpine-3.19.1 AS build

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /app

# Install build tools
RUN apk add --no-cache build-base git

# 2a) Get Elixir deps
COPY mix.exs mix.lock ./
RUN mix local.hex --force \
  && mix local.rebar --force \
  && mix deps.get --only prod \
  && mix deps.compile

# 2b) Bring in compiled assets
COPY --from=node_build /app/priv/static/assets ./priv/static/assets

# 2c) Copy over code & compile
COPY lib       ./lib
COPY config    ./config
COPY priv/repo ./priv/repo
RUN mix compile

# 2d) Build the release
RUN mix release --overwrite

# -----------------------
# 3) Runtime image: slim Elixir release container
# -----------------------
FROM alpine:3.19.1 AS app

# Needed for SSL, compression, etc.
RUN apk add --no-cache openssl ca-certificates

WORKDIR /app

# Copy only the release folder in
COPY --from=build /app/_build/prod/rel/frontend ./

# Copy your entrypoint that calls `bin/frontend`
COPY entrypoint.sh .

RUN chmod +x entrypoint.sh
EXPOSE 4000

ENTRYPOINT ["./entrypoint.sh"]