# codex-rtl-lib.ps1
# Shared logic for the Codex RTL patch: resolve the Codex install, build a patched
# copy via staging + atomic swap (Store/MSIX), or patch in place (direct install),
# manage the auto-update watcher, toast, logging and a single-instance lock.
#
# No elevation required: everything writes under the user profile.

$script:PatchVersion = '0.3.0'
$script:StateDir  = Join-Path $env:LOCALAPPDATA 'CodexRtlPatch'
$script:BinDir    = Join-Path $script:StateDir 'bin'
$script:StateFile = Join-Path $script:StateDir 'state.json'
$script:LogFile   = Join-Path $script:StateDir 'rtl.log'
$script:LockFile  = Join-Path $script:StateDir 'update.lock'
$script:TaskName  = 'CodexRtlPatchWatcher'
$script:CopyRoot  = Join-Path $env:LOCALAPPDATA 'OpenAI\CodexRtl'
$script:Staging   = Join-Path $env:LOCALAPPDATA 'OpenAI\CodexRtl.staging'
$script:OldRoot   = Join-Path $env:LOCALAPPDATA 'OpenAI\CodexRtl.old'
$script:ShortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex (RTL).lnk'
$script:LockStream = $null

# ----------------------------------------------------------------- logging / ui

function Write-RtlLog {
    param([string]$Message)
    $line = "$([DateTime]::Now.ToString('o'))  [$PID]  $Message"
    Write-Host $line
    try {
        if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null }
        if ((Test-Path $script:LogFile) -and (Get-Item $script:LogFile).Length -gt 1MB) { Move-Item $script:LogFile "$($script:LogFile).old" -Force }
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    } catch {}
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

# ----------------------------------------------------------------- state

function Read-RtlState {
    if (-not (Test-Path $script:StateFile)) { return $null }
    try { return (Get-Content $script:StateFile -Raw | ConvertFrom-Json) } catch { return $null }
}

function Write-RtlState {
    param([hashtable]$State)
    if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null }
    [System.IO.File]::WriteAllText($script:StateFile, (([pscustomobject]$State) | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
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
    # Fall back to a direct (non-Store) install.
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

function Test-CodexRtlRunning {
    # Is the patched copy (CodexRtl) currently running? Match the exact folder so
    # CodexRtl.staging / CodexRtl.old never count as the live copy.
    $prefix = $script:CopyRoot.TrimEnd('\') + '\'
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    }
    return [bool]$procs
}

function Invoke-Robocopy {
    param([string]$From, [string]$To)
    $a = @("`"$From`"", "`"$To`"", '/MIR', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    $p = Start-Process robocopy -ArgumentList $a -Wait -PassThru -NoNewWindow
    return $p.ExitCode
}

function Invoke-AsarInject {
    param([string]$AsarPath, [string]$PatchJs, [switch]$NoBak)
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $node) { throw 'Node.js not found on PATH.' }
    $editor = Get-AsarEditPath
    if (-not $editor) { throw 'asar-edit.mjs not found.' }
    $bak = if ($NoBak) { '--no-bak' } else { '' }
    if ($bak) { $out = (& $node $editor $AsarPath $PatchJs $bak) | Out-String }
    else      { $out = (& $node $editor $AsarPath $PatchJs)      | Out-String }
    if ($LASTEXITCODE -ne 0) { throw "asar-edit failed ($LASTEXITCODE): $($out.Trim())" }
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
    $exe = Join-Path $script:CopyRoot 'app\Codex.exe'
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($script:ShortcutPath)
    $sc.TargetPath = $exe; $sc.WorkingDirectory = (Join-Path $script:CopyRoot 'app'); $sc.IconLocation = "$exe,0"
    $sc.Save()
}

# ----------------------------------------------------------------- core update

function Invoke-CodexRtlUpdate {
    param([switch]$Force, [switch]$Auto)
    if (-not (Enter-RtlLock)) { Write-RtlLog 'Another update is in progress; skipping.'; return }
    try {
        $src = Resolve-CodexSource
        if (-not $src) { Write-RtlLog 'No Codex install found.'; if (-not $Auto) { throw 'Codex not found (install it from the Microsoft Store).' }; return }
        $state = Read-RtlState
        $patchJs = Get-PatchJsPath
        if (-not $patchJs) { throw 'codex-rtl-patch.js not found.' }

        $current = if ($state) { $state.sourceSignature } else { $null }
        if (-not $Force -and $current -eq $src.Signature -and (
                ($src.Type -eq 'Store'  -and (Test-Path (Join-Path $script:CopyRoot 'app\Codex.exe'))) -or
                ($src.Type -eq 'Direct'))) {
            Write-RtlLog "Up to date (Codex v$($src.Version))."
            return
        }
        Write-RtlLog "Update needed: Codex v$($src.Version) [$($src.Type)] (was '$current')"

        if ($src.Type -eq 'Direct' -and $src.Writable) {
            Write-RtlLog 'Patching direct (non-Store) install in place...'
            Invoke-AsarInject -AsarPath $src.AsarPath -PatchJs $patchJs
            Write-RtlState @{ patchVersion = $script:PatchVersion; mode = 'inplace'; sourceSignature = $src.Signature; version = $src.Version; asarPath = $src.AsarPath; updatedAt = (Get-Date).ToString('o') }
            if ($Auto) { Show-RtlToast 'Codex RTL' "Patched Codex v$($src.Version)." }
            return
        }

        # ---- Store / copy mode: build to staging, then atomic-swap when closed ----
        $stagingSig = Join-Path $script:Staging '.codexrtl-sig'
        $stagingReady = (Test-Path (Join-Path $script:Staging 'app\Codex.exe')) -and
                        (Test-Path $stagingSig) -and ((Get-Content $stagingSig -Raw).Trim() -eq $src.Signature)
        if (-not $stagingReady) {
            Write-RtlLog 'Building patched copy in staging...'
            if (Test-Path $script:Staging) { Remove-Item -LiteralPath $script:Staging -Recurse -Force }
            $stagingApp = Join-Path $script:Staging 'app'
            New-Item -ItemType Directory -Force -Path $stagingApp | Out-Null
            $rc = Invoke-Robocopy -From $src.AppDir -To $stagingApp
            if ($rc -ge 16) { throw "robocopy failed (exit $rc)" }
            Invoke-AsarInject -AsarPath (Join-Path $stagingApp 'resources\app.asar') -PatchJs $patchJs
            Set-Content -LiteralPath $stagingSig -Value $src.Signature -Encoding UTF8 -NoNewline
            Write-RtlLog 'Staging build complete.'
        } else {
            Write-RtlLog 'Staging already built for this version; attempting swap.'
        }

        if (Test-CodexRtlRunning) {
            Write-RtlLog 'Codex (RTL) is running; deferring swap (staging kept for next close).'
            if ($Auto) { Show-RtlToast 'Codex update ready' 'A newer Codex is staged. It will apply next time you close Codex.' }
            return
        }

        Write-RtlLog 'Swapping staging into place (atomic)...'
        Invoke-AtomicSwap
        New-RtlShortcut
        Write-RtlState @{ patchVersion = $script:PatchVersion; mode = 'copy'; sourceSignature = $src.Signature; version = $src.Version; target = $script:CopyRoot; updatedAt = (Get-Date).ToString('o') }
        Write-RtlLog "DONE: Codex (RTL) now at v$($src.Version)."
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

function Unregister-CodexRtlWatcher {
    try { Remove-ItemProperty -Path $script:RunKey -Name $script:RunName -ErrorAction Stop; Write-RtlLog 'Removed logon watcher.' }
    catch { Write-RtlLog 'No logon watcher to remove.' }
    # also remove any legacy scheduled task from earlier versions
    try { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop; Write-RtlLog 'Removed legacy scheduled task.' } catch {}
}

function Start-CodexRtlWatcher {
    param([string]$WatchScript)
    $ps = (Get-Command powershell.exe).Source
    Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $WatchScript, '-Loop')
    Write-RtlLog 'Started watcher for the current session.'
}

# ----------------------------------------------------------------- deploy

function Copy-RtlBin {
    # Copy the watcher's runtime files to a stable per-user location so the
    # scheduled task never depends on the repo path.
    param([string]$RepoRoot)
    New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    Copy-Item (Join-Path $RepoRoot 'scripts\lib\codex-rtl-lib.ps1') (Join-Path $script:BinDir 'codex-rtl-lib.ps1') -Force
    Copy-Item (Join-Path $RepoRoot 'scripts\lib\asar-edit.mjs')     (Join-Path $script:BinDir 'asar-edit.mjs')     -Force
    Copy-Item (Join-Path $RepoRoot 'src\codex-rtl-patch.js')        (Join-Path $script:BinDir 'codex-rtl-patch.js') -Force
    Copy-Item (Join-Path $RepoRoot 'scripts\Watch-CodexRtl.ps1')    (Join-Path $script:BinDir 'Watch-CodexRtl.ps1') -Force
    Write-RtlLog "Deployed watcher runtime to $($script:BinDir)"
    return (Join-Path $script:BinDir 'Watch-CodexRtl.ps1')
}
