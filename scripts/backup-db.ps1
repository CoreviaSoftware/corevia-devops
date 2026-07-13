# Dump the Postgres/TimescaleDB database to a timestamped file and prune old ones.
# Run from anywhere:  powershell -ExecutionPolicy Bypass -File scripts\backup-db.ps1
#
#   -BackupDir     where dumps land (default C:\corevia-backups). Point this at a
#                  mapped network drive / external disk to get the copy OFF the box.
#   -RetentionDays delete dumps older than this many days (default 14). 0 = keep all.
#
# The DB port isn't published off-box, so we dump *inside* the container with
# pg_dump and pull the file out with `docker cp`. Streaming the dump through a
# PowerShell pipe would corrupt it (PS re-encodes stdout) -- hence write-then-copy.
#
# Format is pg_dump custom (-Fc): compressed and restorable with restore-db.ps1,
# which handles the TimescaleDB pre/post-restore steps plain pg_restore skips.

param(
    [string] $BackupDir = "C:\corevia-backups",
    [int]    $RetentionDays = 14,
    [string] $Container = "corevia-db",
    [string] $DbUser = "smartcity",
    [string] $DbName = "smartcity"
)

$ErrorActionPreference = "Stop"

$stamp     = Get-Date -Format "yyyyMMdd-HHmmss"
$fileName  = "$DbName-$stamp.dump"
$destPath  = Join-Path $BackupDir $fileName
$inContainer = "/tmp/$fileName"

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

# Fail loudly if the DB container isn't up -- a silent no-op backup is worse than none.
docker inspect -f '{{.State.Running}}' $Container 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "DB container '$Container' not found. Is the stack up?" }

Write-Host "==> Dumping $DbName from '$Container'"
docker exec $Container pg_dump -U $DbUser -Fc -f $inContainer $DbName
if ($LASTEXITCODE -ne 0) { Write-Error "pg_dump failed." }

Write-Host "==> Copying dump to $destPath"
docker cp "${Container}:$inContainer" $destPath
if ($LASTEXITCODE -ne 0) { Write-Error "docker cp failed." }
docker exec $Container rm -f $inContainer | Out-Null

$sizeMB = [math]::Round((Get-Item $destPath).Length / 1MB, 2)
if ($sizeMB -eq 0) { Write-Error "Dump is empty ($destPath) -- treating as failure." }
Write-Host "    Wrote $fileName ($sizeMB MB)"

if ($RetentionDays -gt 0) {
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $old = Get-ChildItem -Path $BackupDir -Filter "$DbName-*.dump" |
           Where-Object { $_.LastWriteTime -lt $cutoff }
    foreach ($f in $old) {
        Write-Host "==> Pruning old backup $($f.Name)"
        Remove-Item $f.FullName -Force
    }
}

Write-Host ""
Write-Host "Backup complete: $destPath"
