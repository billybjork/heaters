# For PRODUCTION Environment

# -----------------------
# 1) Build stage
# -----------------------
FROM elixir:1.18.4-otp-26-slim AS build

ENV MIX_ENV=prod

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
  build-essential \
  git \
  unzip \
  python3 \
  curl \
  ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Install Bun for fast JavaScript package management and bundling
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH"

# Install uv for fast Python package management
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"

WORKDIR /app

# --- Set up Python Virtual Environment in the build stage ---
RUN uv venv /opt/venv
ENV VIRTUAL_ENV="/opt/venv"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Install Elixir tools
RUN mix local.hex --force && mix local.rebar --force

# Install Elixir dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

# Install Python dependencies into the venv
COPY py/pyproject.toml py/uv.lock ./py/
RUN uv sync --project py --frozen --no-dev --no-install-project --active

# Copy the rest of the application source
COPY . .

# Compile deps and application together (avoids MixProject recompilation conflict)
RUN mix deps.compile

# Build assets
RUN bun install --cwd ./assets
RUN bun run --cwd ./assets deploy
RUN mix phx.digest

# Create the final, self-contained release.
# The mix.exs config will copy py into the release.
RUN mix release heaters --overwrite

# -----------------------
# 2) Runtime image
# -----------------------
FROM debian:bookworm-slim AS app

# Install only essential runtime dependencies.
# The Python executable is needed to run the scripts.
RUN apt-get update && apt-get install -y --no-install-recommends \
  ca-certificates \
  libgcc-s1 \
  libstdc++6 \
  openssl \
  libncurses6 \
  python3 \
  curl \
  wget \
  xz-utils \
  && rm -rf /var/lib/apt/lists/*

# Install static FFmpeg build from GitHub (architecture-aware)
# Uses TARGETARCH from Docker buildx to select the correct binary
ARG TARGETARCH
RUN set -ex; \
    case "${TARGETARCH}" in \
      amd64) FFMPEG_ARCH="linux64" ;; \
      arm64) FFMPEG_ARCH="linuxarm64" ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}"; exit 1 ;; \
    esac; \
    FFMPEG_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-${FFMPEG_ARCH}-gpl.tar.xz"; \
    wget -q "${FFMPEG_URL}" -O /tmp/ffmpeg.tar.xz \
    && tar -xf /tmp/ffmpeg.tar.xz -C /tmp \
    && cp /tmp/ffmpeg-master-latest-${FFMPEG_ARCH}-gpl/bin/ffmpeg /usr/local/bin/ffmpeg \
    && cp /tmp/ffmpeg-master-latest-${FFMPEG_ARCH}-gpl/bin/ffprobe /usr/local/bin/ffprobe \
    && chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe \
    && rm -rf /tmp/ffmpeg* \
    && ffmpeg -version

WORKDIR /app

# Copy the compiled Elixir release from the build stage.
COPY --from=build /app/_build/prod/rel/heaters .
# Copy the entire Python virtual environment from the build stage.
COPY --from=build /opt/venv /opt/venv

# Activate the virtual environment for the runtime.
ENV PATH="/opt/venv/bin:$PATH"

# Create a non-root user to run the application securely
RUN addgroup --system app && adduser --system --ingroup app app
RUN chown -R app:app /app
USER app

ENV HOME=/app
ENV PHX_SERVER=true
ENV PORT=4000
ENV MIX_ENV=prod

EXPOSE 4000

# The command to run migrations and start the server
CMD ["/bin/sh", "-c", "bin/heaters eval 'Heaters.Release.migrate()' && exec bin/heaters start"]
