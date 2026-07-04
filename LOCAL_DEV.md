# Dograh Local Development

This guide covers the host-managed local setup for running Dograh with a separate backend, frontend, and local database services.

## What You Need Running

- PostgreSQL, Redis, and MinIO from Docker Compose
- The FastAPI backend via `scripts/start_services_dev.sh`
- The Next.js frontend via `ui/npm run dev`

## Start Everything

Run these commands from the repository root.

### 1. Start the local services

```bash
docker compose -f docker-compose-local.yaml up -d
```

This starts:

- PostgreSQL on `localhost:5432`
- Redis on `localhost:6379`
- MinIO on `localhost:9000`

### 2. Start the backend

Use Bash for this command:

```bash
bash scripts/start_services_dev.sh
```

What it does:

- Loads `api/.env`
- Waits for PostgreSQL, Redis, and MinIO to be reachable
- Runs Alembic migrations
- Starts the backend services in the background
- Waits for the backend health check to pass

If you are using fish as your interactive shell, keep using fish for your terminal session if you want, but run the backend command through Bash like above.

### 3. Start the frontend

In another terminal:

```bash
cd ui
npm run dev
```

Then open:

```text
http://localhost:3000
```

## Stop Everything

Stop in the reverse order.

### 1. Stop the frontend

Press `Ctrl+C` in the terminal running `npm run dev`.

### 2. Stop the backend services

From the repository root:

```bash
bash scripts/stop_services.sh
```

This stops the backend processes started by `start_services_dev.sh`, including:

- `uvicorn`
- `arq`
- `ari_manager`
- `campaign_orchestrator`

### 3. Stop the database services

If you want to stop the Docker services but keep their volumes:

```bash
docker compose -f docker-compose-local.yaml stop
```

If you want to stop and remove the containers while keeping the data volumes:

```bash
docker compose -f docker-compose-local.yaml down
```

If you also want to remove the local data volumes and start fresh next time:

```bash
docker compose -f docker-compose-local.yaml down -v
```

## Quick Health Checks

Backend health:

```bash
curl http://127.0.0.1:8000/api/v1/health
```

Frontend config endpoint:

```bash
curl http://127.0.0.1:3000/api/config/version
```

## Common Notes

- If login fails for a local OSS account, signing up again with the same email now updates the password for that local account.
- If `start_services_dev.sh` says PostgreSQL is unreachable, start the Docker services first.
- If you edit backend code, re-run `bash scripts/start_services_dev.sh` to restart the backend processes.
