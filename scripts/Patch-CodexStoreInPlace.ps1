<#
.SYNOPSIS
    In-place RTL patch for the Microsoft Store Codex (Option 2 core).
.DESCRIPTION
    MUST run elevated. Resolves the Store Codex app.asar, keeps a pristine
    per-version backup outside WindowsApps, takes ownership of the asar, restores
    it to pristine (idempotent), then injects the RTL patch with asar-edit.mjs.
    Writes status + log under %LOCALAPPDATA%\CodexRtlPatch so a non-elevated
    caller can read the result.
#>
[CmdletBinding()]
param(
    [string]$PatchJs,
    [string]$StateDir = (Join-Path $env:LOCALAPPDATA 'CodexRtlPatch')
)
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $PatchJs) {
    $repoRoot = Split-Path -Parent $scriptDir
    $PatchJs = Join-Path $repoRoot 'src\codex-rtl-patch.js'
}
$editor = Join-Path $scriptDir 'asar-edit.mjs'
if (-not (Test-Path $editor)) { $editor = Join-Path $scriptDir 'lib\asar-edit.mjs' }
$backupDir  = Join-Path $StateDir 'backup'
$logFile    = Join-Path $StateDir 'patch.log'
$statusFile = Join-Path $StateDir 'last-status.json'

function Log($m) {
    $l = "$([DateTime]::Now.ToString('o'))  $m"
    Write-Host $l
    try { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null; Add-Content -LiteralPath $logFile -Value $l -Encoding UTF8 } catch {}
}
function Save-Status($ok, $msg, $ver, $asar) {
    $o = [ordered]@{ ok = $ok; message = "$msg"; version = "$ver"; asar = "$asar"; at = (Get-Date).ToString('o') }
    try { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null; ($o | ConvertTo-Json) | Set-Content -LiteralPath $statusFile -Encoding UTF8 } catch {}
}

try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Not elevated (run as Administrator).'
    }
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $node) { throw 'Node.js not found on PATH.' }
    if (-not (Test-Path $editor))  { throw "asar-edit.mjs not found ($editor)." }
    if (-not (Test-Path $PatchJs)) { throw "patch script not found ($PatchJs)." }

    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $pkg) { throw 'OpenAI.Codex Store package not found.' }
    $ver = $pkg.Version
    $asarItem = Get-ChildItem (Join-Path $pkg.InstallLocation 'app\resources') -Filter app.asar -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $asarItem) { $asarItem = Get-ChildItem $pkg.InstallLocation -Recurse -Filter app.asar -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $asarItem) { throw "app.asar not found under $($pkg.InstallLocation)" }
    $asarPath = $asarItem.FullName
    Log "Store Codex v$ver"
    Log "asar: $asarPath"

    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $pristine = Join-Path $backupDir "app.asar.$ver.orig"
    if (-not (Test-Path $pristine)) {
        Log "Saving pristine backup -> $pristine"
        Copy-Item -LiteralPath $asarPath -Destination $pristine -Force
    } else {
        Log "Pristine backup already present for v$ver"
    }

    Log "attrs before: $((Get-Item -LiteralPath $asarPath -Force).Attributes)"
    $toOut = (& takeown.exe /f "$asarPath" /a 2>&1) | Out-String
    Log "takeown: $($toOut.Trim())"
    $icOut = (& icacls.exe "$asarPath" /grant "*S-1-5-32-544:(F)" 2>&1) | Out-String
    Log "icacls grant: $($icOut.Trim())"
    $atOut = (& attrib.exe -r -s -h "$asarPath" 2>&1) | Out-String
    Log "attrib clear: $($atOut.Trim())"
    Log "attrs after:  $((Get-Item -LiteralPath $asarPath -Force).Attributes)"
    $view = (& icacls.exe "$asarPath" 2>&1) | Out-String
    Log "icacls view: $($view.Trim())"

    Log "Restoring clean asar from pristine (idempotent), then injecting patch..."
    [System.IO.File]::WriteAllBytes($asarPath, [System.IO.File]::ReadAllBytes($pristine))

    $nodeOut = (& $node $editor "$asarPath" "$PatchJs" "--no-bak") | Out-String
    $code = $LASTEXITCODE
    Log "asar-edit: $($nodeOut.Trim())  (exit $code)"
    if ($code -ne 0) { throw "asar-edit failed (exit $code)" }

    Save-Status $true 'patched in place' $ver $asarPath
    Log "DONE: Store Codex v$ver patched in place."
    exit 0
} catch {
    Log "ERROR: $($_.Exception.Message)"
    Save-Status $false $_.Exception.Message '' ''
    exit 1
}
