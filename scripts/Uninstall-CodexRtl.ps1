<#
.SYNOPSIS
    Remove the Codex RTL patch: the patched copy, shortcut, watcher task and state.
    The original Microsoft Store Codex is not affected.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\codex-rtl-lib.ps1')

if (Test-CodexRtlRunning) { throw "Codex (RTL) is running. Close it, then re-run." }

Unregister-CodexRtlWatcher

foreach ($d in @($script:CopyRoot, $script:Staging, $script:OldRoot, $script:BinDir)) {
    if (Test-Path $d) {
        try { Remove-Item -LiteralPath $d -Recurse -Force; Write-RtlLog "removed $d" }
        catch { Write-RtlLog "could not remove $d : $($_.Exception.Message)" }
    }
}
if (Test-Path $script:ShortcutPath) { Remove-Item -LiteralPath $script:ShortcutPath -Force }
if (Test-Path $script:StateFile)    { Remove-Item -LiteralPath $script:StateFile -Force }

Write-Host "[OK] Uninstalled. The original Microsoft Store Codex is unaffected." -ForegroundColor Green
