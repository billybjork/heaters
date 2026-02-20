# Production Deployment

## Overview

Current production target is **Render** using `render.yaml`.

This project does **not** currently include Fly deployment assets (`fly.toml`) or
an active FLAME runtime dependency in `mix.exs`. Treat Fly/FLAME as future
architecture work, not active deployment instructions.

For a minimal environment/command reference, see
`docs/environment-operations.md`.

## Current Architecture (Render)

```
Browser -> CloudFront (signed URLs) -> S3 media
                ^
Phoenix App (Render) -> Oban queues -> FFmpeg/Python jobs (same app image)
        |
     PostgreSQL
```

Embedding jobs currently run with an ONNX Runtime Python backend (`onnx_clip`)
rather than a PyTorch runtime dependency.

## Runtime and Queue Model

Production queue activation is controlled by `OBAN_QUEUES` in `config/runtime.exs`.

Configured queue names:

- `default`
- `media_processing`
- `background_jobs`
- `temp_clips`
- `maintenance`

Important behavior:

- Unknown queue names in `OBAN_QUEUES` fail fast at boot.
- Queue concurrency is sourced from canonical config (`config/config.exs`).
- Scheduler behavior:
  - Default: cron enabled when `default` queue is active.
  - Worker-only node: set `OBAN_SCHEDULER=false` to disable cron plugins.

Current cron jobs:

- Dispatcher: every minute (`* * * * *`)
- Playback cache cleanup: every 5 minutes (`*/5 * * * *`)

## Service Topology

### Web service (minimum)

- Handles HTTP traffic.
- Runs scheduler with `default` queue.
- Suggested env:
  - `OBAN_QUEUES=default`
  - `OBAN_SCHEDULER=true` (or unset; default queue implies scheduler)

### Optional worker service

- No public HTTP traffic.
- Runs heavy/background queues only.
- Suggested env:
  - `OBAN_QUEUES=media_processing,background_jobs,temp_clips,maintenance`
  - `OBAN_SCHEDULER=false`

## Local Worker Commands

Run local workers with direct Docker/mix commands instead of helper scripts.

Examples:

- Docker: `docker-compose run --rm app sh -lc 'OBAN_QUEUES=media_processing,background_jobs,temp_clips,maintenance OBAN_SCHEDULER=false mix run --no-halt'`
- Docker scheduler node: `docker-compose run --rm app sh -lc 'OBAN_QUEUES=default OBAN_SCHEDULER=true mix run --no-halt'`
- Local mix (non-Docker): `OBAN_QUEUES=media_processing,background_jobs,temp_clips,maintenance OBAN_SCHEDULER=false mix run --no-halt`

## Required Environment Variables

| Variable                 | Description                                  |
| ------------------------ | -------------------------------------------- |
| `DATABASE_URL`           | PostgreSQL connection string                 |
| `SECRET_KEY_BASE`        | Phoenix secret key                           |
| `PHX_HOST`               | Public hostname for URL generation           |
| `PROD_S3_BUCKET_NAME`    | S3 bucket for production media               |
| `PROD_CLOUDFRONT_DOMAIN` | CloudFront distribution domain               |
| `AWS_ACCESS_KEY_ID`      | AWS access key                               |
| `AWS_SECRET_ACCESS_KEY`  | AWS secret key                               |
| `AWS_REGION`             | AWS region                                   |
| `OBAN_QUEUES`            | Comma-separated queue names to activate      |
| `OBAN_SCHEDULER`         | `true/false` cron plugin gate (optional)     |

Optional compatibility vars:

- `APP_ENV=production` (runtime now derives app mode from `MIX_ENV`, but this
  remains safe to set)
- `PROD_DATABASE_URL` (fallback if `DATABASE_URL` is not provided)

## Deployment Checklist

### Pre-deploy

- [ ] Render service and Postgres are healthy
- [ ] Required env vars configured in Render
- [ ] S3 bucket and CloudFront distribution reachable from app runtime
- [ ] Docker image includes FFmpeg and Python runtime

### Deploy

- [ ] Deploy latest image via Render
- [ ] Confirm release boot runs migrations and starts app
- [ ] Verify app health endpoint/page is reachable

### Post-deploy

- [ ] Confirm Dispatcher cron activity in logs (every minute)
- [ ] Confirm CleanupWorker activity in logs (every 5 minutes)
- [ ] Run an encoding/export flow and verify S3 + CloudFront paths
- [ ] Verify temp clip playback path in review UI

## Troubleshooting

**Unknown queue boot failure**

- Check `OBAN_QUEUES` contains only configured names.
- Allowed names are logged in the runtime error.

**Cron jobs not running**

- Ensure scheduler node has `default` queue active, or set
  `OBAN_SCHEDULER=true` explicitly.
- Ensure worker-only nodes use `OBAN_SCHEDULER=false`.

**Media pipeline jobs backing up**

- Confirm `media_processing` queue is active on at least one node.
- Scale worker service or tune canonical queue concurrency.

**S3/CloudFront failures**

- Verify AWS credentials and region.
- Verify `PROD_S3_BUCKET_NAME` and `PROD_CLOUDFRONT_DOMAIN` values.

## Future Architecture (Not Active Yet)

If/when Fly + FLAME is adopted, add `fly.toml`, FLAME dependencies/config, and
cutover docs in a dedicated migration phase. Do not remove Render assets before
successful cutover validation.
