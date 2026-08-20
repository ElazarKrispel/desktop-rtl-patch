# Build-Banner.ps1 - generate the README banner and the GitHub social preview.
# -----------------------------------------------------------------------------
# One data table below drives BOTH artwork variants, so adding a supported app
# means editing ONE array. Text is measured with GDI+ and emitted with explicit
# text-anchor/textLength, which keeps every centred row exactly centred no matter
# how the viewing renderer's font metrics differ from ours.
#
# Outputs (overwritten in place):
#   assets/banner.svg          1600x460, the README identity band (no tagline)
#   assets/social-preview.svg  1280x640, source for assets/social-preview.png
#
# The PNG is produced separately by tools/Render-Assets.ps1 (headless Chrome).
# Maintainer tooling: tools/ is NOT shipped in the release package.
#
# ASCII only (Windows PowerShell 5.1 reads .ps1 as ANSI without a BOM), so the
# middle-dot separator is emitted as the XML entity &#183; and measured via
# [char]0x00B7.
#
# Usage: powershell -ExecutionPolicy Bypass -File tools\Build-Banner.ps1

param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$repoRoot = Split-Path -Parent $PSScriptRoot
$assets   = Join-Path $repoRoot 'assets'
$logoPath = Join-Path $assets 'logo.png'
if (-not (Test-Path $logoPath)) { throw "logo not found: $logoPath" }

# ---------------------------------------------------------------- source data
$Product   = 'Desktop RTL Patch'
$Tagline   = 'Hebrew & Arabic RTL support for AI desktop apps on Windows.'
$Apps      = @('ChatGPT / Codex', 'Grok Bot', 'OpenCode', 'Traycer', 'T3 Code')
$Chips     = @('Windows 10/11', 'No admin', 'Originals untouched', 'Auto re-patching')
$SocialSub = @('No admin', 'Originals untouched', 'Auto re-patching')

$C = @{
    BgTop = '#0d1022'; BgMid    = '#141230'; BgBot    = '#1a1333'
    Glow  = '#7c5cff'
    Title = '#f4f2ff'; Tag      = '#b9b3d8'
    ChipBg= '#241f45'; ChipLine = '#3b3370'; ChipText = '#d9d4f2'
    Label = '#6f6a96'; AppText  = '#b3adcf'; Sep      = '#5b5686'; SubText = '#8e88b5'
}
$Family  = 'Segoe UI, Arial, sans-serif'
$SepChar = [string][char]0x00B7   # measured form
$SepXml  = '&#183;'               # emitted form (keeps the SVG ASCII)

# ------------------------------------------------------------- text measuring
$bmp = New-Object System.Drawing.Bitmap 1, 1
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
$fmt = [System.Drawing.StringFormat]::GenericTypographic

function Measure-TextWidth {
    param([string]$Text, [single]$Size, [switch]$Bold)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $font  = New-Object System.Drawing.Font('Segoe UI', $Size, $style, [System.Drawing.GraphicsUnit]::Pixel)
    try {
        $origin = New-Object System.Drawing.PointF 0, 0
        [double]$gfx.MeasureString($Text, $font, $origin, $fmt).Width
    } finally { $font.Dispose() }
}

function ConvertTo-XmlText([string]$s) {
    $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

# One row of items joined by a middle dot. Every item is placed at its own measured
# centre with textLength, so the row cannot drift in another renderer. Pass -StartX
# to left-align the row, or -CenterX to centre it.
function New-DotRow {
    param(
        [string[]]$Items, [double]$BaselineY, [single]$Size,
        [string]$Fill, [string]$SepFill, [double]$Gap = 18,
        [double]$CenterX = [double]::NaN, [double]$StartX = [double]::NaN
    )
    $widths = @($Items | ForEach-Object { Measure-TextWidth -Text $_ -Size $Size })
    $sepW   = Measure-TextWidth -Text $SepChar -Size $Size
    $total  = ($widths | Measure-Object -Sum).Sum + ($Items.Count - 1) * ($sepW + 2 * $Gap)
    $x      = if ([double]::IsNaN($StartX)) { $CenterX - $total / 2 } else { $StartX }
    $out    = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $w  = $widths[$i]
        $cx = [math]::Round($x + $w / 2, 1)
        [void]$out.AppendLine(('    <text x="{0}" y="{1}" text-anchor="middle" textLength="{2}" lengthAdjust="spacingAndGlyphs" fill="{3}">{4}</text>' -f
            $cx, $BaselineY, [math]::Round($w, 1), $Fill, (ConvertTo-XmlText $Items[$i])))
        $x += $w
        if ($i -lt $Items.Count - 1) {
            $scx = [math]::Round($x + $Gap + $sepW / 2, 1)
            [void]$out.AppendLine(('    <text x="{0}" y="{1}" text-anchor="middle" fill="{2}">{3}</text>' -f
                $scx, $BaselineY, $SepFill, $SepXml))
            $x += $sepW + 2 * $Gap
        }
    }
    $out.ToString().TrimEnd()
}

# A row of pill chips; each rect is sized from its measured label. Same -StartX /
# -CenterX contract as New-DotRow.
function New-ChipRow {
    param(
        [string[]]$Items, [double]$TopY, [single]$Size,
        [double]$PadX = 22, [double]$Height = 42, [double]$Gap = 16,
        [double]$CenterX = [double]::NaN, [double]$StartX = [double]::NaN
    )
    $widths = @($Items | ForEach-Object { Measure-TextWidth -Text $_ -Size $Size })
    $boxes  = @($widths | ForEach-Object { $_ + 2 * $PadX })
    $total  = ($boxes | Measure-Object -Sum).Sum + ($Items.Count - 1) * $Gap
    $x      = if ([double]::IsNaN($StartX)) { $CenterX - $total / 2 } else { $StartX }
    $rx     = [math]::Round($Height / 2, 0)
    $out    = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $bw = [math]::Round($boxes[$i], 1)
        [void]$out.AppendLine(('    <rect x="{0}" y="{1}" rx="{2}" ry="{2}" width="{3}" height="{4}" fill="{5}" stroke="{6}"/>' -f
            [math]::Round($x, 1), $TopY, $rx, $bw, $Height, $C.ChipBg, $C.ChipLine))
        [void]$out.AppendLine(('    <text x="{0}" y="{1}" text-anchor="middle" textLength="{2}" lengthAdjust="spacingAndGlyphs" fill="{3}">{4}</text>' -f
            [math]::Round($x + $bw / 2, 1), [math]::Round($TopY + $Height / 2 + $Size * 0.35, 1),
            [math]::Round($widths[$i], 1), $C.ChipText, (ConvertTo-XmlText $Items[$i])))
        $x += $bw + $Gap
    }
    $out.ToString().TrimEnd()
}

function New-Defs {
@"
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="$($C.BgTop)"/>
      <stop offset="0.55" stop-color="$($C.BgMid)"/>
      <stop offset="1" stop-color="$($C.BgBot)"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="$($C.Glow)" stop-opacity="0.35"/>
      <stop offset="1" stop-color="$($C.Glow)" stop-opacity="0"/>
    </radialGradient>
  </defs>
"@
}

$logoB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($logoPath))

# --------------------------------------------------------------------- banner
function Build-Banner {
    # 1600x460 (3.48:1). The banner is the project's VISUAL IDENTITY only: a logo
    # lockup, the trust chips and the supported apps. It deliberately does NOT
    # carry the tagline and does NOT set the product name as a headline, because
    # the README's own <h1> is the document title and repeating either one at
    # headline weight 30px below reads as a duplicate. The wordmark here is a
    # lockup label (medium weight, muted), not a title. The social preview is a
    # standalone card, so that one DOES set the name large.
    $W = 1600; $H = 460
    $colX = 480                               # every row shares this left edge

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" ' +
        ('width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f $W, $H))
    [void]$sb.AppendLine((New-Defs))
    [void]$sb.AppendLine(('  <rect width="{0}" height="{1}" fill="url(#bg)"/>' -f $W, $H))
    [void]$sb.AppendLine('  <circle cx="250" cy="230" r="260" fill="url(#glow)"/>')
    [void]$sb.AppendLine('  <circle cx="1420" cy="70" r="190" fill="url(#glow)" opacity="0.5"/>')
    [void]$sb.AppendLine(('  <image x="140" y="100" width="260" height="260" xlink:href="data:image/png;base64,{0}"/>' -f $logoB64))
    # Sized and coloured to stay BELOW the README's <h1> in the visual hierarchy:
    # at README width this renders around 27px against the h1's 32px, and muted
    # rather than white, so the pair reads as "logo band, then document title".
    [void]$sb.AppendLine(('  <text x="{0}" y="148" font-family="{1}" font-size="46" font-weight="600" letter-spacing="1" fill="{2}">{3}</text>' -f
        $colX, $Family, $C.Tag, (ConvertTo-XmlText $Product)))
    [void]$sb.AppendLine(('  <g font-family="{0}" font-size="23">' -f $Family))
    [void]$sb.AppendLine((New-ChipRow -Items $Chips -StartX $colX -TopY 186 -Size 23 -Height 44))
    [void]$sb.AppendLine('  </g>')
    [void]$sb.AppendLine(('  <text x="{0}" y="292" font-family="{1}" font-size="18" letter-spacing="4" fill="{2}">WORKS WITH</text>' -f
        $colX, $Family, $C.Label))
    [void]$sb.AppendLine(('  <g font-family="{0}" font-size="30">' -f $Family))
    [void]$sb.AppendLine((New-DotRow -Items $Apps -StartX $colX -BaselineY 346 -Size 30 -Fill $C.AppText -SepFill $C.Sep))
    [void]$sb.AppendLine('  </g>')
    [void]$sb.AppendLine('</svg>')
    $sb.ToString()
}

# ------------------------------------------------------------- social preview
function Build-Social {
    $W = 1280; $H = 640
    $cx = $W / 2

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" ' +
        ('width="{0}" height="{1}" viewBox="0 0 {0} {1}">' -f $W, $H))
    [void]$sb.AppendLine((New-Defs))
    [void]$sb.AppendLine(('  <rect width="{0}" height="{1}" fill="url(#bg)"/>' -f $W, $H))
    [void]$sb.AppendLine('  <circle cx="200" cy="120" r="300" fill="url(#glow)"/>')
    [void]$sb.AppendLine('  <circle cx="1120" cy="560" r="300" fill="url(#glow)" opacity="0.6"/>')
    [void]$sb.AppendLine(('  <image x="{0}" y="88" width="160" height="160" xlink:href="data:image/png;base64,{1}"/>' -f ($cx - 80), $logoB64))

    $tw = Measure-TextWidth -Text $Product -Size 78 -Bold
    [void]$sb.AppendLine(('  <text x="{0}" y="330" text-anchor="middle" textLength="{1}" lengthAdjust="spacingAndGlyphs" font-family="{2}" font-size="78" font-weight="700" fill="{3}">{4}</text>' -f
        $cx, [math]::Round($tw, 1), $Family, $C.Title, (ConvertTo-XmlText $Product)))
    $gw = Measure-TextWidth -Text $Tagline -Size 36
    [void]$sb.AppendLine(('  <text x="{0}" y="390" text-anchor="middle" textLength="{1}" lengthAdjust="spacingAndGlyphs" font-family="{2}" font-size="36" fill="{3}">{4}</text>' -f
        $cx, [math]::Round($gw, 1), $Family, $C.Tag, (ConvertTo-XmlText $Tagline)))

    [void]$sb.AppendLine(('  <g font-family="{0}" font-size="27">' -f $Family))
    [void]$sb.AppendLine((New-DotRow -Items $SocialSub -CenterX $cx -BaselineY 452 -Size 27 -Fill $C.SubText -SepFill $C.Sep))
    [void]$sb.AppendLine('  </g>')
    [void]$sb.AppendLine(('  <g font-family="{0}" font-size="32">' -f $Family))
    [void]$sb.AppendLine((New-DotRow -Items $Apps -CenterX $cx -BaselineY 552 -Size 32 -Fill $C.AppText -SepFill $C.Sep))
    [void]$sb.AppendLine('  </g>')
    [void]$sb.AppendLine('</svg>')
    $sb.ToString()
}

function Save-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

Save-Utf8NoBom (Join-Path $assets 'banner.svg') (Build-Banner)
Save-Utf8NoBom (Join-Path $assets 'social-preview.svg') (Build-Social)
$gfx.Dispose(); $bmp.Dispose()

if (-not $Quiet) {
    Write-Host ("banner.svg          {0} bytes" -f (Get-Item (Join-Path $assets 'banner.svg')).Length)
    Write-Host ("social-preview.svg  {0} bytes" -f (Get-Item (Join-Path $assets 'social-preview.svg')).Length)
    Write-Host ("apps: {0}" -f ($Apps -join ', '))
}
