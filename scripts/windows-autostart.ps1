# Configure a Windows box so the whole stack comes back on its own after a
# reboot, with no manual login. Run once, elevated (Run as Administrator):
#
#   powershell -ExecutionPolicy Bypass -File scripts\windows-autostart.ps1 -User "corevia" -Password "THE-WINDOWS-PASSWORD"
#
# What it sets up (four layers, so any one failing still recovers):
#   1. Windows auto-login for -User          -> a desktop session exists at boot
#   2. Docker Desktop launched at that login -> the engine starts
#   3. restart: unless-stopped (in compose)  -> containers restart with the engine
#   4. a logon Scheduled Task running deploy.ps1 -> guarantees the stack is 'up'
#
# SECURITY NOTE: auto-login stores the Windows password in the registry in
# clear text (standard Windows behaviour). Only use this on a dedicated,
# physically secured appliance box.

param(
    [Parameter(Mandatory = $true)] [string] $User,
    [Parameter(Mandatory = $true)] [string] $Password,
    [string] $DockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
)

$ErrorActionPreference = "Stop"
$RepoRoot   = Split-Path -Parent $PSScriptRoot
$DeployPs1  = Join-Path $RepoRoot "scripts\deploy.ps1"

if (-not (Test-Path $DeployPs1)) { Write-Error "deploy.ps1 not found at $DeployPs1" }

# --- 1. Windows auto-login --------------------------------------------------
Write-Host "==> Enabling Windows auto-login for '$User'"
$winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty $winlogon -Name "AutoAdminLogon" -Value "1" -Type String
Set-ItemProperty $winlogon -Name "DefaultUserName" -Value $User -Type String
Set-ItemProperty $winlogon -Name "DefaultPassword" -Value $Password -Type String

# --- 2. Launch Docker Desktop at login (Startup-folder shortcut) ------------
Write-Host "==> Adding Docker Desktop to Startup"
if (-not (Test-Path $DockerDesktopExe)) {
    Write-Warning "Docker Desktop not found at $DockerDesktopExe — install it, then re-run, or add the shortcut manually."
} else {
    $startup  = [Environment]::GetFolderPath("Startup")
    $lnkPath  = Join-Path $startup "Docker Desktop.lnk"
    $shell    = New-Object -ComObject WScript.Shell
    $lnk      = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = $DockerDesktopExe
    $lnk.Save()
    Write-Host "    Created $lnkPath"
}

# --- 3. Scheduled Task: bring the stack up at logon -------------------------
Write-Host "==> Registering 'CoreVia-Startup' scheduled task"
$taskName = "CoreVia-Startup"
$action   = New-ScheduledTaskAction -Execute "powershell.exe" `
              -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$DeployPs1`""
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $User
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -RunLevel Highest -User $User -Password $Password | Out-Null

Write-Host ""
Write-Host "Done. Reboot to verify: the box should log in, Docker Desktop should start,"
Write-Host "and 'docker compose -f docker-compose.yml -f docker-compose.windows.yml ps' should show the stack Up."
