# desktop-rtl-lib.ps1
# Shared logic for the RTL patch (Codex + OpenCode): resolve the app install, build a
# patched copy via staging + atomic swap, manage the auto-update watcher, logging,
# progress reporting and a single-instance lock.
#
# MULTI-APP: the engine is app-agnostic via profiles (Get-RtlProfile). Set-RtlActiveApp
# <id> rebinds every per-app $script: path global from the selected profile; the few
# genuinely app-specific functions read $script:ActiveProfile. Codex is the default and
# its load-time globals are reproduced exactly by Set-RtlActiveApp 'codex'.
#
# SAFETY INVARIANT: we NEVER modify the original app install. We only READ from it and
# build/maintain a SEPARATE copy under the profile's CopyRoot. Every asar edit happens
# inside the active profile's staging / copy only (enforced by Assert-RtlWriteAllowed).
#
# No elevation required: everything writes under the user profile.
# This file is ASCII-only; the Hebrew shortcut label is built from code points so it
# is safe regardless of how Windows PowerShell 5.1 decodes the file.

$script:PatchVersion  = '2.0.0'
$script:SchemaVersion = 2
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
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Desktop RTL Patch').Show($toast)
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
        payloadSha256   = $State.payloadSha256
        asarSha256      = $State.asarSha256
        verifiedAt      = $(if ($State.payloadSha256) { $now } else { $null })
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

# ----------------------------------------------------------------- profiles

# App PROFILES describe how to patch a given app, so one engine can serve several.
# Codex is the built-in copy-only, no-admin profile (unchanged behavior). Additional
# profiles (e.g. a future in-place profile for another app) plug in here without touching the engine.
# For copy-mode profiles every in-place field is $null, so the copy code path can never
# reach an in-place operation. Paths currently mirror the module-level $script: vars.
function Get-RtlProfile {
    param([string]$AppId = 'codex')
    switch ($AppId) {
        'codex' {
            return [pscustomobject]@{
                Id                = 'codex'
                DisplayName       = 'Codex'
                ShortcutLabel     = 'Codex (RTL)'
                ShortcutDesc      = 'Codex with Hebrew / RTL support'
                Mode              = 'copy'         # 'copy' | 'inplace'
                RequiresElevation = $false
                AppxName          = 'OpenAI.Codex'
                SourceRoots       = @()            # codex uses its own recursive resolver
                StateDir          = (Join-Path $env:LOCALAPPDATA 'CodexRtlPatch')
                CopyRoot          = (Join-Path $env:LOCALAPPDATA 'OpenAI\CodexRtl')
                Staging           = (Join-Path $env:LOCALAPPDATA 'OpenAI\CodexRtl.staging')
                OldRoot           = (Join-Path $env:LOCALAPPDATA 'OpenAI\CodexRtl.old')
                TargetDir         = $null          # in-place target (original app dir); copy mode never has one
                AppSubdir         = 'app'          # tree lives under <root>\app
                # v26.715+ ("owl" runtime rebrand): the manifest entry exe is ChatGPT.exe;
                # Codex.exe still ships as a small shim. Running-detection matches both names.
                ExeLeaf           = 'ChatGPT.exe'
                ExeRelPath        = 'app\ChatGPT.exe'
                AsarRelPath       = 'app\resources\app.asar'
                ProcessName       = @('ChatGPT', 'Codex')
                NodeStrategy      = 'bundled'      # cua_node next to the asar
                NodeRelPath       = 'app\resources\cua_node\bin\node.exe'
                WatcherRunName    = 'CodexRtlPatchWatcher'
                RemoveFromCopy    = @()            # files to strip from the copy during staging
                AssertFuseOff     = $true          # read-only asar-integrity fuse guard
                FuseScanRelPath   = 'app\chrome.dll'   # owl runtime: the fuse wire lives in chrome.dll, not the exe
                # owl runtime keeps a full Chromium profile here; Code Cache must be cleared
                # after re-injects or V8 serves the stale pre-patch bundle.
                UserDataDir       = (Join-Path $env:APPDATA 'Codex\web\Codex\Default')
                RendererPayloads  = @('desktop-rtl-patch.js')
                MainProcessSpec   = $null
                ServicesToHalt    = @()
                TakeOwnershipDirs = @()
                ExeHashPatch      = $null
                CodeSign          = $null
                UpdateHelper      = $null
            }
        }
        'opencode' {
            $base = Join-Path $env:LOCALAPPDATA 'RtlPatch\opencode'
            return [pscustomobject]@{
                Id                = 'opencode'
                DisplayName       = 'OpenCode'
                ShortcutLabel     = 'OpenCode (RTL)'
                ShortcutDesc      = 'OpenCode with Hebrew / RTL support'
                Mode              = 'copy'
                RequiresElevation = $false
                AppxName          = $null          # NSIS per-user, no Store/Appx
                # VERIFIED root name is @opencode-aidesktop; keep the guessed names as fallbacks.
                SourceRoots       = @(
                    (Join-Path $env:LOCALAPPDATA 'Programs\@opencode-aidesktop'),
                    (Join-Path $env:LOCALAPPDATA 'Programs\opencode-desktop'),
                    (Join-Path $env:LOCALAPPDATA 'Programs\OpenCode'),
                    (Join-Path ${env:ProgramFiles} 'opencode-desktop'),
                    (Join-Path ${env:ProgramFiles} 'OpenCode')
                )
                StateDir          = $base
                CopyRoot          = (Join-Path $base 'copy')
                Staging           = (Join-Path $base 'copy.staging')
                OldRoot           = (Join-Path $base 'copy.old')
                TargetDir         = $null
                AppSubdir         = ''              # tree lives at the copy root (no app\ subdir)
                ExeLeaf           = 'OpenCode.exe'
                ExeRelPath        = 'OpenCode.exe'
                AsarRelPath       = 'resources\app.asar'
                ProcessName       = @('OpenCode')
                NodeStrategy      = 'electron-as-node'   # run the copied exe with ELECTRON_RUN_AS_NODE=1
                NodeRelPath       = $null
                WatcherRunName    = 'OpenCodeRtlPatchWatcher'
                RemoveFromCopy    = @('resources\app-update.yml')   # neutralize electron-updater in the copy
                AssertFuseOff     = $true
                FuseScanRelPath   = $null           # fuse wire is in the exe itself; default to ExeRelPath
                UserDataDir       = (Join-Path $env:APPDATA '@opencode-aidesktop')
                RendererPayloads  = @('desktop-rtl-patch.js')
                MainProcessSpec   = $null
                ServicesToHalt    = @()
                TakeOwnershipDirs = @()
                ExeHashPatch      = $null
                CodeSign          = $null
                UpdateHelper      = $null
            }
        }
        default { throw "[PROFILE] Unknown app id: $AppId" }
    }
}

# The active app for this process. Engine functions that are app-specific read this.
# Defaults to codex; entry scripts call Set-RtlActiveApp to switch.
$script:ActiveProfile = Get-RtlProfile 'codex'

# Point every per-app $script: path global at the selected profile. One choke point
# so the whole engine (staging, swap, watcher, config, state, shortcuts) operates on
# the chosen app without threading a profile through every function. Calling it with
# 'codex' reproduces the module's load-time values exactly (no behavior change).
function Set-RtlActiveApp {
    param([string]$AppId = 'codex')
    $p = Get-RtlProfile $AppId
    $script:ActiveProfile = $p
    $script:StateDir  = $p.StateDir
    $script:BinDir    = Join-Path $p.StateDir 'bin'
    $script:LogsDir   = Join-Path $p.StateDir 'logs'
    $script:StateFile = Join-Path $p.StateDir 'state.json'
    $script:LogFile   = Join-Path $p.StateDir 'rtl.log'
    $script:LockFile  = Join-Path $p.StateDir 'update.lock'
    $script:CopyRoot  = $p.CopyRoot
    $script:Staging   = $p.Staging
    $script:OldRoot   = $p.OldRoot
    $script:TaskName  = $p.WatcherRunName
    $script:RunName   = $p.WatcherRunName
    $script:ConfigFile          = Join-Path $p.StateDir 'config.json'
    $script:ConfigAppliedMarker = Join-Path $p.StateDir 'config-applied.sha'
    $script:PendingSelfUpdate   = Join-Path $p.StateDir 'pending-selfupdate'
    # Shortcuts
    $script:ShortcutLabel   = $p.ShortcutLabel
    $script:ShortcutStart   = Join-Path ([Environment]::GetFolderPath('Programs')) ($p.ShortcutLabel + '.lnk')
    $script:ShortcutDesktop = Join-Path ([Environment]::GetFolderPath('Desktop'))  ($p.ShortcutLabel + '.lnk')
    $script:ShortcutPath    = $script:ShortcutStart
    $script:LegacyShortcuts = if ($AppId -eq 'codex') {
        @(
            (Join-Path ([Environment]::GetFolderPath('Programs')) ($script:_ivrit + '.lnk')),
            (Join-Path ([Environment]::GetFolderPath('Desktop'))  ($script:_ivrit + '.lnk'))
        )
    } else { @() }
    $script:ShortcutPaths = @($script:ShortcutStart, $script:ShortcutDesktop) + $script:LegacyShortcuts
    # electron-as-node profiles run the copied app exe as Node for asar editing:
    #   ELECTRON_RUN_AS_NODE=1  makes the Electron exe behave as plain Node.
    #   ELECTRON_NO_ASAR=1      stops Electron's fs shim from treating any ".asar" path
    #                           as an archive to read FROM (without it, readFileSync on
    #                           app.asar fails with "'' not found in ...app.asar").
    # Both are Electron-specific and ignored by a plain node, so they are safe to set
    # process-wide here (this process only ever invokes the exe as a Node editor).
    if ($p.NodeStrategy -eq 'electron-as-node') {
        $env:ELECTRON_RUN_AS_NODE = '1'
        $env:ELECTRON_NO_ASAR = '1'
    } else {
        if ($env:ELECTRON_RUN_AS_NODE) { Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue }
        if ($env:ELECTRON_NO_ASAR)     { Remove-Item Env:\ELECTRON_NO_ASAR -ErrorAction SilentlyContinue }
    }
    Write-RtlLog "Active app: $($p.DisplayName) (state=$($p.StateDir))"
}

# Join a base with an app-tree-relative path, treating an empty AppSubdir as the base
# itself (opencode has no app\ subdir; codex does).
function Join-RtlTree {
    param([string]$Base, [string]$Rel)
    if ([string]::IsNullOrEmpty($Rel)) { return $Base }
    return (Join-Path $Base $Rel)
}

# Per-app locations for the current active profile.
function Get-RtlPaths {
    param($Profile = $script:ActiveProfile)
    return [pscustomobject]@{
        StateDir  = $script:StateDir
        BinDir    = $script:BinDir
        LogsDir   = $script:LogsDir
        StateFile = $script:StateFile
        LockFile  = $script:LockFile
        CopyRoot  = $Profile.CopyRoot
        Staging   = $Profile.Staging
        OldRoot   = $Profile.OldRoot
        TargetDir = $Profile.TargetDir
    }
}

function Test-RtlElevated {
    try { return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    catch { return $false }
}

# The generalized safety guard. A COPY-mode profile may only ever write inside its
# CopyRoot / Staging - the original app dir is never in the allowed set, so a copy
# profile cannot touch the original by construction. An IN-PLACE profile additionally
# allows its TargetDir, but ONLY when it is elevation-required AND actually elevated
# AND the caller passed an explicit -InPlaceOptIn (set only by the deliberate in-place
# pipeline). Every engine write path calls this before touching a file.
function Assert-RtlWriteAllowed {
    param([Parameter(Mandatory)]$Profile, [Parameter(Mandatory)][string]$Path, [switch]$InPlaceOptIn)
    $full = [System.IO.Path]::GetFullPath($Path)
    $allowed = @(
        ([System.IO.Path]::GetFullPath($Profile.CopyRoot).TrimEnd('\') + '\'),
        ([System.IO.Path]::GetFullPath($Profile.Staging).TrimEnd('\') + '\')
    )
    if ($Profile.Mode -eq 'inplace' -and $Profile.RequiresElevation -and $InPlaceOptIn -and (Test-RtlElevated) -and $Profile.TargetDir) {
        $allowed += ([System.IO.Path]::GetFullPath($Profile.TargetDir).TrimEnd('\') + '\')
    }
    foreach ($a in $allowed) {
        if ($full.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    throw "[SAFETY] Refusing to edit a file outside the allowed RTL roots: $full"
}

# ----------------------------------------------------------------- config

# User-tunable settings, read by the renderer payload at runtime via a generated
# desktop-rtl-config.js asset (so most changes need no asar rebuild). Lives next to
# the state; UTF-8 no BOM like state.json.
$script:ConfigFile          = Join-Path $script:StateDir 'config.json'
$script:ConfigSchemaVersion = 1
# Records the hash of config.json that is currently baked into the copy's asar, so
# we only re-apply the config asset when settings actually changed (and only while
# Codex (RTL) is closed - the asar is locked while it runs).
$script:ConfigAppliedMarker = Join-Path $script:StateDir 'config-applied.sha'

# Default settings for one app's RTL surfaces (same shape for every app).
function Get-RtlDefaultAppConfig {
    return [ordered]@{
        enabled   = $true
        direction = [ordered]@{ policy = 'anyHebrew' }   # anyHebrew | firstStrong
        surfaces  = [ordered]@{ prose = $true; inputs = $true; tables = $true; math = $true; codeIsolation = $true }
        font      = [ordered]@{ override = $false; family = ''; sizePercent = 100 }
    }
}

function Get-RtlDefaultConfig {
    return [ordered]@{
        schemaVersion       = $script:ConfigSchemaVersion
        autoPatch           = $true
        checkForToolUpdates = $true
        apps = [ordered]@{
            codex    = Get-RtlDefaultAppConfig
            opencode = Get-RtlDefaultAppConfig
        }
    }
}

# Read config, deep-merged over defaults (missing keys get defaults), validated. The
# per-app block has the same shape for every app, so merge/validate in a loop.
function Read-RtlConfig {
    $cfg = Get-RtlDefaultConfig
    if (Test-Path $script:ConfigFile) {
        try {
            $j = (Get-Content $script:ConfigFile -Raw) | ConvertFrom-Json
            if ($null -ne $j.autoPatch)           { $cfg.autoPatch = [bool]$j.autoPatch }
            if ($null -ne $j.checkForToolUpdates) { $cfg.checkForToolUpdates = [bool]$j.checkForToolUpdates }
            foreach ($appId in @($cfg.apps.Keys)) {
                $c = if ($j.apps) { $j.apps.$appId } else { $null }
                if (-not $c) { continue }
                $a = $cfg.apps.$appId
                if ($null -ne $c.enabled) { $a.enabled = [bool]$c.enabled }
                if ($c.direction -and $c.direction.policy) { $a.direction.policy = [string]$c.direction.policy }
                if ($c.surfaces) {
                    foreach ($k in @('prose', 'inputs', 'tables', 'math', 'codeIsolation')) {
                        if ($null -ne $c.surfaces.$k) { $a.surfaces.$k = [bool]$c.surfaces.$k }
                    }
                }
                if ($c.font) {
                    if ($null -ne $c.font.override)    { $a.font.override = [bool]$c.font.override }
                    if ($null -ne $c.font.family)      { $a.font.family = [string]$c.font.family }
                    if ($null -ne $c.font.sizePercent) { $a.font.sizePercent = [int]$c.font.sizePercent }
                }
            }
        } catch { Write-RtlLog "config read failed, using defaults: $($_.Exception.Message)" }
    }
    foreach ($appId in @($cfg.apps.Keys)) {
        $a = $cfg.apps.$appId
        if ($a.direction.policy -notin @('anyHebrew', 'firstStrong')) { $a.direction.policy = 'anyHebrew' }
        $sp = [int]$a.font.sizePercent
        if ($sp -lt 80) { $sp = 80 } elseif ($sp -gt 150) { $sp = 150 }
        $a.font.sizePercent = $sp
    }
    return $cfg
}

function Write-RtlConfig {
    param($Config)
    if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null }
    $json = ([pscustomobject]$Config) | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($script:ConfigFile, $json, (New-Object System.Text.UTF8Encoding $false))
    Write-RtlLog "Config written: $($script:ConfigFile)"
}

# Generate the desktop-rtl-config.js asset that sets window.__codexRtlConfig to the
# per-app settings slice (only the app object; host-side flags stay host-side).
# Returns a temp file path the caller injects and then deletes.
function Build-RtlConfigAsset {
    param([string]$AppId = 'codex', $Config)
    if (-not $Config) { $Config = Read-RtlConfig }
    $appCfg = $Config.apps.$AppId
    $json = ([pscustomobject]$appCfg) | ConvertTo-Json -Depth 6 -Compress
    $js = 'window.__codexRtlConfig = ' + $json + ';'
    $tmp = Join-Path $env:TEMP ('desktop-rtl-config-' + [Guid]::NewGuid().ToString('N') + '.js')
    [System.IO.File]::WriteAllText($tmp, $js, (New-Object System.Text.UTF8Encoding $false))
    return $tmp
}

# ----------------------------------------------------------------- helpers

function Get-PatchJsPath {
    # Prefer a copy deployed next to this lib (the installed watcher); fall back to the repo.
    $here = $PSScriptRoot
    foreach ($p in @((Join-Path $here 'desktop-rtl-patch.js'), (Join-Path $here '..\..\src\desktop-rtl-patch.js'))) {
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    return $null
}

function Get-AsarEditPath {
    $p = Join-Path $PSScriptRoot 'asar-edit.mjs'
    if (Test-Path $p) { return (Resolve-Path $p).Path }
    return $null
}

# The Node runtime used to edit the asar, with no external Node.js prerequisite:
#   - 'bundled'          : Codex ships node at <app>\resources\cua_node\bin\node.exe
#   - 'electron-as-node' : OpenCode has no bundled node, but the app's own Electron
#                          exe runs as Node when ELECTRON_RUN_AS_NODE=1 (set process-
#                          wide by Set-RtlActiveApp). The exe sits at the tree root,
#                          one level up from <root>\resources\app.asar.
function Resolve-RtlNode {
    param([string]$AsarPath, $Profile = $script:ActiveProfile)
    if ($Profile -and $Profile.NodeStrategy -eq 'electron-as-node') {
        $root = Split-Path -Parent (Split-Path -Parent $AsarPath)   # ...\resources\app.asar -> root
        $exe = Join-Path $root $Profile.ExeLeaf
        if (Test-Path $exe) { return $exe }
        return $null
    }
    $resources = Split-Path -Parent $AsarPath
    $node = Join-Path $resources 'cua_node\bin\node.exe'
    if (Test-Path $node) { return $node }
    return $null
}

# Run the resolved Node with args and return @{ Out=<combined stdout+stderr>; Exit }.
# A bundled console node (Codex's cua_node) would work with the call operator, but an
# Electron GUI-subsystem exe (OpenCode, run as Node) does NOT propagate stdout or the
# exit code synchronously through "& exe ..." - output arrives late and $LASTEXITCODE
# is empty. Start-Process -Wait with redirected output handles both uniformly.
function Invoke-RtlNodeCli {
    param([string]$Node, [string[]]$Arguments)
    $outF = [System.IO.Path]::GetTempFileName()
    $errF = [System.IO.Path]::GetTempFileName()
    try {
        # Pre-quote args with spaces (dev repo path has spaces; deployed bin does not).
        $quoted = $Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
        $pr = Start-Process -FilePath $Node -ArgumentList $quoted -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outF -RedirectStandardError $errF
        $out = [string](Get-Content -LiteralPath $outF -Raw -ErrorAction SilentlyContinue)
        $err = [string](Get-Content -LiteralPath $errF -Raw -ErrorAction SilentlyContinue)
        return @{ Out = ($out + $err).Trim(); Exit = $pr.ExitCode }
    } finally {
        Remove-Item -LiteralPath $outF, $errF -Force -ErrorAction SilentlyContinue
    }
}

# Read-only guard: confirm the copied Electron exe does NOT have the embedded
# asar-integrity fuse enabled. We never modify the exe, so an enabled fuse would make
# the injected asar fail validation at runtime. Runs asar-edit.mjs 'fusestate' via the
# app's own exe (as Node). exit 0 = fuse off / not wired (ok); 20 = fuse ON (blocked).
function Assert-RtlAsarFuseOff {
    # Node = a runnable Node (bundled node, or the exe itself for electron-as-node);
    # ScanPath = the binary holding the fuse wire (the exe, or chrome.dll for owl).
    param([string]$Node, [string]$ScanPath)
    if (-not $Node) { throw "[FUSE] no Node runtime available for the fuse check." }
    if (-not (Test-Path $ScanPath)) { throw "[FUSE] fuse-scan target not found: $ScanPath" }
    $editor = Get-AsarEditPath
    if (-not $editor) { throw 'asar-edit.mjs not found.' }
    $r = Invoke-RtlNodeCli -Node $Node -Arguments @($editor, 'fusestate', $ScanPath)
    $out = $r.Out; $code = $r.Exit
    Write-RtlLog "fusestate: $out (exit $code)"
    if ($code -eq 20) {
        throw "[FUSE] $($script:ActiveProfile.DisplayName) ships with the asar-integrity fuse ENABLED in this build; the copy-only method cannot patch it. Please report this so we can add fuse handling."
    }
    if ($code -ne 0) { Write-RtlLog "fusestate inconclusive (exit $code); proceeding on the assumption the fuse is off." }
}

# Delete only the regeneratable Electron caches (V8 Code Cache, GPU cache) under the
# app's shared userData dir, so a re-injected renderer is not shadowed by the old
# cached bundle. Never touches Local/Session Storage, IndexedDB or cookies (the login
# lives there). Skips entirely when either the copy or the original is running.
function Clear-RtlRendererCache {
    param($Profile = $script:ActiveProfile)
    if (-not $Profile.UserDataDir) { return }
    if ((Test-CodexRtlRunning) -or (Test-OriginalCodexRunning)) { Write-RtlLog 'Skipping renderer cache clear; the app is running.'; return }
    foreach ($sub in @('Code Cache', 'GPUCache')) {
        $dir = Join-Path $Profile.UserDataDir $sub
        if (Test-Path $dir) {
            try { Remove-Item -LiteralPath $dir -Recurse -Force; Write-RtlLog "Cleared renderer cache: $sub" }
            catch { Write-RtlLog "renderer cache clear failed ($sub): $($_.Exception.Message)" }
        }
    }
}

# Launch the ACTIVE app's patched copy as a normal GUI app. Critical for
# electron-as-node profiles: Set-RtlActiveApp sets ELECTRON_RUN_AS_NODE /
# ELECTRON_NO_ASAR process-wide (for the asar editor), and a child inherits them,
# which would start the app as a headless Node process that exits immediately.
# Strip them for the launch, then restore.
function Start-RtlCopyApp {
    $exe = Join-Path $script:CopyRoot $script:ActiveProfile.ExeRelPath
    if (-not (Test-Path $exe)) { return $false }
    $saveRun = $env:ELECTRON_RUN_AS_NODE; $saveAsar = $env:ELECTRON_NO_ASAR
    Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    Remove-Item Env:ELECTRON_NO_ASAR -ErrorAction SilentlyContinue
    try { Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe -Parent) }
    finally {
        if ($saveRun)  { $env:ELECTRON_RUN_AS_NODE = $saveRun }
        if ($saveAsar) { $env:ELECTRON_NO_ASAR = $saveAsar }
    }
    return $true
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

# Locate an OpenCode (NSIS, per-user) install. No Store/Appx; the exe and asar sit
# under one of the profile's SourceRoots. AppDir is the whole install tree (we copy
# it wholesale, including resources\app.asar.unpacked native modules). Signature is
# the asar size+mtime (electron-updater overwrites app.asar in place on update).
function Resolve-OpenCodeSource {
    param($Profile = $script:ActiveProfile)
    $roots = @($Profile.SourceRoots) | Where-Object { $_ -and (Test-Path $_) }
    foreach ($r in $roots) {
        $asar = Join-Path $r $Profile.AsarRelPath
        if (-not (Test-Path $asar)) { continue }
        $exe = Join-Path $r $Profile.ExeLeaf
        $ver = $null
        if (Test-Path $exe) { try { $ver = (Get-Item $exe).VersionInfo.ProductVersion } catch {} }
        $asarItem = Get-Item $asar
        if (-not $ver) { $ver = $asarItem.LastWriteTimeUtc.ToString('yyyyMMddHHmmss') }
        return [pscustomobject]@{
            Type = 'Direct'; Version = [string]$ver
            Signature = "opencode:$($asarItem.Length)-$($asarItem.LastWriteTimeUtc.Ticks)"
            AppDir = $r; AsarPath = $asar; Writable = $true
        }
    }
    return $null
}

# Resolve the source for the ACTIVE app (dispatches to the app-specific resolver).
function Resolve-RtlSource {
    param($Profile = $script:ActiveProfile)
    if ($Profile.Id -eq 'opencode') { return Resolve-OpenCodeSource -Profile $Profile }
    return Resolve-CodexSource
}

# Validate that a resolved source has the layout we expect. Throws coded errors so
# the installer fails safely instead of proceeding on wrong assumptions.
function Test-CodexSource {
    param([Parameter(Mandatory)]$Source, $Profile = $script:ActiveProfile)
    $name = $Profile.DisplayName
    if (-not $Source)                      { throw "[NOCODEX] No $name source found." }
    if (-not (Test-Path $Source.AppDir))   { throw "[LAYOUT] $name app folder missing: $($Source.AppDir)" }
    if (-not (Test-Path $Source.AsarPath)) { throw "[LAYOUT] $name app.asar missing: $($Source.AsarPath)" }
    try {
        $fs = [System.IO.File]::OpenRead($Source.AsarPath)
        try { $hdr = New-Object byte[] 4; [void]$fs.Read($hdr, 0, 4) } finally { $fs.Dispose() }
        if ([System.BitConverter]::ToUInt32($hdr, 0) -ne 4) { throw 'unexpected asar header' }
    } catch { throw "[LAYOUT] $name app.asar is not a readable asar: $($_.Exception.Message)" }
    if (-not (Resolve-RtlNode -AsarPath $Source.AsarPath -Profile $Profile)) {
        $where = if ($Profile.NodeStrategy -eq 'electron-as-node') { "$($Profile.ExeLeaf) (run as Node)" } else { 'resources\cua_node\bin\node.exe' }
        throw "[NODE] $name Node runtime ($where) was not found; the app may be incompletely installed or its layout changed."
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

# Is the ORIGINAL (non-RTL) app running? Detected by exe path NOT under our copy, so
# the original being open is never mistaken for the RTL copy. This matters most for
# OpenCode, where the original and the copy share the same process name (OpenCode);
# the path filter (not the name) is what keeps them distinct.
function Test-OriginalCodexRunning {
    $procNames = @($script:ActiveProfile.ProcessName)
    $prefix = $script:CopyRoot.TrimEnd('\') + '\'
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and ($procNames -contains $_.Name) -and -not $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    }
    return [bool]$procs
}

# Verify the installer package is complete (catches "user extracted only the .cmd",
# or a partial ZIP). Throws [PACKAGE] listing what is missing.
function Test-RtlPackage {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $required = @(
        'scripts\lib\desktop-rtl-lib.ps1',
        'scripts\lib\asar-edit.mjs',
        'src\desktop-rtl-patch.js',
        'scripts\Watch-DesktopRtl.ps1'
    )
    $missing = @()
    foreach ($rel in $required) { if (-not (Test-Path (Join-Path $RepoRoot $rel))) { $missing += $rel } }
    if ($missing.Count) { throw "[PACKAGE] Installer package is incomplete; missing: $($missing -join ', ')" }
    return $true
}

function Assert-RtlDiskSpace {
    # Worst-case preflight before building: we need room for a full staging copy
    # (~source size) plus a safety buffer. The atomic swap renames within the same
    # volume, so it needs no extra space. Logs the numbers; throws [DISK] if short.
    param([Parameter(Mandatory)][string]$SourceDir)
    $drive = Split-Path -Qualifier $script:Staging
    $need = $null; $free = $null
    try { $need = (Get-ChildItem -LiteralPath $SourceDir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } catch {}
    try { $free = [double](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'" -ErrorAction Stop).FreeSpace } catch {}
    if (-not $need -or -not $free) { Write-RtlLog 'Disk check skipped (could not measure size/free space).'; return }
    $required = ($need * 1.1) + 1GB
    Write-RtlLog ("Disk check: drive={0} free={1:N1}GB source={2:N1}GB required={3:N1}GB" -f $drive, ($free / 1GB), ($need / 1GB), ($required / 1GB))
    if ($free -lt $required) {
        throw ("[DISK] Not enough free space on {0}: about {1:N1} GB needed, {2:N1} GB free. Free up space and try again." -f $drive, ($required / 1GB), ($free / 1GB))
    }
}

function Invoke-Robocopy {
    param([string]$From, [string]$To)
    $a = @("`"$From`"", "`"$To`"", '/MIR', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    $p = Start-Process robocopy -ArgumentList $a -Wait -PassThru -NoNewWindow
    return $p.ExitCode
}

function Invoke-AsarInject {
    param([string]$AsarPath, [string]$PatchJs, [string]$ConfigJs, [switch]$NoBak, [switch]$AllowExternalNodeFallback, $Profile)
    # SAFETY: only ever edit an asar the profile allows (copy mode: our copy/staging
    # only, never the original app). Defaults to the ACTIVE app profile.
    if (-not $Profile) { $Profile = $script:ActiveProfile }
    Assert-RtlWriteAllowed -Profile $Profile -Path $AsarPath | Out-Null
    # End users depend ONLY on the app's own bundled/embedded Node; PATH fallback is
    # dev/headless only.
    $node = Resolve-RtlNode -AsarPath $AsarPath -Profile $Profile
    if (-not $node -and $AllowExternalNodeFallback) {
        $node = (Get-Command node -ErrorAction SilentlyContinue).Source
        if ($node) { Write-RtlLog "WARNING: bundled Node missing; using external PATH Node ($node) via -AllowExternalNodeFallback (non-standard)." }
    }
    if (-not $node) { throw "[NODE] The app's Node runtime was not found next to the copied app; cannot edit the bundle." }
    $editor = Get-AsarEditPath
    if (-not $editor) { throw 'asar-edit.mjs not found.' }
    $editArgs = @('inject', $AsarPath, $PatchJs)
    if ($ConfigJs) { $editArgs += @('--config', $ConfigJs) }
    if ($NoBak)    { $editArgs += '--no-bak' }
    $r = Invoke-RtlNodeCli -Node $node -Arguments (@($editor) + $editArgs)
    if ($r.Exit -ne 0) { throw "[ASAR] asar-edit failed ($($r.Exit)): $($r.Out)" }
    Write-RtlLog "asar-edit: $($r.Out)"
}

# Rewrite ONLY the config asset in the live patched copy's asar (no full rebuild),
# to apply a settings change quickly. Caller must ensure Codex (RTL) is not running
# (an in-place asar write is not atomic); the GUI/tray falls back to a staged
# Invoke-CodexRtlUpdate -Force when the copy is open or on any error.
function Update-CodexRtlConfigAsset {
    param([string]$AppId = 'codex', [switch]$AllowExternalNodeFallback)
    $prof = Get-RtlProfile $AppId
    $liveAsar = Join-Path $prof.CopyRoot $prof.AsarRelPath
    if (-not (Test-Path $liveAsar)) { throw '[LAYOUT] Patched copy asar not found; install first.' }
    Assert-RtlWriteAllowed -Profile $prof -Path $liveAsar | Out-Null
    $node = Resolve-RtlNode -AsarPath $liveAsar
    if (-not $node -and $AllowExternalNodeFallback) { $node = (Get-Command node -ErrorAction SilentlyContinue).Source }
    if (-not $node) { throw '[NODE] bundled Node not found; cannot update config.' }
    $editor = Get-AsarEditPath
    if (-not $editor) { throw 'asar-edit.mjs not found.' }
    $cfgJs = Build-RtlConfigAsset -AppId $AppId
    try {
        $r = Invoke-RtlNodeCli -Node $node -Arguments @($editor, 'config', $liveAsar, $cfgJs, '--no-bak')
        if ($r.Exit -ne 0) { throw "[ASAR] config update failed ($($r.Exit)): $($r.Out)" }
        Write-RtlLog "config asset updated: $($r.Out)"
        Set-RtlConfigApplied
    } finally { Remove-Item -LiteralPath $cfgJs -Force -ErrorAction SilentlyContinue }
}

# Hash of the current settings file; used to detect when the baked config asset is
# stale relative to config.json.
function Get-RtlConfigHash {
    if (-not (Test-Path $script:ConfigFile)) { return '' }
    try { return (Get-FileHash -Path $script:ConfigFile -Algorithm SHA256).Hash } catch { return '' }
}
function Set-RtlConfigApplied {
    try {
        if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null }
        Set-Content -LiteralPath $script:ConfigAppliedMarker -Value (Get-RtlConfigHash) -Encoding ASCII -NoNewline
    } catch {}
}

# Apply config.json to the copy's config asset IF it changed since the last apply
# AND Codex (RTL) is closed (the asar is locked while it runs). Called on each update
# pass, so a settings change made while Codex (RTL) is open is applied automatically
# the next time it is closed. Returns $true if it applied.
function Sync-RtlConfigAsset {
    param([string]$AppId = 'codex', [switch]$AllowExternalNodeFallback)
    if (-not (Test-Path $script:ConfigFile)) { return $false }
    $prof = Get-RtlProfile $AppId
    $liveAsar = Join-Path $prof.CopyRoot $prof.AsarRelPath
    if (-not (Test-Path $liveAsar)) { return $false }
    $cur = Get-RtlConfigHash
    $applied = if (Test-Path $script:ConfigAppliedMarker) { (Get-Content $script:ConfigAppliedMarker -Raw).Trim() } else { '' }
    if ($cur -and $cur -eq $applied) { return $false }   # already up to date
    if (Test-CodexRtlRunning) { Write-RtlLog 'Config change pending; will apply when Codex (RTL) closes.'; return $false }
    Update-CodexRtlConfigAsset -AppId $AppId -AllowExternalNodeFallback:$AllowExternalNodeFallback
    Write-RtlLog 'Applied pending settings to the copy.'
    return $true
}

# Gracefully close (then force, if needed) the patched copy so the asar unlocks.
# Returns $true once nothing under CopyRoot is running.
function Stop-CodexRtlApp {
    param([int]$TimeoutSec = 12)
    $prefix = $script:CopyRoot.TrimEnd('\') + '\'
    $mine = { Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } }
    (& $mine) | ForEach-Object { try { [void]$_.CloseMainWindow() } catch {} }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Test-CodexRtlRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    if (Test-CodexRtlRunning) {
        (& $mine) | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {} }
        $deadline = (Get-Date).AddSeconds(6)
        while ((Test-CodexRtlRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    }
    return (-not (Test-CodexRtlRunning))
}

# Post-patch verification: re-open the (patched) asar and confirm the RTL payload
# entry and its <script> tag are really present and the header parses. Returns an
# object with payloadSha256 / asarSha256 / renderer; throws [VERIFY] on any problem.
function Test-RtlInjection {
    param([string]$AsarPath, [switch]$AllowExternalNodeFallback)
    $node = Resolve-RtlNode -AsarPath $AsarPath
    if (-not $node -and $AllowExternalNodeFallback) { $node = (Get-Command node -ErrorAction SilentlyContinue).Source }
    if (-not $node) { throw "[NODE] The app's Node runtime was not found next to the copied app; cannot verify the bundle." }
    $editor = Get-AsarEditPath
    if (-not $editor) { throw 'asar-edit.mjs not found.' }
    $r = Invoke-RtlNodeCli -Node $node -Arguments @($editor, 'verify', $AsarPath)
    $out = $r.Out
    if ($r.Exit -ne 0) { throw "[VERIFY] Post-patch verification failed ($($r.Exit)): $out" }
    $res = $null
    try { $res = $out | ConvertFrom-Json } catch { throw "[VERIFY] Verification output was not valid JSON: $out" }
    if (-not $res.ok) { throw "[VERIFY] Post-patch verification failed: $($res.reason)" }
    Write-RtlLog "verify: renderer=$($res.renderer) payloadSha256=$($res.payloadSha256) asarSha256=$($res.asarSha256)"
    return $res
}

function Invoke-AtomicSwap {
    # Replace CopyRoot with Staging via near-atomic directory renames. Caller must
    # have verified Codex (RTL) is not running.
    #   -ReseedStaging: instead of deleting the previous copy, relabel it as the new
    #   Staging so the NEXT update mirrors only deltas (warm baseline) rather than
    #   doing a full ~1.6GB copy. Uninstall clears the persistent staging.
    param([switch]$ReseedStaging)
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
    if (Test-Path $script:OldRoot) {
        if ($ReseedStaging) {
            # Keep the previous copy as the warm staging baseline for the next update.
            # If relabeling fails for any reason, fall back to deleting it (correctness
            # over speed): a missing staging just means the next build is a full copy.
            try { Rename-Item -LiteralPath $script:OldRoot -NewName (Split-Path $script:Staging -Leaf) -Force }
            catch { try { Remove-Item -LiteralPath $script:OldRoot -Recurse -Force } catch {} }
        } else {
            Remove-Item -LiteralPath $script:OldRoot -Recurse -Force
        }
    }
}

function New-RtlShortcut {
    # Differentiate from the regular app by NAME only ("<App> (RTL)"), keeping the
    # app's ORIGINAL icon (IconLocation points at the copy's exe, so Windows resolves
    # the icon itself - no extraction). Creates a Start-menu and a Desktop shortcut,
    # and removes any legacy-named shortcuts.
    $p    = $script:ActiveProfile
    $exe  = Join-Path $script:CopyRoot $p.ExeRelPath
    $work = Join-RtlTree $script:CopyRoot $p.AppSubdir
    $ws = New-Object -ComObject WScript.Shell
    foreach ($lnk in @($script:ShortcutStart, $script:ShortcutDesktop)) {
        try {
            $sc = $ws.CreateShortcut($lnk)
            $sc.TargetPath       = $exe
            $sc.WorkingDirectory = $work
            $sc.IconLocation     = "$exe,0"   # original app icon
            $sc.Description       = $p.ShortcutDesc
            $sc.Save()
        } catch {
            $m = $_.Exception.Message
            if ($lnk -eq $script:ShortcutDesktop -and ($m -match 'denied|access')) {
                Write-RtlLog "Desktop shortcut blocked (likely Controlled Folder Access); the Start-menu shortcut still works. $m"
            } else {
                Write-RtlLog "shortcut '$lnk' failed: $m"
            }
        }
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
        $src = Resolve-RtlSource
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
        $r.CopyExists = (Test-Path (Join-Path $script:CopyRoot $script:ActiveProfile.ExeRelPath))
        $r.RtlInstalled = ([bool]$state -and $r.CopyExists)
        $r.RtlRunning = Test-CodexRtlRunning
        $r.OriginalRunning = Test-OriginalCodexRunning
    } catch { Write-RtlLog "diagnose error: $($_.Exception.Message)" }
    foreach ($k in $r.Keys) { Write-RtlLog ("  {0} = {1}" -f $k, $r[$k]) }
    Write-RtlLog '=== Diagnose end ==='
    return [pscustomobject]$r
}

# Redact user-identifying paths and any token-shaped secrets from diagnostic text,
# so a shared bundle never leaks the username, profile path, or an auth token that
# happened to land in a log line.
function Get-RtlSanitizedText {
    param([string]$Text)
    if (-not $Text) { return $Text }
    $map = @(
        @{ v = $env:USERPROFILE;  t = '%USERPROFILE%' },
        @{ v = $env:LOCALAPPDATA; t = '%LOCALAPPDATA%' },
        @{ v = $env:USERNAME;     t = '%USERNAME%' }
    )
    foreach ($m in $map) {
        if ($m.v) { $Text = [regex]::Replace($Text, [regex]::Escape($m.v), $m.t, 'IgnoreCase') }
    }
    $Text = [regex]::Replace($Text, 'Bearer\s+[A-Za-z0-9._\-]+', 'Bearer [REDACTED]')
    $Text = [regex]::Replace($Text, 'eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{6,}', '[REDACTED-JWT]')
    $Text = [regex]::Replace($Text, '\b(?:sk|key|api)[-_][A-Za-z0-9]{16,}\b', '[REDACTED-KEY]')
    return $Text
}

# One-click support bundle: a single sanitized ZIP with our state, capped logs, a
# fresh diagnose snapshot, versions, environment, and a live injection report. It
# includes ONLY our own files (never Codex user data) and redacts paths/tokens.
function Export-CodexRtlDiagnostics {
    param([string]$OutDir)
    if (-not $OutDir) {
        foreach ($d in @(([Environment]::GetFolderPath('Desktop')), (Join-Path $env:USERPROFILE 'Downloads'), $env:TEMP)) {
            if ($d -and (Test-Path $d)) { $OutDir = $d; break }
        }
    }
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $work = Join-Path $env:TEMP ("CodexRtl-diag-" + $ts)
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $writeSan = {
        param($name, $text)
        [System.IO.File]::WriteAllText((Join-Path $work $name), (Get-RtlSanitizedText $text), (New-Object System.Text.UTF8Encoding $false))
    }
    try {
        # state.json (sanitized)
        if (Test-Path $script:StateFile) { & $writeSan 'state.json' (Get-Content $script:StateFile -Raw) }
        # diagnose snapshot
        try { $diag = Invoke-CodexRtlDiagnose; & $writeSan 'diagnose.json' ($diag | ConvertTo-Json -Depth 4) } catch { & $writeSan 'diagnose.error.txt' $_.Exception.Message }
        # versions + environment
        $nodeVer = $null
        try { $src = Resolve-RtlSource; if ($src) { $n = Resolve-RtlNode -AsarPath $src.AsarPath; if ($n) { $nodeVer = (Invoke-RtlNodeCli -Node $n -Arguments @('--version')).Out } } } catch {}
        $ver = @(
            "patchVersion  = $($script:PatchVersion)",
            "schemaVersion = $($script:SchemaVersion)",
            "os            = $([Environment]::OSVersion.VersionString)",
            "psVersion     = $($PSVersionTable.PSVersion)",
            "bundledNode   = $nodeVer"
        ) -join "`r`n"
        & $writeSan 'versions.txt' $ver
        $runKeyVal = $null; try { $runKeyVal = (Get-ItemProperty -Path $script:RunKey -Name $script:RunName -ErrorAction Stop).$($script:RunName) } catch {}
        $env = @(
            "runKeyPresent = $([bool]$runKeyVal)",
            "runKeyValue   = $runKeyVal",
            "copyExists    = $(Test-Path (Join-Path $script:CopyRoot $script:ActiveProfile.ExeRelPath))",
            "stagingExists = $(Test-Path $script:Staging)",
            "oldExists     = $(Test-Path $script:OldRoot)",
            "shortcutStart = $(Test-Path $script:ShortcutStart)",
            "shortcutDesk  = $(Test-Path $script:ShortcutDesktop)"
        ) -join "`r`n"
        & $writeSan 'environment.txt' $env
        # live injection report
        try {
            $liveAsar = Join-Path $script:CopyRoot $script:ActiveProfile.AsarRelPath
            if (Test-Path $liveAsar) { $inj = Test-RtlInjection -AsarPath $liveAsar -AllowExternalNodeFallback; & $writeSan 'injection.json' ($inj | ConvertTo-Json) }
        } catch { & $writeSan 'injection.error.txt' $_.Exception.Message }
        # capped logs (last ~10MB total, newest first)
        $logDst = Join-Path $work 'logs'; New-Item -ItemType Directory -Force -Path $logDst | Out-Null
        $budget = 10MB
        $logFiles = @()
        if (Test-Path $script:LogsDir) { $logFiles += Get-ChildItem $script:LogsDir -File -ErrorAction SilentlyContinue }
        foreach ($extra in @($script:LogFile, "$($script:LogFile).old")) { if (Test-Path $extra) { $logFiles += Get-Item $extra } }
        foreach ($f in ($logFiles | Sort-Object LastWriteTime -Descending)) {
            if ($budget -le 0) { break }
            try { & $writeSan (Join-Path 'logs' $f.Name) (Get-Content $f.FullName -Raw); $budget -= $f.Length } catch {}
        }
        $zip = Join-Path $OutDir ("CodexRtl-diagnostics-" + $ts + ".zip")
        if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
        Compress-Archive -Path (Join-Path $work '*') -DestinationPath $zip -Force
        Write-RtlLog "Diagnostics bundle written to $zip"
        return $zip
    } finally {
        try { Remove-Item -LiteralPath $work -Recurse -Force } catch {}
    }
}

# Read-only status for the GUI to frame the right action. States:
#   Fresh             no install, ready to install
#   Update            Codex itself updated; the RTL copy is behind
#   PatchUpgrade      our tool version changed; re-apply the patch
#   UpToDate          installed and current
#   Repair            a copy exists but its state record is missing/invalid
#   ReinstallRequired state written by a newer tool version
function Get-CodexRtlStatus {
    $src = $null; try { $src = Resolve-RtlSource } catch {}
    $copyOk = Test-Path (Join-Path $script:CopyRoot $script:ActiveProfile.ExeRelPath)
    $state = Read-RtlState
    # corrupt state file (exists but did not parse) -> back it up once.
    if (-not $state -and (Test-Path $script:StateFile)) {
        try {
            $raw = Get-Content $script:StateFile -Raw -ErrorAction Stop
            if ($raw -and $raw.Trim()) {
                Move-Item -LiteralPath $script:StateFile -Destination "$($script:StateFile).bad" -Force
                Write-RtlLog 'Corrupt state.json backed up to state.json.bad.'
            }
        } catch {}
    }
    $o = [ordered]@{
        State            = 'Fresh'
        CodexFound       = [bool]$src
        AvailableVersion = $(if ($src) { $src.Version } else { $null })
        InstalledVersion = $(if ($state) { $state.codexVersion } else { $null })
        CopyExists       = $copyOk
        Running          = (Test-CodexRtlRunning)
    }
    if ($state -and $state.schemaVersion -and ([int]$state.schemaVersion -gt $script:SchemaVersion)) { $o.State = 'ReinstallRequired' }
    elseif (-not $state) { $o.State = $(if ($copyOk) { 'Repair' } else { 'Fresh' }) }
    elseif (-not $copyOk) { $o.State = 'Repair' }
    elseif ($src -and $state.sourceSignature -ne $src.Signature) { $o.State = 'Update' }
    elseif ($state.patchVersion -ne $script:PatchVersion) { $o.State = 'PatchUpgrade' }
    else { $o.State = 'UpToDate' }
    return [pscustomobject]$o
}

# ----------------------------------------------------------------- core update

function Invoke-CodexRtlUpdate {
    param([switch]$Force, [switch]$Auto, [switch]$AllowExternalNodeFallback)
    if (-not (Enter-RtlLock)) { Write-RtlLog 'Another update is in progress; skipping.'; return }
    try {
        $p   = $script:ActiveProfile
        $app = $p.DisplayName
        $copyExe  = Join-Path $script:CopyRoot $p.ExeRelPath
        $liveAsar = Join-Path $script:CopyRoot $p.AsarRelPath
        Set-RtlStep 'preflight' 5
        # self-heal: recover from a crash mid-swap (CopyRoot gone, OldRoot present).
        if (-not (Test-Path $script:CopyRoot) -and (Test-Path $script:OldRoot)) {
            Write-RtlLog 'Self-heal: CopyRoot missing but OldRoot present; restoring previous copy.'
            try { Rename-Item -LiteralPath $script:OldRoot -NewName (Split-Path $script:CopyRoot -Leaf) -Force }
            catch { Write-RtlLog "self-heal failed: $($_.Exception.Message)" }
        }
        $src = Resolve-RtlSource
        if (-not $src) {
            Write-RtlLog "[NOCODEX] No $app install found."
            if (-not $Auto) { throw "[NOCODEX] $app not found (install it first)." }
            return
        }
        Test-CodexSource -Source $src | Out-Null   # throws [LAYOUT]/[NODE] on structural problems

        $state   = Read-RtlState
        $patchJs = Get-PatchJsPath
        if (-not $patchJs) { throw 'desktop-rtl-patch.js not found.' }

        $current = if ($state) { $state.sourceSignature } else { $null }
        if (-not $Force -and $current -eq $src.Signature -and (Test-Path $copyExe)) {
            Write-RtlLog "Up to date ($app v$($src.Version))."
            # Apply any settings change made while the RTL copy was open (now that a
            # pass is running and it may be closed).
            try { Sync-RtlConfigAsset -AppId $p.Id -AllowExternalNodeFallback:$AllowExternalNodeFallback | Out-Null } catch { Write-RtlLog "config sync error: $($_.Exception.Message)" }
            Set-RtlStep 'done' 100
            return
        }
        Write-RtlLog "Update needed: $app v$($src.Version) [$($src.Type)] (was '$current')"

        # ---- copy mode (always): build to staging, then atomic-swap when closed ----
        # Staging is PERSISTENT (a warm baseline): on a Codex update we robocopy /MIR
        # the pristine source over the existing staging tree, so unchanged files are
        # skipped and only real deltas (typically app.asar) copy - seconds, not minutes.
        # A .codexrtl-building sentinel marks a build in progress; if it survives a
        # crash, the tree is torn and we force a clean cold rebuild.
        $stagingApp   = Join-RtlTree $script:Staging $p.AppSubdir
        $stagingAsar  = Join-Path $stagingApp 'resources\app.asar'
        $stagingExe   = Join-Path $stagingApp $p.ExeLeaf
        $stagingSig   = Join-Path $script:Staging '.codexrtl-sig'
        $buildingFlag = Join-Path $script:Staging '.codexrtl-building'
        $stagingReady = (Test-Path $stagingExe) -and
                        (Test-Path $stagingSig) -and ((Get-Content $stagingSig -Raw).Trim() -eq $src.Signature) -and
                        (-not (Test-Path $buildingFlag))
        # A matching source signature is NOT enough: the staging may hold an older
        # PATCH (e.g. after a tool upgrade the reseeded baseline carries the previous
        # payload). Re-verify it; on any failure fall through to a rebuild.
        if ($stagingReady) {
            try { Test-RtlInjection -AsarPath $stagingAsar -AllowExternalNodeFallback:$AllowExternalNodeFallback | Out-Null }
            catch {
                Write-RtlLog "Staging matches the source version but failed verification ($($_.Exception.Message)); rebuilding it."
                Remove-Item -LiteralPath $stagingSig -Force -ErrorAction SilentlyContinue
                $stagingReady = $false
            }
        }
        if (-not $stagingReady) {
            $torn = Test-Path $buildingFlag
            $warm = (Test-Path $stagingExe) -and (-not $torn)
            if ($torn) {
                Write-RtlLog 'Previous staging build was interrupted; forcing a clean cold rebuild.'
                try { if (Test-Path $script:Staging) { Remove-Item -LiteralPath $script:Staging -Recurse -Force } }
                catch { throw "[STAGING] Could not clear a torn staging folder ($($script:Staging)); close anything using it and try again. $($_.Exception.Message)" }
                $warm = $false
            }
            Set-RtlStep 'copy' 15 $true
            if ($warm) {
                Write-RtlLog 'Refreshing existing staging (incremental mirror; only changed files copy)...'
            } else {
                Assert-RtlDiskSpace -SourceDir $src.AppDir   # only a full copy needs the big free-space budget
                Write-RtlLog 'Building patched copy in staging (full copy)...'
            }
            New-Item -ItemType Directory -Force -Path $stagingApp | Out-Null
            # Mark the build in progress BEFORE we start mutating the tree, so an
            # interrupted mirror is detected as torn on the next run.
            Set-Content -LiteralPath $buildingFlag -Value '1' -Encoding ASCII -NoNewline
            # Stale sig removed up front: a matching sig must only ever coexist with a
            # fully built + verified tree, never with a half-mirrored one.
            if (Test-Path $stagingSig) { Remove-Item -LiteralPath $stagingSig -Force -ErrorAction SilentlyContinue }
            # /MIR re-mirrors the pristine source over staging: our patched app.asar
            # differs from the source, so robocopy restores the pristine asar (giving
            # re-injection a clean base) and drops any stale artifacts (e.g. app.asar.bak).
            $rc = Invoke-Robocopy -From $src.AppDir -To $stagingApp
            if ($rc -ge 8) { throw "[LOCK] Could not copy all files (robocopy exit $rc); they may be locked by antivirus or another process. Close them and try again." }
            # Strip files that must not live in the copy (e.g. OpenCode's app-update.yml,
            # so the copy's electron-updater never tries to update itself in place).
            foreach ($rel in @($p.RemoveFromCopy)) {
                $victim = Join-RtlTree $stagingApp $rel
                if (Test-Path $victim) { try { Remove-Item -LiteralPath $victim -Force; Write-RtlLog "Removed from copy: $rel" } catch { Write-RtlLog "could not remove $rel from copy: $($_.Exception.Message)" } }
            }
            # Read-only guard: some Electron builds pin the asar via the integrity fuse.
            # We never modify the exe, so if that fuse is ON we cannot produce a working
            # copy - fail clearly instead of shipping a broken one. (OpenCode ships with
            # it OFF, so this passes; it protects against a future build turning it on.)
            if ($p.AssertFuseOff) {
                $fuseScan = if ($p.FuseScanRelPath) { Join-Path $script:Staging $p.FuseScanRelPath } else { $stagingExe }
                Assert-RtlAsarFuseOff -Node (Resolve-RtlNode -AsarPath $stagingAsar -Profile $p) -ScanPath $fuseScan
            }
            Set-RtlStep 'inject' 70 $true
            # Bake the current settings alongside the payload so a fresh copy already
            # reflects them; later tweaks use Update-CodexRtlConfigAsset (no rebuild).
            $cfgJs = Build-RtlConfigAsset -AppId $p.Id
            try {
                Invoke-AsarInject -AsarPath $stagingAsar -PatchJs $patchJs -ConfigJs $cfgJs -AllowExternalNodeFallback:$AllowExternalNodeFallback
            } finally {
                Remove-Item -LiteralPath $cfgJs -Force -ErrorAction SilentlyContinue
            }
            # Gate: a bad injection must never reach the atomic swap. Verify staging
            # BEFORE we record the signature that would let a later run skip rebuild.
            Set-RtlStep 'verify' 82 $true
            Test-RtlInjection -AsarPath $stagingAsar -AllowExternalNodeFallback:$AllowExternalNodeFallback | Out-Null
            Set-Content -LiteralPath $stagingSig -Value $src.Signature -Encoding UTF8 -NoNewline
            Remove-Item -LiteralPath $buildingFlag -Force -ErrorAction SilentlyContinue
            Write-RtlLog 'Staging build complete and verified.'
        } else {
            Write-RtlLog 'Staging already built for this version; attempting swap.'
        }

        if (Test-CodexRtlRunning) {
            Write-RtlLog "$app (RTL) is running; deferring swap (staging kept for next close)."
            if ($Auto) { Show-RtlToast "$app update ready" "A newer $app is staged. It will apply next time you close $app." }
            Set-RtlStep 'deferred' 100
            return
        }

        Set-RtlStep 'swap' 90
        Write-RtlLog 'Swapping staging into place (atomic)...'
        Invoke-AtomicSwap -ReseedStaging
        Set-RtlStep 'shortcut' 95
        New-RtlShortcut
        # Drop the shared Electron V8 code cache so the freshly injected renderer is
        # not shadowed by the pre-patch bundle cached under the shared userData dir.
        # Only regeneratable caches are touched (never Local Storage / cookies / login).
        Clear-RtlRendererCache -Profile $p
        # Post-swap smoke check on the LIVE copy; also the source of the recorded
        # hashes. Best-effort: a transient read-lock here should not fail a good
        # install (the next watcher tick re-verifies), so we log and proceed.
        $verify = $null
        try { $verify = Test-RtlInjection -AsarPath $liveAsar -AllowExternalNodeFallback:$AllowExternalNodeFallback }
        catch { Write-RtlLog "WARNING: post-swap verification issue: $($_.Exception.Message)" }
        Write-RtlState @{ sourceSignature = $src.Signature; codexVersion = $src.Version; sourcePath = $src.AppDir; payloadSha256 = $verify.payloadSha256; asarSha256 = $verify.asarSha256 }
        Set-RtlConfigApplied   # the fresh build baked the current config.json
        Write-RtlLog "DONE: $app (RTL) now at v$($src.Version)."
        Set-RtlStep 'done' 100
        if ($Auto) { Show-RtlToast "$app RTL updated" "Patched for $app v$($src.Version)." }
    }
    catch [System.UnauthorizedAccessException] { throw "[AV] Access was denied, possibly blocked by antivirus or Controlled Folder Access. $($_.Exception.Message)" }
    catch [System.Security.SecurityException]   { throw "[AV] A security restriction blocked the operation, possibly antivirus. $($_.Exception.Message)" }
    finally {
        Exit-RtlLock
    }
}

# ----------------------------------------------------------------- source watch

# A FileSystemWatcher on the folder holding app.asar, for DIRECT installs, so an
# update is noticed within seconds. The Store (MSIX) source lives under WindowsApps
# whose ACLs often block watching and whose updates land as a whole new versioned
# folder, so there the short poll in the watch loop is the reliable path. Returns a
# configured watcher (used via its synchronous WaitForChanged), or $null.
function New-RtlSourceWatcher {
    param([string]$WatchPath)
    try {
        if ($WatchPath) {
            $dir = Split-Path -Parent $WatchPath
            $name = Split-Path -Leaf $WatchPath
            if ($dir -and (Test-Path $dir)) {
                $fsw = New-Object System.IO.FileSystemWatcher $dir
                $fsw.Filter = $name
                $fsw.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size -bor [System.IO.NotifyFilters]::FileName
                $fsw.IncludeSubdirectories = $false
                Write-RtlLog "Source watch: FileSystemWatcher on $dir ($name)"
                return $fsw
            }
        }
    } catch { Write-RtlLog "Source watch: FSW setup failed: $($_.Exception.Message)" }
    return $null
}

# The blocking watch loop, shared by the watcher entry script. Runs one update pass
# immediately, then blocks on FileSystemWatcher.WaitForChanged (near-instant for
# direct installs, returns on the poll timeout otherwise) or a plain sleep when no
# watcher is available, and runs another pass. Each pass is Invoke-CodexRtlUpdate
# -Auto: cheap when nothing changed, and it completes a previously deferred swap
# once Codex (RTL) is closed. WaitForChanged is used instead of event subscriptions
# so a blocked main thread can still be woken (no runspace-pump deadlock).
function Invoke-CodexRtlWatchLoop {
    param([switch]$Loop, [int]$PollSec = 90, [int]$DebounceMs = 5000)
    $src0 = $null; try { $src0 = Resolve-RtlSource } catch {}
    # Watch the app.asar file itself (its folder + filename filter), not the whole tree,
    # so log/cache writes don't trigger false updates. NSIS/direct installs overwrite
    # app.asar in place on update, so LastWrite/Size/rename on that file is the signal.
    $watchPath = if ($src0 -and $src0.Type -eq 'Direct') { $src0.AsarPath } else { $null }
    $fsw = New-RtlSourceWatcher -WatchPath $watchPath
    Write-RtlLog ("Watch loop starting (poll={0}s, fsw={1})." -f $PollSec, [bool]$fsw)
    try {
        try { Invoke-CodexRtlUpdate -Auto } catch { Write-RtlLog "watch error: $($_.Exception.Message)" }
        while ($Loop) {
            if ($fsw) {
                $r = $fsw.WaitForChanged([System.IO.WatcherChangeTypes]::All, ($PollSec * 1000))
                if (-not $r.TimedOut) { Start-Sleep -Milliseconds $DebounceMs; Write-RtlLog 'Watch: source change detected.' }
            } else {
                Start-Sleep -Seconds $PollSec
            }
            try { Invoke-CodexRtlUpdate -Auto } catch { Write-RtlLog "watch error: $($_.Exception.Message)" }
        }
    } finally {
        if ($fsw) { try { $fsw.Dispose() } catch {} }
    }
}

# ----------------------------------------------------------------- watcher

# We autostart via the per-user HKCU\...\Run key (writable without admin), rather
# than a scheduled task (which requires admin to register). The watcher then runs
# a light background loop, so there is ZERO admin involvement, ever.
$script:RunKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunName = 'CodexRtlPatchWatcher'

# The autostart entry prefers the tray app (a resident NotifyIcon that subsumes the
# watcher). If no tray launcher is deployed yet (older layout) it falls back to the
# hidden watcher loop. Same HKCU\Run value name either way, so an upgrade replaces it.
function Get-RtlTrayLauncher {
    param([string]$BinDir)
    if (-not $BinDir) { $BinDir = $script:BinDir }
    $vbs = Join-Path $BinDir 'Desktop-RTL-Tray.vbs'
    if (Test-Path $vbs) { return $vbs }
    return $null
}

# Build the HKCU\Run command for the active app's watcher. Codex prefers the tray
# (a resident NotifyIcon that subsumes the watcher); OpenCode has no tray yet, so it
# runs the hidden watcher loop with -App opencode. The RunName is per-app, so both
# apps' autostart entries coexist.
function Get-RtlWatchCommand {
    param([string]$WatchScript)
    $appId = $script:ActiveProfile.Id
    $binDir = Split-Path $WatchScript -Parent
    $tray = Get-RtlTrayLauncher -BinDir $binDir
    if ($appId -eq 'codex' -and $tray) {
        $ws = (Get-Command wscript.exe).Source
        return "`"$ws`" `"$tray`""
    }
    $ps = (Get-Command powershell.exe).Source
    return "`"$ps`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WatchScript`" -App $appId -Loop"
}

# Predicate: does a process command line belong to the ACTIVE app's watcher/tray?
# OpenCode is identified by "-App opencode"; codex by the watcher/tray markers with
# no opencode marker, so per-app stop never touches the other app's watcher.
function Test-RtlWatchCommandLine {
    param([string]$CommandLine)
    if (-not $CommandLine) { return $false }
    if ($script:ActiveProfile.Id -eq 'opencode') { return ($CommandLine -match '-App\s+opencode') }
    # New names first; the old Codex-era names stay so upgrading evicts legacy watchers.
    return (($CommandLine -match 'Watch-DesktopRtl|DesktopRtlTray|Desktop-RTL-Tray|Watch-CodexRtl|CodexRtlTray|Codex-RTL-Tray') -and ($CommandLine -notmatch '-App\s+opencode'))
}

function Register-CodexRtlWatcher {
    param([string]$WatchScript)
    $cmd = Get-RtlWatchCommand -WatchScript $WatchScript
    if (-not (Test-Path $script:RunKey)) { New-Item -Path $script:RunKey -Force | Out-Null }
    Set-ItemProperty -Path $script:RunKey -Name $script:RunName -Value $cmd
    Write-RtlLog "Registered logon autostart (HKCU\Run\$($script:RunName)): $cmd"
}

function Stop-CodexRtlWatcher {
    # Kill the ACTIVE app's watcher/tray process(es) so a freshly deployed one can
    # replace it, and so uninstall leaves none behind. Scoped per-app so uninstalling
    # one app never stops the other's watcher. Never kills the calling process.
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $PID -and (Test-RtlWatchCommandLine $_.CommandLine) } |
            ForEach-Object {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Write-RtlLog "Stopped background process PID $($_.ProcessId)." } catch {}
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
    Stop-CodexRtlWatcher   # replace any existing (possibly visible) watcher/tray
    $appId = $script:ActiveProfile.Id
    $binDir = Split-Path $WatchScript -Parent
    $tray = Get-RtlTrayLauncher -BinDir $binDir
    if ($appId -eq 'codex' -and $tray) {
        Start-Process -FilePath (Get-Command wscript.exe).Source -ArgumentList "`"$tray`""
        Write-RtlLog 'Started tray for the current session.'
    } else {
        $ps = (Get-Command powershell.exe).Source
        Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $WatchScript, '-App', $appId, '-Loop')
        Write-RtlLog "Started watcher for the current session (app=$appId)."
    }
}

# ----------------------------------------------------------------- deploy

function Copy-RtlBin {
    # Copy the runtime files (lib, asar editor, payload, watcher, tray, settings,
    # tray launcher) to a stable per-user location so background pieces never depend
    # on the repo path. -Dest lets the self-updater stage into bin.staging.
    param([string]$RepoRoot, [string]$Dest)
    if (-not $Dest) { $Dest = $script:BinDir }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $items = @(
        @{ src = 'scripts\lib\desktop-rtl-lib.ps1'; dst = 'desktop-rtl-lib.ps1';   req = $true },
        @{ src = 'scripts\lib\asar-edit.mjs';     dst = 'asar-edit.mjs';        req = $true },
        @{ src = 'src\desktop-rtl-patch.js';        dst = 'desktop-rtl-patch.js';   req = $true },
        @{ src = 'scripts\Watch-DesktopRtl.ps1';    dst = 'Watch-DesktopRtl.ps1';   req = $true },
        @{ src = 'scripts\DesktopRtlTray.ps1';      dst = 'DesktopRtlTray.ps1';     req = $false },
        @{ src = 'scripts\DesktopRtlSettings.ps1';  dst = 'DesktopRtlSettings.ps1'; req = $false },
        @{ src = 'Desktop-RTL-Tray.vbs';            dst = 'Desktop-RTL-Tray.vbs';   req = $false },
        @{ src = 'Desktop-RTL-Settings.vbs';        dst = 'Desktop-RTL-Settings.vbs'; req = $false },
        # Legacy alias: a pre-rename tray (v1.x) applying a self-update looks for the old
        # launcher name in the fresh bin; ship it so the relaunch after bin-swap still works.
        @{ src = 'Desktop-RTL-Tray.vbs';            dst = 'Codex-RTL-Tray.vbs';     req = $false }
    )
    foreach ($it in $items) {
        $s = Join-Path $RepoRoot $it.src
        if (Test-Path $s) { Copy-Item $s (Join-Path $Dest $it.dst) -Force }
        elseif ($it.req) { throw "[PACKAGE] deploy source missing: $($it.src)" }
    }
    Write-RtlLog "Deployed runtime to $Dest"
    return (Join-Path $Dest 'Watch-DesktopRtl.ps1')
}

# ----------------------------------------------------------------- self-update

$script:Repo               = 'ElazarKrispel/desktop-rtl-patch'
$script:PendingSelfUpdate  = Join-Path $script:StateDir 'pending-selfupdate'

function Get-RtlLatestRelease {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $u = "https://api.github.com/repos/$($script:Repo)/releases/latest"
        return Invoke-RestMethod -Uri $u -Headers @{ 'User-Agent' = 'CodexRtlPatch'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 20
    } catch { Write-RtlLog "release check failed: $($_.Exception.Message)"; return $null }
}

# Pure decision helper (no network): given a tag and the release assets, decide
# whether a newer tool version is available and pick the zip + checksum URLs.
function Get-RtlUpdateDecision {
    param([string]$Tag, $Assets)
    $m = [regex]::Match([string]$Tag, '^v?(\d+\.\d+\.\d+)$')
    if (-not $m.Success) { return $null }
    $latest = [version]$m.Groups[1].Value
    $cur = [version]$script:PatchVersion
    $zip = $null; $sums = $null
    foreach ($a in @($Assets)) {
        if ($a.name -like '*.zip') { $zip = $a.browser_download_url }
        elseif ($a.name -eq 'SHA256SUMS.txt') { $sums = $a.browser_download_url }
    }
    return [pscustomobject]@{
        Available = ($latest -gt $cur); LatestTag = [string]$Tag; LatestVersion = $latest
        CurrentVersion = $cur; ZipUrl = $zip; Sha256Url = $sums
    }
}

function Test-RtlToolUpdateAvailable {
    $rel = Get-RtlLatestRelease
    if (-not $rel -or -not $rel.tag_name) { return $null }
    $d = Get-RtlUpdateDecision -Tag $rel.tag_name -Assets $rel.assets
    if ($d) { $d | Add-Member -NotePropertyName Notes -NotePropertyValue ([string]$rel.body) -Force }
    return $d
}

# Download + verify + stage a newer tool release into bin.staging, and drop a
# pending-selfupdate marker. The actual bin swap happens on the next tray start
# (before it loads anything from bin), so the running tool never overwrites its
# own in-use files. Verification is REQUIRED: an unverifiable release is refused.
function Invoke-RtlSelfUpdate {
    param($Info)
    if (-not $Info) { $Info = Test-RtlToolUpdateAvailable }
    if (-not $Info -or -not $Info.Available) { Write-RtlLog 'Self-update: already current.'; return $false }
    if (-not $Info.ZipUrl)   { throw '[INTEGRITY] release has no downloadable zip asset.' }
    if (-not $Info.Sha256Url) { throw '[INTEGRITY] release has no SHA256SUMS.txt; refusing an unverified tool update.' }
    if (-not (Enter-RtlLock)) { throw '[LOCK] an update is already in progress.' }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $tmp = Join-Path $env:TEMP ('codexrtl-selfupd-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            $zip = Join-Path $tmp 'pkg.zip'
            Invoke-WebRequest -Uri $Info.ZipUrl -OutFile $zip -UseBasicParsing
            $sumsRaw = (Invoke-WebRequest -Uri $Info.Sha256Url -UseBasicParsing).Content
            $sums = if ($sumsRaw -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($sumsRaw) } else { [string]$sumsRaw }
            $have = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower()
            if (-not ($sums -and ($sums.ToLower() -match [regex]::Escape($have)))) {
                throw '[INTEGRITY] the downloaded tool update did not match the published SHA-256 checksum.'
            }
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $root = Get-ChildItem -Directory -Path $tmp | Select-Object -First 1
            if (-not $root) { throw '[INTEGRITY] update archive was empty.' }
            Test-RtlPackage -RepoRoot $root.FullName | Out-Null
            $binStaging = "$($script:BinDir).staging"
            if (Test-Path $binStaging) { Remove-Item -LiteralPath $binStaging -Recurse -Force }
            Copy-RtlBin -RepoRoot $root.FullName -Dest $binStaging | Out-Null
            if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null }
            Set-Content -LiteralPath $script:PendingSelfUpdate -Value $Info.LatestTag -Encoding ASCII -NoNewline
            Write-RtlLog "Self-update staged $($Info.LatestTag); will apply on next tray start."
            return $true
        } finally { try { Remove-Item -LiteralPath $tmp -Recurse -Force } catch {} }
    } finally { Exit-RtlLock }
}

# ----------------------------------------------------------------- uninstall

function Invoke-CodexRtlUninstall {
    # Remove the watcher, the patched copy (+ staging/old), all shortcuts and state.
    # The logs folder is KEPT by default (for diagnostics); pass -PurgeLogs to delete it.
    param([switch]$PurgeLogs)
    if (Test-CodexRtlRunning) { throw '[LOCK] Codex (RTL) is running. Close it and try again.' }
    if (-not (Enter-RtlLock)) { throw '[LOCK] An update is in progress; try again in a moment.' }
    try {
        Unregister-CodexRtlWatcher   # stops the watcher/tray + removes the Run key + legacy task
        if (Test-Path $script:PendingSelfUpdate) { try { Remove-Item -LiteralPath $script:PendingSelfUpdate -Force } catch {} }
        foreach ($d in @($script:CopyRoot, $script:Staging, $script:OldRoot, $script:BinDir, "$($script:BinDir).staging", "$($script:BinDir).old")) {
            if (Test-Path $d) {
                try { Remove-Item -LiteralPath $d -Recurse -Force; Write-RtlLog "removed $d" }
                catch { Write-RtlLog "could not remove $d : $($_.Exception.Message)" }
            }
        }
        foreach ($lnk in $script:ShortcutPaths) {
            if (Test-Path $lnk) { try { Remove-Item -LiteralPath $lnk -Force; Write-RtlLog "removed $lnk" } catch {} }
        }
        if (Test-Path $script:StateFile) { Remove-Item -LiteralPath $script:StateFile -Force }
        if ($PurgeLogs -and (Test-Path $script:LogsDir)) { try { Remove-Item -LiteralPath $script:LogsDir -Recurse -Force; Write-RtlLog 'Purged logs.' } catch {} }
        Write-RtlLog 'Uninstall complete.'
    } finally { Exit-RtlLock }
}
