<#
.SYNOPSIS
    Manually re-apply the Codex RTL patch from the current Codex version.
.DESCRIPTION
    Normally the watcher does this automatically. Run this to force it now.
    Builds to staging and swaps in place only while Codex (RTL) is closed.
.PARAMETER Force
    Rebuild even if the Codex version has not changed.
#>
[CmdletBinding()]
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\codex-rtl-lib.ps1')
Invoke-CodexRtlUpdate -Force:$Force
$state = Read-RtlState
if ($state) { Write-Host "[OK] Codex (RTL) at v$($state.version) (mode=$($state.mode))." -ForegroundColor Green }
