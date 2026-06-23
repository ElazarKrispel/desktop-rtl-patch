<#
.SYNOPSIS
    Removes the RTL-patched Codex copy and its Start-menu shortcut.
.PARAMETER Target
    The patched copy root. Default: %LOCALAPPDATA%\OpenAI\CodexRtl
#>
[CmdletBinding()]
param(
    [string]$Target = (Join-Path $env:LOCALAPPDATA 'OpenAI\CodexRtl')
)
$ErrorActionPreference = 'Stop'
function Write-Step($m) { Write-Host "[*] $m" -ForegroundColor Cyan }

$targetApp = Join-Path $Target 'app'
$running = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($targetApp, [StringComparison]::OrdinalIgnoreCase) }
if ($running) { throw "Codex (RTL) is running from $targetApp. Close it, then re-run." }

if (Test-Path $Target) {
    Write-Step "Removing $Target ..."
    Remove-Item -LiteralPath $Target -Recurse -Force
} else {
    Write-Step "Nothing to remove at $Target"
}

$lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex (RTL).lnk'
if (Test-Path $lnk) { Remove-Item -LiteralPath $lnk -Force; Write-Step "Removed shortcut" }

Write-Host "[OK] Uninstalled. Your original Microsoft Store Codex is unaffected." -ForegroundColor Green
