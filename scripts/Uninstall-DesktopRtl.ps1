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
$appName = $script:ActiveProfile.DisplayName

Start-RtlInstallLog 'uninstall' | Out-Null
$res = Invoke-CodexRtlUninstall -PurgeLogs:$PurgeLogs

# Agent lifecycle: keep the unified agent while any app remains; tear it down only when
# none remain AND this cleanup was certain (else retain the agent and log).
$remaining = @(Get-RtlInstalledApps)
if ($remaining.Count -gt 0) {
    Write-Host "[*] $($remaining.Count) app(s) still installed; keeping the unified agent." -ForegroundColor Cyan
    try { Register-RtlAgent } catch {}
    Restart-RtlAgentTray                       # re-detect the reduced app set
} elseif ($res.Certain) {
    Write-Host "[*] Last app removed; removing the unified background agent." -ForegroundColor Cyan
    Invoke-RtlAgentLastCleanup
} else {
    Write-Host "[!] Cleanup was uncertain; retaining the unified agent." -ForegroundColor Yellow
}

Write-Host "[OK] Uninstalled. The original $appName install is unaffected." -ForegroundColor Green
if (-not $PurgeLogs) { Write-Host "     (Logs kept at $($script:LogsDir).)" -ForegroundColor DarkGray }
