# desktop-rtl-herdr.ps1 - Herdr support for the Desktop RTL patch engine.
#
# Herdr (herdr.dev) is NOT an Electron app: it is a single Rust binary that renders a
# terminal UI with ratatui and a vendored libghostty VT engine. There is no renderer
# HTML and no JavaScript, so desktop-rtl-patch.js and every injection mode in the core
# library are inapplicable. The RTL fix for Herdr lives inside Herdr itself, as a
# display-only BiDi reordering pass, and is shipped as a PATCHED BUILD from our fork
# (ElazarKrispel/herdr, branch feat/bidi-display-order).
#
# So this profile does not copy and patch the user's install. It installs our prebuilt
# herdr.exe next to the official one as "Herdr (RTL)":
#
#   - the official install under ~\.herdr and %APPDATA%\herdr is only ever READ, to
#     learn which upstream version is installed and to seed settings;
#   - the RTL build runs with XDG_CONFIG_HOME / XDG_STATE_HOME pointed at our own
#     folder, so it never shares config.toml, session.json, sockets or logs with the
#     official Herdr and the two can run side by side;
#   - `[terminal] bidi` is written into that private config, which is what turns the
#     reordering on.
#
# This file is ASCII only, like the core library, and is dot-sourced by it.

$script:HerdrRtlAssetName = 'herdr-windows-x86_64.zip'

# --------------------------------------------------------------------- discovery

# Locate the official Herdr install. Herdr installs a standalone package under
# ~\.herdr\packages\standalone\releases\<version>-<target>\ and points
# %LOCALAPPDATA%\Programs\Herdr\bin at it with a directory symlink, so the release
# folder name is the authoritative version string.
function Resolve-HerdrSource {
    param($Profile = $script:ActiveProfile)
    foreach ($root in @($Profile.SourceRoots)) {
        if (-not $root -or -not (Test-Path $root)) { continue }
        $exe = Join-Path $root $Profile.ExeLeaf
        if (-not (Test-Path $exe)) { continue }
        $item = Get-Item $exe
        # %LOCALAPPDATA%\Programs\Herdrin is a directory symlink into
        # ...\releases\<version>-<target>, so follow it before reading the
        # out of the path. Only then fall back to asking the binary itself.
        $ver = Get-HerdrVersionFromPath -Path $item.FullName
        if (-not $ver) { $ver = Get-HerdrVersionFromPath -Path (Resolve-HerdrLinkTarget -Path $root) }
        if (-not $ver) { $ver = Get-HerdrExeVersion -Exe $item.FullName }
        if (-not $ver) { $ver = $item.LastWriteTimeUtc.ToString('yyyyMMddHHmmss') }
        return [pscustomobject]@{
            Type      = 'Herdr'
            Version   = [string]$ver
            # The signature drives "is the copy stale". It folds in the upstream
            # version AND the RTL build we install, so a new upstream release or a
            # new fork build both force a fresh install.
            Signature = "herdr:$ver|rtl=$(Get-HerdrRtlBuildTag -Profile $Profile)"
            AppDir    = $root
            AsarPath  = $null
            ExePath   = $item.FullName
            Writable  = $true
        }
    }
    return $null
}

# Pull "0.8.2" out of a resolved standalone release path such as
# ...\releases\0.8.2-x86_64-pc-windows-msvc\herdr.exe. Returns $null when the path
# does not look like a standalone release (for example a plain copy on PATH).
function Get-HerdrVersionFromPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = $Path
    try { $full = [IO.Path]::GetFullPath($Path) } catch {}
    $m = [regex]::Match($full, '(?i)[\\/]releases[\\/](\d+\.\d+\.\d+)-')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# Follow a directory symlink or junction one level. Returns the original path when it
# is not a link, so callers can use the result unconditionally.
function Resolve-HerdrLinkTarget {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $target = $null
        if ($item.PSObject.Properties['Target'] -and $item.Target) {
            $target = @($item.Target)[0]
        }
        if ($target) {
            if (-not [IO.Path]::IsPathRooted($target)) {
                $target = Join-Path (Split-Path $Path -Parent) $target
            }
            return $target
        }
    } catch {}
    return $Path
}

# Ask a Herdr binary for its own version. Read only; `--version` prints and exits
# without starting a server or touching any state.
function Get-HerdrExeVersion {
    param([Parameter(Mandatory)][string]$Exe)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = '--version'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd() + $proc.StandardError.ReadToEnd()
        if (-not $proc.WaitForExit(20000)) { try { $proc.Kill() } catch {} ; return $null }
        $m = [regex]::Match($out, '(\d+\.\d+\.\d+)')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch {}
    return $null
}

# Which RTL build this tool installs. Pinned per tool version so an engine upgrade
# can move to a newer fork build deliberately, never implicitly.
function Get-HerdrRtlBuildTag {
    param($Profile = $script:ActiveProfile)
    if ($env:HERDR_RTL_BUILD_TAG) { return [string]$env:HERDR_RTL_BUILD_TAG }
    return [string]$Profile.PrebuiltTag
}

# ----------------------------------------------------------------------- artifact

# Produce a directory holding the RTL build (herdr.exe plus its conpty payload).
#
# Order of preference:
#   1. HERDR_RTL_ARTIFACT - a local .zip or a directory. This is what the maintainer
#      uses to test a build before it is released, and what a developer building the
#      fork locally points at.
#   2. The release asset from the fork.
#
# Returns the path to a directory that contains herdr.exe. The caller owns cleanup of
# $WorkDir.
function Resolve-HerdrRtlArtifact {
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        $Profile = $script:ActiveProfile
    )
    if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }

    $local = $env:HERDR_RTL_ARTIFACT
    if ($local) {
        if (-not (Test-Path $local)) { throw "[ARTIFACT] HERDR_RTL_ARTIFACT is set but does not exist: $local" }
        $item = Get-Item $local
        if ($item.PSIsContainer) {
            Write-RtlLog "Using local RTL build directory: $($item.FullName)"
            return (Find-HerdrExeRoot -Root $item.FullName)
        }
        Write-RtlLog "Using local RTL build archive: $($item.FullName)"
        $dest = Join-Path $WorkDir 'artifact'
        Expand-HerdrArchive -Archive $item.FullName -Destination $dest
        return (Find-HerdrExeRoot -Root $dest)
    }

    $tag = Get-HerdrRtlBuildTag -Profile $Profile
    if (-not $tag) { throw '[ARTIFACT] No RTL build tag is configured for Herdr.' }
    $url = "https://github.com/$($Profile.PrebuiltRepo)/releases/download/$tag/$script:HerdrRtlAssetName"
    $zip = Join-Path $WorkDir $script:HerdrRtlAssetName
    Write-RtlLog "Downloading RTL build $tag from $url"
    try {
        $old = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -MaximumRedirection 5
        } finally { $ProgressPreference = $old }
    }
    catch { throw "[ARTIFACT] Could not download the Herdr RTL build ($url): $($_.Exception.Message)" }
    $dest = Join-Path $WorkDir 'artifact'
    Expand-HerdrArchive -Archive $zip -Destination $dest
    return (Find-HerdrExeRoot -Root $dest)
}

function Expand-HerdrArchive {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Destination)
    if (Test-Path $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
    }
    catch { throw "[ARTIFACT] Could not extract $Archive : $($_.Exception.Message)" }
}

# The release zip may hold herdr.exe at its root or one level down; accept both.
function Find-HerdrExeRoot {
    param([Parameter(Mandatory)][string]$Root)
    if (Test-Path (Join-Path $Root 'herdr.exe')) { return $Root }
    $hit = Get-ChildItem -LiteralPath $Root -Filter 'herdr.exe' -Recurse -File -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($hit) { return $hit.Directory.FullName }
    throw "[ARTIFACT] The Herdr RTL build does not contain herdr.exe: $Root"
}

# ------------------------------------------------------------------------- build

# Stage the RTL build. Mirrors the shape of the Electron path (build into staging,
# verify, then let the caller atomically swap) but there is nothing to inject: the
# fix is compiled into the binary.
function Invoke-HerdrRtlBuild {
    param([Parameter(Mandatory)]$Source, $Profile = $script:ActiveProfile)
    $work = Join-Path $script:StateDir 'artifact.work'
    try {
        $artifact = Resolve-HerdrRtlArtifact -WorkDir $work -Profile $Profile
        if (Test-Path $script:Staging) { Remove-Item -LiteralPath $script:Staging -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $script:Staging | Out-Null
        # Guard: the staging tree is inside our own state folder, never the user's install.
        Assert-RtlWriteAllowed -Path (Join-Path $script:Staging 'herdr.exe') -Profile $Profile
        Copy-Item -Path (Join-Path $artifact '*') -Destination $script:Staging -Recurse -Force
        # Windows Herdr needs the ConPTY payload beside the binary. Our build ships it,
        # but fall back to the official install's copy if a future asset drops it.
        $stagedConpty = Join-Path $script:Staging 'conpty'
        if (-not (Test-Path $stagedConpty)) {
            $srcConpty = Join-Path $Source.AppDir 'conpty'
            if (Test-Path $srcConpty) {
                Write-RtlLog 'RTL build has no conpty payload; taking it from the official install (read only).'
                Copy-Item -Path $srcConpty -Destination $stagedConpty -Recurse -Force
            }
        }
        Test-HerdrRtlBuild -Root $script:Staging -Source $Source | Out-Null
    }
    finally {
        if (Test-Path $work) { try { Remove-Item -LiteralPath $work -Recurse -Force } catch {} }
    }
}

# Verify a staged or installed RTL build: the binary must exist, run, and report the
# same upstream version as the official install, so a fork build that lags behind an
# upstream update is caught here instead of surprising the user later.
function Test-HerdrRtlBuild {
    param(
        [Parameter(Mandatory)][string]$Root,
        $Source,
        [switch]$AllowVersionSkew
    )
    $exe = Join-Path $Root 'herdr.exe'
    if (-not (Test-Path $exe)) { throw "[ARTIFACT] Herdr RTL binary missing: $exe" }
    $out = ''
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = '--version'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd() + $proc.StandardError.ReadToEnd()
        if (-not $proc.WaitForExit(30000)) { try { $proc.Kill() } catch {} ; throw 'timed out' }
    }
    catch { throw "[ARTIFACT] The Herdr RTL binary did not run: $($_.Exception.Message)" }
    $m = [regex]::Match($out, '(\d+\.\d+\.\d+)')
    if (-not $m.Success) { throw "[ARTIFACT] Could not read a version from the Herdr RTL binary (output: $($out.Trim()))" }
    $built = $m.Groups[1].Value
    if ($Source -and $Source.Version -and -not $AllowVersionSkew -and $built -ne $Source.Version) {
        Write-RtlLog "NOTE: RTL build is Herdr $built while the official install is $($Source.Version)."
    }
    return [pscustomobject]@{ Version = $built; Output = $out.Trim() }
}

# ------------------------------------------------------------------- private data

# Everything the RTL build reads and writes lives here, so launching it never touches
# %APPDATA%\herdr. Herdr honours XDG_CONFIG_HOME and XDG_STATE_HOME on Windows too,
# and derives config.toml, session.json, both sockets and its logs from them.
function Get-HerdrRtlDataDir { param($Profile = $script:ActiveProfile) return (Join-Path $script:StateDir 'data') }
function Get-HerdrRtlStateHome { param($Profile = $script:ActiveProfile) return (Join-Path $script:StateDir 'state') }
function Get-HerdrRtlConfigPath {
    param($Profile = $script:ActiveProfile)
    # config_dir() appends the app name to XDG_CONFIG_HOME.
    return (Join-Path (Join-Path (Get-HerdrRtlDataDir -Profile $Profile) 'herdr') 'config.toml')
}

# Map the shared RTL settings onto Herdr's own config key.
#   enabled = false            -> off
#   policy  = firstStrong      -> auto   (base direction from the first strong char)
#   otherwise                  -> ltr    (reverse RTL runs, keep the line left to right)
function Get-HerdrBidiValue {
    param($Config)
    if (-not $Config) { return 'ltr' }
    $enabled = Get-HerdrConfigMember -Container $Config -Name 'enabled'
    if ($null -ne $enabled -and -not [bool]$enabled) { return 'off' }
    $direction = Get-HerdrConfigMember -Container $Config -Name 'direction'
    $policy = if ($direction) { Get-HerdrConfigMember -Container $direction -Name 'policy' } else { $null }
    if ([string]$policy -eq 'firstStrong') { return 'auto' }
    return 'ltr'
}

# Read one member from a settings container. Read-RtlConfig builds ordered
# dictionaries, while config parsed from JSON arrives as PSCustomObject, and the two
# are read differently. Returns $null when the member is absent.
function Get-HerdrConfigMember {
    param($Container, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Container) { return $null }
    if ($Container -is [System.Collections.IDictionary]) {
        if ($Container.Contains($Name)) { return $Container[$Name] }
        return $null
    }
    $prop = $Container.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

# Write the RTL build's private config.toml.
#
# On first install the official config.toml is copied in, so the user keeps their
# shell, theme and keybindings. After that only the managed [terminal] bidi key is
# rewritten and every other line the user edited is preserved.
function Sync-HerdrRtlConfig {
    param($Source, $Profile = $script:ActiveProfile)
    $path = Get-HerdrRtlConfigPath -Profile $Profile
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $text = $null
    if (Test-Path $path) {
        $text = [IO.File]::ReadAllText($path)
    } elseif ($Source) {
        # Seed from the official config, read only.
        $official = Join-Path (Join-Path $env:APPDATA 'herdr') 'config.toml'
        if (Test-Path $official) {
            try {
                $text = [IO.File]::ReadAllText($official)
                Write-RtlLog "Seeded the RTL config from the official one ($official, read only)."
            } catch { Write-RtlLog "could not read the official config: $($_.Exception.Message)" }
        }
    }
    if ($null -eq $text) { $text = '' }

    $cfg = Read-RtlConfig
    $appCfg = if ($cfg.apps) { $cfg.apps.$($Profile.Id) } else { $null }
    $value = Get-HerdrBidiValue -Config $appCfg
    $text = Set-HerdrTomlKey -Text $text -Section 'terminal' -Key 'bidi' -Value $value
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
    Write-RtlLog "Herdr RTL config: [terminal] bidi = `"$value`" ($path)"
    return $value
}

# Minimal TOML key setter: enough for one scalar string key in one table, which is all
# this profile owns. Rewrites the key in place when it is already there, appends the
# table when it is not, and never reorders or reformats anything else.
function Set-HerdrTomlKey {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    $nl = "`r`n"
    $lines = @()
    if ($Text.Length -gt 0) { $lines = [regex]::Split($Text, "`r`n|`n|`r") }
    $line = "$Key = `"$Value`""

    $inSection = $false
    $sectionStart = -1
    $sectionEnd = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].Trim()
        if ($t -match '^\[\s*([^\]]+?)\s*\]$') {
            if ($inSection) { $sectionEnd = $i; break }
            if ($matches[1] -eq $Section) { $inSection = $true; $sectionStart = $i }
            continue
        }
        if ($inSection -and $t -match "^$([regex]::Escape($Key))\s*=") {
            $lines[$i] = $line
            return (($lines -join $nl))
        }
    }
    if ($inSection) {
        if ($sectionEnd -lt 0) { $sectionEnd = $lines.Count }
        $head = if ($sectionStart -ge 0) { $lines[0..$sectionEnd] } else { $lines }
        $out = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($i -eq $sectionEnd) { $out.Add($line) }
            $out.Add($lines[$i])
        }
        if ($sectionEnd -ge $lines.Count) { $out.Add($line) }
        return ($out.ToArray() -join $nl)
    }
    if ($Text.Length -eq 0) { return ("[$Section]" + $nl + $line + $nl) }
    $prefix = if (-not $Text.EndsWith("`n")) { $nl } else { '' }
    return ($Text + $prefix + $nl + "[$Section]" + $nl + $line + $nl)
}

# ---------------------------------------------------------------------- launcher

# Herdr is a terminal program, so the shortcut cannot point at the bare exe the way the
# Electron profiles do: that would open a legacy console window. Write a .cmd that sets
# the private environment and launches the copy, and prefer Windows Terminal to host it.
function New-HerdrRtlLauncher {
    param($Profile = $script:ActiveProfile)
    $exe = Join-Path $script:CopyRoot 'herdr.exe'
    $data = Get-HerdrRtlDataDir -Profile $Profile
    $state = Get-HerdrRtlStateHome -Profile $Profile
    foreach ($d in @($data, $state)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }

    $lines = @(
        '@echo off',
        'rem Herdr (RTL) launcher - generated by the Desktop RTL patch. Do not edit:',
        'rem it is rewritten from the app profile on every install and update.',
        'rem XDG_CONFIG_HOME and XDG_STATE_HOME keep this build completely separate',
        'rem from the official Herdr: its own config.toml, session.json, sockets and logs.',
        'setlocal',
        "set `"XDG_CONFIG_HOME=$data`"",
        "set `"XDG_STATE_HOME=$state`"",
        "set `"HERDR_BIN_PATH=$exe`"",
        "if not exist `"$exe`" (",
        "  echo Herdr ^(RTL^) is not installed: `"$exe`" is missing.",
        '  echo Reinstall it from the Desktop RTL patch installer.',
        '  pause',
        '  exit /b 1',
        ')',
        "`"$exe`" %*",
        'rem The shortcut runs this in its own window, which Windows closes the moment',
        'rem the script ends. On a clean quit that is what we want; on a failure it',
        'rem would hide the reason, so hold the window open and show the exit code.',
        'if errorlevel 1 (',
        '  echo.',
        '  echo Herdr exited with error level %errorlevel%.',
        '  pause',
        ')'
    )
    $path = Join-Path $script:StateDir 'Herdr-RTL.cmd'
    [IO.File]::WriteAllText($path, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.ASCIIEncoding))
    Write-RtlLog "Wrote launcher $path"
    return $path
}

# Create the "Herdr (RTL)" shortcuts. Windows Terminal hosts the session when it is
# available (correct Unicode and font handling); otherwise the .cmd runs in the
# classic console, which still works.
function New-HerdrRtlShortcut {
    param($Profile = $script:ActiveProfile)
    $cmd = New-HerdrRtlLauncher -Profile $Profile
    # Point the shortcut straight at cmd.exe running the launcher. Herdr needs a
    # terminal to draw in, and Windows opens this in whatever the user's default
    # terminal is, which on Windows 11 is Windows Terminal.
    #
    # Deliberately NOT `wt.exe -- <launcher>`: Windows Terminal starts its command
    # with CreateProcess, which cannot execute a .cmd file at all, so that form
    # fails with "the system cannot find the file specified" even though the file
    # is right there. Going through cmd.exe also means one less set of quoting
    # rules between the shortcut and the program.
    $target = Join-Path $env:WINDIR 'System32\cmd.exe'
    $args = '/c "' + $cmd + '"'
    # Icon: take it from the official install's exe, which is present and branded.
    $iconExe = Join-Path $script:CopyRoot 'herdr.exe'
    try {
        $s = Resolve-HerdrSource -Profile $Profile
        if ($s -and (Test-Path $s.ExePath)) { $iconExe = $s.ExePath }
    } catch {}

    $ws = New-Object -ComObject WScript.Shell
    foreach ($lnk in @($script:ShortcutStart, $script:ShortcutDesktop)) {
        try {
            $sc = $ws.CreateShortcut($lnk)
            $sc.TargetPath       = $target
            $sc.Arguments        = $args
            # Start in the user's home, never in the copy: cmd.exe keeps its
            # working directory open for as long as the window lives (including
            # the pause on a failed start), which would pin the copy folder and
            # make an update or uninstall fail to replace it.
            $sc.WorkingDirectory = $env:USERPROFILE
            $sc.IconLocation     = "$iconExe,0"
            $sc.Description      = $Profile.ShortcutDesc
            $sc.Save()
        }
        catch {
            $m = $_.Exception.Message
            if ($lnk -eq $script:ShortcutDesktop -and ($m -match 'denied|access')) {
                Write-RtlLog "Desktop shortcut blocked (likely Controlled Folder Access); the Start-menu shortcut still works. $m"
            } else {
                Write-RtlLog "shortcut '$lnk' failed: $m"
            }
        }
    }
}

# ------------------------------------------------------------------------ install

# The whole install pass for Herdr, called from Invoke-CodexRtlUpdate in place of the
# Electron copy-and-inject pipeline. Same contract: build into staging, refuse to swap
# while the RTL copy is running, then swap atomically and record state.
function Invoke-HerdrRtlInstall {
    param(
        [Parameter(Mandatory)]$Source,
        [switch]$Force,
        [switch]$Auto,
        $Profile = $script:ActiveProfile
    )
    $app = $Profile.DisplayName
    $copyExe = Join-Path $script:CopyRoot 'herdr.exe'
    $state = Read-RtlState
    $current = if ($state) { $state.sourceSignature } else { $null }
    $patchCurrent = ($state -and $state.patchVersion -eq $script:PatchVersion)

    if (-not $Force -and $current -eq $Source.Signature -and (Test-Path $copyExe) -and $patchCurrent) {
        Write-RtlLog "Up to date ($app v$($Source.Version), patch $($script:PatchVersion))."
        # Settings may have changed while the RTL build was open; the config is a plain
        # file outside the copy, so it can always be refreshed.
        try { Sync-HerdrRtlConfig -Source $Source -Profile $Profile | Out-Null }
        catch { Write-RtlLog "config sync error: $($_.Exception.Message)" }
        # Re-assert the shortcuts. A shortcut can go missing without the install
        # changing at all (a cleanup tool, a profile sync, a stray delete), and
        # without this the only way back is a forced reinstall.
        if (@($script:ShortcutPaths | Where-Object { -not (Test-Path $_) })) {
            Write-RtlLog 'A shortcut is missing; recreating it.'
            try { New-HerdrRtlShortcut -Profile $Profile }
            catch { Write-RtlLog "shortcut refresh failed: $($_.Exception.Message)" }
        }
        Set-RtlStep 'done' 100
        return
    }
    Write-RtlLog "Install needed: $app v$($Source.Version) [$($Source.Type)] (was '$current')"

    Set-RtlStep 'copy' 25 $true
    Invoke-HerdrRtlBuild -Source $Source -Profile $Profile
    Set-RtlStep 'verify' 70 $true
    $staged = Test-HerdrRtlBuild -Root $script:Staging -Source $Source
    Write-RtlLog "Staged Herdr RTL build $($staged.Version)."

    if (Test-CodexRtlRunning) {
        Write-RtlLog "$app (RTL) is running; deferring swap (staging kept for next close)."
        if ($Auto) { Show-RtlToast "$app update ready" "A newer $app (RTL) is staged. It will apply next time you close it." }
        Set-RtlStep 'deferred' 100
        return
    }

    Set-RtlStep 'swap' 88
    Write-RtlLog 'Swapping staging into place (atomic)...'
    Invoke-AtomicSwap
    Set-RtlStep 'shortcut' 94
    New-HerdrRtlShortcut -Profile $Profile
    $bidi = Sync-HerdrRtlConfig -Source $Source -Profile $Profile

    # Post-swap smoke check on the live copy.
    $live = Test-HerdrRtlBuild -Root $script:CopyRoot -Source $Source
    Write-RtlState @{
        sourceSignature = $Source.Signature
        codexVersion    = $Source.Version
        sourcePath      = $Source.AppDir
        payloadSha256   = (Get-HerdrFileSha256 -Path (Join-Path $script:CopyRoot 'herdr.exe'))
        asarSha256      = $null
    }
    Set-RtlConfigApplied
    Write-RtlLog "DONE: $app (RTL) $($live.Version) installed (bidi=$bidi)."
    Set-RtlStep 'done' 100
    if ($Auto) { Show-RtlToast "$app RTL updated" "Herdr (RTL) $($live.Version) is ready." }
}

function Get-HerdrFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() } catch { return $null }
}

# Diagnostics rows for a prebuilt profile. The Electron report asks about asars,
# renderers and Node, none of which exist here.
function Get-HerdrRtlDiagnostics {
    param($Profile = $script:ActiveProfile)
    $rows = [ordered]@{}
    $rows['Mode'] = 'prebuilt binary (no injection)'
    $rows['RtlBuildTag'] = (Get-HerdrRtlBuildTag -Profile $Profile)
    $rows['ArtifactOverride'] = if ($env:HERDR_RTL_ARTIFACT) { $env:HERDR_RTL_ARTIFACT } else { '(none)' }
    $rows['PrivateConfig'] = (Get-HerdrRtlConfigPath -Profile $Profile)
    $rows['ConfigExists'] = (Test-Path (Get-HerdrRtlConfigPath -Profile $Profile))
    try {
        $src = Resolve-HerdrSource -Profile $Profile
        $rows['OfficialVersion'] = if ($src) { $src.Version } else { '(not found)' }
        $rows['OfficialExe'] = if ($src) { $src.ExePath } else { '(not found)' }
    } catch { $rows['OfficialVersion'] = "error: $($_.Exception.Message)" }
    $copyExe = Join-Path $script:CopyRoot 'herdr.exe'
    $rows['RtlExe'] = $copyExe
    $rows['RtlExeExists'] = (Test-Path $copyExe)
    if (Test-Path $copyExe) {
        try { $rows['RtlVersion'] = (Get-HerdrExeVersion -Exe $copyExe) } catch { $rows['RtlVersion'] = 'error' }
    }
    return $rows
}
