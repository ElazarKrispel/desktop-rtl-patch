<#
.SYNOPSIS
    Remove the Desktop RTL patch for the selected app (-App codex|opencode): the
    patched copy, shortcuts, watcher and state. The original install is not affected.
.PARAMETER PurgeLogs
    Also delete the logs folder (kept by default for diagnostics).
#>
[CmdletBinding()]
param([ValidateSet('codex','opencode')][string]$App = 'codex', [switch]$PurgeLogs)
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\desktop-rtl-lib.ps1')
Set-RtlActiveApp $App

Start-RtlInstallLog 'uninstall' | Out-Null
Invoke-CodexRtlUninstall -PurgeLogs:$PurgeLogs

Write-Host "[OK] Uninstalled. The original $($script:ActiveProfile.DisplayName) install is unaffected." -ForegroundColor Green
if (-not $PurgeLogs) { Write-Host "     (Logs kept at $($script:LogsDir).)" -ForegroundColor DarkGray }
