<#
.SYNOPSIS
    Rebuilds the RTL-patched Codex copy from the current Microsoft Store version.
.DESCRIPTION
    The Store app updates on its own; the patched copy stays on whatever version it
    was built from. Run this after Codex updates to re-copy the latest version and
    re-apply the RTL patch. Equivalent to Install-CodexRtl.ps1 -Force.
#>
[CmdletBinding()]
param(
    [string]$Target = (Join-Path $env:LOCALAPPDATA 'OpenAI\CodexRtl')
)
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $scriptDir 'Install-CodexRtl.ps1') -Target $Target -Force
