<#
.SYNOPSIS
    Install the Codex RTL patch (patched copy + auto-update watcher).
.DESCRIPTION
    Builds a patched copy of the Microsoft Store Codex (or patches a direct
    install in place), creates a 'Codex (RTL)' shortcut, and registers a
    per-user scheduled task that re-applies the patch whenever Codex updates -
    safely, while Codex is closed, with no administrator rights.
.PARAMETER NoWatcher
    Skip registering the auto-update task (manual updates only).
#>
[CmdletBinding()]
param([switch]$NoWatcher)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir 'lib\codex-rtl-lib.ps1')

if (Test-CodexRtlRunning) {
    throw "Codex (RTL) is currently running. Close it, then re-run the installer."
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "Node.js is required but was not found on PATH. Install it from https://nodejs.org (LTS), reopen PowerShell, and re-run."
}

Write-Host "[*] Building the patched Codex copy (first run copies ~1.6 GB)..." -ForegroundColor Cyan
Invoke-CodexRtlUpdate -Force

$state = Read-RtlState
if (-not $state) { throw "Install did not complete. See $($script:LogFile)." }

if (-not $NoWatcher) {
    Write-Host "[*] Setting up the auto-update watcher..." -ForegroundColor Cyan
    $watch = Copy-RtlBin -RepoRoot $repoRoot
    Register-CodexRtlWatcher -WatchScript $watch
    Start-CodexRtlWatcher -WatchScript $watch
}

Write-Host ""
Write-Host "[OK] Codex RTL patch installed (mode=$($state.mode), Codex v$($state.version))." -ForegroundColor Green
if ($state.mode -eq 'copy') {
    Write-Host "     Launch Codex from the 'Codex (RTL)' Start-menu shortcut." -ForegroundColor Green
}
if (-not $NoWatcher) {
    Write-Host "     Auto-update is ON (no admin) - re-patches when Codex updates, while Codex is closed." -ForegroundColor Green
}
Write-Host "     The original Microsoft Store Codex is untouched." -ForegroundColor DarkGray
