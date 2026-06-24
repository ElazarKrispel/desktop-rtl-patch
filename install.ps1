# install.ps1 - one-line web bootstrap for the Codex RTL patch (advanced).
# -----------------------------------------------------------------------------
# Usage (advanced; the ZIP from the Releases page is the recommended path):
#   irm https://raw.githubusercontent.com/ElazarKrispel/codex-desktop-rtl-patch/v1.1.0/install.ps1 | iex
#
# It downloads this exact tagged release, then opens the graphical installer.
# No administrator rights. Running a remote script requires trusting it; this is
# pinned to the v1.1.0 tag and is the same code as the ZIP download.

$ErrorActionPreference = 'Stop'
$Repo = 'ElazarKrispel/codex-desktop-rtl-patch'
$Tag  = 'v1.1.0'

$tmp = Join-Path $env:TEMP ('codexrtl-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$zip = Join-Path $tmp 'src.zip'
$url = "https://github.com/$Repo/archive/refs/tags/$Tag.zip"

Write-Host "Downloading Codex RTL $Tag ..." -ForegroundColor Cyan
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath $tmp -Force

$root = Get-ChildItem -Directory -Path $tmp | Select-Object -First 1
$gui = Join-Path $root.FullName 'scripts\Install-CodexRtlGui.ps1'
if (-not (Test-Path $gui)) { throw 'Installer script not found in the download.' }

Write-Host 'Opening the installer window...' -ForegroundColor Cyan
$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $gui)
