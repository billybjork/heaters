# Simplify Deployment Setup

Plan to reduce unnecessary complexity across deployment config, dependencies,
and codebase setup. Each commit is independently shippable.

---

## Commit 1: Fix broken Dockerfile CMD and switch to minimal runtime base

### Problem

Two issues in `Dockerfile`:

1. **CMD is broken.** The exec-form array doesn't interpret `;` — it passes a
   literal semicolon as an argument to the binary. Migrations may run but the
   server never starts (or it errors out silently).

   ```dockerfile
   # Current (broken)
   CMD ["bin/heaters", "eval", "Heaters.Release.migrate()", ";", "bin/heaters", "start"]
   ```

2. **Runtime image is too heavy.** The runtime stage uses `elixir:1.18.4-otp-26-slim`
   but we're running a compiled OTP release — Elixir, Mix, and IEx aren't needed
   at runtime. A plain Debian base with the Erlang runtime libs (already copied
   inside the release) is sufficient.

### Changes

**`Dockerfile`**

- Change runtime base from `elixir:1.18.4-otp-26-slim` to `debian:bookworm-slim`.
- Add only the minimal runtime packages: `libstdc++6`, `openssl`, `libncurses6`,
  `locales`, `ca-certificates`, `python3`, `curl`, `wget`, `xz-utils`.
- Fix CMD to use shell form:
  ```dockerfile
  CMD sh -c "bin/heaters eval 'Heaters.Release.migrate()' && bin/heaters start"
  ```

### Result

- Smaller production image (drops ~200MB of Elixir/Erlang tooling).
- Server actually starts after migrations.

---

## Commit 2: Remove Render, target Fly.io exclusively

### Problem

`render.yaml` deploys to Render.com. `production_deployment_guide.md` describes
Fly.io with FLAME. `runtime.exs` has ~60 lines of Render-specific logic
(RENDER_INSTANCE_ID detection, Render DB SSL handling, RENDER_EXTERNAL_HOSTNAME
fallback, sslmode URL rewriting). These two deployment targets are incompatible —
FLAME requires Fly.io Machines — and the split creates confusion.

### Changes

**Delete:**
- `render.yaml`

**`config/runtime.exs`** — rewrite the production database and endpoint sections:
- Remove `RENDER_INSTANCE_ID` detection and `is_on_render_platform` logic.
- Remove `is_render_db_host` checks and the Render-specific SSL branching
  (~30 lines of `cond` for Render vs non-Render SSL).
- Remove `RENDER_EXTERNAL_HOSTNAME` fallback for host.
- Remove `repo_url_with_sslmode` rewriting for Render URLs.
- Replace with clean Fly.io-oriented config:
  ```elixir
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL is missing for production"

  config :heaters, Heaters.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6
  ```
  SSL is handled by `DATABASE_URL` query params (Fly Postgres uses
  `sslmode=disable` inside the private network by default; external access uses
  `sslmode=require`). No special-casing needed.

- For the endpoint host, require `PHX_HOST`:
  ```elixir
  host = System.get_env("PHX_HOST") || raise "PHX_HOST must be set for prod"
  ```

- Remove all Render-mentioning comments throughout the file.
- Update comment at top of `runtime.exs` from "Render deployments" to
  "Fly.io deployments".

**`production_deployment_guide.md`:**
- Remove any remaining Render references (the guide already targets Fly.io, just
  clean up any stale mentions).

### Result

- One deployment target. No ambiguity.
- `runtime.exs` production DB config drops from ~50 lines to ~10.

---

## Commit 3: Simplify runtime.exs — remove argv parsing hack, consolidate CloudFront/S3 config

### Problem

`runtime.exs` parses `System.argv()` to detect migration commands and skip
CloudFront config. This is fragile (breaks if any argument coincidentally
contains "ecto." or "create"). It also uses a verbose `APP_ENV` case statement
with a 3-way fallback for CloudFront domain resolution (~80 lines).

### Changes

**`config/runtime.exs`:**

- **Remove `is_database_operation` hack entirely.** Replace with a simpler guard:
  ```elixir
  if config_env() == :prod do
    # CloudFront/S3 config here — only evaluated in prod releases
  end
  ```
  In dev, CloudFront config lives in `dev.exs` already. Migrations in prod run
  via `bin/heaters eval` which loads runtime.exs but doesn't need CloudFront
  to be valid — so make these configs optional with defaults rather than raising:

  ```elixir
  if config_env() == :prod do
    cloudfront_domain =
      System.get_env("CLOUDFRONT_DOMAIN") ||
        raise "CLOUDFRONT_DOMAIN must be set for production"

    s3_bucket =
      System.get_env("S3_BUCKET_NAME") ||
        raise "S3_BUCKET_NAME must be set for production"

    config :heaters,
      cloudfront_domain: cloudfront_domain,
      s3_bucket: s3_bucket,
      cloudfront_streaming_enabled: System.get_env("CLOUDFRONT_STREAMING_ENABLED", "true") == "true",
      proxy_cdn_domain: System.get_env("PROXY_CDN_DOMAIN") || cloudfront_domain,
      master_storage_class: System.get_env("MASTER_STORAGE_CLASS", "STANDARD"),
      proxy_storage_class: System.get_env("PROXY_STORAGE_CLASS", "STANDARD")
  end
  ```

- **Eliminate `APP_ENV` branching.** Currently `APP_ENV` switches between
  `DEV_CLOUDFRONT_DOMAIN` and `PROD_CLOUDFRONT_DOMAIN`. Simplify to a single
  env var per concern:
  - Production: `CLOUDFRONT_DOMAIN` (replaces `PROD_CLOUDFRONT_DOMAIN`)
  - Production: `S3_BUCKET_NAME` (replaces `PROD_S3_BUCKET_NAME`)
  - Dev already has its own config in `dev.exs`

  This eliminates the `APP_ENV` case statement, the fallback stderr warnings,
  and the MIX_ENV inference hack.

- **Remove `IO.puts` debug logging.** The 10+ `IO.puts("[Runtime.exs] ...")`
  lines are noisy in production logs. Config values should be observable via
  `Application.get_env/3` at runtime, not printed at boot.

- **Remove the "database operation" stub config.** No more
  `"database-op.cloudfront.test"` dummy values.

**`config/dev.exs`:**
- Rename `DEV_CLOUDFRONT_DOMAIN` → `CLOUDFRONT_DOMAIN` in dev env var reads
  (or keep the `DEV_` prefix for dev and just use the unprefixed version in prod —
  pick one convention). Recommendation: use `CLOUDFRONT_DOMAIN` everywhere,
  set differently per environment in `.env` / Fly secrets.

**`.env.example` (or `.env` docs):**
- Update env var names to match the simplified scheme.

### Result

- `runtime.exs` CloudFront/S3 section drops from ~130 lines to ~15.
- No more fragile argv parsing.
- No more APP_ENV case statements.
- Clean separation: dev config in `dev.exs`, prod config in `runtime.exs`.

---

## Commit 4: Consolidate Oban config to two places

### Problem

Oban queues are defined in three places with conflicting values:

| Location | Queues | CleanupWorker cron |
|----------|--------|--------------------|
| `config.exs` | 6 queues (default:10, media_processing:5, exports:5, ...) | Every 5 min |
| `dev.exs` | 4 queues (default:3, media_processing:1, ...) | Every 5 min |
| `runtime.exs` (prod) | Dynamic from `OBAN_QUEUES` env, all set to concurrency 10 | Every 4 hours |

The `runtime.exs` approach throws away the carefully tuned concurrency from
`config.exs` and replaces everything with a flat `10`. The `exports` and
`maintenance` queues from `config.exs` are silently dropped in production since
`OBAN_QUEUES` defaults to `"default"`.

### Changes

**`config/config.exs`:**
- Keep as the canonical source for queue definitions with production concurrency
  values. This is the "full" config.

**`config/dev.exs`:**
- Override only the queues that need lower concurrency for dev. No change to
  structure, just confirm it only overrides what differs.

**`config/runtime.exs`:**
- Change the production Oban override to **filter** which queues are active
  rather than **rebuilding** the concurrency map:
  ```elixir
  if config_env() == :prod do
    enabled_queues =
      "OBAN_QUEUES"
      |> System.get_env("default")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_atom/1)
      |> MapSet.new()

    # Get the base queue config from config.exs, filter to only enabled queues
    base_queues = Application.get_env(:heaters, Oban)[:queues] || []
    filtered_queues = Enum.filter(base_queues, fn {name, _} -> name in enabled_queues end)

    # Only schedule cron if "default" queue is running on this node
    plugins =
      if :default in enabled_queues do
        [
          Oban.Plugins.Pruner,
          {Oban.Plugins.Cron,
           crontab: [
             {"* * * * *", Heaters.Pipeline.Dispatcher},
             {"*/5 * * * *", Heaters.Storage.PlaybackCache.CleanupWorker}
           ]}
        ]
      else
        [Oban.Plugins.Pruner]
      end

    config :heaters, Oban,
      queues: filtered_queues,
      plugins: plugins
  end
  ```

- **Fix CleanupWorker cron discrepancy:** `config.exs` says every 5 min
  (`*/5 * * * *`), `runtime.exs` says every 4 hours (`0 */4 * * *`),
  `production_deployment_guide.md` says every 4 hours. Align to one value.
  Recommendation: every 5 minutes (matches config.exs and dev.exs; the guide
  was wrong). Update the deployment guide.

### Result

- Queue concurrency defined once in `config.exs`, respected everywhere.
- `OBAN_QUEUES` controls which queues are *active*, not their concurrency.
- Cron schedule consistent across all environments.

---

## Commit 5: Remove ExAws config duplication

### Problem

ExAws is configured in `config.exs` using `{:system, "VAR"}` tuples (which
read env vars at runtime automatically). Then `dev.exs` overwrites it with
`System.get_env("VAR")` calls (which read at compile time and bake in `nil`
if unset). The `config.exs` approach already handles runtime env vars correctly.

### Changes

**`config/dev.exs`:**
- Remove the ExAws override block entirely (lines 173-181). The base config in
  `config.exs` with `{:system, "AWS_ACCESS_KEY_ID"}` etc. already works
  correctly at runtime for all environments.
- Keep the dev-specific S3 host override only if the region-specific hostname
  (`s3.us-west-1.amazonaws.com`) is actually needed for dev. If not, remove
  that too and let ExAws use its default host resolution.

### Result

- ExAws configured in one place.
- No compile-time env var reads for AWS credentials.

---

## Commit 6: Replace ffmpex/rambo with System.cmd

### Problem

The entire Rust toolchain (~500MB in the build layer, significant build time)
is installed in both Dockerfiles solely because `ffmpex` depends on `rambo`
(a Rust NIF for process execution). Meanwhile, half the codebase already uses
`System.cmd` for FFmpeg/FFprobe calls directly.

### Scope

FFmpex is used in exactly **2 files**:
- `lib/heaters/processing/support/ffmpeg/runner.ex` — clip creation, keyframe extraction
- `lib/heaters/processing/encode/video_processing.ex` — proxy/master encoding

Both use FFmpex as a command builder that ultimately produces `{executable, args}`.
The `config.ex` module already generates raw argument lists for all profiles.

### Changes

**`lib/heaters/processing/support/ffmpeg/runner.ex`:**
- Remove `import FFmpex` and `use FFmpex.Options`.
- Replace `FFmpex.new_command() |> add_input_file(...) |> ... |> FFmpex.execute()`
  with direct argument list construction and `System.cmd(ffmpeg_bin, args)`.
- The `create_video_clip/5` function builds args like:
  ```elixir
  args = ["-ss", start_time, "-i", input_path, "-t", duration,
          "-map", "0:v:0?", "-map", "0:a:0?"] ++ profile_args ++ ["-y", output_path]
  System.cmd(ffmpeg_bin(), args, stderr_to_stdout: true)
  ```
- Similarly convert `extract_keyframes_by_timestamp/4`.
- Keep `get_video_metadata/2` and `get_video_fps/1` unchanged (already System.cmd).

**`lib/heaters/processing/encode/video_processing.ex`:**
- Remove `import FFmpex` and `use FFmpex.Options`.
- Replace `build_ffmpeg_command/3` with direct argument list construction.
- For `execute_ffmpeg_with_progress/4`, replace `FFmpex.prepare(command)` with
  the argument list directly — the Port-based progress monitoring already works
  with raw args.
- Update the `@spec` annotations to use `{String.t(), [String.t()]}` instead of
  `FFmpex.Command.t()`.

**Create `lib/heaters/processing/support/ffmpeg/command.ex`** (optional helper):
- If there's value in a thin builder abstraction, create a simple module that
  constructs argument lists without any NIF dependency. But given the usage is
  straightforward, inline argument construction in each function is fine and
  simpler.

**`mix.exs`:**
- Remove `{:ffmpex, "~> 0.11.0"}` from deps.

**`Dockerfile` and `Dockerfile.dev`:**
- Remove Rust installation (4 lines: curl rustup, ENV PATH, rustc --version).
- Remove the "Install Rust for rambo compilation" comments.

**Run `mix deps.unlock ffmpex rambo` and `mix deps.get`** to clean up mix.lock.

### Result

- No Rust toolchain in Docker builds.
- Faster builds (Rust compilation of rambo takes 1-2 minutes).
- Smaller build layer.
- Two fewer dependencies in mix.lock (ffmpex + rambo).
- The code is actually more direct — you can see the exact FFmpeg args being
  passed without navigating through a DSL.

---

## Commit 7: Replace PyTorch with ONNX Runtime for embeddings

### Problem

`torch==2.6.0` is ~2GB (full CUDA-capable PyTorch) and `transformers==4.51.0`
pulls in additional heavy dependencies. These are used in exactly one place:
`py/tasks/embed.py` for generating CLIP and DINOv2 image embeddings on CPU.

### Scope

The embedding task (`py/tasks/embed.py`, 272 lines) does:
1. Load a CLIP or DINOv2 model via `transformers`
2. Preprocess images with the model's processor
3. Run inference with `torch.no_grad()`
4. Return embedding vectors as lists

No other Python task uses PyTorch or transformers. `detect_scenes.py` is pure
OpenCV. `download.py` is pure yt-dlp.

### Changes

**Pre-work: Export models to ONNX format.**
- Export `openai/clip-vit-base-patch32` vision encoder to ONNX.
- Export any DINOv2 variants in use to ONNX.
- Host the `.onnx` files in S3 (or bundle in the Docker image under `py/models/`).
- This can be done with a one-time script using `optimum` or `torch.onnx.export`.
  The script itself doesn't need to ship in prod — it's a dev/CI artifact.

**`py/tasks/embed.py`:**
- Replace PyTorch model loading with `onnxruntime.InferenceSession(model_path)`.
- Replace `CLIPProcessor` preprocessing with equivalent PIL/numpy operations
  (CLIP preprocessing is: resize to 224x224, center crop, normalize with
  specific mean/std values — straightforward to implement directly).
- Replace `model.get_image_features()` with `session.run(None, {"pixel_values": inputs})`.
- Keep the same external interface (accepts image paths, returns embedding list).
- Keep model caching (cache `InferenceSession` objects instead of PyTorch models).
- Keep support for both CLIP and DINOv2 model families.

**`py/requirements.txt`:**
- Remove: `torch==2.6.0`, `transformers==4.51.0`, `accelerate==1.10.0`
- Add: `onnxruntime==1.21.0` (~50MB vs ~2GB for torch)
- Keep: `Pillow`, `numpy` (needed for image preprocessing)
- Keep: `yt-dlp`, `opencv-python-headless` (unrelated)

**`py/models/` directory:**
- Add pre-exported ONNX model files (or a download script that fetches them
  on first use from S3/HuggingFace).
- Add the preprocessing config (image size, normalization values) as a small
  JSON file per model to avoid hardcoding.

**Elixir side (no changes needed):**
- `Heaters.Processing.Embed.Worker` calls `PyRunner.run_python_task("embed", args)`
  — the interface is unchanged. The Python task still returns the same JSON
  structure.

### Verification

- Compare ONNX outputs against PyTorch outputs for a sample of images.
  Embeddings should match within float32 tolerance (~1e-6).
- Run the existing embedding pipeline end-to-end with the new implementation.

### Result

- Docker image shrinks by ~2GB.
- Build time drops significantly (no PyTorch wheel download/install).
- Inference speed is comparable or faster (ONNX Runtime is optimized for CPU).
- Three fewer Python dependencies.

---

## Commit 8: Fix hardcoded macOS FFmpeg path and minor mix.exs issues

### Problem

Several small issues that are quick to fix:

1. `dev.exs` defaults FFmpeg to `/opt/homebrew/bin/ffmpeg` — only works on
   Apple Silicon Macs. Anyone on Linux or Intel Mac needs to set an env var.

2. `mix.exs` has `include_executables: true` in the release config — this is
   not a valid option for `mix release`. The correct option is
   `include_executables_for: [:unix]` (which is the default, making the line
   unnecessary).

3. `mix.exs` has `compilers: [:phoenix_live_view] ++ Mix.compilers()` — Phoenix
   1.8 / LiveView 1.1 no longer requires a custom compiler entry.

4. `config.exs` has `live_view: [signing_salt: "KWvQc1I2"]` hardcoded —
   this should use a proper secret in production.

### Changes

**`config/dev.exs`:**
- Replace the FFmpeg default:
  ```elixir
  # Before
  else: System.get_env("FFMPEG_BIN") || "/opt/homebrew/bin/ffmpeg"

  # After
  else: System.get_env("FFMPEG_BIN") || System.find_executable("ffmpeg") || "ffmpeg"
  ```

**`mix.exs`:**
- Remove `include_executables: true` from the release config (or replace
  with nothing — the default behavior is correct).
- Remove `:phoenix_live_view` from the `compilers` list. Use the default:
  ```elixir
  # Before
  compilers: [:phoenix_live_view] ++ Mix.compilers(),

  # After (just remove the line — Mix.compilers() is the default)
  ```

**`config/config.exs`:**
- Change the LiveView signing salt to be read from config or generate a proper
  one. For dev/test a hardcoded value is fine, but prod should use an env var.
  Since `runtime.exs` configures the full endpoint for prod, and the endpoint
  config there doesn't currently set `live_view`, add:
  ```elixir
  # In runtime.exs, inside the prod block:
  live_view_salt = System.get_env("LIVE_VIEW_SIGNING_SALT") || secret_key_base
  ```
  Or simply derive it from `SECRET_KEY_BASE` (Phoenix does this automatically
  if not explicitly set in newer versions — verify this).

### Result

- FFmpeg works on any platform without manual env var setup.
- Clean mix.exs without invalid/unnecessary options.
- Proper signing salt in production.

---

## Commit 9: Optimize Docker Compose dev startup

### Problem

The dev container command re-runs `mix deps.get` and `bun install` on every
start. Since the app directory is volume-mounted, deps persist between restarts,
making this wasteful. Also `mix ecto.create` prints a noisy error when the
database already exists.

### Changes

**`docker-compose.yaml`:**
- Replace the inline command with an entrypoint script or a smarter command:
  ```yaml
  command: >
    sh -c "
      mix ecto.migrate &&
      mix phx.server
    "
  ```
- Move `mix deps.get` and `bun install` to run only when needed (on first build
  or when explicitly triggered). Since the volume mount persists `_build/`,
  `deps/`, and `assets/node_modules/`, these only need to run after dependency
  changes.
- Alternatively, add a lightweight entrypoint script at `bin/dev-entrypoint.sh`:
  ```bash
  #!/bin/sh
  set -e

  # Install deps only if not already present
  [ -d deps ] || mix deps.get
  [ -d assets/node_modules ] || bun install --cwd assets

  mix ecto.create 2>/dev/null || true
  mix ecto.migrate
  exec mix phx.server
  ```

### Result

- Dev container starts faster on subsequent runs.
- No noisy "database already exists" errors.

---

## Commit 10: Switch FFmpeg download source to BtbN GitHub releases

### Problem

The production Dockerfile downloads static FFmpeg from `johnvansickle.com` — an
individual's personal server with no uptime SLA. If it goes down, builds break.

### Changes

**`Dockerfile`:**
- Replace the FFmpeg download with BtbN's GitHub releases (same static builds,
  hosted on GitHub infrastructure):
  ```dockerfile
  RUN wget -q https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz \
    && tar -xf ffmpeg-master-latest-linux64-gpl.tar.xz \
    && cp ffmpeg-master-latest-linux64-gpl/bin/ffmpeg /usr/local/bin/ffmpeg \
    && cp ffmpeg-master-latest-linux64-gpl/bin/ffprobe /usr/local/bin/ffprobe \
    && chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe \
    && rm -rf ffmpeg-* \
    && ffmpeg -version
  ```
- Or pin to a specific release tag for reproducibility instead of `latest`.

### Result

- Builds don't depend on a personal server's availability.
- Same FFmpeg quality (static GPL build with all codecs).

---

## Commit order and dependencies

Commits are ordered to minimize conflicts:

1. **Fix Dockerfile CMD + minimal runtime base** — foundational correctness
2. **Remove Render** — simplifies runtime.exs for subsequent commits
3. **Simplify runtime.exs** — depends on Render removal being done first
4. **Consolidate Oban** — cleaner after runtime.exs simplification
5. **Remove ExAws duplication** — independent but cleaner after the above
6. **Replace ffmpex with System.cmd** — independent, largest code change
7. **PyTorch → ONNX Runtime** — independent, largest dependency change
8. **Fix FFmpeg path + mix.exs cleanup** — small, independent fixes
9. **Optimize Docker Compose startup** — independent
10. **Switch FFmpeg download source** — independent

Commits 6-10 can be done in any order. Commits 1-5 are best done sequentially.

---

## Net impact

| Metric | Before | After |
|--------|--------|-------|
| Production image size | ~4GB+ (PyTorch + Elixir runtime + Rust artifacts) | ~1.5-2GB |
| Build dependencies | Elixir + Rust + Python + Bun | Elixir + Python + Bun |
| Deployment targets | Render + Fly.io (contradictory) | Fly.io only |
| runtime.exs lines | ~347 | ~100 estimated |
| Oban config locations | 3 (conflicting) | 2 (complementary) |
| ExAws config locations | 2 (conflicting) | 1 |
| FFmpex/rambo deps | 2 packages + Rust toolchain | 0 |
| Python ML deps | torch + transformers + accelerate (~2.5GB) | onnxruntime (~50MB) |
