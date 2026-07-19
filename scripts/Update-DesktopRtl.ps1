<#
.SYNOPSIS
    Manually re-apply the Desktop RTL patch from the current Codex version.
.DESCRIPTION
    Normally the watcher does this automatically. Run this to force it now.
    Builds to staging and swaps in place only while Codex (RTL) is closed.
.PARAMETER Force
    Rebuild even if the Codex version has not changed.
#>
[CmdletBinding()]
param([ValidateSet('codex','opencode')][string]$App = 'codex', [switch]$Force, [switch]$AllowExternalNodeFallback)
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\desktop-rtl-lib.ps1')
Set-RtlActiveApp $App
Start-RtlInstallLog 'update' | Out-Null
Invoke-CodexRtlUpdate -Force:$Force -AllowExternalNodeFallback:$AllowExternalNodeFallback
$state = Read-RtlState
if ($state) { Write-Host "[OK] $($script:ActiveProfile.DisplayName) (RTL) at v$($state.codexVersion) (mode=$($state.mode))." -ForegroundColor Green }
