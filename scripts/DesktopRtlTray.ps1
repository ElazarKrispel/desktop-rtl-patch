# DesktopRtlTray.ps1
# Resident system-tray app for the Desktop RTL patch. It subsumes the background
# watcher: a hidden message pump keeps a NotifyIcon alive, an event-driven +
# polled loop keeps "Codex (RTL)" patched across Codex updates (never interrupting
# a running copy), and a menu exposes open / update / settings / diagnostics /
# tool-update / quit. No admin. UTF-8 WITH BOM (Hebrew literals).
#
# -SelfTest builds the icon + menu then disposes without running the message loop.

param([switch]$NoRelaunch, [switch]$SelfTest)

# --- Apply a staged tool self-update BEFORE loading anything from bin ---------
# The self-updater stages a new bin\ into bin.staging and drops a marker; we swap
# it in here, while nothing from bin is loaded yet, then re-exec the fresh copy.
if (-not $SelfTest) {
    try {
        $sd = Join-Path $env:LOCALAPPDATA 'CodexRtlPatch'
        $marker = Join-Path $sd 'pending-selfupdate'
        $binDir = Join-Path $sd 'bin'
        $binStaging = "$binDir.staging"
        $binOld = "$binDir.old"
        if ((Test-Path $marker) -and (Test-Path $binStaging)) {
            if (Test-Path $binOld) { Remove-Item -LiteralPath $binOld -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path $binDir) { Rename-Item -LiteralPath $binDir -NewName ([IO.Path]::GetFileName($binOld)) -Force }
            Rename-Item -LiteralPath $binStaging -NewName ([IO.Path]::GetFileName($binDir)) -Force
            if (Test-Path $binOld) { Remove-Item -LiteralPath $binOld -Recurse -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            $freshVbs = Join-Path $binDir 'Desktop-RTL-Tray.vbs'
            if (-not $NoRelaunch -and (Test-Path $freshVbs)) {
                Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList "`"$freshVbs`""
                return
            }
        }
    } catch {}
}

# --- Relaunch under Windows PowerShell 5.1 + STA if needed -------------------
if (-not $SelfTest -and -not $NoRelaunch) {
    $needRelaunch = $false
    if ($PSVersionTable.PSEdition -eq 'Core') { $needRelaunch = $true }
    elseif ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { $needRelaunch = $true }
    if ($needRelaunch) {
        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath, '-NoRelaunch')
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
if (-not $script:LibPath) { return }
. $script:LibPath
if (-not $SelfTest) { Hide-RtlConsole }

# --- single instance ---------------------------------------------------------
$script:Created = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\CodexRtlTray', [ref]$script:Created)
if (-not $script:Created -and -not $SelfTest) { return }
if (-not $SelfTest) { Stop-CodexRtlWatcher }   # evict any legacy watcher (never kills self)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
try {
    Add-Type -Namespace CodexRtl -Name TaskbarIdT -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
'@ -ErrorAction Stop
    [void][CodexRtl.TaskbarIdT]::SetCurrentProcessExplicitAppUserModelID('CodexRtl.Tray')
} catch {}

# --- shared state between UI thread and background passes ---------------------
$script:Sync = [hashtable]::Synchronized(@{
        Lines = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
        Busy  = $false; Done = $false; Ok = $false; Err = $null; Op = 'auto'
    })
$script:PassPs = $null; $script:PassHandle = $null; $script:PassRs = $null
$script:ToolInfo = $null

$script:Config = Read-RtlConfig

# --- hidden host form (message pump + FileSystemWatcher SynchronizingObject) --
$form = New-Object System.Windows.Forms.Form
$form.ShowInTaskbar = $false
$form.WindowState = 'Minimized'
$form.FormBorderStyle = 'FixedToolWindow'
$form.Opacity = 0
$form.Width = 0; $form.Height = 0

# --- tray icon ---------------------------------------------------------------
$script:BaseIcon = [System.Drawing.SystemIcons]::Application
try {
    $exe = Join-Path $script:CopyRoot $script:ActiveProfile.ExeRelPath
    if (Test-Path $exe) { $script:BaseIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($exe) }
    else {
        $src = $null; try { $src = Resolve-CodexSource } catch {}
        if ($src -and (Test-Path (Join-Path $src.AppDir $script:ActiveProfile.ExeLeaf))) { $script:BaseIcon = [System.Drawing.Icon]::ExtractAssociatedIcon((Join-Path $src.AppDir $script:ActiveProfile.ExeLeaf)) }
    }
} catch {}

$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = $script:BaseIcon
$ni.Text = 'Codex (RTL)'
$ni.Visible = $true

function Set-TrayStatus([string]$text) {
    if ($text.Length -gt 62) { $text = $text.Substring(0, 62) }
    $ni.Text = $text
}
function Show-TrayBalloon([string]$title, [string]$body, [System.Windows.Forms.ToolTipIcon]$icon = 'Info') {
    try { $ni.ShowBalloonTip(4000, $title, $body, $icon) } catch {}
}

# --- context menu (RTL) ------------------------------------------------------
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.RightToLeft = 'Yes'
$miOpen    = $menu.Items.Add('פתח את Codex (RTL)')
$miUpdate  = $menu.Items.Add('עדכן עכשיו')
$miAuto    = New-Object System.Windows.Forms.ToolStripMenuItem 'עדכון אוטומטי'
$miAuto.CheckOnClick = $true
$miAuto.Checked = [bool]$script:Config.autoPatch
[void]$menu.Items.Add($miAuto)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miSettings = $menu.Items.Add('הגדרות...')
$miDiag     = $menu.Items.Add('אבחון...')
$miLogs     = $menu.Items.Add('פתח תיקיית לוגים')
$miCheckUpd = $menu.Items.Add('בדוק עדכונים לכלי')
$miInstallUpd = New-Object System.Windows.Forms.ToolStripMenuItem 'התקן עדכון לכלי'
$miInstallUpd.Visible = $false
[void]$menu.Items.Add($miInstallUpd)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miQuit     = $menu.Items.Add('יציאה')
$ni.ContextMenuStrip = $menu

# --- background update pass ---------------------------------------------------
function Start-TrayPass {
    param([switch]$Force)
    if ($script:Sync.Busy) { return }
    $script:Sync.Busy = $true; $script:Sync.Done = $false; $script:Sync.Ok = $false; $script:Sync.Err = $null
    $script:Sync.Op = if ($Force) { 'force' } else { 'auto' }
    Set-TrayStatus 'Codex (RTL) - מעדכן...'
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $script:Sync)
    $rs.SessionStateProxy.SetVariable('LibPath', $script:LibPath)
    $rs.SessionStateProxy.SetVariable('DoForce', [bool]$Force)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
            . $LibPath
            $script:UiSink = { param($m) [void]$Sync.Lines.Add($m) }
            try {
                if ($DoForce) { Invoke-CodexRtlUpdate -Force } else { Invoke-CodexRtlUpdate -Auto }
                $Sync.Ok = $true
            } catch { $Sync.Err = $_.Exception.Message }
            finally { $Sync.Done = $true }
        })
    $script:PassRs = $rs; $script:PassPs = $ps
    $script:PassHandle = $ps.BeginInvoke()
}

# --- background tool-update check / install ----------------------------------
function Start-ToolCheck {
    param([switch]$Install)
    if ($script:Sync.Busy) { return }
    $script:Sync.Busy = $true; $script:Sync.Done = $false; $script:Sync.Ok = $false; $script:Sync.Err = $null
    $script:Sync.Op = if ($Install) { 'toolinstall' } else { 'toolcheck' }
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $script:Sync)
    $rs.SessionStateProxy.SetVariable('LibPath', $script:LibPath)
    $rs.SessionStateProxy.SetVariable('DoInstall', [bool]$Install)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
            . $LibPath
            try {
                $info = Test-RtlToolUpdateAvailable
                $Sync['ToolInfo'] = $info
                if ($DoInstall -and $info -and $info.Available) { [void](Invoke-RtlSelfUpdate -Info $info) }
                $Sync.Ok = $true
            } catch { $Sync.Err = $_.Exception.Message }
            finally { $Sync.Done = $true }
        })
    $script:PassRs = $rs; $script:PassPs = $ps
    $script:PassHandle = $ps.BeginInvoke()
}

# --- drain timer: reflect background progress on the UI thread ---------------
$drain = New-Object System.Windows.Forms.Timer
$drain.Interval = 200
$drain.Add_Tick({
        while ($script:Sync.Lines.Count -gt 0) {
            $line = $script:Sync.Lines[0]; $script:Sync.Lines.RemoveAt(0)
            Write-RtlLog "tray: $line"
        }
        if ($script:Sync.Busy -and $script:Sync.Done) {
            $op = $script:Sync.Op
            try { if ($script:PassPs) { $script:PassPs.Dispose() } } catch {}
            try { if ($script:PassRs) { $script:PassRs.Dispose() } } catch {}
            $script:PassPs = $null; $script:PassRs = $null; $script:PassHandle = $null
            $err = $script:Sync.Err
            if ($op -eq 'toolcheck' -or $op -eq 'toolinstall') {
                $info = $script:Sync['ToolInfo']
                if ($op -eq 'toolinstall') {
                    if (-not $err) {
                        Show-TrayBalloon 'עדכון הכלי הותקן' 'מפעיל מחדש כדי לסיים...' 'Info'
                        $vbs = Get-RtlTrayLauncher
                        if ($vbs) { Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList "`"$vbs`"" }
                        $script:Sync.Busy = $false
                        Invoke-TrayQuit
                        return
                    } else { Show-TrayBalloon 'עדכון הכלי נכשל' (Get-TrayError $err) 'Error' }
                } elseif ($info -and $info.Available) {
                    $script:ToolInfo = $info
                    $miInstallUpd.Text = "התקן עדכון לכלי ($($info.LatestTag))"
                    $miInstallUpd.Visible = $true
                    Show-TrayBalloon 'עדכון זמין לכלי' "גרסה $($info.LatestTag) זמינה. לחצ/י 'התקן עדכון לכלי' בתפריט." 'Info'
                } else {
                    Show-TrayBalloon 'הכלי מעודכן' 'זו הגרסה האחרונה.' 'Info'
                }
            } else {
                if ($err) {
                    Show-TrayBalloon 'עדכון RTL נכשל' (Get-TrayError $err) 'Error'
                } elseif ($op -eq 'force') {
                    Show-TrayBalloon 'Codex (RTL)' 'העדכון הוחל.' 'Info'
                }
            }
            $script:Sync.Busy = $false
            Update-TrayStatus
        }
    })

# --- periodic + event-driven update triggers ---------------------------------
$poll = New-Object System.Windows.Forms.Timer
$poll.Interval = 90000   # 90s Store fallback + completes a deferred swap on close
$poll.Add_Tick({ if ($miAuto.Checked) { Start-TrayPass } })

$toolTimer = New-Object System.Windows.Forms.Timer
$toolTimer.Interval = 86400000   # once a day
$toolTimer.Add_Tick({ if ($script:Config.checkForToolUpdates) { Start-ToolCheck } })

# FileSystemWatcher for direct installs (near-instant), marshaled to the UI thread.
$script:Fsw = $null
$debounce = New-Object System.Windows.Forms.Timer
$debounce.Interval = 5000
$debounce.Add_Tick({ $debounce.Stop(); if ($miAuto.Checked) { Start-TrayPass } })
try {
    $src0 = $null; try { $src0 = Resolve-CodexSource } catch {}
    if ($src0 -and $src0.Type -eq 'Direct') {
        $script:Fsw = New-RtlSourceWatcher -WatchPath $src0.AsarPath
        if ($script:Fsw) {
            $script:Fsw.SynchronizingObject = $form
            $script:Fsw.EnableRaisingEvents = $true
            $onChange = { $debounce.Stop(); $debounce.Start() }
            $script:Fsw.add_Changed($onChange); $script:Fsw.add_Created($onChange); $script:Fsw.add_Renamed($onChange)
        }
    }
} catch {}

function Update-TrayStatus {
    $st = $null; try { $st = Get-CodexRtlStatus } catch {}
    if (-not $st) { Set-TrayStatus 'Codex (RTL)'; return }
    switch ($st.State) {
        'UpToDate' { Set-TrayStatus "Codex (RTL) - מעודכן (v$($st.InstalledVersion))" }
        'Update'   { Set-TrayStatus 'Codex (RTL) - עדכון זמין' }
        'PatchUpgrade' { Set-TrayStatus 'Codex (RTL) - עדכון תיקון זמין' }
        'Repair'   { Set-TrayStatus 'Codex (RTL) - דרוש תיקון' }
        'Fresh'    { Set-TrayStatus 'Codex (RTL) - לא מותקן' }
        default    { Set-TrayStatus 'Codex (RTL)' }
    }
    $miOpen.Enabled = [bool]$st.CopyExists
}

function Get-TrayError([string]$m) {
    if (Get-Command Get-RtlHebrewError -ErrorAction SilentlyContinue) { return (Get-RtlHebrewError $m) }
    if ($m) { return $m } else { return 'שגיאה' }
}

# --- menu actions ------------------------------------------------------------
$miOpen.Add_Click({
        $exe = Join-Path $script:CopyRoot $script:ActiveProfile.ExeRelPath
        if (Test-Path $exe) { Start-Process -FilePath $exe }
    })
$miUpdate.Add_Click({ Start-TrayPass -Force })
$miAuto.Add_Click({
        $script:Config = Read-RtlConfig
        $script:Config.autoPatch = [bool]$miAuto.Checked
        Write-RtlConfig $script:Config
    })
$miSettings.Add_Click({
        # Prefer the VBS launcher so no PowerShell console window ever flashes.
        $vbs = Join-Path $here 'Desktop-RTL-Settings.vbs'
        if (-not (Test-Path $vbs)) { $vbs = Join-Path (Split-Path $here -Parent) 'Desktop-RTL-Settings.vbs' }
        if (Test-Path $vbs) {
            Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList "`"$vbs`""
            return
        }
        $s = Join-Path $here 'DesktopRtlSettings.ps1'
        if (-not (Test-Path $s)) { $s = Join-Path (Split-Path $here -Parent) 'scripts\DesktopRtlSettings.ps1' }
        if (Test-Path $s) { Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', $s) }
    })
$miDiag.Add_Click({
        try { $zip = Export-CodexRtlDiagnostics; if ($zip) { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$zip`"" } }
        catch { Show-TrayBalloon 'אבחון נכשל' (Get-TrayError $_.Exception.Message) 'Error' }
    })
$miLogs.Add_Click({
        if (-not (Test-Path $script:LogsDir)) { New-Item -ItemType Directory -Force -Path $script:LogsDir | Out-Null }
        Start-Process -FilePath 'explorer.exe' -ArgumentList $script:LogsDir
    })
$miCheckUpd.Add_Click({ Start-ToolCheck })
$miInstallUpd.Add_Click({ Start-ToolCheck -Install })
$ni.Add_DoubleClick({ $miOpen.PerformClick() })

function Invoke-TrayQuit {
    try { $drain.Stop(); $poll.Stop(); $toolTimer.Stop(); $debounce.Stop() } catch {}
    try { if ($script:Fsw) { $script:Fsw.EnableRaisingEvents = $false; $script:Fsw.Dispose() } } catch {}
    try { $ni.Visible = $false; $ni.Dispose() } catch {}
    try { if ($script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch {}
    try { [System.Windows.Forms.Application]::Exit() } catch {}
}
$miQuit.Add_Click({ Invoke-TrayQuit })
$form.Add_FormClosed({ try { $ni.Visible = $false; $ni.Dispose() } catch {} })

Update-TrayStatus

if ($SelfTest) {
    Write-Host ("SelfTest OK: tray built; items={0}; autoPatch={1}" -f $menu.Items.Count, $miAuto.Checked)
    try { $ni.Visible = $false; $ni.Dispose() } catch {}
    try { $form.Dispose() } catch {}
    try { if ($script:Created) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch {}
    return
}

# Start background activity and run the message pump (no visible window).
$drain.Start(); $poll.Start(); $toolTimer.Start()
Start-TrayPass                     # initial pass at startup
if ($script:Config.checkForToolUpdates) { Start-ToolCheck }
$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)
