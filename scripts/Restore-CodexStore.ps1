<#
.SYNOPSIS
    Rolls the Microsoft Store Codex app.asar back to the pristine pre-patch backup.
    MUST run elevated. Used if an in-place patch ever misbehaves.
#>
[CmdletBinding()]
param(
    [string]$StateDir = (Join-Path $env:LOCALAPPDATA 'CodexRtlPatch')
)
$ErrorActionPreference = 'Stop'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Not elevated (run as Administrator).'
}

$pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pkg) { throw 'OpenAI.Codex Store package not found.' }
$ver = $pkg.Version
$asarItem = Get-ChildItem (Join-Path $pkg.InstallLocation 'app\resources') -Filter app.asar -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $asarItem) { throw 'app.asar not found.' }
$asarPath = $asarItem.FullName
$pristine = Join-Path (Join-Path $StateDir 'backup') "app.asar.$ver.orig"
if (-not (Test-Path $pristine)) { throw "No pristine backup for v$ver at $pristine" }

& takeown.exe /f "$asarPath" | Out-Null
& icacls.exe "$asarPath" /grant "*S-1-5-32-544:(F)" | Out-Null
[System.IO.File]::WriteAllBytes($asarPath, [System.IO.File]::ReadAllBytes($pristine))

Write-Host "[OK] Restored Store Codex v$ver app.asar from pristine backup." -ForegroundColor Green
