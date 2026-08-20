# Compose-Installer.ps1 - build assets/installer.png from the raw window grab.
# -----------------------------------------------------------------------------
# Places the installer window on the project's brand background and annotates it in
# English. The installer UI itself is Hebrew, and translating it would mean changing
# shipped code, so the callouts do that job for a README reader who cannot read the
# window.
#
# Usage:
#   .\Compose-Installer.ps1                                  # uses tools\raw\installer-picker.png
#   .\Compose-Installer.ps1 -Shot tools\raw\installer-plain.png
#
# Maintainer tooling: tools/ is NOT shipped in the release package. ASCII only.

[CmdletBinding()]
param(
    [string]$Shot = 'tools\raw\installer-picker.png',
    [string]$Out  = 'assets\installer.png'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$repoRoot = Split-Path -Parent $PSScriptRoot
$shotPath = if ([IO.Path]::IsPathRooted($Shot)) { $Shot } else { Join-Path $repoRoot $Shot }
if (-not (Test-Path $shotPath)) { throw "window grab not found: $shotPath (run Capture-Installer.ps1 first)" }

$img = [System.Drawing.Image]::FromFile($shotPath)
try { $sw = $img.Width; $sh = $img.Height } finally { $img.Dispose() }

$steps = @(
    @{ n = '1'; t = 'Pick your app';           s = 'Codex, Grok Bot, OpenCode, Traycer or T3 Code' },
    @{ n = '2'; t = 'Click Install';           s = 'It builds a separate patched copy, about a minute' },
    @{ n = '3'; t = 'Open the (RTL) shortcut'; s = 'Waiting on your Desktop and in the Start menu' }
)

$pad = 44; $gap = 60; $textW = 460
$canvasW = $pad + $sw + $gap + $textW + $pad
$canvasH = [math]::Max($sh + 2 * $pad, 420)
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($shotPath))

$stepHtml = ($steps | ForEach-Object {
@"
      <li>
        <span class="num">$($_.n)</span>
        <span class="txt"><b>$($_.t)</b><em>$($_.s)</em></span>
      </li>
"@
}) -join "`n"

$html = @"
<!doctype html>
<meta charset="utf-8">
<style>
  html,body { margin:0; padding:0; background:#0d1022;
              font-family:"Segoe UI",Arial,sans-serif; }
  .wrap { display:flex; align-items:center; gap:${gap}px; padding:${pad}px; width:max-content; }
  .shot { border-radius:10px; overflow:hidden; box-shadow:0 18px 48px rgba(0,0,0,.55);
          border:1px solid #322c58; line-height:0; }
  .shot img { display:block; width:${sw}px; }
  ol { list-style:none; margin:0; padding:0; width:${textW}px; }
  li { display:flex; align-items:flex-start; gap:16px; margin:0 0 30px; }
  li:last-child { margin-bottom:0; }
  .num { flex:0 0 34px; height:34px; border-radius:17px; background:#2a2350; color:#c9bfff;
         border:1px solid #443a80; font-size:17px; font-weight:700; text-align:center; line-height:34px; }
  .txt { display:block; padding-top:3px; }
  .txt b { display:block; color:#f4f2ff; font-size:21px; font-weight:600; }
  .txt em { display:block; color:#948dbd; font-size:15px; font-style:normal; margin-top:5px; }
</style>
<div class="wrap">
  <div class="shot"><img src="data:image/png;base64,$b64"></div>
  <ol>
$stepHtml
  </ol>
</div>
"@

$tmpHtml = Join-Path ([IO.Path]::GetTempPath()) ('rtl-installer-' + [Guid]::NewGuid().ToString('N') + '.html')
[IO.File]::WriteAllText($tmpHtml, $html, (New-Object Text.UTF8Encoding $false))
Write-Host ("window: {0}x{1}  canvas: {2}x{3}" -f $sw, $sh, $canvasW, $canvasH)
try {
    & (Join-Path $PSScriptRoot 'Render-Assets.ps1') -Source $tmpHtml -Out $Out -Width $canvasW -Height $canvasH
} finally {
    Remove-Item $tmpHtml -Force -ErrorAction SilentlyContinue
}
