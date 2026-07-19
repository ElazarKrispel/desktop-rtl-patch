# install.ps1 - one-line web bootstrap for the Desktop RTL patch (advanced).
# -----------------------------------------------------------------------------
# Usage (advanced; the ZIP from the Releases page is the recommended path):
#   irm https://raw.githubusercontent.com/ElazarKrispel/desktop-rtl-patch/v2.2.0/install.ps1 | iex
#
# It downloads this exact tagged release, then opens the graphical installer.
# Fully headless (no window; piping to iex cannot take parameters, so options are
# passed via environment variables set on the same line):
#   $env:RTL_SILENT='1'; irm .../install.ps1 | iex                        # install for Codex
#   $env:RTL_SILENT='1'; $env:RTL_APP='opencode'; irm .../install.ps1 | iex
#
# No administrator rights. Running a remote script requires trusting it; this is
# pinned to the v2.2.0 tag and is the same code as the ZIP download.

$ErrorActionPreference = 'Stop'
$Repo = 'ElazarKrispel/desktop-rtl-patch'
$Tag  = 'v2.2.0'

$tmp = Join-Path $env:TEMP ('codexrtl-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$zip = Join-Path $tmp 'src.zip'

# We prefer a CHECKSUMMED release asset (a zip we upload alongside a SHA256SUMS.txt),
# verify its SHA-256 before extracting, and abort on any mismatch. Older releases that
# have no asset fall back to GitHub's auto source archive (integrity not verifiable).
# NOTE: the asset name carries the BARE version (Build-Release.ps1 -Version 2.2.0
# produces desktop-rtl-patch-2.2.0.zip), while the tag has the 'v' prefix.
$assetZip = "https://github.com/$Repo/releases/download/$Tag/desktop-rtl-patch-$($Tag.TrimStart('v')).zip"
$sumsUrl  = "https://github.com/$Repo/releases/download/$Tag/SHA256SUMS.txt"
$srcZip   = "https://github.com/$Repo/archive/refs/tags/$Tag.zip"

Write-Host "Downloading Desktop RTL $Tag ..." -ForegroundColor Cyan
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$verified = $false
try {
    Invoke-WebRequest -Uri $assetZip -OutFile $zip -UseBasicParsing
    # GitHub serves the .txt asset as octet-stream, so .Content arrives as byte[].
    $sums = (Invoke-WebRequest -Uri $sumsUrl -UseBasicParsing).Content
    if ($sums -is [byte[]]) { $sums = [Text.Encoding]::ASCII.GetString($sums) }
    $sums = [string]$sums
    $have = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower()
    if ($sums -and ($sums.ToLower() -match [regex]::Escape($have))) {
        $verified = $true
        Write-Host "Integrity verified (SHA-256 matches SHA256SUMS.txt)." -ForegroundColor Green
    } else {
        throw "[INTEGRITY] The download did not match the published SHA-256 checksum. Nothing was installed. Please try again or download from the Releases page."
    }
} catch {
    if ($_.Exception.Message -match '^\[INTEGRITY\]') { throw }
    # No checksummed asset for this tag; fall back to the source archive.
    Write-Host "WARNING: no checksummed release asset found; falling back to the source archive (integrity not verified)." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $srcZip -OutFile $zip -UseBasicParsing
}

Expand-Archive -Path $zip -DestinationPath $tmp -Force

$root = Get-ChildItem -Directory -Path $tmp | Select-Object -First 1
$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

if ($env:RTL_SILENT) {
    # Headless: run the CLI installer in THIS console and show its output.
    $cli = Join-Path $root.FullName 'scripts\Install-DesktopRtl.ps1'
    if (-not (Test-Path $cli)) { throw 'Installer script not found in the download.' }
    $app = if ($env:RTL_APP) { $env:RTL_APP } else { 'codex' }
    if ($app -notin @('codex', 'opencode', 'traycer')) { throw "Invalid RTL_APP '$app' (expected codex, opencode or traycer)." }
    Write-Host "Installing (headless) for '$app'..." -ForegroundColor Cyan
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $cli -App $app
    if ($LASTEXITCODE -ne 0) { throw "Headless install failed (exit $LASTEXITCODE). See the log output above." }
} else {
    $gui = Join-Path $root.FullName 'scripts\Install-DesktopRtlGui.ps1'
    if (-not (Test-Path $gui)) { throw 'Installer script not found in the download.' }
    Write-Host 'Opening the installer window...' -ForegroundColor Cyan
    Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $gui)
}
