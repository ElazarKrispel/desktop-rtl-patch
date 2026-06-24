# codex-rtl-lib.ps1
# Shared logic for the Codex RTL patch: resolve the Codex install, build a patched
# copy via staging + atomic swap, manage the auto-update watcher, logging, progress
# reporting and a single-instance lock.
#
# SAFETY INVARIANT: we NEVER modify the original Codex install. We only READ from it
# and build/maintain a SEPARATE copy under %LOCALAPPDATA%\OpenAI\CodexRtl. Every asar
# edit happens inside staging / the RTL copy only (enforced in Invoke-AsarInject).
#
# No elevation required: everything writes under the user profile.
# This file is ASCII-only; the Hebrew shortcut label is built from code points so it
# is safe regardless of how Windows PowerShell 5.1 decodes the file.

$script:PatchVersion  = '1.0.0'
$script:SchemaVersion = 1
$script:StateDir   = Join-Path $env:LOCALAPPDATA 'CodexRtlPatch'
$script:BinDir     = Join-Path $script:StateDir 'bin'
$script:LogsDir    = Join-Path $script:StateDir 'logs'
$script:StateFile  = Join-Path $script:StateDir 'state.json'
$script:LogFile    = Join-Path $script:StateDir 'rtl.log'
$script:LockFile   = Join-Path $script:StateDir 'update.lock'
$script:TaskName   = 'CodexRtlPatchWatcher'
$script:CopyRoot   = Join-Path $env:LOCALAPPDATA 'OpenAI\CodexRtl'
$script:Staging    = Join-Path $env:LOCALAPPDATA 'OpenAI\CodexRtl.staging'
$script:OldRoot    = Join-Path $env:LOCALAPPDATA 'OpenAI\CodexRtl.old'
$script:LockStream = $null
$script:InstallLogFile = $null
$script:StepSink   = $null   # { param($key,$percent,$marquee) }  optionally set by the GUI
$script:UiSink     = $null   # { param($message) }                optionally set by the GUI

# Shortcut: differentiate from the regular Codex by NAME only ("Codex (RTL)"),
# keeping the ORIGINAL Codex icon. The app is not "in Hebrew", it only adds RTL
# support, so the name says (RTL) rather than implying a Hebrew build.
$script:ShortcutLabel   = 'Codex (RTL)'
$script:ShortcutStart   = Join-Path ([Environment]::GetFolderPath('Programs')) ($script:ShortcutLabel + '.lnk')
$script:ShortcutDesktop = Join-Path ([Environment]::GetFolderPath('Desktop'))  ($script:ShortcutLabel + '.lnk')
$script:ShortcutPath    = $script:ShortcutStart   # back-compat alias
# Legacy shortcut names from earlier builds (the short-lived "Codex <ivrit>" name),
# removed so users never see duplicates. Built from code points (keeps this file ASCII).
$script:_ivrit = 'Codex ' + (-join @([char]0x05E2, [char]0x05D1, [char]0x05E8, [char]0x05D9, [char]0x05EA))
$script:LegacyShortcuts = @(
    (Join-Path ([Environment]::GetFolderPath('Programs')) ($script:_ivrit + '.lnk')),
    (Join-Path ([Environment]::GetFolderPath('Desktop'))  ($script:_ivrit + '.lnk'))
)
$script:ShortcutPaths = @($script:ShortcutStart, $script:ShortcutDesktop) + $script:LegacyShortcuts

# ----------------------------------------------------------------- logging / ui

function Start-RtlInstallLog {
    # Begin a fresh timestamped run log under the stable logs folder. The detailed
    # technical log goes to this file (and the rolling rtl.log); the GUI shows only
    # friendly lines via Write-RtlUi / Set-RtlStep.
    param([string]$Kind = 'install')
    if (-not (Test-Path $script:LogsDir)) { New-Item -ItemType Directory -Force -Path $script:LogsDir | Out-Null }
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:InstallLogFile = Join-Path $script:LogsDir ("{0}-{1}.log" -f $Kind, $ts)
    return $script:InstallLogFile
}

function Write-RtlLog {
    param([string]$Message)
    $line = "$([DateTime]::Now.ToString('o'))  [$PID]  $Message"
    Write-Host $line
    try {
        if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null }
        if ((Test-Path $script:LogFile) -and (Get-Item $script:LogFile).Length -gt 1MB) { Move-Item $script:LogFile "$($script:LogFile).old" -Force }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
        if ($script:InstallLogFile) { Add-Content -LiteralPath $script:InstallLogFile -Value $line -Encoding UTF8 }
    } catch {}
}

# Structured progress for the GUI: a step key, a percent, and a marquee flag (for
# stages with no granular percentage). Also written to the file log.
function Set-RtlStep {
    param([string]$Key, [int]$Percent = -1, [bool]$Marquee = $false)
    Write-RtlLog ("STEP {0} {1}%{2}" -f $Key, $Percent, $(if ($Marquee) { ' (marquee)' } else { '' }))
    if ($script:StepSink) { try { & $script:StepSink $Key $Percent $Marquee } catch {} }
}

# A user-friendly status line for the GUI (kept separate from the detailed file log).
function Write-RtlUi {
    param([string]$Message)
    Write-RtlLog "UI: $Message"
    if ($script:UiSink) { try { & $script:UiSink $Message } catch {} }
}

function Show-RtlToast {
    param([string]$Title, [string]$Body)
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $t = [System.Security.SecurityElement]::Escape($Title)
        $b = [System.Security.SecurityElement]::Escape($Body)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$t</text><text>$b</text></binding></visual></toast>")
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Codex RTL Patch').Show($toast)
    } catch { Write-RtlLog "toast failed: $($_.Exception.Message)" }
}

function Hide-RtlConsole {
    # Reliably hide the console window of the current process, so a GUI or a
    # background script shows no black PowerShell window (more robust than relying
    # on -WindowStyle Hidden alone). Safe no-op when there is no console.
    try {
        if (-not ([System.Management.Automation.PSTypeName]'CodexRtl.ConsoleWin').Type) {
            Add-Type -Namespace CodexRtl -Name ConsoleWin -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
        }
        $h = [CodexRtl.ConsoleWin]::GetConsoleWindow()
        if ($h -ne [System.IntPtr]::Zero) { [void][CodexRtl.ConsoleWin]::ShowWindow($h, 0) }  # SW_HIDE = 0
    } catch {}
}

# ----------------------------------------------------------------- state

function Read-RtlState {
    if (-not (Test-Path $script:StateFile)) { return $null }
    try { return (Get-Content $script:StateFile -Raw | ConvertFrom-Json) } catch { return $null }
}

function Write-RtlState {
    # State schema v1. installedAt is preserved across updates; lastUpdatedAt is bumped.
    param([hashtable]$State)
    if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null }
    $existing = Read-RtlState
    $now = (Get-Date).ToString('o')
    $installedAt = if ($existing -and $existing.installedAt) { $existing.installedAt } else { $now }
    $full = [ordered]@{
        schemaVersion   = $script:SchemaVersion
        patchVersion    = $script:PatchVersion
        mode            = 'copy'
        sourceSignature = $State.sourceSignature
        sourcePath      = $State.sourcePath
        copyRoot        = $script:CopyRoot
        codexVersion    = $State.codexVersion
        installedAt     = $installedAt
        lastUpdatedAt   = $now
    }
    [System.IO.File]::WriteAllText($script:StateFile, (([pscustomobject]$full) | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
    Write-RtlLog "State written: $($script:StateFile) (sig=$($State.sourceSignature))"
}

# ----------------------------------------------------------------- lock

function Enter-RtlLock {
    try {
        if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null }
        $script:LockStream = [System.IO.File]::Open($script:LockFile, 'OpenOrCreate', 'ReadWrite', 'None')
        return $true
    } catch { return $false }
}

function Exit-RtlLock {
    if ($script:LockStream) { try { $script:LockStream.Close() } catch {}; $script:LockStream = $null }
}

# ----------------------------------------------------------------- helpers

function Get-PatchJsPath {
    # Prefer a copy deployed next to this lib (the installed watcher); fall back to the repo.
    $here = $PSScriptRoot
    foreach ($p in @((Join-Path $here 'codex-rtl-patch.js'), (Join-Path $here '..\..\src\codex-rtl-patch.js'))) {
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    return $null
}

function Get-AsarEditPath {
    $p = Join-Path $PSScriptRoot 'asar-edit.mjs'
    if (Test-Path $p) { return (Resolve-Path $p).Path }
    return $null
}

# The Node runtime that ships INSIDE Codex, next to the asar:
#   <app>\resources\cua_node\bin\node.exe
# Using it removes any external Node.js prerequisite for end users.
function Resolve-RtlNode {
    param([string]$AsarPath)
    $resources = Split-Path -Parent $AsarPath
    $node = Join-Path $resources 'cua_node\bin\node.exe'
    if (Test-Path $node) { return $node }
    return $null
}

function Resolve-CodexSource {
    # Prefer the Microsoft Store (MSIX) package.
    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg -and $pkg.InstallLocation) {
        $asar = Join-Path $pkg.InstallLocation 'app\resources\app.asar'
        if (Test-Path $asar) {
            return [pscustomobject]@{
                Type = 'Store'; Version = [string]$pkg.Version; Signature = "store:$($pkg.Version)"
                AppDir = (Join-Path $pkg.InstallLocation 'app'); AsarPath = $asar; Writable = $false
            }
        }
    }
    # Fall back to a direct (non-Store) install. NOTE: even for a writable direct
    # install we build a SEPARATE copy and never edit the original (safety invariant).
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\codex'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Codex'),
        (Join-Path $env:LOCALAPPDATA 'codex'),
        (Join-Path ${env:ProgramFiles} 'Codex')
    ) | Where-Object { $_ -and (Test-Path $_) }
    foreach ($r in $roots) {
        $asarItem = Get-ChildItem $r -Recurse -Filter app.asar -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $asarItem) { continue }
        $appDir = Split-Path (Split-Path $asarItem.FullName -Parent) -Parent
        $ver = $null
        if ($asarItem.FullName -match 'app-(\d+(?:\.\d+){1,3})') { $ver = $matches[1] }
        if (-not $ver) { $ver = "$($asarItem.LastWriteTimeUtc.ToString('yyyyMMddHHmmss'))" }
        return [pscustomobject]@{
            Type = 'Direct'; Version = $ver; Signature = "direct:$($asarItem.Length)-$($asarItem.LastWriteTimeUtc.Ticks)"
            AppDir = $appDir; AsarPath = $asarItem.FullName; Writable = $true
        }
    }
    return $null
}

# Validate that a resolved source has the layout we expect. Throws coded errors so
# the installer fails safely instead of proceeding on wrong assumptions.
function Test-CodexSource {
    param([Parameter(Mandatory)]$Source)
    if (-not $Source)                      { throw '[NOCODEX] No Codex source found.' }
    if (-not (Test-Path $Source.AppDir))   { throw "[LAYOUT] Codex app folder missing: $($Source.AppDir)" }
    if (-not (Test-Path $Source.AsarPath)) { throw "[LAYOUT] Codex app.asar missing: $($Source.AsarPath)" }
    try {
        $fs = [System.IO.File]::OpenRead($Source.AsarPath)
        try { $hdr = New-Object byte[] 4; [void]$fs.Read($hdr, 0, 4) } finally { $fs.Dispose() }
        if ([System.BitConverter]::ToUInt32($hdr, 0) -ne 4) { throw 'unexpected asar header' }
    } catch { throw "[LAYOUT] Codex app.asar is not a readable asar: $($_.Exception.Message)" }
    if (-not (Resolve-RtlNode -AsarPath $Source.AsarPath)) {
        throw "[NODE] Codex bundled Node (resources\cua_node\bin\node.exe) was not found; Codex may be incompletely installed or its layout changed."
    }
    return $true
}

function Test-CodexRtlRunning {
    # Is the patched copy (CodexRtl) currently running? Match the exact folder so
    # CodexRtl.staging / CodexRtl.old never count as the live copy.
    $prefix = $script:CopyRoot.TrimEnd('\') + '\'
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    }
    return [bool]$procs
}

# Is the ORIGINAL (non-RTL) Codex running? Detected by exe path NOT under our copy,
# so the original Codex being open is never mistaken for the RTL copy.
function Test-OriginalCodexRunning {
    $prefix = $script:CopyRoot.TrimEnd('\') + '\'
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and ($_.Name -ieq 'Codex') -and -not $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    }
    return [bool]$procs
}

# Verify the installer package is complete (catches "user extracted only the .cmd",
# or a partial ZIP). Throws [PACKAGE] listing what is missing.
function Test-RtlPackage {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $required = @(
        'scripts\lib\codex-rtl-lib.ps1',
        'scripts\lib\asar-edit.mjs',
        'src\codex-rtl-patch.js',
        'scripts\Watch-CodexRtl.ps1'
    )
    $missing = @()
    foreach ($rel in $required) { if (-not (Test-Path (Join-Path $RepoRoot $rel))) { $missing += $rel } }
    if ($missing.Count) { throw "[PACKAGE] Installer package is incomplete; missing: $($missing -join ', ')" }
    return $true
}

function Invoke-Robocopy {
    param([string]$From, [string]$To)
    $a = @("`"$From`"", "`"$To`"", '/MIR', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    $p = Start-Process robocopy -ArgumentList $a -Wait -PassThru -NoNewWindow
    return $p.ExitCode
}

function Invoke-AsarInject {
    param([string]$AsarPath, [string]$PatchJs, [switch]$NoBak, [switch]$AllowExternalNodeFallback)
    # SAFETY: only ever edit an asar INSIDE our copy/staging, never the original app.
    $full  = [System.IO.Path]::GetFullPath($AsarPath)
    $copyP = [System.IO.Path]::GetFullPath($script:CopyRoot).TrimEnd('\') + '\'
    $stagP = [System.IO.Path]::GetFullPath($script:Staging).TrimEnd('\') + '\'
    if (-not ($full.StartsWith($copyP, [StringComparison]::OrdinalIgnoreCase) -or
              $full.StartsWith($stagP, [StringComparison]::OrdinalIgnoreCase))) {
        throw "[SAFETY] Refusing to edit an asar outside the RTL copy/staging: $full"
    }
    # End users depend ONLY on Codex's bundled Node; PATH fallback is dev/headless only.
    $node = Resolve-RtlNode -AsarPath $AsarPath
    if (-not $node -and $AllowExternalNodeFallback) {
        $node = (Get-Command node -ErrorAction SilentlyContinue).Source
        if ($node) { Write-RtlLog "WARNING: bundled Node missing; using external PATH Node ($node) via -AllowExternalNodeFallback (non-standard)." }
    }
    if (-not $node) { throw "[NODE] Codex bundled Node (resources\cua_node\bin\node.exe) was not found next to the copied app; cannot edit the bundle." }
    $editor = Get-AsarEditPath
    if (-not $editor) { throw 'asar-edit.mjs not found.' }
    $bak = if ($NoBak) { '--no-bak' } else { '' }
    if ($bak) { $out = (& $node $editor $AsarPath $PatchJs $bak) | Out-String }
    else      { $out = (& $node $editor $AsarPath $PatchJs)      | Out-String }
    if ($LASTEXITCODE -ne 0) { throw "[ASAR] asar-edit failed ($LASTEXITCODE): $($out.Trim())" }
    Write-RtlLog "asar-edit: $($out.Trim())"
}

function Invoke-AtomicSwap {
    # Replace CopyRoot with Staging via near-atomic directory renames. Caller must
    # have verified Codex (RTL) is not running.
    if (Test-Path $script:OldRoot) { Remove-Item -LiteralPath $script:OldRoot -Recurse -Force }
    if (Test-Path $script:CopyRoot) {
        Rename-Item -LiteralPath $script:CopyRoot -NewName (Split-Path $script:OldRoot -Leaf) -Force
    }
    try {
        Rename-Item -LiteralPath $script:Staging -NewName (Split-Path $script:CopyRoot -Leaf) -Force
    } catch {
        # Roll back: restore the previous copy so the user is never left without one.
        if (-not (Test-Path $script:CopyRoot) -and (Test-Path $script:OldRoot)) {
            Rename-Item -LiteralPath $script:OldRoot -NewName (Split-Path $script:CopyRoot -Leaf) -Force
        }
        throw
    }
    if (Test-Path $script:OldRoot) { Remove-Item -LiteralPath $script:OldRoot -Recurse -Force }
}

function New-RtlShortcut {
    # Differentiate from the regular Codex by NAME only ("Codex <ivrit>"), keeping
    # Codex's ORIGINAL icon so the app stays visually recognizable as Codex. Creates
    # both a Start-menu and a Desktop shortcut, and removes legacy-named shortcuts.
    $exe  = Join-Path $script:CopyRoot 'app\Codex.exe'
    $work = Join-Path $script:CopyRoot 'app'
    $ws = New-Object -ComObject WScript.Shell
    foreach ($lnk in @($script:ShortcutStart, $script:ShortcutDesktop)) {
        try {
            $sc = $ws.CreateShortcut($lnk)
            $sc.TargetPath       = $exe
            $sc.WorkingDirectory = $work
            $sc.IconLocation     = "$exe,0"   # original Codex icon
            $sc.Description       = 'Codex with Hebrew / RTL support'
            $sc.Save()
        } catch { Write-RtlLog "shortcut '$lnk' failed: $($_.Exception.Message)" }
    }
    foreach ($old in $script:LegacyShortcuts) {
        if (Test-Path $old) { try { Remove-Item -LiteralPath $old -Force } catch {} }
    }
}

# Read-only environment report for support / diagnostics. Never modifies anything.
function Invoke-CodexRtlDiagnose {
    Start-RtlInstallLog 'diagnose' | Out-Null
    Write-RtlLog '=== Diagnose start ==='
    $r = [ordered]@{
        CodexFound = $false; SourceType = $null; SourceVersion = $null; AppDir = $null
        AsarPath = $null; AsarExists = $false; NodePath = $null; NodeExists = $false
        LayoutValid = $false; LayoutError = $null
        TargetDrive = $null; FreeGB = $null; SourceSizeGB = $null; EnoughSpace = $null
        RtlInstalled = $false; CopyExists = $false; RtlRunning = $false; OriginalRunning = $false
        StateOk = $false; PatchVersion = $script:PatchVersion
    }
    try {
        $src = Resolve-CodexSource
        if ($src) {
            $r.CodexFound = $true; $r.SourceType = $src.Type; $r.SourceVersion = $src.Version
            $r.AppDir = $src.AppDir; $r.AsarPath = $src.AsarPath; $r.AsarExists = (Test-Path $src.AsarPath)
            $node = Resolve-RtlNode -AsarPath $src.AsarPath
            $r.NodePath = $node; $r.NodeExists = [bool]$node
            try { Test-CodexSource -Source $src | Out-Null; $r.LayoutValid = $true }
            catch { $r.LayoutError = $_.Exception.Message }
        }
        $r.TargetDrive = (Split-Path -Qualifier $script:CopyRoot)
        $freeBytes = $null
        try {
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($r.TargetDrive)'" -ErrorAction Stop
            $freeBytes = [double]$disk.FreeSpace
            $r.FreeGB = [math]::Round($freeBytes / 1GB, 1)
        } catch {}
        if ($src -and (Test-Path $src.AppDir)) {
            try {
                $sum = (Get-ChildItem -LiteralPath $src.AppDir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                if ($sum) {
                    $r.SourceSizeGB = [math]::Round($sum / 1GB, 2)
                    if ($null -ne $freeBytes) { $r.EnoughSpace = ($freeBytes -gt ($sum * 1.1 + 1GB)) }
                }
            } catch {}
        }
        $state = Read-RtlState
        $r.StateOk = [bool]$state
        $r.CopyExists = (Test-Path (Join-Path $script:CopyRoot 'app\Codex.exe'))
        $r.RtlInstalled = ([bool]$state -and $r.CopyExists)
        $r.RtlRunning = Test-CodexRtlRunning
        $r.OriginalRunning = Test-OriginalCodexRunning
    } catch { Write-RtlLog "diagnose error: $($_.Exception.Message)" }
    foreach ($k in $r.Keys) { Write-RtlLog ("  {0} = {1}" -f $k, $r[$k]) }
    Write-RtlLog '=== Diagnose end ==='
    return [pscustomobject]$r
}

# ----------------------------------------------------------------- core update

function Invoke-CodexRtlUpdate {
    param([switch]$Force, [switch]$Auto, [switch]$AllowExternalNodeFallback)
    if (-not (Enter-RtlLock)) { Write-RtlLog 'Another update is in progress; skipping.'; return }
    try {
        Set-RtlStep 'preflight' 5
        $src = Resolve-CodexSource
        if (-not $src) {
            Write-RtlLog '[NOCODEX] No Codex install found.'
            if (-not $Auto) { throw '[NOCODEX] Codex not found (install it from the Microsoft Store).' }
            return
        }
        Test-CodexSource -Source $src | Out-Null   # throws [LAYOUT]/[NODE] on structural problems

        $state   = Read-RtlState
        $patchJs = Get-PatchJsPath
        if (-not $patchJs) { throw 'codex-rtl-patch.js not found.' }

        $current = if ($state) { $state.sourceSignature } else { $null }
        if (-not $Force -and $current -eq $src.Signature -and (Test-Path (Join-Path $script:CopyRoot 'app\Codex.exe'))) {
            Write-RtlLog "Up to date (Codex v$($src.Version))."
            Set-RtlStep 'done' 100
            return
        }
        Write-RtlLog "Update needed: Codex v$($src.Version) [$($src.Type)] (was '$current')"

        # ---- copy mode (always): build to staging, then atomic-swap when closed ----
        $stagingSig = Join-Path $script:Staging '.codexrtl-sig'
        $stagingReady = (Test-Path (Join-Path $script:Staging 'app\Codex.exe')) -and
                        (Test-Path $stagingSig) -and ((Get-Content $stagingSig -Raw).Trim() -eq $src.Signature)
        if (-not $stagingReady) {
            Set-RtlStep 'copy' 15 $true
            Write-RtlLog 'Building patched copy in staging...'
            if (Test-Path $script:Staging) { Remove-Item -LiteralPath $script:Staging -Recurse -Force }
            $stagingApp = Join-Path $script:Staging 'app'
            New-Item -ItemType Directory -Force -Path $stagingApp | Out-Null
            $rc = Invoke-Robocopy -From $src.AppDir -To $stagingApp
            if ($rc -ge 8) { throw "robocopy failed (exit $rc); copy incomplete (out of disk space or locked files)." }
            Set-RtlStep 'inject' 70 $true
            Invoke-AsarInject -AsarPath (Join-Path $stagingApp 'resources\app.asar') -PatchJs $patchJs -AllowExternalNodeFallback:$AllowExternalNodeFallback
            Set-Content -LiteralPath $stagingSig -Value $src.Signature -Encoding UTF8 -NoNewline
            Write-RtlLog 'Staging build complete.'
        } else {
            Write-RtlLog 'Staging already built for this version; attempting swap.'
        }

        if (Test-CodexRtlRunning) {
            Write-RtlLog 'Codex (RTL) is running; deferring swap (staging kept for next close).'
            if ($Auto) { Show-RtlToast 'Codex update ready' 'A newer Codex is staged. It will apply next time you close Codex.' }
            Set-RtlStep 'deferred' 100
            return
        }

        Set-RtlStep 'swap' 90
        Write-RtlLog 'Swapping staging into place (atomic)...'
        Invoke-AtomicSwap
        Set-RtlStep 'shortcut' 95
        New-RtlShortcut
        Write-RtlState @{ sourceSignature = $src.Signature; codexVersion = $src.Version; sourcePath = $src.AppDir }
        Write-RtlLog "DONE: Codex (RTL) now at v$($src.Version)."
        Set-RtlStep 'done' 100
        if ($Auto) { Show-RtlToast 'Codex RTL updated' "Patched for Codex v$($src.Version)." }
    } finally {
        Exit-RtlLock
    }
}

# ----------------------------------------------------------------- watcher

# We autostart via the per-user HKCU\...\Run key (writable without admin), rather
# than a scheduled task (which requires admin to register). The watcher then runs
# a light background loop, so there is ZERO admin involvement, ever.
$script:RunKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunName = 'CodexRtlPatchWatcher'

function Register-CodexRtlWatcher {
    param([string]$WatchScript)
    $ps = (Get-Command powershell.exe).Source
    $cmd = "`"$ps`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WatchScript`" -Loop"
    if (-not (Test-Path $script:RunKey)) { New-Item -Path $script:RunKey -Force | Out-Null }
    Set-ItemProperty -Path $script:RunKey -Name $script:RunName -Value $cmd
    Write-RtlLog "Registered logon watcher (HKCU\Run)."
}

function Stop-CodexRtlWatcher {
    # Kill any running watcher process(es) so a freshly deployed watcher (e.g. one
    # that now hides its console) can replace it, and so uninstall leaves none behind.
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*Watch-CodexRtl*' } |
            ForEach-Object {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Write-RtlLog "Stopped watcher PID $($_.ProcessId)." } catch {}
            }
    } catch {}
}

function Unregister-CodexRtlWatcher {
    Stop-CodexRtlWatcher
    try { Remove-ItemProperty -Path $script:RunKey -Name $script:RunName -ErrorAction Stop; Write-RtlLog 'Removed logon watcher.' }
    catch { Write-RtlLog 'No logon watcher to remove.' }
    # also remove any legacy scheduled task from earlier versions
    try { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop; Write-RtlLog 'Removed legacy scheduled task.' } catch {}
}

function Start-CodexRtlWatcher {
    param([string]$WatchScript)
    Stop-CodexRtlWatcher   # replace any existing (possibly visible) watcher with the fresh one
    $ps = (Get-Command powershell.exe).Source
    Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $WatchScript, '-Loop')
    Write-RtlLog 'Started watcher for the current session.'
}

# ----------------------------------------------------------------- deploy

function Copy-RtlBin {
    # Copy the watcher's runtime files to a stable per-user location so the
    # watcher never depends on the repo path.
    param([string]$RepoRoot)
    New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    Copy-Item (Join-Path $RepoRoot 'scripts\lib\codex-rtl-lib.ps1') (Join-Path $script:BinDir 'codex-rtl-lib.ps1') -Force
    Copy-Item (Join-Path $RepoRoot 'scripts\lib\asar-edit.mjs')     (Join-Path $script:BinDir 'asar-edit.mjs')     -Force
    Copy-Item (Join-Path $RepoRoot 'src\codex-rtl-patch.js')        (Join-Path $script:BinDir 'codex-rtl-patch.js') -Force
    Copy-Item (Join-Path $RepoRoot 'scripts\Watch-CodexRtl.ps1')    (Join-Path $script:BinDir 'Watch-CodexRtl.ps1') -Force
    Write-RtlLog "Deployed watcher runtime to $($script:BinDir)"
    return (Join-Path $script:BinDir 'Watch-CodexRtl.ps1')
}
