<#
.SYNOPSIS
    Rolls back to the backup that Install-CodexRtl.ps1 created (CodexRtl.bak),
    e.g. if a rebuild produced a broken copy.
.PARAMETER Target
    The patched copy root. Default: %LOCALAPPDATA%\OpenAI\CodexRtl
#>
[CmdletBinding()]
param(
    [string]$Target = (Join-Path $env:LOCALAPPDATA 'OpenAI\CodexRtl')
)
$ErrorActionPreference = 'Stop'
function Write-Step($m) { Write-Host "[*] $m" -ForegroundColor Cyan }

$backup = "$Target.bak"
if (-not (Test-Path $backup)) { throw "No backup found at $backup" }

$targetApp = Join-Path $Target 'app'
$running = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($targetApp, [StringComparison]::OrdinalIgnoreCase) }
if ($running) { throw "Codex (RTL) is running from $targetApp. Close it, then re-run." }

if (Test-Path $Target) {
    Write-Step "Removing the current copy..."
    Remove-Item -LiteralPath $Target -Recurse -Force
}
Write-Step "Restoring backup -> $(Split-Path $Target -Leaf)"
Rename-Item -LiteralPath $backup -NewName (Split-Path $Target -Leaf) -Force

Write-Host "[OK] Restored from backup ($backup -> $Target)." -ForegroundColor Green
