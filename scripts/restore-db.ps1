# Restore a backup-db.ps1 dump into the running Postgres/TimescaleDB container.
# Run from anywhere:  powershell -ExecutionPolicy Bypass -File scripts\restore-db.ps1 -DumpFile C:\corevia-backups\smartcity-20260713-030000.dump
#
# DESTRUCTIVE: overwrites the current database. It requires -Confirm to proceed.
#
# TimescaleDB needs pre/post-restore hooks around pg_restore, otherwise hypertable
# chunks and background jobs restore incorrectly. This script:
#   1. copies the dump into the container
#   2. drops + recreates the target DB (clean slate)
#   3. SELECT timescaledb_pre_restore()  -> pg_restore  -> timescaledb_post_restore()
#
# After restore, recreate the backend so it reconnects cleanly:
#   docker compose -f docker-compose.yml -f docker-compose.windows.yml up -d --force-recreate backend

param(
    [Parameter(Mandatory = $true)] [string] $DumpFile,
    [switch] $Confirm,
    [string] $Container = "corevia-db",
    [string] $DbUser = "smartcity",
    [string] $DbName = "smartcity"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $DumpFile)) { Write-Error "Dump file not found: $DumpFile" }
if (-not $Confirm) {
    Write-Error "This DROPS and replaces the '$DbName' database. Re-run with -Confirm to proceed."
}

docker inspect -f '{{.State.Running}}' $Container 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "DB container '$Container' not found. Is the stack up?" }

$inContainer = "/tmp/restore.dump"

Write-Host "==> Copying dump into '$Container'"
docker cp $DumpFile "${Container}:$inContainer"
if ($LASTEXITCODE -ne 0) { Write-Error "docker cp failed." }

# Drop/recreate from the maintenance 'postgres' db so we're not connected to the target.
Write-Host "==> Recreating database '$DbName' (dropping existing data)"
docker exec $Container psql -U $DbUser -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS $DbName WITH (FORCE);"
if ($LASTEXITCODE -ne 0) { Write-Error "DROP DATABASE failed." }
docker exec $Container psql -U $DbUser -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE $DbName OWNER $DbUser;"
if ($LASTEXITCODE -ne 0) { Write-Error "CREATE DATABASE failed." }

Write-Host "==> timescaledb_pre_restore()"
docker exec $Container psql -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS timescaledb; SELECT timescaledb_pre_restore();"
if ($LASTEXITCODE -ne 0) { Write-Error "timescaledb_pre_restore failed." }

Write-Host "==> pg_restore"
# --no-owner/--no-privileges: roles differ per box; the app role is set up by Flyway anyway.
docker exec $Container pg_restore -U $DbUser -d $DbName --no-owner --no-privileges $inContainer
# pg_restore may exit non-zero on benign warnings; surface it but continue to post_restore.
if ($LASTEXITCODE -ne 0) { Write-Warning "pg_restore reported errors (often benign warnings). Review output above." }

Write-Host "==> timescaledb_post_restore()"
docker exec $Container psql -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -c "SELECT timescaledb_post_restore();"
if ($LASTEXITCODE -ne 0) { Write-Error "timescaledb_post_restore failed." }

docker exec $Container rm -f $inContainer | Out-Null

Write-Host ""
Write-Host "Restore complete. Now recreate the backend so it reconnects:"
Write-Host "  docker compose -f docker-compose.yml -f docker-compose.windows.yml up -d --force-recreate backend"
