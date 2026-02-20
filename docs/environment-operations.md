# Environment & Operations Quick Reference

## Purpose

Minimal reference for environment variables and common runtime commands.
Use this for day-to-day operations without helper scripts.

## Runtime Modes

- `MIX_ENV=dev` -> local development behavior
- `MIX_ENV=test` -> test config and sandboxed DB behavior
- `MIX_ENV=prod` -> production runtime config path (`config/runtime.exs`)

`APP_ENV` can still be set for compatibility (`development` / `production`), but
runtime mode is derived from `MIX_ENV`.

## Core Environment Variables

Required in production:

- `DATABASE_URL`
- `SECRET_KEY_BASE`
- `PHX_HOST`
- `PROD_S3_BUCKET_NAME`
- `PROD_CLOUDFRONT_DOMAIN`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`

Worker/runtime controls:

- `OBAN_QUEUES` (comma-separated queue names)
- `OBAN_SCHEDULER` (`true`/`false`, optional)

Allowed queue names:

- `default`
- `media_processing`
- `background_jobs`
- `temp_clips`
- `maintenance`

## Local Docker Commands

Start stack:

```bash
docker-compose up -d
docker-compose ps
```

Compile/tests:

```bash
docker-compose run --rm app mix compile --warnings-as-errors
docker-compose run --rm -e MIX_ENV=test app mix test
```

Runtime smoke:

```bash
docker-compose run --rm app mix run -e 'IO.puts("env=#{Application.get_env(:heaters, :app_env)} cloudfront=#{Application.get_env(:heaters, :cloudfront_domain)} s3=#{Application.get_env(:heaters, :s3_bucket)}")'
```

## Worker Commands (No Helper Script)

Worker-only queues:

```bash
docker-compose run --rm app sh -lc 'OBAN_QUEUES=media_processing,background_jobs,temp_clips,maintenance OBAN_SCHEDULER=false mix run --no-halt'
```

Scheduler/web queue:

```bash
docker-compose run --rm app sh -lc 'OBAN_QUEUES=default OBAN_SCHEDULER=true mix run --no-halt'
```

Local non-Docker equivalent:

```bash
OBAN_QUEUES=media_processing,background_jobs,temp_clips,maintenance OBAN_SCHEDULER=false mix run --no-halt
```

## Python Environment (uv)

Python task dependencies are managed with `uv` from `py/pyproject.toml` + `py/uv.lock`.

Local sync command:

```bash
uv sync --project py --frozen --no-dev --no-install-project
```

The local interpreter path used by dev config is `py/.venv/bin/python`.

## Notes

- Unknown queue names in `OBAN_QUEUES` fail fast at boot.
- Queue concurrency is canonical in `config/config.exs`.
- For deployment-specific details, see `plans/production-deployment.md`.
