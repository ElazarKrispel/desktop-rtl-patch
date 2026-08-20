# Compose-Screens.ps1 - build assets/before-after.png from two raw captures.
# -----------------------------------------------------------------------------
# Takes the full-viewport screenshots produced by tools/CAPTURE.md step 3 (one from
# the original app, one from the patched "(RTL)" copy) plus their .json sidecars,
# crops both to the SAME CSS-pixel region around the reply, and lays them out as a
# labelled two-panel comparison.
#
# The two apps can report different device pixel ratios, so the crop is expressed in
# CSS pixels and converted per image using that image's own scale (png width divided
# by the viewport width recorded in its sidecar). That is what keeps both panels
# showing an identical region even when the rasters differ.
#
# Usage:
#   .\Compose-Screens.ps1 -Before tools\raw\before-full.png -After tools\raw\after-full.png
#
# Maintainer tooling: tools/ is NOT shipped in the release package. ASCII only.

[CmdletBinding()]
param(
    [string]$Before = 'tools\raw\before-full.png',
    [string]$After  = 'tools\raw\after-full.png',
    [string]$Out    = 'assets\before-after.png',
    [int]$PanelWidth = 720,
    [string]$BeforeLabel = 'BEFORE',
    [string]$BeforeSub   = 'the original app',
    [string]$AfterLabel  = 'AFTER',
    [string]$AfterSub    = 'the "(RTL)" copy'
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
function Resolve-RepoPath([string]$p) {
    if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $repoRoot $p }
}

Add-Type -AssemblyName System.Drawing

function Get-Capture([string]$PngPath) {
    $png = Resolve-RepoPath $PngPath
    if (-not (Test-Path $png)) { throw "capture not found: $png" }
    $meta = [IO.Path]::ChangeExtension($png, '.json')
    if (-not (Test-Path $meta)) { throw "sidecar not found: $meta (re-run the capture step)" }

    $j = Get-Content $meta -Raw | ConvertFrom-Json
    $img = [System.Drawing.Image]::FromFile($png)
    try { $pw = $img.Width; $ph = $img.Height } finally { $img.Dispose() }

    # CSS px -> raster px for THIS capture.
    $scale = $pw / [double]$j.vw
    [pscustomobject]@{
        Path = $png; PixelWidth = $pw; PixelHeight = $ph; Scale = $scale
        Msg = $j.msg; Scroll = $j.scroll; ViewportW = $j.vw; ViewportH = $j.vh
    }
}

$b = Get-Capture $Before
$a = Get-Capture $After

# One crop rectangle in CSS pixels, applied to both. The reply can overflow its own
# bubble, so the width comes from scrollWidth rather than the bubble's rect.
$padX = 14; $padTop = 10; $padBottom = 12
$cropW = [math]::Max($b.Msg.w, $b.Scroll.w) + 2 * $padX
$cropH = [math]::Max($b.Msg.h, $b.Scroll.h) + $padTop + $padBottom
$aCropW = [math]::Max($a.Msg.w, $a.Scroll.w) + 2 * $padX
$aCropH = [math]::Max($a.Msg.h, $a.Scroll.h) + $padTop + $padBottom
if ($cropW -ne $aCropW -or $cropH -ne $aCropH) {
    Write-Warning "the two replies do not occupy the same box (before ${cropW}x${cropH}, after ${aCropW}x${aCropH}); using the larger of each"
    $cropW = [math]::Max($cropW, $aCropW)
    $cropH = [math]::Max($cropH, $aCropH)
}

# Display scale so the crop fills exactly $PanelWidth.
$display = $PanelWidth / [double]$cropW
$panelH  = [math]::Round($cropH * $display)

function New-Panel {
    param($Cap, [string]$Label, [string]$Sub, [string]$Accent, [string]$AccentBg)
    $s = $Cap.Scale
    # Scale the raster so one CSS px of the capture maps to $display px on the canvas.
    # Offsets are therefore CSS px * $display: do NOT multiply by $s again, the img
    # element is already carrying that conversion in its width.
    $imgW = [math]::Round($Cap.PixelWidth / $s * $display, 2)
    $left = [math]::Round(($Cap.Msg.x - $padX) * $display, 2)
    $top  = [math]::Round(($Cap.Msg.y - $padTop) * $display, 2)
    $b64  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Cap.Path))
@"
    <div class="panel">
      <div class="head" style="background:$AccentBg;color:$Accent">
        <span class="lbl">$Label</span><span class="sub">$Sub</span>
      </div>
      <div class="shot" style="width:${PanelWidth}px;height:${panelH}px">
        <img src="data:image/png;base64,$b64" style="width:${imgW}px;left:-${left}px;top:-${top}px">
      </div>
    </div>
"@
}

$totalW = 2 * $PanelWidth + 28 + 2 * 32
$totalH = $panelH + 46 + 2 * 32

$html = @"
<!doctype html>
<meta charset="utf-8">
<style>
  html,body { margin:0; padding:0; background:#0d1022; }
  .row { display:flex; gap:28px; padding:32px; width:max-content; }
  .panel { border:1px solid #322c58; border-radius:14px; overflow:hidden; background:#fff; }
  .head { height:46px; display:flex; align-items:center; gap:10px; padding:0 16px;
          font:600 15px/1 "Segoe UI",Arial,sans-serif; letter-spacing:1px; }
  .head .sub { font-weight:400; letter-spacing:0; opacity:.72; font-size:14px; }
  .shot { position:relative; overflow:hidden; }
  .shot img { position:absolute; display:block; }
</style>
<div class="row">
$(New-Panel -Cap $b -Label $BeforeLabel -Sub $BeforeSub -Accent '#ff9aa8' -AccentBg '#2c1720')
$(New-Panel -Cap $a -Label $AfterLabel  -Sub $AfterSub  -Accent '#84e6ac' -AccentBg '#15271e')
</div>
"@

$tmpHtml = Join-Path ([IO.Path]::GetTempPath()) ('rtl-compose-' + [Guid]::NewGuid().ToString('N') + '.html')
[IO.File]::WriteAllText($tmpHtml, $html, (New-Object Text.UTF8Encoding $false))

Write-Host ("crop  : {0}x{1} CSS px  (before scale {2:N3}, after scale {3:N3})" -f $cropW, $cropH, $b.Scale, $a.Scale)
Write-Host ("canvas: {0}x{1}" -f $totalW, $totalH)

try {
    & (Join-Path $PSScriptRoot 'Render-Assets.ps1') -Source $tmpHtml -Out $Out -Width $totalW -Height $totalH
} finally {
    Remove-Item $tmpHtml -Force -ErrorAction SilentlyContinue
}
