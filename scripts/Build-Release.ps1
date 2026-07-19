# Build-Release.ps1 - package a checksummed release asset for a version tag.
# -----------------------------------------------------------------------------
# Produces dist\desktop-rtl-patch-<Version>.zip (a single top-level folder,
# the layout install.ps1 expects) plus dist\SHA256SUMS.txt covering it. Upload BOTH
# as assets on the GitHub release so install.ps1 and the self-updater can verify the
# download against the checksum before extracting.
#
# This does NOT create a tag or a GitHub release (that stays a manual, approved step).
# Usage:  powershell -ExecutionPolicy Bypass -File scripts\Build-Release.ps1 -Version 1.2.0

param([Parameter(Mandatory)][string]$Version)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$dist     = Join-Path $repoRoot 'dist'
$stageTop = Join-Path $dist 'staging'
$folder   = 'desktop-rtl-patch'
$stage    = Join-Path $stageTop $folder
$zipName  = "desktop-rtl-patch-$Version.zip"
$zipPath  = Join-Path $dist $zipName
$sumsPath = Join-Path $dist 'SHA256SUMS.txt'

# Only ship what the installer needs; never the repo plumbing or build artifacts.
$include = @('scripts', 'src', 'test', 'install.ps1', 'Install-Desktop-RTL.vbs', 'Install-Desktop-RTL.cmd',
             'Desktop-RTL-Tray.vbs', 'Desktop-RTL-Settings.vbs', 'README.md', 'LICENSE')

if (Test-Path $stageTop) { Remove-Item -LiteralPath $stageTop -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
foreach ($item in $include) {
    $src = Join-Path $repoRoot $item
    if (-not (Test-Path $src)) { Write-Host "  skip (missing): $item"; continue }
    if ((Get-Item $src).PSIsContainer) { Copy-Item $src (Join-Path $stage $item) -Recurse -Force }
    else { Copy-Item $src (Join-Path $stage $item) -Force }
    Write-Host "  staged: $item"
}

if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path $stage -DestinationPath $zipPath -Force
$hash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()
"$hash  $zipName" | Set-Content -LiteralPath $sumsPath -Encoding ASCII
Remove-Item -LiteralPath $stageTop -Recurse -Force

Write-Host ''
Write-Host "Release asset : $zipPath"
Write-Host "Checksums     : $sumsPath"
Write-Host "SHA-256       : $hash"
Write-Host ''
Write-Host "Next (manual, after approval):"
Write-Host "  gh release create v$Version `"$zipPath`" `"$sumsPath`" --title v$Version --notes ..."
