# Watch-CodexRtl.ps1 — background watcher (started at logon via HKCU\Run, and once
# at install time). Deployed to %LOCALAPPDATA%\CodexRtlPatch\bin. No admin.
#
# It updates the patched copy ONLY when the Codex version changed AND Codex (RTL)
# is not running, so it never interrupts a running Codex. With -Loop it re-checks
# every few hours; a session-local mutex keeps a single instance per logon.
param([switch]$Loop)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'codex-rtl-lib.ps1')

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\CodexRtlPatchWatcher', [ref]$created)
if (-not $created) { return }  # another watcher is already running this session

try {
    do {
        try { Invoke-CodexRtlUpdate -Auto } catch { Write-RtlLog "watch error: $($_.Exception.Message)" }
        if ($Loop) { Start-Sleep -Seconds 21600 }  # re-check every 6 hours
    } while ($Loop)
} finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
