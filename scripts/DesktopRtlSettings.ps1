# DesktopRtlSettings.ps1
# Per-app settings dialog for the Desktop RTL patch (WinForms, Hebrew, RTL). Reads/writes
# the per-app config.json via the shared library and applies changes to the live copy with
# Update-CodexRtlConfigAsset (no full rebuild). No admin. -App selects which app's settings
# to edit (codex|opencode). The two GLOBAL toggles (auto-update / tool-update checks) live
# in the unified tray, not here.
#
# -SelfTest builds the form without showing it (headless construction check).

param([ValidateSet('codex', 'opencode')][string]$App = 'codex', [switch]$NoRelaunch, [switch]$SelfTest)

# --- Relaunch under Windows PowerShell 5.1 + STA if needed -------------------
if (-not $SelfTest -and -not $NoRelaunch) {
    $needRelaunch = $false
    if ($PSVersionTable.PSEdition -eq 'Core') { $needRelaunch = $true }
    elseif ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { $needRelaunch = $true }
    if ($needRelaunch) {
        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath, '-NoRelaunch', '-App', $App)
        return
    }
}

$ErrorActionPreference = 'Stop'
# The lib sits next to us in bin, or under scripts\lib in the repo.
$here = $PSScriptRoot
$script:LibPath = $null
foreach ($c in @((Join-Path $here 'desktop-rtl-lib.ps1'), (Join-Path $here 'lib\desktop-rtl-lib.ps1'))) {
    if (Test-Path $c) { $script:LibPath = $c; break }
}

try {
    Add-Type -Namespace CodexRtl -Name NativeDpiS -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(System.IntPtr value);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@ -ErrorAction Stop
    try { if (-not [CodexRtl.NativeDpiS]::SetProcessDpiAwarenessContext([IntPtr](-4))) { [void][CodexRtl.NativeDpiS]::SetProcessDPIAware() } } catch {}
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

try {
    Add-Type -Namespace CodexRtl -Name TaskbarIdS -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
'@ -ErrorAction Stop
    [void][CodexRtl.TaskbarIdS]::SetCurrentProcessExplicitAppUserModelID('DesktopRtl.Settings')
} catch {}

if (-not $script:LibPath -or -not (Test-Path $script:LibPath)) {
    [System.Windows.Forms.MessageBox]::Show('חבילת ההתקנה חסרה קבצים.', 'Desktop RTL', 'OK', 'Error') | Out-Null
    return
}
. $script:LibPath
Set-RtlActiveApp $App
$appLabel = $script:ActiveProfile.ShortcutLabel
if (-not $SelfTest) { Hide-RtlConsole }

# --- Build the window --------------------------------------------------------
$cfg = Read-RtlConfig
$appCfg = $cfg.apps.$App   # NOTE: not $app - PowerShell vars are case-insensitive, so $app would alias the validated $App param

$form = New-Object System.Windows.Forms.Form
$form.Text = "הגדרות $appLabel"
$form.StartPosition = 'CenterScreen'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.RightToLeft = [System.Windows.Forms.RightToLeft]::Yes
$form.RightToLeftLayout = $true
# Size to the content so it opens fully readable (no manual resize), still resizable,
# and scroll only if the content would exceed the screen. AutoSize is DPI-proof: it
# measures the actual laid-out controls instead of a fixed ClientSize that scaling
# can override.
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox = $true; $form.MinimizeBox = $true
$form.AutoSize = $true
$form.AutoSizeMode = 'GrowAndShrink'
$form.AutoScroll = $true
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.MaximumSize = New-Object System.Drawing.Size(900, [Math]::Max(520, $wa.Height - 60))
try {
    $exe = Join-Path $script:CopyRoot $script:ActiveProfile.ExeRelPath
    if (Test-Path $exe) { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exe) }
} catch {}

$root = New-Object System.Windows.Forms.TableLayoutPanel
# NOT docked: an AutoSize panel reports its real content width/height to the AutoSize
# form (a Dock=Top panel reports zero width and collapses the form). The form then
# opens exactly fitting the content.
$root.ColumnCount = 1; $root.Padding = '12,12,12,12'
$root.AutoSize = $true; $root.AutoSizeMode = 'GrowAndShrink'
$root.Location = New-Object System.Drawing.Point(0, 0)
$form.Controls.Add($root)

function Add-Row($ctrl) { $ctrl.Margin = '0,0,0,8'; [void]$root.Controls.Add($ctrl); return $ctrl }

$title = New-Object System.Windows.Forms.Label
$title.Text = 'הגדרות תמיכת עברית (RTL)'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
Add-Row $title | Out-Null

$chkEnabled = New-Object System.Windows.Forms.CheckBox
$chkEnabled.Text = "הפעל תמיכת RTL עבור $appLabel"
$chkEnabled.AutoSize = $true
$chkEnabled.Checked = [bool]$appCfg.enabled
Add-Row $chkEnabled | Out-Null

# Direction policy
$grpDir = New-Object System.Windows.Forms.GroupBox
$grpDir.Text = 'כיוון טקסט'; $grpDir.AutoSize = $true; $grpDir.RightToLeft = 'Yes'
$grpDir.Dock = 'Top'; $grpDir.Padding = '8,4,8,8'
$dirPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$dirPanel.FlowDirection = 'TopDown'; $dirPanel.AutoSize = $true; $dirPanel.Dock = 'Top'; $dirPanel.WrapContents = $false
$rbAny = New-Object System.Windows.Forms.RadioButton
$rbAny.Text = 'כל שורה שיש בה עברית/ערבית תהפוך ל-RTL (ברירת מחדל)'; $rbAny.AutoSize = $true
$rbFirst = New-Object System.Windows.Forms.RadioButton
$rbFirst.Text = 'לפי התו החזק הראשון בשורה (firstStrong)'; $rbFirst.AutoSize = $true
if ($appCfg.direction.policy -eq 'firstStrong') { $rbFirst.Checked = $true } else { $rbAny.Checked = $true }
$dirPanel.Controls.AddRange(@($rbAny, $rbFirst))
$grpDir.Controls.Add($dirPanel)
Add-Row $grpDir | Out-Null

# Surfaces
$grpSurf = New-Object System.Windows.Forms.GroupBox
$grpSurf.Text = 'משטחים'; $grpSurf.AutoSize = $true; $grpSurf.RightToLeft = 'Yes'; $grpSurf.Dock = 'Top'; $grpSurf.Padding = '8,4,8,8'
$surfPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$surfPanel.FlowDirection = 'TopDown'; $surfPanel.AutoSize = $true; $surfPanel.Dock = 'Top'; $surfPanel.WrapContents = $false
$chkProse = New-Object System.Windows.Forms.CheckBox; $chkProse.Text = 'טקסט רגיל (פסקאות, כותרות, רשימות)'; $chkProse.AutoSize = $true; $chkProse.Checked = [bool]$appCfg.surfaces.prose
$chkInputs = New-Object System.Windows.Forms.CheckBox; $chkInputs.Text = 'שדות קלט (תיבת ההקלדה)'; $chkInputs.AutoSize = $true; $chkInputs.Checked = [bool]$appCfg.surfaces.inputs
$chkTables = New-Object System.Windows.Forms.CheckBox; $chkTables.Text = 'טבלאות'; $chkTables.AutoSize = $true; $chkTables.Checked = [bool]$appCfg.surfaces.tables
$chkMath = New-Object System.Windows.Forms.CheckBox; $chkMath.Text = 'בידוד נוסחאות ומתמטיקה (LaTeX / חשבון) משמאל-לימין'; $chkMath.AutoSize = $true; $chkMath.Checked = [bool]$appCfg.surfaces.math
$chkCodeIso = New-Object System.Windows.Forms.CheckBox; $chkCodeIso.Text = 'שמור קוד תמיד משמאל-לימין (מומלץ)'; $chkCodeIso.AutoSize = $true; $chkCodeIso.Checked = [bool]$appCfg.surfaces.codeIsolation
$surfPanel.Controls.AddRange(@($chkProse, $chkInputs, $chkTables, $chkMath, $chkCodeIso))
$grpSurf.Controls.Add($surfPanel)
Add-Row $grpSurf | Out-Null

# Font
$grpFont = New-Object System.Windows.Forms.GroupBox
$grpFont.Text = 'גופן (לטקסט עברי בלבד)'; $grpFont.AutoSize = $true; $grpFont.RightToLeft = 'Yes'; $grpFont.Dock = 'Top'; $grpFont.Padding = '8,4,8,8'
$fontPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$fontPanel.FlowDirection = 'TopDown'; $fontPanel.AutoSize = $true; $fontPanel.Dock = 'Top'; $fontPanel.WrapContents = $false
$chkFontOverride = New-Object System.Windows.Forms.CheckBox; $chkFontOverride.Text = 'החלף גופן וגודל'; $chkFontOverride.AutoSize = $true; $chkFontOverride.Checked = [bool]$appCfg.font.override
$cmbFamily = New-Object System.Windows.Forms.ComboBox; $cmbFamily.DropDownStyle = 'DropDown'; $cmbFamily.Width = 260
try { foreach ($ff in ([System.Drawing.FontFamily]::Families | Select-Object -ExpandProperty Name -Unique)) { [void]$cmbFamily.Items.Add($ff) } } catch {}
$cmbFamily.Text = [string]$appCfg.font.family
$numSize = New-Object System.Windows.Forms.NumericUpDown; $numSize.Minimum = 80; $numSize.Maximum = 150; $numSize.Increment = 5; $numSize.Value = [int]$appCfg.font.sizePercent
$lblSize = New-Object System.Windows.Forms.Label; $lblSize.Text = 'גודל (% מהרגיל):'; $lblSize.AutoSize = $true
$fontPanel.Controls.AddRange(@($chkFontOverride, $cmbFamily, $lblSize, $numSize))
$grpFont.Controls.Add($fontPanel)
Add-Row $grpFont | Out-Null
$syncFont = { $cmbFamily.Enabled = $chkFontOverride.Checked; $numSize.Enabled = $chkFontOverride.Checked; $lblSize.Enabled = $chkFontOverride.Checked }
$chkFontOverride.Add_CheckedChanged($syncFont); & $syncFont

$note = New-Object System.Windows.Forms.Label
$note.Text = "שינויים חלים בפעם הבאה שתפתח/י את $appLabel. (עדכון אוטומטי ובדיקת עדכונים מנוהלים מסמל המגש.)"
$note.AutoSize = $true; $note.ForeColor = [System.Drawing.Color]::DimGray
Add-Row $note | Out-Null

$status = New-Object System.Windows.Forms.Label
$status.AutoSize = $true; $status.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
Add-Row $status | Out-Null

# Buttons
$btnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$btnPanel.FlowDirection = 'LeftToRight'; $btnPanel.AutoSize = $true; $btnPanel.Dock = 'Top'; $btnPanel.RightToLeft = 'Yes'
$btnSave = New-Object System.Windows.Forms.Button; $btnSave.Text = 'שמור והחל'; $btnSave.AutoSize = $true; $btnSave.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = 'ביטול'; $btnCancel.AutoSize = $true
$btnReset = New-Object System.Windows.Forms.Button; $btnReset.Text = 'אפס לברירת מחדל'; $btnReset.AutoSize = $true
$btnPanel.Controls.AddRange(@($btnSave, $btnCancel, $btnReset))
Add-Row $btnPanel | Out-Null

# Pin the single column to the widest control's natural width so the Dock=Top group
# boxes fill a real width (instead of collapsing) and no checkbox text is clipped.
try {
    $wide = 0
    foreach ($ctl in @($title, $chkEnabled, $rbAny, $rbFirst, $chkProse, $chkInputs, $chkTables, $chkMath, $chkCodeIso, $chkFontOverride, $note)) {
        if ($ctl) { $pw = $ctl.PreferredSize.Width; if ($pw -gt $wide) { $wide = $pw } }
    }
    $colW = [Math]::Min([Math]::Max($wide + 88, 470), 860)
    $root.ColumnStyles.Clear()
    [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, [single]$colW)))
} catch {}

function Read-Controls {
    $c = Read-RtlConfig
    $c.apps.$App.enabled = [bool]$chkEnabled.Checked
    $c.apps.$App.direction.policy = if ($rbFirst.Checked) { 'firstStrong' } else { 'anyHebrew' }
    $c.apps.$App.surfaces.prose = [bool]$chkProse.Checked
    $c.apps.$App.surfaces.inputs = [bool]$chkInputs.Checked
    $c.apps.$App.surfaces.tables = [bool]$chkTables.Checked
    $c.apps.$App.surfaces.math = [bool]$chkMath.Checked
    $c.apps.$App.surfaces.codeIsolation = [bool]$chkCodeIso.Checked
    $c.apps.$App.font.override = [bool]$chkFontOverride.Checked
    $c.apps.$App.font.family = [string]$cmbFamily.Text
    $c.apps.$App.font.sizePercent = [int]$numSize.Value
    return $c
}

$btnSave.Add_Click({
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $c = Read-Controls
            Write-RtlConfig $c
            $st = $null; try { $st = Get-CodexRtlStatus } catch {}
            if (-not $st -or -not $st.CopyExists) {
                $status.Text = "נשמר. יוחל כשתתקין/י את $appLabel."
            } elseif (Test-CodexRtlRunning) {
                # The asar is locked while the copy runs; offer to close, apply, and reopen
                # now. If declined, the agent applies it automatically once the copy is next
                # closed (Sync-RtlConfigAsset on the update pass).
                $ans = [System.Windows.Forms.MessageBox]::Show(
                    "$appLabel פתוח כעת. כדי להחיל את השינויים צריך לסגור ולפתוח אותו מחדש." + [char]13 + [char]10 + [char]13 + [char]10 +
                    "לסגור אותו, להחיל, ולפתוח מחדש עכשיו?" + [char]13 + [char]10 +
                    "(אם לא - השינוי יוחל אוטומטית בפעם הבאה שתסגור/י אותו.)",
                    'Desktop RTL', 'YesNo', 'Question')
                if ($ans -eq 'Yes') {
                    if (Stop-CodexRtlApp) {
                        try {
                            Update-CodexRtlConfigAsset -AppId $App
                            [void](Start-RtlCopyApp)
                            $status.Text = "הוחל. $appLabel נפתח מחדש עם ההגדרות החדשות."
                        } catch { $status.Text = 'ההחלה נכשלה: ' + (Get-RtlHebrewError $_.Exception.Message) }
                    } else { $status.Text = "לא ניתן היה לסגור את $appLabel. סגור/י אותו ידנית וההגדרות יוחלו אוטומטית." }
                } else {
                    $status.Text = "נשמר. יוחל אוטומטית כשתסגור/י את $appLabel (עד כדקה)."
                }
            } else {
                try { Update-CodexRtlConfigAsset -AppId $App; $status.Text = "נשמר והוחל. פתח/י מחדש את $appLabel לראות את השינוי." }
                catch {
                    Write-RtlLog "config apply fallback to rebuild: $($_.Exception.Message)"
                    try { Invoke-CodexRtlUpdate -Force; $status.Text = 'נשמר והוחל (נבנה מחדש).' }
                    catch { $status.Text = 'נשמר, אך ההחלה נכשלה: ' + (Get-RtlHebrewError $_.Exception.Message) }
                }
            }
        } catch { $status.Text = 'שמירה נכשלה: ' + $_.Exception.Message }
        finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    })

$btnReset.Add_Click({
        $d = Get-RtlDefaultConfig
        $a = $d.apps.$App
        $chkEnabled.Checked = [bool]$a.enabled
        if ($a.direction.policy -eq 'firstStrong') { $rbFirst.Checked = $true } else { $rbAny.Checked = $true }
        $chkProse.Checked = [bool]$a.surfaces.prose; $chkInputs.Checked = [bool]$a.surfaces.inputs
        $chkTables.Checked = [bool]$a.surfaces.tables; $chkMath.Checked = [bool]$a.surfaces.math; $chkCodeIso.Checked = [bool]$a.surfaces.codeIsolation
        $chkFontOverride.Checked = [bool]$a.font.override; $cmbFamily.Text = [string]$a.font.family; $numSize.Value = [int]$a.font.sizePercent
        & $syncFont
        $status.Text = 'שוחזרו ברירות המחדל (לא נשמר עדיין).'
    })

$btnCancel.Add_Click({ $form.Close() })

# Get-RtlHebrewError normally comes from the shared lib; provide a tiny local fallback so
# this dialog can run standalone.
if (-not (Get-Command Get-RtlHebrewError -ErrorAction SilentlyContinue)) {
    function Get-RtlHebrewError([string]$m) { if ($m) { $m } else { 'שגיאה' } }
}

if ($SelfTest) {
    Write-Host ("SelfTest OK: settings form built; app={0}; policy={1}; enabled={2}" -f $App, $appCfg.direction.policy, $appCfg.enabled)
    $form.Dispose()
    return
}

[void]$form.ShowDialog()
$form.Dispose()
