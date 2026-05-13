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

## Config split (application.yml profiles)

- `application.yml` — shared. Business config and env-driven keys. No
  environment-specific defaults.
- `application-local.yml` — loaded by default (`spring.profiles.default: local`).
  Localhost defaults for everything, dev sentinels for secrets, `dev-mode: true`,
  `app.dev-seed.*` for seeding super-admins.
- `application-prod.yml` — loaded when `SPRING_PROFILE=prod`. Hardcodes
  `mfa.dev-mode: false` and `password-reset.dev-mode: false` (env can't flip
  them). Holds `app.bootstrap-admin.email`. `ProdConfigGuard` additionally
  refuses to boot if any value is a known dev sentinel, contains localhost, or
  re-enables dev-mode.

Multi super-admin seeding (works in both profiles, same env var):
`DEV_ADMIN_ACCOUNTS=a@x:pw1,b@y:pw2`
- **local/dev** — `DevUserSeeder` (`@Profile("!prod")`) **upserts** on every
  boot: handy for resetting dev passwords from env.
- **prod** — `ProdAdminSeeder` (`@Profile("prod")`) is **create-only**: rows
  are inserted only if missing, never overwritten. Each admin logs in with the
  initial password and changes it via the app; subsequent restarts are no-ops.
  Safe to leave the env var set across deploys.

The single-admin random-password fallback `ProdAdminBootstrap`
(`BOOTSTRAP_ADMIN_EMAIL`) is still wired but unused by default.

## Outstanding work (not blockers for staging — needed before real prod)

1. **Rotate and remove the committed Gmail app password.** A real Gmail token
   (`sjps dmat vayh xoka`) is hardcoded in
   `smartcity-be/src/main/resources/application-local.yml`. It only affects the
   local profile (prod rejects it via `ProdConfigGuard`), but it's still a live
   credential in git history. Rotate the Google account first, then replace
   the literal with a placeholder or env var.

2. **Mosquitto auth.** `mosquitto.conf` is `allow_anonymous true`. Add a
   password file + `allow_anonymous false` before any real device traffic.

3. **DB backups.** None in place. For real prod: `pg_dump` on cron to an
   off-box location (S3 / restic / Hetzner Storage Box).

4. **Frontend BACKEND_URL is build-time.** Baked into the Next.js image as
   `http://backend:3001` via Dockerfile `ENV`. If the backend ever moves to a
   different hostname, rebuild the FE image. Acceptable for now.
