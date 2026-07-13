# Register a daily Scheduled Task that runs backup-db.ps1. Run once, elevated
# (Run as Administrator):
#
#   powershell -ExecutionPolicy Bypass -File scripts\schedule-db-backup.ps1
#
# Optional:
#   -At "03:00"          time of day to run (default 03:00)
#   -BackupDir <path>    passed through to backup-db.ps1 (default its own default)
#   -RetentionDays <n>   passed through to backup-db.ps1
#
# The task runs as NT AUTHORITY\SYSTEM (ServiceAccount logon) -- no user or
# password needed, runs whether or not anyone is logged in, and catches up if
# the box was off at the scheduled time (StartWhenAvailable). SYSTEM must be
# able to reach the Docker engine (Docker Desktop grants it via the docker
# named pipe) -- verify with a manual Start-ScheduledTask after registering.

param(
    [string] $At = "03:00",
    [string] $BackupDir,
    [int]    $RetentionDays
)

$ErrorActionPreference = "Stop"
$RepoRoot  = Split-Path -Parent $PSScriptRoot
$BackupPs1 = Join-Path $RepoRoot "scripts\backup-db.ps1"

if (-not (Test-Path $BackupPs1)) { Write-Error "backup-db.ps1 not found at $BackupPs1" }

$argLine = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$BackupPs1`""
if ($BackupDir)     { $argLine += " -BackupDir `"$BackupDir`"" }
if ($PSBoundParameters.ContainsKey('RetentionDays')) { $argLine += " -RetentionDays $RetentionDays" }

Write-Host "==> Registering 'CoreVia-DB-Backup' scheduled task (daily at $At)"
$taskName = "CoreVia-DB-Backup"
$action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argLine
$trigger  = New-ScheduledTaskTrigger -Daily -At $At
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

$principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal | Out-Null

Write-Host ""
Write-Host "Done. Run it now to verify:  Start-ScheduledTask -TaskName '$taskName'"
Write-Host "Check results in the backup dir, or: Get-ScheduledTaskInfo -TaskName '$taskName'"
