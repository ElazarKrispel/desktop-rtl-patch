# Install-DesktopRtlGui.ps1
# Friendly graphical installer for the Desktop RTL patch (WinForms, Hebrew UI).
# Wraps the already-tested library functions in desktop-rtl-lib.ps1. No admin.
#
# Launched by Install-Desktop-RTL.cmd (powershell -STA -WindowStyle Hidden), or directly.
# -SelfTest builds the form without showing it (for headless construction checks).

param([switch]$NoRelaunch, [switch]$SelfTest)

# --- Relaunch under Windows PowerShell 5.1 + STA if needed -------------------
if (-not $SelfTest -and -not $NoRelaunch) {
    $needRelaunch = $false
    if ($PSVersionTable.PSEdition -eq 'Core') { $needRelaunch = $true }                       # running under pwsh
    elseif ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { $needRelaunch = $true }
    if ($needRelaunch) {
        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath, '-NoRelaunch')
        return
    }
}

$ErrorActionPreference = 'Stop'
$script:RepoRoot = Split-Path -Parent $PSScriptRoot         # ...\scripts\.. = repo root
$script:LibPath  = Join-Path $script:RepoRoot 'scripts\lib\desktop-rtl-lib.ps1'

# --- High DPI awareness (safe, staged) BEFORE creating any control -----------
try {
    Add-Type -Namespace CodexRtl -Name NativeDpi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(System.IntPtr value);
[System.Runtime.InteropServices.DllImport("shcore.dll")] public static extern int  SetProcessDpiAwareness(int value);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@ -ErrorAction Stop
    $dpiDone = $false
    try { if ([CodexRtl.NativeDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))) { $dpiDone = $true } } catch {}   # Per-Monitor-V2
    if (-not $dpiDone) { try { [void][CodexRtl.NativeDpi]::SetProcessDpiAwareness(2); $dpiDone = $true } catch {} } # Per-Monitor
    if (-not $dpiDone) { try { [void][CodexRtl.NativeDpi]::SetProcessDPIAware() } catch {} }                        # System
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# Give the process a distinct AppUserModelID so its taskbar button uses the window's
# own icon (Codex) and its own label, instead of grouping under (and showing the icon
# of) PowerShell. Must be set before the window is created.
try {
    Add-Type -Namespace CodexRtl -Name TaskbarId -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
'@ -ErrorAction Stop
    [void][CodexRtl.TaskbarId]::SetCurrentProcessExplicitAppUserModelID('CodexRtl.Installer')
} catch {}

# --- Package integrity (the lib must exist before we can use Test-RtlPackage) -
if (-not (Test-Path $script:LibPath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "חבילת ההתקנה חסרה קבצים. ודא/י שחילצת את כל ה-ZIP, לא רק את קובץ ה-cmd, ונסה/י שוב.",
        'Desktop RTL', 'OK', 'Error') | Out-Null
    return
}
. $script:LibPath
Hide-RtlConsole   # hide the background PowerShell console; the GUI window stays visible
try { Test-RtlPackage -RepoRoot $script:RepoRoot | Out-Null }
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "חבילת ההתקנה חסרה קבצים. ודא/י שחילצת את כל ה-ZIP, לא רק את קובץ ה-cmd, ונסה/י שוב.`n`n$($_.Exception.Message)",
        'Desktop RTL', 'OK', 'Error') | Out-Null
    return
}

# --- Shared state between the UI thread and the background runspace -----------
$script:Sync = [hashtable]::Synchronized(@{
        Lines       = New-Object System.Collections.ArrayList
        StepKey     = ''
        StepPct     = 0
        StepMarquee = $false
        Done        = $false
        Ok          = $false
        Err         = $null
        Busy        = $false
        Op          = 'install'
    })
$script:Job = $null

# --- Hebrew helpers ----------------------------------------------------------
function Get-StepHebrew([string]$key) {
    $appName = try { $script:ActiveProfile.DisplayName } catch { 'האפליקציה' }
    switch ($key) {
        'preflight' { 'בודק את המערכת...' ; break }
        'copy'      { "מעתיק את $appName. זה עשוי לקחת כדקה..." ; break }
        'inject'    { 'מחיל את תיקון העברית (RTL)...' ; break }
        'verify'    { 'מאמת שהתיקון הוחל כראוי...' ; break }
        'swap'      { 'מחליף קבצים...' ; break }
        'shortcut'  { 'יוצר קיצורי דרך...' ; break }
        'deferred'  { "העדכון מוכן, ויוחל בפעם הבאה שתסגור/י את $appName (RTL)." ; break }
        'done'      { 'הושלם!' ; break }
        default     { '' }
    }
}

function Get-RtlHebrewError([string]$msg) {
    if (-not $msg) { return 'הפעולה נכשלה. ראה/י את הלוג למטה ושלח/י אותו למפתח.' }
    $appName = try { $script:ActiveProfile.DisplayName } catch { 'האפליקציה' }
    switch -Regex ($msg) {
        '^\[NOCODEX\]' { "$appName אינו מותקן. התקן/י אותו ואז לחץ/י ""בדוק שוב""." ; break }
        '^\[NODE\]'    { "מנוע ה-Node של $appName לא נמצא. ייתכן שהאפליקציה לא הותקנה במלואה או עודכנה. נסה/י לתקן את ההתקנה ואז לנסות שוב." ; break }
        '^\[LAYOUT\]'  { "$appName זוהה אך המבנה הפנימי שלו אינו כמצופה. ייתכן שהאפליקציה עודכנה ושהכלי צריך עדכון. עדכן/י את הכלי או פנה/י למפתח." ; break }
        '^\[FUSE\]'    { "בגרסה זו של $appName אימות ה-asar מופעל, ולכן שיטת ההעתקה אינה יכולה להחיל את התיקון. אנא דווח/י למפתח." ; break }
        '^\[DISK\]'    { 'אין מספיק מקום פנוי בדיסק. פנה/י מספר GB ונסה/י שוב.' ; break }
        '^\[LOCK\]'    { "חלק מהקבצים נעולים (אולי אנטי-וירוס, סייר הקבצים, או ש-$appName (RTL) פתוח). סגור/י אותם ונסה/י שוב." ; break }
        '^\[AV\]'      { "הפעולה נחסמה כנראה על ידי האנטי-וירוס (Windows Defender). הכלי עורך רק עותק מקומי של $appName ואינו נוגע במקור. אפשר לאשר זמנית או להוסיף חריגה ולנסות שוב." ; break }
        '^\[PACKAGE\]' { 'חבילת ההתקנה חסרה קבצים. ודא/י שחילצת את כל ה-ZIP, לא רק את קובץ ה-cmd, ונסה/י שוב.' ; break }
        '^\[SAFETY\]'  { "הפעולה בוטלה מטעמי בטיחות (ניסיון לגעת בקובץ מחוץ לעותק ה-RTL). ההתקנה המקורית של $appName לא נפגעה." ; break }
        '^\[VERIFY\]'  { 'בדיקת התקינות שלאחר ההתקנה נכשלה: התיקון לא אומת בעותק. נסה/י "התקן מחדש". אם התקלה חוזרת, שלח/י את הלוג למפתח.' ; break }
        '^\[STAGING\]' { 'בניית העותק הזמני נכשלה או נותרה חלקית. נסה/י "התקן מחדש"; אם התקלה חוזרת, פנה/י תיקיית %LOCALAPPDATA%\OpenAI ובדוק/י שאין תהליך שנועל אותה.' ; break }
        '^\[INTEGRITY\]' { 'בדיקת ה-checksum של קובץ ההורדה נכשלה. ההורדה בוטלה ולא בוצע שום שינוי. נסה/י שוב; אם התקלה חוזרת, הורד/י מחדש מ-GitHub.' ; break }
        '^\[CANCEL\]'  { 'הפעולה בוטלה.' ; break }
        default        { "הפעולה נכשלה. הפרטים נשמרו בקובץ הלוג, אנא שלח/י אותו למפתח.`r`n`r`n$msg" }
    }
}

function Add-LogLine([string]$text) {
    if ($script:LogBox) { $script:LogBox.AppendText($text + "`r`n") }
}

# --- Build the window --------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'התקנת Codex (RTL)'
$form.StartPosition = 'CenterScreen'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Font
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.RightToLeft = [System.Windows.Forms.RightToLeft]::Yes
$form.RightToLeftLayout = $true
$form.MinimumSize = New-Object System.Drawing.Size(560, 460)
$form.ClientSize  = New-Object System.Drawing.Size(580, 470)
$form.MaximizeBox = $false
$form.FormBorderStyle = 'Sizable'
# Use the selected app's own icon for the installer window (no separate branded icon).
# ExtractAssociatedIcon needs an Icon object, so this is the one place we extract; the
# shortcut itself just points IconLocation at the exe.
function Set-RtlFormIcon {
    try {
        $p = $script:ActiveProfile
        $iconExe = $null
        $cands = @((Join-Path $script:CopyRoot $p.ExeRelPath))
        $srcForIcon = $null; try { $srcForIcon = Resolve-RtlSource } catch {}
        if ($srcForIcon) { $cands += (Join-Path $srcForIcon.AppDir $p.ExeLeaf) }
        foreach ($c in $cands) { if (Test-Path $c) { $iconExe = $c; break } }
        if ($iconExe) { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconExe) }
    } catch {}
}
Set-RtlFormIcon

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.ColumnCount = 1
$root.RowCount = 7
$root.Padding = New-Object System.Windows.Forms.Padding(16)
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
foreach ($h in 0, 0, 0, 0, 0, 100, 0) {
    $t = if ($h -eq 0) { [System.Windows.Forms.SizeType]::AutoSize } else { [System.Windows.Forms.SizeType]::Percent }
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($t, $h)))
}
$form.Controls.Add($root)

# --- App picker (single screen serves both Codex and OpenCode) ---------------
$pickPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$pickPanel.FlowDirection = 'RightToLeft'
$pickPanel.AutoSize = $true
$pickPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$pickPanel.Margin = New-Object System.Windows.Forms.Padding(3, 0, 3, 6)
$pickLabel = New-Object System.Windows.Forms.Label
$pickLabel.Text = 'אפליקציה:'
$pickLabel.AutoSize = $true
$pickLabel.Margin = New-Object System.Windows.Forms.Padding(3, 8, 6, 3)
$pickCombo = New-Object System.Windows.Forms.ComboBox
$pickCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$pickCombo.Width = 160
$pickCombo.Margin = New-Object System.Windows.Forms.Padding(3, 4, 3, 3)
[void]$pickCombo.Items.Add('Codex')
[void]$pickCombo.Items.Add('OpenCode')
$pickCombo.SelectedIndex = 0
$pickPanel.Controls.AddRange(@($pickLabel, $pickCombo))
$root.Controls.Add($pickPanel, 0, 0)
$script:AppCombo = $pickCombo
# ComboBox item index -> app id.
$script:AppIds = @('codex', 'opencode')

$title = New-Object System.Windows.Forms.Label
$title.Text = 'תמיכת עברית (RTL) ל-Codex'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 8)
$root.Controls.Add($title, 0, 1)
$script:TitleLabel = $title

$desc = New-Object System.Windows.Forms.Label
$desc.Text = ''
$desc.AutoSize = $true
$desc.MaximumSize = New-Object System.Drawing.Size(520, 0)
$desc.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 10)
$root.Controls.Add($desc, 0, 2)
$script:DescLabel = $desc

$status = New-Object System.Windows.Forms.Label
$status.Text = ''
$status.AutoSize = $true
$status.MaximumSize = New-Object System.Drawing.Size(520, 0)
$status.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$status.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 6)
$root.Controls.Add($status, 0, 3)
$script:StatusLabel = $status

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Style = 'Continuous'
$progress.Minimum = 0; $progress.Maximum = 100; $progress.Value = 0
$progress.Height = 22
$progress.Anchor = [System.Windows.Forms.AnchorStyles]([System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$progress.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 8)
$progress.Visible = $false
$root.Controls.Add($progress, 0, 4)
$script:ProgressBar = $progress

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.WordWrap = $true
$logBox.Dock = 'Fill'
$logBox.BackColor = [System.Drawing.Color]::White
$root.Controls.Add($logBox, 0, 5)
$script:LogBox = $logBox

$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.FlowDirection = 'RightToLeft'
$buttons.WrapContents = $true
$buttons.AutoSize = $true
$buttons.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$buttons.Dock = 'Fill'
$buttons.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$root.Controls.Add($buttons, 0, 6)

function New-RtlButton([string]$text, [int]$minWidth = 110) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.AutoSize = $true
    $b.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $b.MinimumSize = New-Object System.Drawing.Size($minWidth, 34)
    $b.Margin = New-Object System.Windows.Forms.Padding(6, 3, 6, 3)
    $b.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 4)
    return $b
}

$btnPrimary = New-RtlButton 'התקן' 150
$btnPrimary.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$btnSecondary = New-RtlButton 'התקן מחדש'
$btnUninstall = New-RtlButton 'הסר התקנה'
$btnDiag = New-RtlButton 'אבחון'
$btnCopyLog = New-RtlButton 'העתק לוג'
$btnBundle = New-RtlButton 'אסוף אבחון (ZIP)'
$btnOpenLogs = New-RtlButton 'פתח תיקיית לוגים'
$btnClose = New-RtlButton 'סגור'
$buttons.Controls.AddRange(@($btnPrimary, $btnSecondary, $btnUninstall, $btnDiag, $btnCopyLog, $btnBundle, $btnOpenLogs, $btnClose))

# --- Switch the active app (rebinds the engine + reframes the UI) ------------
function Select-RtlApp([string]$id) {
    if ($script:Sync.Busy) { return }
    Set-RtlActiveApp $id
    $script:AppId = $id
    $name = $script:ActiveProfile.DisplayName
    $form.Text = "התקנת $name (RTL)"
    $script:TitleLabel.Text = "תמיכת עברית (RTL) ל-$name"
    $script:DescLabel.Text = "מוסיף תמיכת עברית (כיוון מימין לשמאל) ל-$name, בלי הרשאות מנהל. נוצר עותק נפרד בשם ""$name (RTL)""; ה-$name המקורי לא משתנה. ההעתקה הראשונה עשויה לקחת כדקה."
    Set-RtlFormIcon
    $script:LogBox.Clear()
    $script:ProgressBar.Visible = $false
    Update-Buttons
}

# --- State / preflight: frame the UI per Get-CodexRtlStatus ------------------
function Update-Buttons {
    $appName = $script:ActiveProfile.DisplayName
    if ($script:Sync.Busy) {
        foreach ($b in @($btnPrimary, $btnSecondary, $btnUninstall, $btnDiag, $btnCopyLog, $btnBundle, $btnOpenLogs, $btnClose)) { $b.Enabled = $false }
        return
    }
    foreach ($b in @($btnDiag, $btnCopyLog, $btnBundle, $btnOpenLogs, $btnClose)) { $b.Enabled = $true }
    $btnPrimary.Enabled = $true; $btnSecondary.Visible = $false; $btnUninstall.Visible = $false
    $st = $null; try { $st = Get-CodexRtlStatus } catch {}
    if (-not $st -or -not $st.CodexFound) {
        $status.Text = "$appName אינו מותקן. התקן/י אותו ואז לחץ/י ""בדוק שוב""."
        $btnPrimary.Text = 'בדוק שוב'; $btnPrimary.Tag = 'recheck'
        if ($st -and $st.CopyExists) { $btnUninstall.Visible = $true; $btnUninstall.Enabled = $true }
        return
    }
    switch ($st.State) {
        'Update' {
            $status.Text = "$appName עודכן לגרסה $($st.AvailableVersion). נעדכן את גרסת ה-RTL."
            $btnPrimary.Text = 'עדכן'; $btnPrimary.Tag = 'install'
            $btnUninstall.Visible = $true; $btnUninstall.Enabled = $true
        }
        'PatchUpgrade' {
            $status.Text = 'יש גרסה חדשה של הכלי. נעדכן את ההתקנה.'
            $btnPrimary.Text = 'עדכן'; $btnPrimary.Tag = 'install'
            $btnUninstall.Visible = $true; $btnUninstall.Enabled = $true
        }
        'Repair' {
            $status.Text = 'נמצא עותק קיים ללא רישום תקין. אפשר לתקן את ההתקנה.'
            $btnPrimary.Text = 'תקן'; $btnPrimary.Tag = 'install'
            $btnUninstall.Visible = $true; $btnUninstall.Enabled = $true
        }
        'ReinstallRequired' {
            $status.Text = 'נכתב מידע מגרסה חדשה יותר של הכלי. צריך התקנה מחדש.'
            $btnPrimary.Text = 'התקן מחדש'; $btnPrimary.Tag = 'install'
            $btnUninstall.Visible = $true; $btnUninstall.Enabled = $true
        }
        'Fresh' {
            $status.Text = 'מוכן להתקנה.'
            $btnPrimary.Text = 'התקן'; $btnPrimary.Tag = 'install'
        }
        default {
            # UpToDate
            $status.Text = "מותקן ומוכן ($appName v$($st.InstalledVersion)). אפשר לפתוח את $appName (RTL)."
            $btnPrimary.Text = "פתח את $appName (RTL)"; $btnPrimary.Tag = 'open'
            $btnSecondary.Visible = $true; $btnSecondary.Enabled = $true
            $btnUninstall.Visible = $true; $btnUninstall.Enabled = $true
        }
    }
}

# --- Background install ------------------------------------------------------
function Start-Install {
    $appName = $script:ActiveProfile.DisplayName
    if (Test-CodexRtlRunning) {
        [System.Windows.Forms.MessageBox]::Show("$appName (RTL) פתוח כרגע. סגור/י אותו ואז נסה/י שוב.", 'Desktop RTL', 'OK', 'Warning') | Out-Null
        return
    }
    $script:Sync.Done = $false; $script:Sync.Ok = $false; $script:Sync.Err = $null
    $script:Sync.StepKey = ''; $script:Sync.StepPct = 0; $script:Sync.StepMarquee = $false
    $script:Sync.Op = 'install'; $script:Sync.Busy = $true
    $script:LogBox.Clear()
    $script:ProgressBar.Visible = $true; $script:ProgressBar.Style = 'Continuous'; $script:ProgressBar.Value = 0
    Update-Buttons

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $script:Sync)
    $rs.SessionStateProxy.SetVariable('libPath', $script:LibPath)
    $rs.SessionStateProxy.SetVariable('repoRoot', $script:RepoRoot)
    $rs.SessionStateProxy.SetVariable('appId', $script:AppId)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
            . $libPath
            Set-RtlActiveApp $appId
            $script:StepSink = { param($k, $p, $m) $sync.StepKey = $k; $sync.StepPct = $p; $sync.StepMarquee = $m }
            $script:UiSink = { param($msg) [void]$sync.Lines.Add($msg) }
            try {
                Start-RtlInstallLog 'install' | Out-Null
                Write-RtlUi 'מתחיל בהתקנה...'
                Invoke-CodexRtlUpdate -Force
                Write-RtlUi 'מגדיר עדכון אוטומטי...'
                $watch = Copy-RtlBin -RepoRoot $repoRoot
                Register-CodexRtlWatcher -WatchScript $watch
                Start-CodexRtlWatcher -WatchScript $watch
                $sync.Ok = $true
            }
            catch { $sync.Err = $_.Exception.Message }
            finally { $sync.Done = $true }
        })
    $async = $ps.BeginInvoke()
    $script:Job = @{ ps = $ps; rs = $rs; async = $async }
    $script:Timer.Start()
}

# --- Background uninstall ----------------------------------------------------
function Start-Uninstall {
    $appName = $script:ActiveProfile.DisplayName
    if (Test-CodexRtlRunning) {
        [System.Windows.Forms.MessageBox]::Show("$appName (RTL) פתוח כרגע. סגור/י אותו ואז נסה/י שוב.", 'Desktop RTL', 'OK', 'Warning') | Out-Null
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "להסיר את $appName (RTL)? יוסרו העותק, הקיצורים והעדכון האוטומטי. ה-$appName המקורי לא ייפגע, וקובצי הלוג יישמרו.",
        'Desktop RTL', 'YesNo', 'Question')
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $script:Sync.Done = $false; $script:Sync.Ok = $false; $script:Sync.Err = $null
    $script:Sync.StepKey = ''; $script:Sync.StepPct = 0; $script:Sync.StepMarquee = $false
    $script:Sync.Op = 'uninstall'; $script:Sync.Busy = $true
    $script:LogBox.Clear()
    $script:StatusLabel.Text = 'מסיר את ההתקנה...'
    $script:ProgressBar.Visible = $true; $script:ProgressBar.Style = 'Marquee'; $script:ProgressBar.MarqueeAnimationSpeed = 30
    Update-Buttons

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $script:Sync)
    $rs.SessionStateProxy.SetVariable('libPath', $script:LibPath)
    $rs.SessionStateProxy.SetVariable('appId', $script:AppId)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
            . $libPath
            Set-RtlActiveApp $appId
            $script:UiSink = { param($msg) [void]$sync.Lines.Add($msg) }
            try {
                Start-RtlInstallLog 'uninstall' | Out-Null
                Write-RtlUi 'מסיר את ההתקנה...'
                Invoke-CodexRtlUninstall
                $sync.Ok = $true
            }
            catch { $sync.Err = $_.Exception.Message }
            finally { $sync.Done = $true }
        })
    $async = $ps.BeginInvoke()
    $script:Job = @{ ps = $ps; rs = $rs; async = $async }
    $script:Timer.Start()
}

# --- UI timer: drains progress + completion ----------------------------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
        while ($script:Sync.Lines.Count -gt 0) {
            $line = $script:Sync.Lines[0]; $script:Sync.Lines.RemoveAt(0)
            Add-LogLine ([string]$line)
        }
        $key = [string]$script:Sync.StepKey
        if ($key) {
            $h = Get-StepHebrew $key
            if ($h) { $script:StatusLabel.Text = $h }
            if ($script:Sync.StepMarquee) {
                if ($script:ProgressBar.Style -ne [System.Windows.Forms.ProgressBarStyle]::Marquee) {
                    $script:ProgressBar.Style = 'Marquee'; $script:ProgressBar.MarqueeAnimationSpeed = 30
                }
            }
            else {
                if ($script:ProgressBar.Style -ne [System.Windows.Forms.ProgressBarStyle]::Continuous) {
                    $script:ProgressBar.Style = 'Continuous'
                }
                $p = [int]$script:Sync.StepPct
                if ($p -ge 0 -and $p -le 100) { $script:ProgressBar.Value = $p }
            }
        }
        if ($script:Sync.Done) {
            $script:Timer.Stop()
            if ($script:Job) {
                try { $script:Job.ps.EndInvoke($script:Job.async) } catch {}
                try { $script:Job.ps.Dispose() } catch {}
                try { $script:Job.rs.Dispose() } catch {}
                $script:Job = $null
            }
            $script:Sync.Busy = $false
            $isUninstall = ($script:Sync.Op -eq 'uninstall')
            if ($script:Sync.Ok) {
                if ($isUninstall) {
                    $script:ProgressBar.Visible = $false
                    $script:StatusLabel.Text = 'ההסרה הושלמה.'
                    Add-LogLine 'ההסרה הושלמה בהצלחה.'
                }
                else {
                    $script:ProgressBar.Style = 'Continuous'; $script:ProgressBar.Value = 100
                    $script:StatusLabel.Text = "ההתקנה הושלמה! אפשר לפתוח את $($script:ActiveProfile.DisplayName) (RTL)."
                    Add-LogLine 'ההתקנה הושלמה בהצלחה.'
                }
            }
            else {
                $script:ProgressBar.Visible = $false
                $heb = Get-RtlHebrewError ([string]$script:Sync.Err)
                $script:StatusLabel.Text = if ($isUninstall) { 'ההסרה נכשלה.' } else { 'ההתקנה נכשלה.' }
                Add-LogLine $heb
                [System.Windows.Forms.MessageBox]::Show($heb, 'Desktop RTL', 'OK', 'Error') | Out-Null
            }
            Update-Buttons
        }
    })
$script:Timer = $timer

# --- Button handlers ---------------------------------------------------------
$btnPrimary.Add_Click({
        switch ([string]$btnPrimary.Tag) {
            'install' { Start-Install }
            'recheck' { Update-Buttons }
            'open' {
                $exe = Join-Path $script:CopyRoot $script:ActiveProfile.ExeRelPath
                if (Test-Path $exe) { Start-Process -FilePath $exe }
                else { [System.Windows.Forms.MessageBox]::Show('לא נמצא קובץ ההפעלה. נסה/י להתקין מחדש.', 'Desktop RTL', 'OK', 'Warning') | Out-Null }
            }
        }
    })
$btnSecondary.Add_Click({ Start-Install })   # reinstall
$btnUninstall.Add_Click({ Start-Uninstall })

$btnDiag.Add_Click({
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $d = Invoke-CodexRtlDiagnose
            $diagApp = $script:ActiveProfile.DisplayName
            $lines = @(
                '--- אבחון ---',
                "$diagApp מותקן: $(if($d.CodexFound){'כן'}else{'לא'})  (גרסה $($d.SourceVersion))",
                "מבנה תקין: $(if($d.LayoutValid){'כן'}else{'לא - '+$d.LayoutError})",
                "Node מובנה: $(if($d.NodeExists){'נמצא'}else{'חסר'})",
                "מקום פנוי: $($d.FreeGB)GB  (נדרש ~$($d.SourceSizeGB)GB, מספיק: $(if($d.EnoughSpace){'כן'}else{'לא'}))",
                "RTL מותקן: $(if($d.RtlInstalled){'כן'}else{'לא'})  | RTL רץ: $(if($d.RtlRunning){'כן'}else{'לא'})  | $diagApp מקורי רץ: $(if($d.OriginalRunning){'כן'}else{'לא'})",
                "הפרטים המלאים נשמרו בקובץ הלוג."
            )
            $script:LogBox.Clear()
            foreach ($l in $lines) { Add-LogLine $l }
        }
        catch { Add-LogLine "אבחון נכשל: $($_.Exception.Message)" }
        finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    })

$btnCopyLog.Add_Click({
        $log = if ($script:InstallLogFile -and (Test-Path $script:InstallLogFile)) { $script:InstallLogFile } elseif (Test-Path $script:LogFile) { $script:LogFile } else { $null }
        if ($log) {
            try { [System.Windows.Forms.Clipboard]::SetText((Get-Content $log -Raw)); [System.Windows.Forms.MessageBox]::Show('הלוג הועתק. אפשר להדביק ולשלוח למפתח.', 'Desktop RTL', 'OK', 'Information') | Out-Null }
            catch { [System.Windows.Forms.MessageBox]::Show('לא ניתן להעתיק את הלוג.', 'Desktop RTL', 'OK', 'Warning') | Out-Null }
        }
        else { [System.Windows.Forms.MessageBox]::Show('עדיין אין קובץ לוג.', 'Desktop RTL', 'OK', 'Information') | Out-Null }
    })

$btnBundle.Add_Click({
        try {
            Add-LogLine 'אוסף חבילת אבחון...'
            $zip = Export-CodexRtlDiagnostics
            if ($zip -and (Test-Path $zip)) {
                Add-LogLine "נוצרה חבילת אבחון: $zip"
                Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$zip`""
                [System.Windows.Forms.MessageBox]::Show("נוצר קובץ אבחון (ZIP) שאפשר לשלוח למפתח.`r`n`r`n$zip", 'Desktop RTL', 'OK', 'Information') | Out-Null
            }
        }
        catch { Add-LogLine "איסוף אבחון נכשל: $($_.Exception.Message)"; [System.Windows.Forms.MessageBox]::Show('לא ניתן היה לאסוף את חבילת האבחון.', 'Desktop RTL', 'OK', 'Warning') | Out-Null }
    })

$btnOpenLogs.Add_Click({
        if (-not (Test-Path $script:LogsDir)) { New-Item -ItemType Directory -Force -Path $script:LogsDir | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList $script:LogsDir
    })

$btnClose.Add_Click({ $form.Close() })

# Block closing the window while an operation is active.
$form.Add_FormClosing({
        param($s, $e)
        if ($script:Sync.Busy) {
            $e.Cancel = $true
            [System.Windows.Forms.MessageBox]::Show('פעולה מתבצעת כעת. אנא המתן/י עד שתסתיים.', 'Desktop RTL', 'OK', 'Warning') | Out-Null
        }
    })

$script:AppCombo.Add_SelectedIndexChanged({
        $i = $script:AppCombo.SelectedIndex
        if ($i -ge 0) { Select-RtlApp $script:AppIds[$i] }
    })

$form.Add_Shown({ Select-RtlApp $script:AppIds[$script:AppCombo.SelectedIndex] })

if ($SelfTest) {
    # Construct + run preflight once for BOTH apps, but do not block on ShowDialog.
    foreach ($id in @('codex', 'opencode')) {
        Select-RtlApp $id
        Write-Host "SelfTest OK ($id): state = $((Get-CodexRtlStatus).State); label = [$($status.Text)]"
    }
    $form.Dispose()
    return
}

[void]$form.ShowDialog()
$form.Dispose()
