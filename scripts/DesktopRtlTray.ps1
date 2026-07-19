# DesktopRtlTray.ps1
# The UNIFIED background agent: ONE resident system-tray icon that manages EVERY
# installed app ("Codex (RTL)" and/or "OpenCode (RTL)"). It subsumes the old per-app
# watchers: a hidden message pump keeps a NotifyIcon alive, an event-driven + polled
# loop keeps each installed copy patched across app updates (never interrupting a
# running copy), and a menu exposes per-app open / update / settings / diagnostics plus
# shared tool-update / logs / quit. No admin. Lives in the neutral DesktopRtlPatch home.
# UTF-8 WITH BOM (Hebrew literals).
#
# -SelfTest builds the icon + menu then disposes without running the message loop.

param([switch]$NoRelaunch, [switch]$SelfTest)

# --- Apply a staged tool self-update BEFORE loading anything from bin ----------
# The self-updater stages a fresh bin into <AgentHome>\bin.staging and drops a marker.
# We swap it in here (nothing from bin is loaded yet), then LAUNCH the fresh tray and
# SUPERVISE its readiness: bin.old is kept until the new generation reports ready, and
# on a readiness timeout we roll back to bin.old and relaunch it. This makes a release
# that parses but crashes at startup recoverable, even on a fully-consolidated box.
if (-not $SelfTest -and -not $NoRelaunch) {
    try {
        $ah          = Join-Path $env:LOCALAPPDATA 'DesktopRtlPatch'
        $binDir      = Join-Path $ah 'bin'
        $binStaging  = "$binDir.staging"
        $binOld      = "$binDir.old"
        $marker      = Join-Path $ah 'pending-selfupdate'
        $readyFile   = Join-Path $ah 'ready.json'
        $wscript     = Join-Path $env:WINDIR 'System32\wscript.exe'
        function Test-RtlBinFiles([string]$d) {
            foreach ($f in @('desktop-rtl-lib.ps1', 'asar-edit.mjs', 'desktop-rtl-patch.js', 'Watch-DesktopRtl.ps1')) {
                if (-not (Test-Path (Join-Path $d $f))) { return $false }
            }
            return $true
        }
        if ((Test-Path $marker) -and (Test-Path $binStaging) -and (Test-RtlBinFiles $binStaging)) {
            if (Test-Path $binOld) { Remove-Item -LiteralPath $binOld -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path $binDir) { Rename-Item -LiteralPath $binDir -NewName ([IO.Path]::GetFileName($binOld)) -Force }
            Rename-Item -LiteralPath $binStaging -NewName ([IO.Path]::GetFileName($binDir)) -Force
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            $gen = $null
            $genFile = Join-Path $binDir 'generation.txt'
            if (Test-Path $genFile) { try { $gen = (Get-Content $genFile -Raw).Trim() } catch {} }
            if (Test-Path $readyFile) { try { Remove-Item -LiteralPath $readyFile -Force } catch {} }
            $freshVbs = Join-Path $binDir 'Desktop-RTL-Tray.vbs'
            if (Test-Path $freshVbs) {
                Start-Process -FilePath $wscript -ArgumentList "`"$freshVbs`""
                $ok = $false; $deadline = (Get-Date).AddSeconds(25)
                while ((Get-Date) -lt $deadline) {
                    if (Test-Path $readyFile) {
                        try {
                            $r = (Get-Content $readyFile -Raw) | ConvertFrom-Json
                            if (((-not $gen) -or ($r.generation -eq $gen)) -and (Get-Process -Id $r.pid -ErrorAction SilentlyContinue)) { $ok = $true; break }
                        } catch {}
                    }
                    Start-Sleep -Milliseconds 400
                }
                if ($ok) {
                    if (Test-Path $binOld) { Remove-Item -LiteralPath $binOld -Recurse -Force -ErrorAction SilentlyContinue }
                } elseif (Test-Path $binOld) {
                    $failed = "$binDir.failed"
                    if (Test-Path $failed) { Remove-Item -LiteralPath $failed -Recurse -Force -ErrorAction SilentlyContinue }
                    if (Test-Path $binDir) { Rename-Item -LiteralPath $binDir -NewName ([IO.Path]::GetFileName($failed)) -Force }
                    Rename-Item -LiteralPath $binOld -NewName ([IO.Path]::GetFileName($binDir)) -Force
                    $oldVbs = Join-Path $binDir 'Desktop-RTL-Tray.vbs'
                    if (Test-Path $oldVbs) { Start-Process -FilePath $wscript -ArgumentList "`"$oldVbs`"" }
                }
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
# The lib sits next to us in the agent bin, or under scripts\lib in the repo.
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
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\DesktopRtlTray', [ref]$script:Created)
if (-not $script:Created -and -not $SelfTest) { return }

# --- self-healing: consolidate autostart, evict any legacy watchers ----------
if (-not $SelfTest) {
    try { Invoke-RtlAgentMigration } catch { Write-RtlAgentLog "migration at startup failed: $($_.Exception.Message)" }
    try { Register-RtlAgent } catch { Write-RtlAgentLog "registration at startup failed: $($_.Exception.Message)" }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
try {
    Add-Type -Namespace DesktopRtl -Name NativeT -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool DestroyIcon(System.IntPtr handle);
'@ -ErrorAction Stop
    [void][DesktopRtl.NativeT]::SetCurrentProcessExplicitAppUserModelID('DesktopRtl.Agent')
} catch {}

# --- shared state (UI thread <-> background pass) ----------------------------
$script:Sync = [hashtable]::Synchronized(@{
        Busy = $false; Done = $false; Op = 'pass'; Results = $null; Err = $null; GenAtStart = 0; ToolInfo = $null
    })
$script:PassPs = $null; $script:PassRs = $null; $script:PassHandle = $null
$script:ToolInfo = $null
$script:Disposed = $false
$script:Apps = @()          # current installed-app id snapshot
$script:AppSig = "`0"       # signature of {installed set + sources}; forces first reconcile
$script:Generation = 0      # bumped on reconcile; invalidates an in-flight pass
$script:LastErr = @{}       # appId -> last error string (balloon de-duplication)
# Pending work accumulated while a pass is busy (replayed on completion).
$script:Pending = @{ appIds = @{}; force = $false }
$script:Fsws = @()

$script:AgentConfig = Read-RtlAgentConfig

# --- hidden host form (message pump) -----------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.ShowInTaskbar = $false
$form.WindowState = 'Minimized'
$form.FormBorderStyle = 'FixedToolWindow'
$form.Opacity = 0
$form.Width = 0; $form.Height = 0
$script:Form = $form

# --- tray icon (brand logo + badge variant) ----------------------------------
function Get-RtlBaseIcon {
    $icoPath = Join-Path $here 'desktop-rtl.ico'
    if (Test-Path $icoPath) { try { return (New-Object System.Drawing.Icon $icoPath) } catch {} }
    return [System.Drawing.SystemIcons]::Application
}
# Overlay a small dot on the base icon. Icon.FromHandle does NOT own its HICON, so we
# CLONE it, then DestroyIcon the original handle and keep only the clone (no leak).
function New-RtlBadgedIcon($base) {
    try {
        $bmp = $base.ToBitmap()
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $sz = [Math]::Max(6, [int]($bmp.Width * 0.44))
        $x = $bmp.Width - $sz - 1; $y = $bmp.Height - $sz - 1
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(235, 220, 45, 45))
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White, [Math]::Max(1, $bmp.Width / 16))
        $g.FillEllipse($brush, $x, $y, $sz, $sz)
        $g.DrawEllipse($pen, $x, $y, $sz, $sz)
        $brush.Dispose(); $pen.Dispose(); $g.Dispose()
        $h = $bmp.GetHicon()
        $tmp = [System.Drawing.Icon]::FromHandle($h)
        $clone = $tmp.Clone()
        [void][DesktopRtl.NativeT]::DestroyIcon($h)
        $tmp.Dispose(); $bmp.Dispose()
        return $clone
    } catch { return $base }
}
$script:BaseIcon = Get-RtlBaseIcon
$script:BadgedIcon = New-RtlBadgedIcon $script:BaseIcon

$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = $script:BaseIcon
$ni.Text = 'Desktop RTL'
$ni.Visible = $true

function Set-TrayStatus([string]$text) {
    if ($text.Length -gt 62) { $text = $text.Substring(0, 62) }
    $ni.Text = $text
}
function Show-TrayBalloon([string]$title, [string]$body, [System.Windows.Forms.ToolTipIcon]$icon = 'Info') {
    try { $ni.ShowBalloonTip(4000, $title, $body, $icon) } catch {}
}
function Get-TrayError([string]$m) {
    if (Get-Command Get-RtlHebrewError -ErrorAction SilentlyContinue) { return (Get-RtlHebrewError $m) }
    if ($m) { return $m } else { return 'שגיאה' }
}
function Get-RtlAppLabel([string]$id) {
    $p = Get-RtlProfile $id
    return $p.ShortcutLabel
}

# --- run a per-app UI action with active-app + ELECTRON env save/restore ------
function Invoke-AppAction([string]$id, [scriptblock]$body) {
    $save = $script:ActiveProfile.Id
    $envRun = $env:ELECTRON_RUN_AS_NODE; $envAsar = $env:ELECTRON_NO_ASAR
    try {
        Set-RtlActiveApp $id | Out-Null
        & $body
    } catch {
        Show-TrayBalloon (Get-RtlAppLabel $id) (Get-TrayError $_.Exception.Message) 'Error'
    } finally {
        try { Set-RtlActiveApp $save | Out-Null } catch {}
        if ($null -eq $envRun) { if ($env:ELECTRON_RUN_AS_NODE) { Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue } } else { $env:ELECTRON_RUN_AS_NODE = $envRun }
        if ($null -eq $envAsar) { if ($env:ELECTRON_NO_ASAR) { Remove-Item Env:\ELECTRON_NO_ASAR -ErrorAction SilentlyContinue } } else { $env:ELECTRON_NO_ASAR = $envAsar }
    }
}
function Open-AppSettings([string]$id) {
    $vbs = Join-Path $here 'Desktop-RTL-Settings.vbs'
    if (-not (Test-Path $vbs)) { $vbs = Join-Path (Split-Path $here -Parent) 'Desktop-RTL-Settings.vbs' }
    if (Test-Path $vbs) {
        Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList @("`"$vbs`"", $id)
        return
    }
    $s = Join-Path $here 'DesktopRtlSettings.ps1'
    if (-not (Test-Path $s)) { $s = Join-Path (Split-Path $here -Parent) 'scripts\DesktopRtlSettings.ps1' }
    if (Test-Path $s) { Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', $s, '-App', $id) }
}

# --- ONE shared menu handler; each item carries {App;Action} in .Tag ----------
# (Using .Tag instead of per-iteration closures avoids the PS 5.1 loop-variable
#  capture hazard where every handler would target the last app.)
$script:MenuAction = {
    param($s, $e)
    $t = $s.Tag
    if (-not $t) { return }
    switch ($t.Action) {
        'open'     { Invoke-AppAction $t.App { [void](Start-RtlCopyApp) } }
        'update'   { Start-TrayPass -Apps @($t.App) -Force }
        'settings' { Open-AppSettings $t.App }
        'diag'     { Invoke-AppAction $t.App { $z = Export-CodexRtlDiagnostics; if ($z) { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$z`"" } } }
    }
}
function New-AppMenuItem([string]$text, [string]$id, [string]$action) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $text
    $mi.Tag = [pscustomobject]@{ App = $id; Action = $action }
    $mi.add_Click($script:MenuAction)
    return $mi
}

# --- (re)build the context menu from the current installed-app set ------------
function Build-Menu {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.RightToLeft = 'Yes'
    $apps = $script:Apps
    if ($apps.Count -eq 1) {
        # Flat: the single app's actions live at the top level.
        $id = $apps[0]
        [void]$menu.Items.Add((New-AppMenuItem ('פתח את ' + (Get-RtlAppLabel $id)) $id 'open'))
        [void]$menu.Items.Add((New-AppMenuItem 'עדכן עכשיו' $id 'update'))
        [void]$menu.Items.Add((New-AppMenuItem 'הגדרות...' $id 'settings'))
        [void]$menu.Items.Add((New-AppMenuItem 'אבחון...' $id 'diag'))
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    } elseif ($apps.Count -gt 1) {
        # A submenu per installed app.
        foreach ($id in $apps) {
            $sub = New-Object System.Windows.Forms.ToolStripMenuItem (Get-RtlAppLabel $id)
            [void]$sub.DropDownItems.Add((New-AppMenuItem 'פתח' $id 'open'))
            [void]$sub.DropDownItems.Add((New-AppMenuItem 'עדכן עכשיו' $id 'update'))
            [void]$sub.DropDownItems.Add((New-AppMenuItem 'הגדרות...' $id 'settings'))
            [void]$sub.DropDownItems.Add((New-AppMenuItem 'אבחון...' $id 'diag'))
            [void]$menu.Items.Add($sub)
        }
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }
    # Shared items (recreated each rebuild; refs kept script-scoped for timers/drain).
    $script:miAuto = New-Object System.Windows.Forms.ToolStripMenuItem 'עדכון אוטומטי'
    $script:miAuto.CheckOnClick = $true
    $script:miAuto.Checked = [bool]$script:AgentConfig.autoPatch
    $script:miAuto.add_Click({
            $c = Read-RtlAgentConfig
            $c.autoPatch = [bool]$script:miAuto.Checked
            try { Write-RtlAgentConfig $c; $script:AgentConfig = $c }
            catch { $script:miAuto.Checked = -not $script:miAuto.Checked; Show-TrayBalloon 'שגיאה' 'שמירת ההגדרה נכשלה.' 'Error' }
        })
    [void]$menu.Items.Add($script:miAuto)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miCheck = New-Object System.Windows.Forms.ToolStripMenuItem 'בדוק עדכונים לכלי'
    $miCheck.add_Click({ Start-ToolCheck })
    [void]$menu.Items.Add($miCheck)
    $script:miInstallUpd = New-Object System.Windows.Forms.ToolStripMenuItem 'התקן עדכון לכלי'
    $script:miInstallUpd.Visible = $false
    $script:miInstallUpd.add_Click({ Start-ToolCheck -Install })
    if ($script:ToolInfo -and $script:ToolInfo.Available) {
        $script:miInstallUpd.Text = "התקן עדכון לכלי ($($script:ToolInfo.LatestTag))"
        $script:miInstallUpd.Visible = $true
    }
    [void]$menu.Items.Add($script:miInstallUpd)
    $miLogs = New-Object System.Windows.Forms.ToolStripMenuItem 'פתח תיקיית לוגים'
    $miLogs.add_Click({
            if (-not (Test-Path $script:AgentHome)) { New-Item -ItemType Directory -Force -Path $script:AgentHome | Out-Null }
            Start-Process -FilePath 'explorer.exe' -ArgumentList $script:AgentHome
        })
    [void]$menu.Items.Add($miLogs)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miQuit = New-Object System.Windows.Forms.ToolStripMenuItem 'יציאה'
    $miQuit.add_Click({ Invoke-TrayQuit })
    [void]$menu.Items.Add($miQuit)
    $ni.ContextMenuStrip = $menu
}

# --- FileSystemWatchers (one per installed Direct-source app) -----------------
function Build-Watchers {
    foreach ($w in $script:Fsws) { try { $w.EnableRaisingEvents = $false; $w.Dispose() } catch {} }
    $script:Fsws = @()
    $save = $script:ActiveProfile.Id
    try {
        foreach ($id in $script:Apps) {
            Set-RtlActiveApp $id | Out-Null
            $src = $null; try { $src = Resolve-RtlSource } catch {}
            if ($src -and $src.Type -eq 'Direct' -and $src.AsarPath) {
                $w = New-RtlSourceWatcher -WatchPath $src.AsarPath
                if ($w) {
                    # Do NOT rely on SynchronizingObject for every event path; each handler
                    # explicitly marshals to the UI thread via the hidden form.
                    $onChange = { try { $script:Form.BeginInvoke([Action] { Request-FswPass }) | Out-Null } catch {} }
                    $onError  = { try { $script:Form.BeginInvoke([Action] { Invoke-FswError }) | Out-Null } catch {} }
                    $w.add_Changed($onChange); $w.add_Created($onChange); $w.add_Renamed($onChange); $w.add_Error($onError)
                    $w.EnableRaisingEvents = $true
                    $script:Fsws += $w
                }
            }
        }
    } finally { Set-RtlActiveApp $save | Out-Null }
}
function Request-FswPass {
    if ($script:Disposed) { return }
    $script:Debounce.Stop(); $script:Debounce.Start()
}
function Invoke-FswError {
    if ($script:Disposed) { return }
    Write-RtlAgentLog 'FSW error/overflow; rebuilding watchers + reconciling.'
    Build-Watchers
    Start-TrayPass -Apps $script:Apps
}

# --- reconcile installed-app set (rebuild menu + watchers on change) ----------
function Invoke-Reconcile {
    param([switch]$Force)
    if ($script:Disposed) { return }
    $save = $script:ActiveProfile.Id
    $ids = @(); $sigParts = @()
    try {
        $ids = @(Get-RtlInstalledApps)
        foreach ($id in $ids) {
            Set-RtlActiveApp $id | Out-Null
            $src = $null; try { $src = Resolve-RtlSource } catch {}
            $sigParts += ("{0}|{1}" -f $id, $(if ($src) { "$($src.Type):$($src.AsarPath)" } else { 'none' }))
        }
    } finally { Set-RtlActiveApp $save | Out-Null }
    $sig = ($sigParts -join ';')
    if ($Force -or $sig -ne $script:AppSig) {
        $script:AppSig = $sig
        $script:Apps = $ids
        $script:Generation++
        Build-Menu
        Build-Watchers
        Write-RtlAgentLog ("reconciled: apps=[{0}]" -f ($ids -join ','))
    }
}

# --- background update pass (all target apps in ONE runspace) -----------------
function Start-TrayPass {
    param([string[]]$Apps, [switch]$Force)
    if (-not $Apps -or $Apps.Count -eq 0) { $Apps = $script:Apps }
    if (-not $Apps -or $Apps.Count -eq 0) { return }
    if ($script:Sync.Busy) {
        foreach ($a in $Apps) { $script:Pending.appIds[$a] = $true }
        if ($Force) { $script:Pending.force = $true }
        return
    }
    $script:Sync.Busy = $true; $script:Sync.Done = $false; $script:Sync.Op = 'pass'
    $script:Sync.Results = $null; $script:Sync.Err = $null; $script:Sync.GenAtStart = $script:Generation
    if ($Force -and $Apps.Count -eq 1) { Set-TrayStatus ((Get-RtlAppLabel $Apps[0]) + ' - מעדכן...') }
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $script:Sync)
    $rs.SessionStateProxy.SetVariable('LibPath', $script:LibPath)
    $rs.SessionStateProxy.SetVariable('AppsArg', ([string[]]$Apps))
    $rs.SessionStateProxy.SetVariable('DoForce', [bool]$Force)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
            . $LibPath
            $results = @{}
            foreach ($id in $AppsArg) {
                $r = @{ ok = $false; err = $null }
                try {
                    Set-RtlActiveApp $id | Out-Null
                    if ($DoForce) { Invoke-CodexRtlUpdate -Force } else { Invoke-CodexRtlUpdate -Auto }
                    $r.ok = $true
                } catch { $r.err = $_.Exception.Message }
                $results[$id] = $r
            }
            $Sync.Results = $results
            $Sync.Done = $true
        })
    $script:PassRs = $rs; $script:PassPs = $ps
    $script:PassHandle = $ps.BeginInvoke()
}

# --- background tool-update check / install ----------------------------------
function Start-ToolCheck {
    param([switch]$Install)
    if ($script:Sync.Busy) { return }
    $script:Sync.Busy = $true; $script:Sync.Done = $false; $script:Sync.Op = if ($Install) { 'toolinstall' } else { 'toolcheck' }
    $script:Sync.Err = $null
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
            } catch { $Sync.Err = $_.Exception.Message }
            finally { $Sync.Done = $true }
        })
    $script:PassRs = $rs; $script:PassPs = $ps
    $script:PassHandle = $ps.BeginInvoke()
}

# --- drain timer: reflect background results on the UI thread ----------------
$drain = New-Object System.Windows.Forms.Timer
$drain.Interval = 250
$drain.Add_Tick({
        if (-not ($script:Sync.Busy -and $script:Sync.Done)) { return }
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
                if ($script:miInstallUpd) { $script:miInstallUpd.Text = "התקן עדכון לכלי ($($info.LatestTag))"; $script:miInstallUpd.Visible = $true }
                Show-TrayBalloon 'עדכון זמין לכלי' "גרסה $($info.LatestTag) זמינה. לחצ/י 'התקן עדכון לכלי' בתפריט." 'Info'
            } else {
                $script:ToolInfo = $null
                if ($script:miInstallUpd) { $script:miInstallUpd.Visible = $false }
            }
        } else {
            # update pass: apply per-app results only if no reconcile happened meanwhile.
            if ($script:Sync.GenAtStart -eq $script:Generation) {
                $results = $script:Sync.Results
                if ($results) {
                    foreach ($id in @($results.Keys)) {
                        $r = $results[$id]
                        if ($r.ok) { $script:LastErr.Remove($id) | Out-Null }
                        else {
                            # De-duplicate: balloon a given app's error only when it changes.
                            # Failed apps are NOT requeued here; the next poll retries them.
                            if ($script:LastErr[$id] -ne $r.err) {
                                $script:LastErr[$id] = $r.err
                                Show-TrayBalloon ((Get-RtlAppLabel $id) + ' - עדכון נכשל') (Get-TrayError $r.err) 'Error'
                            }
                        }
                    }
                }
            }
        }
        $script:Sync.Busy = $false
        Update-TrayStatus
        # Replay work that arrived DURING the pass (triggers, not failures).
        if ($script:Pending.appIds.Count -gt 0 -or $script:Pending.force) {
            $ids = @($script:Pending.appIds.Keys)
            $force = [bool]$script:Pending.force
            $script:Pending = @{ appIds = @{}; force = $false }
            if ($force) { Start-TrayPass -Apps $ids -Force } else { Start-TrayPass -Apps $ids }
        }
    })

# --- periodic triggers -------------------------------------------------------
$poll = New-Object System.Windows.Forms.Timer
$poll.Interval = 90000   # reconcile + a Store-fallback pass; also completes a deferred swap on close
$poll.Add_Tick({
        Invoke-Reconcile
        if ($script:miAuto -and $script:miAuto.Checked) { Start-TrayPass -Apps $script:Apps }
    })

$toolTimer = New-Object System.Windows.Forms.Timer
$toolTimer.Interval = 86400000   # once a day
$toolTimer.Add_Tick({ if ((Read-RtlAgentConfig).checkForToolUpdates) { Start-ToolCheck } })

$script:Debounce = New-Object System.Windows.Forms.Timer
$script:Debounce.Interval = 5000
$script:Debounce.Add_Tick({ $script:Debounce.Stop(); if (-not $script:Disposed -and $script:miAuto -and $script:miAuto.Checked) { Start-TrayPass -Apps $script:Apps } })

# --- status / tooltip --------------------------------------------------------
function Update-TrayIcon {
    $want = if ($script:ToolInfo -and $script:ToolInfo.Available) { $script:BadgedIcon } else { $script:BaseIcon }
    if ($ni.Icon -ne $want) { $ni.Icon = $want }
}
function Update-TrayStatus {
    $parts = @()
    $save = $script:ActiveProfile.Id
    try {
        foreach ($id in $script:Apps) {
            Set-RtlActiveApp $id | Out-Null
            $st = $null; try { $st = Get-CodexRtlStatus } catch {}
            $s = switch ($(if ($st) { $st.State } else { '' })) {
                'UpToDate'     { 'מעודכן' }
                'Update'       { 'עדכון זמין' }
                'PatchUpgrade' { 'עדכון תיקון' }
                'Repair'       { 'דרוש תיקון' }
                'Fresh'        { 'לא מותקן' }
                default        { '' }
            }
            $parts += ((Get-RtlProfile $id).DisplayName + ': ' + $s)
        }
    } finally { Set-RtlActiveApp $save | Out-Null }
    if ($parts.Count -gt 0) { Set-TrayStatus ($parts -join ' | ') } else { Set-TrayStatus 'Desktop RTL' }
    Update-TrayIcon
}

$ni.Add_DoubleClick({ if ($script:Apps.Count -ge 1) { Invoke-AppAction $script:Apps[0] { [void](Start-RtlCopyApp) } } })

function Invoke-TrayQuit {
    $script:Disposed = $true
    try { $drain.Stop(); $poll.Stop(); $toolTimer.Stop(); $script:Debounce.Stop() } catch {}
    foreach ($w in $script:Fsws) { try { $w.EnableRaisingEvents = $false; $w.Dispose() } catch {} }
    try { $ni.Visible = $false; $ni.Dispose() } catch {}
    try { if ($script:BadgedIcon -and $script:BadgedIcon -ne $script:BaseIcon) { $script:BadgedIcon.Dispose() } } catch {}
    try { if ($script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch {}
    try { [System.Windows.Forms.Application]::Exit() } catch {}
}
$form.Add_FormClosed({ try { $ni.Visible = $false; $ni.Dispose() } catch {} })

# --- build + go --------------------------------------------------------------
Invoke-Reconcile -Force
Update-TrayStatus

if ($SelfTest) {
    $layout = if ($script:Apps.Count -eq 1) { 'flat' } elseif ($script:Apps.Count -gt 1) { 'submenu-per-app' } else { 'no-app' }
    Write-Host ("SelfTest OK: apps=[{0}] layout={1} menuItems={2} autoPatch={3} badgeBuilt={4}" -f `
        ($script:Apps -join ','), $layout, $ni.ContextMenuStrip.Items.Count, $script:AgentConfig.autoPatch, ($script:BadgedIcon -ne $script:BaseIcon))
    try { $ni.Visible = $false; $ni.Dispose() } catch {}
    try { $form.Dispose() } catch {}
    try { if ($script:Created) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch {}
    return
}

# Announce readiness (PID + deployed generation) for the installer/self-update supervisor.
try { Write-RtlAgentReady -Generation (Read-RtlAgentGeneration) } catch {}

$drain.Start(); $poll.Start(); $toolTimer.Start()
Start-TrayPass -Apps $script:Apps                      # initial pass
if ((Read-RtlAgentConfig).checkForToolUpdates) {
    # queue AFTER the initial pass (the shared busy flag would otherwise drop it)
    $kick = New-Object System.Windows.Forms.Timer
    $kick.Interval = 1500
    $kick.Add_Tick({ if (-not $script:Sync.Busy) { $kick.Stop(); Start-ToolCheck } })
    $kick.Start()
}
$ctx = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($ctx)
