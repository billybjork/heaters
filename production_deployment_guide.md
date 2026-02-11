# Production Deployment Guide

## Overview

Heaters deploys on Fly.io with the FLAME pattern for elastic, scale-to-zero media processing. PostgreSQL for persistence, AWS S3/CloudFront for media storage, and Oban for durable background jobs. Clip playback uses pre-generated temp files via FFmpeg stream copy — there is no on-demand FFmpeg streaming in the request path.

## Architecture

```
Browser → CloudFront (signed URLs) → S3 Proxy Files
                                          ↑
Phoenix App (Fly.io) → Oban Jobs → FLAME.call(Runner, fn -> FFmpeg/Python work end)
       ↓                                ↓
  PostgreSQL (Fly.io)        Ephemeral Fly Machine (same Docker image)
                             └─ boots, runs work, uploads to S3, shuts down
```

**Key Technologies:**
- **Application**: Phoenix LiveView on Fly.io (Docker)
- **Elastic Compute**: FLAME — ephemeral Fly Machines for CPU-heavy work
- **CDN/Storage**: AWS S3 + CloudFront (presigned URLs for proxy files)
- **Database**: PostgreSQL with pgvector on Fly.io
- **Background Jobs**: Oban with queue-based worker separation
- **Media Processing**: FFmpeg (libx264 encoding, stream copy for clips), Python (scene detection, embeddings)

## FLAME

FLAME (`{:flame, "~> 0.5"}`) boots a **full copy of your application** on an
ephemeral Fly.io Machine, sends a function closure via Erlang distribution, and
tears the machine down when idle. The remote node has your entire app context —
Repo, PubSub, config — so closures Just Work.

- ~3 second cold-start on Fly.io (boots your Docker image via Machines API)
- `FLAME.Terminator` monitors parent connection; auto-destroys on disconnect
- `FLAME.LocalBackend` for dev/test (executes closures in-process, no infra needed)

### Which Workers to Wrap with FLAME

| Worker | Queue | Bottleneck | FLAME? | Why |
|--------|-------|------------|--------|-----|
| Encode (proxy/master) | `media_processing` | CPU (libx264, minutes) | **Yes — highest value** | Heaviest CPU workload, bursty |
| Scene detection | `media_processing` | CPU (OpenCV, full video) | **Yes** | Long-running, blocks queue |
| Export | `exports` | I/O (stream copy + S3 upload) | **Yes** | Benefits from elastic scaling |
| Keyframe extraction | `background_jobs` | CPU-light (FFmpeg JPEG) | Optional | Fast already, low priority |
| Temp clip generation | `temp_clips` | I/O (stream copy, instant) | Optional | Already sub-second; FLAME would eliminate cleanup concerns |
| Embeddings | `background_jobs` | CPU (PyTorch CLIP ViT-Base) | No | Fast on CPU at current volume; revisit if moving to larger models |
| Download | `media_processing` | Network I/O | No | FLAME adds no value to network-bound work |

### Integration Pattern

Oban owns job durability, retries, scheduling, and observability.
FLAME wraps the expensive compute inside the worker's `perform/1`:

```elixir
# In an Oban worker
def perform(%Oban.Job{args: %{"video_id" => video_id}}) do
  video = Repo.get!(SourceVideo, video_id)

  FLAME.call(Heaters.MediaRunner, fn ->
    # This closure runs on an ephemeral Fly Machine.
    # Repo, PubSub, and all app config are available.
    Encoder.encode_proxy(video)
  end)
end
```

### Pool Configuration

```elixir
# mix.exs
{:flame, "~> 0.5"}

# config/runtime.exs (prod only)
config :flame, :backend, FLAME.FlyBackend
config :flame, FLAME.FlyBackend,
  token: System.fetch_env!("FLY_API_TOKEN"),
  env: %{
    "DATABASE_URL" => System.fetch_env!("DATABASE_URL"),
    "SECRET_KEY_BASE" => System.fetch_env!("SECRET_KEY_BASE"),
    "PROD_S3_BUCKET_NAME" => System.fetch_env!("PROD_S3_BUCKET_NAME"),
    "PROD_CLOUDFRONT_DOMAIN" => System.fetch_env!("PROD_CLOUDFRONT_DOMAIN"),
    "AWS_ACCESS_KEY_ID" => System.fetch_env!("AWS_ACCESS_KEY_ID"),
    "AWS_SECRET_ACCESS_KEY" => System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
    "POOL_SIZE" => "1"
  }

# application.ex — add pool to supervision tree
# Single pool for all media processing (encoding, scene detection, export)
{FLAME.Pool,
 name: Heaters.MediaRunner,
 min: 0,              # scale to zero when idle
 max: 5,              # max concurrent machines
 max_concurrency: 1,  # one heavy job per machine (encoding is CPU-bound)
 idle_shutdown_after: 30_000}  # 30s idle before teardown
```

Key details:
- Set `min: 0` for scale-to-zero (cost: ~3s cold start on first call)
- Set `min: 1` to keep a warm runner and eliminate cold starts
- FLAME children should skip Oban and the HTTP endpoint (use `FLAME.Parent.get()` to detect)
- Reduce DB `pool_size` to 1 on FLAME children to conserve connections
- Environment variables are NOT inherited — forward them all explicitly via `:env`

## Oban Queue Architecture

Production queues are configured via the `OBAN_QUEUES` environment variable in `config/runtime.exs`:

- **Web machine**: Runs `default` queue (cron scheduler: Dispatcher every minute, CleanupWorker every 4 hours)
- **Heavy queues** (`media_processing`, `exports`, `temp_clips`, `background_jobs`, `maintenance`): Run on the web machine or a separate worker machine depending on load

## Required Environment Variables

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | PostgreSQL connection string |
| `SECRET_KEY_BASE` | Phoenix secret key |
| `PHX_HOST` | Public hostname for URL generation |
| `APP_ENV` | `production` |
| `FLY_API_TOKEN` | Fly.io API token (for FLAME to spawn machines) |
| `OBAN_QUEUES` | Comma-separated queue names to run |
| `PROD_S3_BUCKET_NAME` | S3 bucket for media storage |
| `PROD_CLOUDFRONT_DOMAIN` | CloudFront distribution domain |
| `AWS_ACCESS_KEY_ID` | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |

## Playback Cache

Temp clips are generated by `PlaybackCache.Worker` on the `:temp_clips` Oban queue:
- FFmpeg stream-copies segments from CloudFront proxy URLs to local `/tmp/clip_{id}_{timestamp}.mp4`
- `CleanupWorker` runs every 4 hours: expires files >15 min old, enforces 1GB LRU limit, monitors disk space (500MB threshold)
- Configuration in `config/config.exs` under `:heaters, :playback_cache`

## Deployment Checklist

### Pre-Deployment
- [ ] FFmpeg and Python available in Docker image
- [ ] Fly.io app created, `FLY_API_TOKEN` set
- [ ] All environment variables configured as Fly secrets
- [ ] S3 bucket and CloudFront distribution created
- [ ] Database migrations applied

### Post-Deployment
- [ ] Verify health check endpoint responds
- [ ] Confirm Oban cron jobs are scheduling (check logs for Dispatcher)
- [ ] Test clip playback in review interface
- [ ] Trigger an encoding job and verify FLAME machine spawns (check `fly machines list`)
- [ ] Monitor Oban job queues for failures
- [ ] Verify S3/CloudFront connectivity from FLAME children

## Troubleshooting

**Clip playback not working:**
- Check Oban `:temp_clips` queue is running
- Verify proxy files exist in S3 for the source video
- Review `PlaybackCache.Worker` logs for FFmpeg errors

**FLAME machines not spawning:**
- Verify `FLY_API_TOKEN` is set and valid
- Check that the FLAME pool is in the supervision tree
- Confirm `FLAME.Parent.get()` returns `nil` on the parent (not a FLAME child itself)
- Review Fly.io machine logs: `fly logs` or `fly machines list`

**FLAME children failing:**
- Check that all required env vars are forwarded in the `:env` map
- Verify S3/CloudFront connectivity from the FLAME machine region
- Confirm DB pool size is reduced (`POOL_SIZE=1`) to avoid connection exhaustion

**Oban jobs not running:**
- Confirm `OBAN_QUEUES` env var includes the needed queues
- Check that the `default` queue machine is running (required for cron scheduling)

**Disk space issues:**
- `CleanupWorker` logs cache statistics every 4 hours
- Adjust `:playback_cache` config if temp files accumulate
