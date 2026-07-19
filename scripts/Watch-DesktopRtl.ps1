# Watch-DesktopRtl.ps1 - background watcher (started at logon via HKCU\Run, and once
# at install time). Deployed to %LOCALAPPDATA%\CodexRtlPatch\bin. No admin.
#
# It updates the patched copy ONLY when the Codex version changed AND Codex (RTL)
# is not running, so it never interrupts a running Codex. With -Loop it watches the
# source event-driven (FileSystemWatcher for direct installs, near-instant) with a
# short poll as the Store fallback and to complete a deferred swap once Codex (RTL)
# closes. A session-local mutex keeps a single instance per logon.
param([ValidateSet('codex','opencode')][string]$App = 'codex', [switch]$Loop, [int]$PollSec = 90)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'desktop-rtl-lib.ps1')
Set-RtlActiveApp $App
Hide-RtlConsole   # background watcher: never show a console window

# Per-app mutex so each app has exactly one watcher, but the two apps' watchers
# coexist (they patch independent copies).
$created = $false
$mutex = New-Object System.Threading.Mutex($true, ('Local\' + $script:RunName), [ref]$created)
if (-not $created) { return }  # another watcher for this app is already running this session

try {
    Invoke-CodexRtlWatchLoop -Loop:$Loop -PollSec $PollSec
} finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
