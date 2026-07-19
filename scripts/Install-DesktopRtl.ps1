<#
.SYNOPSIS
    Install the Desktop RTL patch (patched copy + auto-update watcher), headless.
.DESCRIPTION
    Builds a patched COPY of Codex (the original install is only read, never
    modified), creates "Codex <ivrit>" Start-menu and Desktop shortcuts, and
    registers a per-user logon watcher that re-applies the patch whenever Codex
    updates - safely, while Codex is closed, with no administrator rights. Codex's
    bundled Node is used, so no external Node.js is required. The GUI installer
    wraps this same logic.
.PARAMETER NoWatcher
    Skip registering the auto-update watcher (manual updates only).
.PARAMETER AllowExternalNodeFallback
    Dev/headless only: if Codex's bundled Node is missing, fall back to Node on PATH.
    Not used by the end-user GUI (which requires the bundled Node).
#>
[CmdletBinding()]
param([ValidateSet('codex','opencode')][string]$App = 'codex', [switch]$NoWatcher, [switch]$AllowExternalNodeFallback)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir 'lib\desktop-rtl-lib.ps1')
Set-RtlActiveApp $App
$appName = $script:ActiveProfile.DisplayName

Start-RtlInstallLog 'install' | Out-Null
Test-RtlPackage -RepoRoot $repoRoot | Out-Null

if (Test-CodexRtlRunning) {
    throw "$appName (RTL) is currently running. Close it, then re-run the installer."
}

Write-Host "[*] Building the patched $appName copy..." -ForegroundColor Cyan
Invoke-CodexRtlUpdate -Force -AllowExternalNodeFallback:$AllowExternalNodeFallback

$state = Read-RtlState
if (-not $state) { throw "Install did not complete. See $($script:LogFile)." }

if (-not $NoWatcher) {
    Write-Host "[*] Setting up the auto-update watcher..." -ForegroundColor Cyan
    $watch = Copy-RtlBin -RepoRoot $repoRoot
    Register-CodexRtlWatcher -WatchScript $watch
    Start-CodexRtlWatcher -WatchScript $watch
}

Write-Host ""
Write-Host "[OK] $appName RTL patch installed ($appName v$($state.codexVersion))." -ForegroundColor Green
Write-Host "     Launch $appName from the '$($script:ShortcutLabel)' shortcut (Start menu or Desktop)." -ForegroundColor Green
if (-not $NoWatcher) {
    Write-Host "     Auto-update is ON (no admin) - re-patches when $appName updates, while it is closed." -ForegroundColor Green
}
Write-Host "     The original $appName install is untouched." -ForegroundColor DarkGray
