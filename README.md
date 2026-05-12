# CoreVia — staging deployment

Reference for the Hetzner staging server. Single source of truth for "what's
running, where, and how do I push a change."

## What's running

| Service     | URL / endpoint                              | Notes |
|-------------|---------------------------------------------|-------|
| Frontend    | https://staging.corevia.ro                  | Next.js standalone, proxied via Caddy |
| Backend API | https://staging.corevia.ro/api/...          | Next.js rewrites `/api/*` → `backend:3001` |
| HLS streams | https://hls.staging.corevia.ro              | MediaMTX HLS, behind Caddy |
| RTSP ingest | rtsp://178.105.135.16:8554                  | for cameras to publish to |
| MQTT broker | mqtt://178.105.135.16:1883                  | anonymous auth (staging only) |
| Postgres    | internal `postgres:5432`                    | TimescaleDB on pg16, volume `postgres_data` |
| Redis       | internal `redis:6379`                       | volume `redis_data` |

Container names: `corevia-frontend`, `corevia-backend`, `corevia-db`,
`corevia-redis`, `corevia-mqtt`, `corevia-mediamtx`, `corevia-caddy`.

## Repos

| Repo                                | Role                                    |
|-------------------------------------|-----------------------------------------|
| CoreviaSoftware/smartcity-be        | Java/Spring backend. CI pushes image to `ghcr.io/coreviasoftware/corevia-be` on push to main. |
| CoreviaSoftware/smartcity-fe        | Next.js frontend. CI pushes image to `ghcr.io/coreviasoftware/corevia-fe` on push to main. |
| CoreviaSoftware/corevia-devops      | This repo. Compose, Caddyfile, scripts. Public. |

Build workflow file in each app repo: `.github/workflows/build-and-push.yml`.

## Server

- **Host:** Hetzner Cloud CX23, Ubuntu 24.04, Nuremberg/Helsinki
- **Public IP:** 178.105.135.16
- **DNS:** A records on corevia.ro zone (managed in the existing cPanel)
    - `staging.corevia.ro` → 178.105.135.16
    - `hls.staging.corevia.ro` → 178.105.135.16
- **SSH:** `ssh deploy@178.105.135.16` (root login also works but use deploy)
- **Working dir:** `/opt/corevia` (this repo, cloned)
- **Env file:** `/opt/corevia/.env` (gitignored — only lives on server)
- **Firewall (ufw):** 22, 80, 443, 1883, 8554 open

## Deploy flow

```bash
# 1. push code
cd smartcity-be (or smartcity-fe) && git push origin main

# 2. wait ~3 min for GH Actions build (Build and push image workflow)

# 3. pull and restart on server
ssh deploy@178.105.135.16
cd /opt/corevia
bash scripts/deploy.sh
```

`deploy.sh` runs `docker compose -f docker-compose.yml -f docker-compose.prod.yml pull && up -d`.
Only services whose image SHA changed get recreated.

To pin a specific build (rollback or freeze staging):
```bash
IMAGE_TAG_BE=sha-abc1234 bash scripts/deploy.sh
```

## Common ops

```bash
# all logs, tail
docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f

# one service
docker compose -f docker-compose.yml -f docker-compose.prod.yml logs -f backend

# restart one service
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --force-recreate backend

# stack status
docker compose -f docker-compose.yml -f docker-compose.prod.yml ps

# backend health
docker compose -f docker-compose.yml -f docker-compose.prod.yml exec backend wget -qO- http://localhost:3001/actuator/health

# DB shell
docker compose -f docker-compose.yml -f docker-compose.prod.yml exec postgres psql -U smartcity -d smartcity
```

## Secrets layout (.env on the server)

| Var                       | What it does |
|---------------------------|--------------|
| `DOMAIN`                  | Caddy site name, used in Caddyfile |
| `ACME_EMAIL`              | Let's Encrypt contact |
| `DB_*`                    | Postgres user/password/db |
| `JWT_SECRET`              | HS256 signing key (≥ 256 bits) |
| `MEDIAMTX_*`              | MediaMTX shared secret + API creds |
| `MEDIAMTX_HLS_URL_PUBLIC` | URL handed to the browser for HLS playback |
| `CORS_ALLOWED_ORIGINS`    | Spring CORS allowlist; must include public origin |
| `MFA_VERIFY_URL`          | URL in MFA emails |
| `PASSWORD_RESET_URL`      | URL in password reset emails |
| `ACCOUNT_INVITE_URL`      | URL in account invite emails |
| `MEDIA_PUBLIC_BASE_URL`   | Public origin for media file URLs |
| `IMAGE_TAG_BE/FE`         | optional pin to a specific image |

Rotate any value: edit `.env`, then
`docker compose ... up -d --force-recreate backend`.

## TLS

Caddy auto-issues + auto-renews Let's Encrypt certs for `staging.corevia.ro`
and `hls.staging.corevia.ro`. Renewal is automatic; expiry warnings go to
`ACME_EMAIL`. Cert state persisted in the `caddy_data` named volume — survives
container recreation.

## Outstanding work (not blockers for staging — needed before real prod)

1. **Multi super-admin from env.** Today `DevUserSeeder.java` seeds exactly one
   admin from `DEV_ADMIN_EMAIL` / `DEV_ADMIN_PASSWORD`. Change to accept a list
   (e.g. `SUPER_ADMIN_EMAILS=a@x,b@y`) and either seed each with a per-user
   password env or send them password-reset invites on first start.

2. **Strip hardcoded defaults in `application.yml`.** Search for
   `TODO: remove dev default before prod`. Highest priority:
    - Gmail SMTP creds are committed (`spring.mail.password`)
    - `app.dev-seed.email/password` defaults
    - `app.mediamtx.*` dev secrets
    - DB connection defaults
   Remove the `:<default>` part of each `${VAR:default}` so the app refuses to
   start without the env var. Update `.env.production.example` to require them.

3. **Mosquitto auth.** `mosquitto.conf` is currently `allow_anonymous true`.
   Add a password file + `allow_anonymous false` before any real device traffic.

4. **DB backups.** No backups in place. For real prod: `pg_dump` on cron to an
   off-box location (S3 / restic / Hetzner Storage Box).

5. **Frontend BACKEND_URL is build-time.** Currently baked into the Next.js
   image as `http://backend:3001` via Dockerfile ENV. If the backend ever moves
   to a different hostname, rebuild the FE image. Acceptable for now.

6. **MFA dev-mode.** `application.yml` sets `MFA_DEV_MODE=true` by default,
   which probably bypasses real verification. Flip to false in `.env` for any
   real staging test.
