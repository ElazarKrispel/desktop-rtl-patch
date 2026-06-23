<#
.SYNOPSIS
    Installs (or rebuilds) the RTL-patched copy of the OpenAI Codex desktop app.

.DESCRIPTION
    Copies the read-only Microsoft Store install of Codex to a writable location,
    extracts its app.asar into an unpacked app\ folder, injects the RTL patch
    script, and neutralizes the original asar so Electron loads the folder
    (possible because the OnlyLoadAppFromAsar / AsarIntegrity fuses are disabled).
    Dependency-free: pure PowerShell, no Node / asar tooling required.

.PARAMETER Source
    Path to a clean Codex 'app' directory. Auto-detected from the Store package
    (OpenAI.Codex) when omitted.

.PARAMETER Target
    Destination root. Default: %LOCALAPPDATA%\OpenAI\CodexRtl

.PARAMETER PatchJs
    Path to codex-rtl-patch.js. Defaults to ..\src\codex-rtl-patch.js.

.EXAMPLE
    .\Install-CodexRtl.ps1 -Force
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Target = (Join-Path $env:LOCALAPPDATA 'OpenAI\CodexRtl'),
    [string]$PatchJs,
    [switch]$NoShortcut,
    [switch]$NoBackup,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent $scriptDir
if (-not $PatchJs) { $PatchJs = Join-Path $repoRoot 'src\codex-rtl-patch.js' }

function Write-Step($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}
function Invoke-Robocopy($from, $to) {
    $a = @("`"$from`"", "`"$to`"", '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    $p = Start-Process robocopy -ArgumentList $a -Wait -PassThru -NoNewWindow
    return $p.ExitCode
}

# --- 1. resolve source ---------------------------------------------------------
$pkgVer = 'unknown'
if (-not $Source) {
    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) { throw "OpenAI Codex (Microsoft Store) not found. Install it, or pass -Source." }
    $Source = Join-Path $pkg.InstallLocation 'app'
    $pkgVer = $pkg.Version
}
if (-not (Test-Path (Join-Path $Source 'resources\app.asar'))) {
    throw "No resources\app.asar under -Source: $Source"
}
if (-not (Test-Path $PatchJs)) { throw "Patch script not found: $PatchJs" }
Write-Step "Source: $Source  (v$pkgVer)"
Write-Step "Target: $Target"

# --- 2. prepare target ---------------------------------------------------------
$targetApp = Join-Path $Target 'app'
$backup    = "$Target.bak"
if (Test-Path $Target) {
    if (-not $Force) { throw "Target already exists: $Target  (use -Force to rebuild)" }
    $running = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($targetApp, [StringComparison]::OrdinalIgnoreCase) }
    if ($running) { throw "Codex (RTL) is running from $targetApp. Close it, then re-run." }
    if ($NoBackup) {
        Write-Step "Removing existing target (no backup)..."
        Remove-Item -LiteralPath $Target -Recurse -Force
    } else {
        if (Test-Path $backup) { Write-Step "Replacing previous backup..."; Remove-Item -LiteralPath $backup -Recurse -Force }
        Write-Step "Backing up existing install -> $(Split-Path $backup -Leaf)"
        Rename-Item -LiteralPath $Target -NewName (Split-Path $backup -Leaf) -Force
    }
}
New-Item -ItemType Directory -Force -Path $targetApp | Out-Null

# --- 3. copy the app -----------------------------------------------------------
Write-Step "Copying app (~1.6 GB, please wait)..."
$code = Invoke-Robocopy $Source $targetApp
if ($code -ge 16) { throw "robocopy fatal error (exit $code)" }
if ($code -ge 8)  { Write-Warning "robocopy reported some files could not be copied (exit $code) - continuing." }

# --- 4. patch app.asar in place (surgical inject via Node) ---------------------
# Codex's owl-electron runtime loads app.asar only (no unpacked-folder fallback),
# so we keep the asar and edit its contents. asar-edit.mjs appends the patch file
# + index.html change to the data section and rewrites just the header.
$resources = Join-Path $targetApp 'resources'
$asar      = Join-Path $resources 'app.asar'
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { throw "Node.js is required but 'node' was not found on PATH. Install Node.js and re-run." }
$editor = Join-Path $scriptDir 'lib\asar-edit.mjs'
Write-Step "Patching app.asar (surgical inject via Node)..."
& $node $editor $asar $PatchJs
if ($LASTEXITCODE -ne 0) { throw "asar-edit.mjs failed (exit $LASTEXITCODE)" }

# --- 7. record state -----------------------------------------------------------
$state = [ordered]@{
    patchVersion   = '0.2.0'
    method         = 'asar-inject'
    installedAt    = (Get-Date).ToString('o')
    packageName    = 'OpenAI.Codex'
    packageVersion = $pkgVer
    sourceAppDir   = $Source
    targetAppDir   = $targetApp
}
Write-Utf8NoBom (Join-Path $Target 'patch-state.json') (($state | ConvertTo-Json))

# --- 8. shortcut ---------------------------------------------------------------
$exe = Join-Path $targetApp 'Codex.exe'
if (-not $NoShortcut) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex (RTL).lnk'
    $ws  = New-Object -ComObject WScript.Shell
    $sc  = $ws.CreateShortcut($lnk)
    $sc.TargetPath = $exe; $sc.WorkingDirectory = $targetApp; $sc.IconLocation = "$exe,0"
    $sc.Save()
    Write-Step "Shortcut created: $lnk"
}

Write-Host ""
Write-Host "[OK] RTL patch v0.2.0 installed." -ForegroundColor Green
Write-Host "     Launch: $exe" -ForegroundColor Green
if (-not $NoBackup -and (Test-Path $backup)) {
    Write-Host "     Previous install backed up at: $backup" -ForegroundColor DarkGray
    Write-Host "     Delete it once the new build works, or roll back with Restore-CodexRtl.ps1." -ForegroundColor DarkGray
}
