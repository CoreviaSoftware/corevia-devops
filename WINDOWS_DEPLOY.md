# CoreVia — Windows setup runbook

First-time setup for one Windows 10/11 Pro box. **Repeat every step on each box**
with its own IP. The two boxes are fully independent (separate DB, separate `.env`).

---

## 0. Required backend change (do this once, before building images)

The public URLs used to be hardcoded to `staging.corevia.ro`. For one image to
serve two different-IP boxes, six values in
`smartcity-be/src/main/resources/application-prod.yml` must read from env.
Apply this diff in the **smartcity-be** repo:

```diff
   cors:
-    allowed-origins: https://staging.corevia.ro
+    allowed-origins: ${CORS_ALLOWED_ORIGINS}
   ...
   mediamtx:
-    hls-base-url: https://hls.staging.corevia.ro
+    hls-base-url: ${MEDIAMTX_HLS_URL_PUBLIC}
   ...
   mfa:
     from-address: noreply@corevia.ro
-    verify-url: https://staging.corevia.ro/ro/mfa
+    verify-url: ${MFA_VERIFY_URL}
   ...
   password-reset:
     from-address: noreply@corevia.ro
-    reset-url: https://staging.corevia.ro/ro/reset-password
-    invite-url: https://staging.corevia.ro/ro/create-account
+    reset-url: ${PASSWORD_RESET_URL}
+    invite-url: ${ACCOUNT_INVITE_URL}
   ...
   media:
-    public-base-url: https://staging.corevia.ro
+    public-base-url: ${MEDIA_PUBLIC_BASE_URL}
```

`ProdConfigGuard` already accepts plain `http://` and bare IPs (it only blocks
`localhost`/`127.0.0.1`), so no code change is needed there. After applying:

```
cd smartcity-be && ./gradlew build
```

Then trigger the **Build and push image** workflow in both `smartcity-be` and
`smartcity-fe` so GHCR has current `:latest` images.

---

## 1. Install Docker Desktop

1. Install **Docker Desktop for Windows** with the **WSL 2** backend
   (Docker Desktop enables WSL2 during install).
2. Docker Desktop → **Settings → General → "Start Docker Desktop when you sign
   in"** = ON.
3. Confirm it works: open a terminal and run `docker version` — both Client and
   Server should report.

## 2. Log in to the image registry (GHCR)

The images are private. Create a GitHub **Personal Access Token** (classic) in
the CoreviaSoftware org with scope **`read:packages`**, then:

```powershell
$env:CR_PAT="<YOUR_PAT>"
$env:CR_PAT | docker login ghcr.io -u <your-github-username> --password-stdin
```

## 3. Get this repo onto the box

```powershell
git clone https://github.com/CoreviaSoftware/corevia-devops.git C:\corevia
cd C:\corevia
```

## 4. Create this box's `.env`

```powershell
copy .env.windows.example .env
notepad .env
```

Set every URL to **this box's IP** (e.g. `http://192.168.1.50:3030`, HLS on
`:8888`) and fill in real secrets. Generate secrets from Git Bash:
`openssl rand -base64 48` (and `-base64 32` for `APP_SECRET_KEY`).

## 5. Open the Windows Firewall ports

Inbound TCP: **3030** (app), **8888** (HLS), **8554** (RTSP), **1883** (MQTT).

```powershell
New-NetFirewallRule -DisplayName "CoreVia app"  -Direction Inbound -Protocol TCP -LocalPort 3030 -Action Allow
New-NetFirewallRule -DisplayName "CoreVia HLS"  -Direction Inbound -Protocol TCP -LocalPort 8888 -Action Allow
New-NetFirewallRule -DisplayName "CoreVia RTSP" -Direction Inbound -Protocol TCP -LocalPort 8554 -Action Allow
New-NetFirewallRule -DisplayName "CoreVia MQTT" -Direction Inbound -Protocol TCP -LocalPort 1883 -Action Allow
```

## 6. Start the stack

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy.ps1
```

Wait ~1 min for the backend healthcheck, then open `http://<IP>:3030`.

## 7. Enable auto-start on reboot

Run once, **as Administrator**:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows-autostart.ps1 -User "<windows-user>" -Password "<windows-password>"
```

This sets: Windows auto-login → Docker Desktop launches at login →
`restart: unless-stopped` restarts containers with the engine → a logon
Scheduled Task runs `deploy.ps1` as a safety net.

> Auto-login stores the Windows password in the registry in clear text (standard
> Windows behaviour). Only use it on a dedicated, physically secured box.

## 8. Verify reboot recovery

Reboot the box. Without touching anything it should log in, Docker Desktop
should start, and:

```powershell
docker compose -f docker-compose.yml -f docker-compose.windows.yml ps
```

should show every service **Up** (backend **healthy**). Load `http://<IP>:3030`.

---

## Updating later

```powershell
# 1. push backend/frontend code, then run the Build and push image workflow(s)
# 2. on each box:
cd C:\corevia
powershell -ExecutionPolicy Bypass -File scripts\deploy.ps1
```

## Local full-stack build (optional, dev machine only)

To build from sibling `smartcity-be` / `smartcity-fe` source instead of pulling:

```
docker compose -f docker-compose.yml -f docker-compose.local.yml up --build
```
