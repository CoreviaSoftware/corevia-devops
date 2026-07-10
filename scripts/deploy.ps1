# Pull the latest images and (re)start the stack on a Windows box.
# Run from anywhere:  powershell -ExecutionPolicy Bypass -File scripts\deploy.ps1
# Pin a build:        $env:IMAGE_TAG_BE="sha-abc1234"; scripts\deploy.ps1
#
# Safe to run at boot: it waits for the Docker engine before doing anything,
# so it also works as the startup Scheduled Task (see windows-autostart.ps1).

$ErrorActionPreference = "Stop"

# repo root = parent of this script's folder
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

if (-not (Test-Path ".env")) {
    Write-Error ".env missing. Copy .env.windows.example to .env and edit it (set this box's IP + secrets)."
}

$Compose = @("compose", "-f", "docker-compose.yml", "-f", "docker-compose.windows.yml")

Write-Host "==> Waiting for the Docker engine..."
$deadline = (Get-Date).AddMinutes(3)
while ($true) {
    docker info *> $null
    if ($LASTEXITCODE -eq 0) { break }
    if ((Get-Date) -gt $deadline) {
        Write-Error "Docker engine not ready after 3 minutes. Is Docker Desktop running?"
    }
    Start-Sleep -Seconds 5
}
Write-Host "    Docker is up."

Write-Host "==> Pulling images"
docker @Compose pull
if ($LASTEXITCODE -ne 0) { Write-Error "docker compose pull failed (are you logged in to ghcr.io?)" }

Write-Host "==> Starting / updating stack"
docker @Compose up -d --remove-orphans
if ($LASTEXITCODE -ne 0) { Write-Error "docker compose up failed" }

Write-Host "==> Stack status"
docker @Compose ps

Write-Host ""
Write-Host "Tail logs with:  docker compose -f docker-compose.yml -f docker-compose.windows.yml logs -f"
