# CoreVia — Windows deployment

Reference for the two Windows boxes. Single source of truth for "what's running,
where, and how do I push a change." First-time setup + auto-start:
see [WINDOWS_DEPLOY.md](WINDOWS_DEPLOY.md).

Two **independent** boxes, each running the full stack from its own `.env`.
Reached directly by IP — no domain, no TLS. Replace `<IP>` with each box's IP.

## What's running (per box)

| Service     | Endpoint                          | Notes |
|-------------|-----------------------------------|-------|
| Frontend    | `http://<IP>:3030`                | Next.js; also proxies `/api/*` → `backend:3001` |
| Signworld   | `http://<IP>:3031`                | Isolated origin routed to the frontend container |
| Backend API | `http://<IP>:3030/api/...`        | reached only through the frontend proxy (not published) |
| HLS streams | `http://<IP>:8888`                | MediaMTX HLS for the browser |
| RTSP ingest | `rtsp://<IP>:8554`                | cameras publish here |
| MQTT broker | `mqtt://<IP>:1883`                | anonymous auth (see notes) |
| Postgres    | internal `postgres:5432`          | TimescaleDB pg16, volume `postgres_data` |
| Redis       | internal `redis:6379`             | volume `redis_data` |

Container names: `corevia-frontend`, `corevia-backend`, `corevia-db`,
`corevia-redis`, `corevia-mqtt`, `corevia-mediamtx`.

## Repos & images

| Repo                           | Image |
|--------------------------------|-------|
| CoreviaSoftware/smartcity-be   | `ghcr.io/coreviasoftware/corevia-be` |
| CoreviaSoftware/smartcity-fe   | `ghcr.io/coreviasoftware/corevia-fe` |
| CoreviaSoftware/corevia-devops | this repo — compose, scripts (public) |

Images are built + pushed by each app repo's `Build and push image` GitHub
Action (manual `workflow_dispatch`). Boxes pull from GHCR — they never build.

## Deploy flow

On the box, from the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy.ps1
```

`deploy.ps1` waits for the Docker engine, then
`docker compose -f docker-compose.yml -f docker-compose.windows.yml pull && up -d`.
Only services whose image SHA changed get recreated.

Pin a specific build (rollback / freeze):
```powershell
$env:IMAGE_TAG_BE="sha-abc1234"; powershell -File scripts\deploy.ps1
```

## Common ops

```powershell
$c = "docker compose -f docker-compose.yml -f docker-compose.windows.yml"

iex "$c ps"                 # stack status
iex "$c logs -f"           # all logs, tail
iex "$c logs -f backend"   # one service
iex "$c up -d --force-recreate backend"   # restart one service
iex "$c exec postgres psql -U smartcity -d smartcity"   # DB shell
```

Backend health (management port): `iex "$c exec backend wget -qO- http://localhost:9001/actuator/health"`

## Auto-start on reboot

Handled by `scripts\windows-autostart.ps1` (run once, elevated). Four layers:
Windows auto-login → Docker Desktop starts at login → `restart: unless-stopped`
brings containers back with the engine → a logon Scheduled Task runs `deploy.ps1`.
Full steps in [WINDOWS_DEPLOY.md](WINDOWS_DEPLOY.md).

## Secrets & config (`.env`)

Each box has its own `.env` (gitignored). Copy `.env.windows.example` and set
this box's IP in the URL vars plus real secrets. The `.env` carries:

- **Per-box URLs** — `CORS_ALLOWED_ORIGINS`, `MFA_VERIFY_URL`,
  `PASSWORD_RESET_URL`, `ACCOUNT_INVITE_URL`, `MEDIA_PUBLIC_BASE_URL` all point
  at `http://<IP>:3030`; `MEDIAMTX_HLS_URL_PUBLIC` at `http://<IP>:8888`.
- **Secrets** — `DB_PASSWORD`, `DB_APP_PASSWORD`, `JWT_SECRET`, `APP_SECRET_KEY`,
  `MAIL_PASSWORD`, `MEDIAMTX_API_PASSWORD`, `MEDIAMTX_SHARED_SECRET`,
  `MEDIAMTX_SIGNING_KEY`.
- Optional `DEV_ADMIN_ACCOUNTS`, `IMAGE_TAG_BE/FE`.

Everything else (DB host/name/user, Redis/MQTT URLs, SMTP host/user, MediaMTX
API URL, mgmt port) is hardcoded in `application-prod.yml`. Rotate a value:
edit `.env`, then `... up -d --force-recreate backend`.

## Config split (application.yml profiles)

- `application.yml` — shared, env-driven keys.
- `application-local.yml` — default profile; localhost + dev sentinels, `dev-mode: true`.
- `application-prod.yml` — activated by `SPRING_PROFILE=prod`. Hardcodes infra
  and `dev-mode: false`. The public URLs (CORS, MFA/reset/invite, media, HLS)
  read from env so one image serves both boxes. `ProdConfigGuard` refuses to
  boot on a dev sentinel, a `localhost`/`127.0.0.1` URL, or re-enabled dev-mode.

Multi super-admin seeding (`DEV_ADMIN_ACCOUNTS=a@x:pw1,b@y:pw2`): create-only in
prod (`ProdAdminSeeder`) — inserts if missing, never overwrites. Safe across deploys.

## Database backups

TimescaleDB dump/restore, per box (Postgres has no off-box published port, so
these dump *inside* the `corevia-db` container and copy the file out).

```powershell
# one-off backup -> C:\corevia-backups\smartcity-<timestamp>.dump (keeps 14 days)
powershell -ExecutionPolicy Bypass -File scripts\backup-db.ps1

# same, but off-box onto a UNC share, keeping 30 days
powershell -File scripts\backup-db.ps1 -BackupDir "\\server\share\corevia-backups" -RetentionDays 30

# schedule it daily at 03:00 (run once, elevated — runs as SYSTEM, no password)
powershell -File scripts\schedule-db-backup.ps1

# restore a dump (DESTRUCTIVE — drops the DB; handles TimescaleDB pre/post-restore)
powershell -File scripts\restore-db.ps1 -DumpFile C:\corevia-backups\smartcity-<ts>.dump -Confirm
docker compose -f docker-compose.yml -f docker-compose.windows.yml up -d --force-recreate backend
```

`backup-db.ps1` uses `pg_dump -Fc`; `restore-db.ps1` wraps `pg_restore` in
`timescaledb_pre_restore()` / `timescaledb_post_restore()` (plain pg_restore
mangles hypertables). Point `-BackupDir` at a network/external location to keep
copies off the box.

## Notes / before real production

1. **Mosquitto is `allow_anonymous true`.** Fine on a trusted LAN; add a
   password file + `allow_anonymous false` before untrusted device traffic.
2. **DB backups** — `scripts\backup-db.ps1` + `scripts\schedule-db-backup.ps1`
   (see "Database backups" above). Point `-BackupDir` off-box; verify with a
   test `restore-db.ps1` before relying on them.
3. **Mail dependency.** MFA + password-reset (and thus login) need outbound
   SMTP to `mail.corevia.ro:587` with a valid `MAIL_PASSWORD`. If a box can't
   reach it, users can't complete MFA. Host/user are hardcoded in
   `application-prod.yml` — changing SMTP means a backend edit + image rebuild.
4. **Committed Gmail app password** in `application-local.yml` (local profile
   only; prod rejects it). Rotate + replace with a placeholder.
