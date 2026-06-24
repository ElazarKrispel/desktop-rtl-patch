# Install-CodexRtlGui.ps1
# Friendly graphical installer for the Codex RTL patch (WinForms, Hebrew UI).
# Wraps the already-tested library functions in codex-rtl-lib.ps1. No admin.
#
# Launched by Install-Codex-RTL.cmd (powershell -STA -WindowStyle Hidden), or directly.
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
$script:LibPath  = Join-Path $script:RepoRoot 'scripts\lib\codex-rtl-lib.ps1'

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

# --- Package integrity (the lib must exist before we can use Test-RtlPackage) -
if (-not (Test-Path $script:LibPath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "חבילת ההתקנה חסרה קבצים. ודא/י שחילצת את כל ה-ZIP, לא רק את קובץ ה-cmd, ונסה/י שוב.",
        'Codex RTL', 'OK', 'Error') | Out-Null
    return
}
. $script:LibPath
Hide-RtlConsole   # hide the background PowerShell console; the GUI window stays visible
try { Test-RtlPackage -RepoRoot $script:RepoRoot | Out-Null }
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "חבילת ההתקנה חסרה קבצים. ודא/י שחילצת את כל ה-ZIP, לא רק את קובץ ה-cmd, ונסה/י שוב.`n`n$($_.Exception.Message)",
        'Codex RTL', 'OK', 'Error') | Out-Null
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
    })
$script:Job = $null

# --- Hebrew helpers ----------------------------------------------------------
function Get-StepHebrew([string]$key) {
    switch ($key) {
        'preflight' { 'בודק את המערכת...' ; break }
        'copy'      { 'מעתיק את Codex (כ-1.6GB). זה עשוי לקחת כדקה...' ; break }
        'inject'    { 'מחיל את תיקון העברית (RTL)...' ; break }
        'swap'      { 'מחליף קבצים...' ; break }
        'shortcut'  { 'יוצר קיצורי דרך...' ; break }
        'deferred'  { 'העדכון מוכן, ויוחל בפעם הבאה שתסגור/י את Codex (RTL).' ; break }
        'done'      { 'הושלם!' ; break }
        default     { '' }
    }
}

function Get-ErrHebrew([string]$msg) {
    if (-not $msg) { return 'ההתקנה נכשלה. ראה/י את הלוג למטה ושלח/י אותו למפתח.' }
    switch -Regex ($msg) {
        '^\[NOCODEX\]' { 'Codex אינו מותקן. התקן/י אותו מחנות Microsoft, ואז לחץ/י "בדוק שוב".' ; break }
        '^\[NODE\]'    { 'ה-Node המובנה של Codex לא נמצא. ייתכן ש-Codex לא הותקן במלואו או עודכן. נסה/י לתקן את Codex דרך החנות, ואז לנסות שוב.' ; break }
        '^\[LAYOUT\]'  { 'Codex זוהה אך המבנה הפנימי שלו אינו כמצופה. ייתכן ש-Codex עודכן ושהכלי צריך עדכון. עדכן/י את הכלי או פנה/י למפתח.' ; break }
        '^\[PACKAGE\]' { 'חבילת ההתקנה חסרה קבצים. ודא/י שחילצת את כל ה-ZIP, לא רק את קובץ ה-cmd, ונסה/י שוב.' ; break }
        '^\[SAFETY\]'  { 'הפעולה בוטלה מטעמי בטיחות (ניסיון לגעת בקובץ מחוץ לעותק ה-RTL). ההתקנה המקורית של Codex לא נפגעה.' ; break }
        default        { "ההתקנה נכשלה. הפרטים נשמרו בקובץ הלוג, אנא שלח/י אותו למפתח.`r`n`r`n$msg" }
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
# Use Codex's own icon for the installer window (no separate branded icon).
try {
    $iconExe = $null
    $cands = @((Join-Path $script:CopyRoot 'app\Codex.exe'))
    $srcForIcon = $null; try { $srcForIcon = Resolve-CodexSource } catch {}
    if ($srcForIcon) { $cands += (Join-Path $srcForIcon.AppDir 'Codex.exe') }
    foreach ($c in $cands) { if (Test-Path $c) { $iconExe = $c; break } }
    if ($iconExe) { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($iconExe) }
} catch {}

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.ColumnCount = 1
$root.RowCount = 6
$root.Padding = New-Object System.Windows.Forms.Padding(16)
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
foreach ($h in 0, 0, 0, 0, 100, 0) {
    $t = if ($h -eq 0) { [System.Windows.Forms.SizeType]::AutoSize } else { [System.Windows.Forms.SizeType]::Percent }
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($t, $h)))
}
$form.Controls.Add($root)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'תמיכת עברית (RTL) ל-Codex'
$title.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 8)
$root.Controls.Add($title, 0, 0)

$desc = New-Object System.Windows.Forms.Label
$desc.Text = 'מוסיף תמיכת עברית (כיוון מימין לשמאל) ל-Codex, בלי הרשאות מנהל. נוצר עותק נפרד בשם "Codex (RTL)"; ה-Codex המקורי לא משתנה. ההעתקה הראשונה לוקחת כדקה.'
$desc.AutoSize = $true
$desc.MaximumSize = New-Object System.Drawing.Size(520, 0)
$desc.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 10)
$root.Controls.Add($desc, 0, 1)

$status = New-Object System.Windows.Forms.Label
$status.Text = ''
$status.AutoSize = $true
$status.MaximumSize = New-Object System.Drawing.Size(520, 0)
$status.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$status.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 6)
$root.Controls.Add($status, 0, 2)
$script:StatusLabel = $status

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Style = 'Continuous'
$progress.Minimum = 0; $progress.Maximum = 100; $progress.Value = 0
$progress.Height = 22
$progress.Anchor = [System.Windows.Forms.AnchorStyles]([System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right)
$progress.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 8)
$progress.Visible = $false
$root.Controls.Add($progress, 0, 3)
$script:ProgressBar = $progress

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.WordWrap = $true
$logBox.Dock = 'Fill'
$logBox.BackColor = [System.Drawing.Color]::White
$root.Controls.Add($logBox, 0, 4)
$script:LogBox = $logBox

$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.FlowDirection = 'RightToLeft'
$buttons.WrapContents = $true
$buttons.AutoSize = $true
$buttons.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$buttons.Dock = 'Fill'
$buttons.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$root.Controls.Add($buttons, 0, 5)

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
$btnDiag = New-RtlButton 'אבחון'
$btnCopyLog = New-RtlButton 'העתק לוג'
$btnOpenLogs = New-RtlButton 'פתח תיקיית לוגים'
$btnClose = New-RtlButton 'סגור'
$buttons.Controls.AddRange(@($btnPrimary, $btnSecondary, $btnDiag, $btnCopyLog, $btnOpenLogs, $btnClose))

# --- State / preflight -------------------------------------------------------
# Phase 1 basic states: NoCodex / NotInstalled / Installed.
function Get-BasicState {
    $src = $null
    try { $src = Resolve-CodexSource } catch {}
    if (-not $src) { return 'NoCodex' }
    $state = Read-RtlState
    $copyOk = Test-Path (Join-Path $script:CopyRoot 'app\Codex.exe')
    if ($state -and $copyOk) { return 'Installed' }
    return 'NotInstalled'
}

function Update-Buttons {
    if ($script:Sync.Busy) {
        foreach ($b in @($btnPrimary, $btnSecondary, $btnDiag, $btnCopyLog, $btnOpenLogs, $btnClose)) { $b.Enabled = $false }
        return
    }
    $st = Get-BasicState
    $btnDiag.Enabled = $true; $btnCopyLog.Enabled = $true; $btnOpenLogs.Enabled = $true; $btnClose.Enabled = $true
    switch ($st) {
        'NoCodex' {
            $status.Text = 'Codex אינו מותקן. התקן/י אותו מחנות Microsoft, ואז לחץ/י "בדוק שוב".'
            $btnPrimary.Text = 'בדוק שוב'; $btnPrimary.Enabled = $true; $btnPrimary.Tag = 'recheck'
            $btnSecondary.Visible = $false
        }
        'NotInstalled' {
            $status.Text = 'מוכן להתקנה.'
            $btnPrimary.Text = 'התקן'; $btnPrimary.Enabled = $true; $btnPrimary.Tag = 'install'
            $btnSecondary.Visible = $false
        }
        'Installed' {
            $st2 = Read-RtlState
            $ver = if ($st2.codexVersion) { $st2.codexVersion } elseif ($st2.version) { $st2.version } else { '?' }
            $status.Text = "מותקן ומוכן (Codex v$ver). אפשר לפתוח את Codex (RTL)."
            $btnPrimary.Text = 'פתח את Codex (RTL)'; $btnPrimary.Enabled = $true; $btnPrimary.Tag = 'open'
            $btnSecondary.Visible = $true; $btnSecondary.Enabled = $true
        }
    }
}

# --- Background install ------------------------------------------------------
function Start-Install {
    if (Test-CodexRtlRunning) {
        [System.Windows.Forms.MessageBox]::Show('Codex (RTL) פתוח כרגע. סגור/י אותו ואז נסה/י שוב.', 'Codex RTL', 'OK', 'Warning') | Out-Null
        return
    }
    $script:Sync.Done = $false; $script:Sync.Ok = $false; $script:Sync.Err = $null
    $script:Sync.StepKey = ''; $script:Sync.StepPct = 0; $script:Sync.StepMarquee = $false
    $script:Sync.Busy = $true
    $script:LogBox.Clear()
    $script:ProgressBar.Visible = $true; $script:ProgressBar.Style = 'Continuous'; $script:ProgressBar.Value = 0
    Update-Buttons

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('sync', $script:Sync)
    $rs.SessionStateProxy.SetVariable('libPath', $script:LibPath)
    $rs.SessionStateProxy.SetVariable('repoRoot', $script:RepoRoot)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
            . $libPath
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
            if ($script:Sync.Ok) {
                $script:ProgressBar.Style = 'Continuous'; $script:ProgressBar.Value = 100
                $script:StatusLabel.Text = 'ההתקנה הושלמה! אפשר לפתוח את Codex (RTL).'
                Add-LogLine 'ההתקנה הושלמה בהצלחה.'
            }
            else {
                $script:ProgressBar.Visible = $false
                $heb = Get-ErrHebrew ([string]$script:Sync.Err)
                $script:StatusLabel.Text = 'ההתקנה נכשלה.'
                Add-LogLine $heb
                [System.Windows.Forms.MessageBox]::Show($heb, 'Codex RTL', 'OK', 'Error') | Out-Null
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
                $exe = Join-Path $script:CopyRoot 'app\Codex.exe'
                if (Test-Path $exe) { Start-Process -FilePath $exe }
                else { [System.Windows.Forms.MessageBox]::Show('לא נמצא קובץ ההפעלה. נסה/י להתקין מחדש.', 'Codex RTL', 'OK', 'Warning') | Out-Null }
            }
        }
    })
$btnSecondary.Add_Click({ Start-Install })   # reinstall

$btnDiag.Add_Click({
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $d = Invoke-CodexRtlDiagnose
            $lines = @(
                '--- אבחון ---',
                "Codex מותקן: $(if($d.CodexFound){'כן'}else{'לא'})  (גרסה $($d.SourceVersion))",
                "מבנה תקין: $(if($d.LayoutValid){'כן'}else{'לא - '+$d.LayoutError})",
                "Node מובנה: $(if($d.NodeExists){'נמצא'}else{'חסר'})",
                "מקום פנוי: $($d.FreeGB)GB  (נדרש ~$($d.SourceSizeGB)GB, מספיק: $(if($d.EnoughSpace){'כן'}else{'לא'}))",
                "RTL מותקן: $(if($d.RtlInstalled){'כן'}else{'לא'})  | RTL רץ: $(if($d.RtlRunning){'כן'}else{'לא'})  | Codex מקורי רץ: $(if($d.OriginalRunning){'כן'}else{'לא'})",
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
            try { [System.Windows.Forms.Clipboard]::SetText((Get-Content $log -Raw)); [System.Windows.Forms.MessageBox]::Show('הלוג הועתק. אפשר להדביק ולשלוח למפתח.', 'Codex RTL', 'OK', 'Information') | Out-Null }
            catch { [System.Windows.Forms.MessageBox]::Show('לא ניתן להעתיק את הלוג.', 'Codex RTL', 'OK', 'Warning') | Out-Null }
        }
        else { [System.Windows.Forms.MessageBox]::Show('עדיין אין קובץ לוג.', 'Codex RTL', 'OK', 'Information') | Out-Null }
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
            [System.Windows.Forms.MessageBox]::Show('פעולה מתבצעת כעת. אנא המתן/י עד שתסתיים.', 'Codex RTL', 'OK', 'Warning') | Out-Null
        }
    })

$form.Add_Shown({ Update-Buttons })

if ($SelfTest) {
    # Construct + run preflight once, but do not block on ShowDialog.
    Update-Buttons
    Write-Host "SelfTest OK: form built; basic state = $(Get-BasicState); label = [$($status.Text)]"
    $form.Dispose()
    return
}

[void]$form.ShowDialog()
$form.Dispose()
