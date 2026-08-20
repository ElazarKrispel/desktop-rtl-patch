# Render-Assets.ps1 - rasterise the generated artwork with headless Chrome.
# -----------------------------------------------------------------------------
# Turns a local .svg or .html file into a PNG at an exact pixel size. Used for the
# GitHub social preview (which must be a raster) and, in Phase 2, for the composed
# screenshot panels. The README banner stays SVG and is NOT rendered here.
#
# With no arguments it rebuilds every default job:
#   assets/social-preview.svg -> assets/social-preview.png   (1280x640)
#
# Single file:
#   .\Render-Assets.ps1 -Source tools\templates\installer.html -Out assets\installer.png -Width 1200 -Height 800
#
# Maintainer tooling: tools/ is NOT shipped in the release package. ASCII only.

[CmdletBinding()]
param(
    [string]$Source,
    [string]$Out,
    [int]$Width,
    [int]$Height,
    [int]$Scale = 1
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

function Get-HeadlessBrowser {
    $candidates = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    throw 'No Chrome or Edge found; install one or render the PNG by hand.'
}

function Invoke-Render {
    param([string]$SourcePath, [string]$OutPath, [int]$W, [int]$H, [int]$DeviceScale = 1)

    $src = if ([IO.Path]::IsPathRooted($SourcePath)) { $SourcePath } else { Join-Path $repoRoot $SourcePath }
    $dst = if ([IO.Path]::IsPathRooted($OutPath))    { $OutPath }    else { Join-Path $repoRoot $OutPath }
    if (-not (Test-Path $src)) { throw "source not found: $src" }

    $browser = Get-HeadlessBrowser
    # A throwaway profile keeps the render independent of the signed-in browser and
    # stops Chrome from reusing an existing instance (which would ignore our flags).
    $profileDir = Join-Path ([IO.Path]::GetTempPath()) ('rtl-render-' + [Guid]::NewGuid().ToString('N'))
    $uri = ([Uri](Resolve-Path $src).Path).AbsoluteUri

    # Quote every path-bearing switch: the repo path may contain spaces (and does
    # contain non-ASCII on the maintainer's machine), which Chrome otherwise splits
    # into extra positional arguments and then exits 13 without writing a file.
    # NOTE: do not name this $args, that is a PowerShell automatic variable.
    $chromeArgs = @(
        '--headless=new', '--disable-gpu', '--hide-scrollbars',
        ('--user-data-dir="{0}"' -f $profileDir),
        "--force-device-scale-factor=$DeviceScale",
        "--window-size=$W,$H",
        ('--screenshot="{0}"' -f $dst),
        ('"{0}"' -f $uri)
    )
    try {
        $p = Start-Process -FilePath $browser -ArgumentList $chromeArgs -Wait -PassThru -WindowStyle Hidden
        if (-not (Test-Path $dst)) { throw "render produced no file (browser exit $($p.ExitCode)): $dst" }
        $bytes = (Get-Item $dst).Length
        Write-Host ("  {0,-34} {1}x{2}  {3:N0} bytes" -f (Split-Path $dst -Leaf), ($W * $DeviceScale), ($H * $DeviceScale), $bytes)
        if ($bytes -gt 1MB) { Write-Warning "$([IO.Path]::GetFileName($dst)) is over 1 MB; GitHub's social preview upload rejects that." }
    } finally {
        if (Test-Path $profileDir) { Remove-Item $profileDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

if ($Source) {
    if (-not $Out -or -not $Width -or -not $Height) { throw 'With -Source you must also pass -Out, -Width and -Height.' }
    Invoke-Render -SourcePath $Source -OutPath $Out -W $Width -H $Height -DeviceScale $Scale
} else {
    Write-Host 'Rendering default jobs:'
    Invoke-Render -SourcePath 'assets\social-preview.svg' -OutPath 'assets\social-preview.png' -W 1280 -H 640
}
