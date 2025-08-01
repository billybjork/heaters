# For PRODUCTION Environment

# -----------------------
# 1) Build stage
# -----------------------
FROM elixir:1.16.2-otp-26-slim AS build

ENV MIX_ENV=prod

# Install system dependencies (including Rust for rambo/FFmpex)
RUN apt-get update && apt-get install -y --no-install-recommends \
  build-essential \
  git \
  nodejs \
  npm \
  python3 \
  python3-pip \
  python3-venv \
  curl \
  && rm -rf /var/lib/apt/lists/*

# Install Rust for rambo compilation BEFORE installing Elixir dependencies
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:$PATH"

# Verify Rust installation
RUN rustc --version && cargo --version

WORKDIR /app

# --- Set up Python Virtual Environment in the build stage ---
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install Elixir tools
RUN mix local.hex --force && mix local.rebar --force

# Install Elixir dependencies (with Rust now available for rambo compilation)
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Install Python dependencies into the venv
COPY py/requirements.txt ./py/requirements.txt
RUN pip install --no-cache-dir -r py/requirements.txt

# Copy the rest of the application source
COPY . .

# Build assets
RUN npm install --prefix ./assets
RUN npm run --prefix ./assets deploy
RUN mix phx.digest

# Create the final, self-contained release.
# The mix.exs config will copy py into the release.
RUN mix release heaters --overwrite

# -----------------------
# 2) Runtime image
# -----------------------
FROM elixir:1.16.2-otp-26-slim AS app

# Install only essential runtime dependencies.
# The Python executable is needed to run the scripts.
RUN apt-get update && apt-get install -y --no-install-recommends \
  openssl \
  libncurses6 \
  python3 \
  curl \
  wget \
  xz-utils \
  && rm -rf /var/lib/apt/lists/*

# Install OpenSSL-enabled static FFmpeg build to fix CloudFront TLS issues
RUN wget -q https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz \
  && tar -xf ffmpeg-release-amd64-static.tar.xz \
  && cp ffmpeg-*-amd64-static/ffmpeg /usr/local/bin/ffmpeg \
  && cp ffmpeg-*-amd64-static/ffprobe /usr/local/bin/ffprobe \
  && chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe \
  && rm -rf ffmpeg-* \
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
CMD ["bin/heaters", "eval", "Heaters.Release.migrate()", ";", "bin/heaters", "start"]