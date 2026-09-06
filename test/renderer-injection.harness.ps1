$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('rtl-renderer-tests-' + [guid]::NewGuid().ToString('N'))
$oldLocal = $env:LOCALAPPDATA; $oldRoam = $env:APPDATA
$env:LOCALAPPDATA = Join-Path $temp 'local'; $env:APPDATA = Join-Path $temp 'roaming'
. (Join-Path $repo 'scripts\lib\desktop-rtl-lib.ps1')

# Shortcut paths come from [Environment]::GetFolderPath, which resolves the REAL
# Start menu and Desktop no matter what APPDATA says. Without this the uninstall
# assertions below delete the user's actual "(RTL)" shortcuts, which is how the
# Grok Bot one went missing. Wrap Set-RtlActiveApp so every call redirects them
# into the temp tree instead.
$script:ShortcutSandbox = Join-Path $temp 'shortcuts'
New-Item -ItemType Directory -Force -Path $script:ShortcutSandbox | Out-Null
$script:RealSetRtlActiveApp = ${function:Set-RtlActiveApp}
function Set-RtlActiveApp {
    param([string]$AppId = 'codex')
    & $script:RealSetRtlActiveApp $AppId | Out-Null
    $script:ShortcutStart   = Join-Path $script:ShortcutSandbox ($script:ShortcutLabel + '.lnk')
    $script:ShortcutDesktop = Join-Path $script:ShortcutSandbox ('Desktop - ' + $script:ShortcutLabel + '.lnk')
    $script:ShortcutPath    = $script:ShortcutStart
    $script:LegacyShortcuts = @()
    $script:ShortcutPaths   = @($script:ShortcutStart, $script:ShortcutDesktop)
}

$script:passed = 0
function Assert-True([bool]$Value, [string]$Name) {
    if (-not $Value) { throw "FAIL: $Name" }
    $script:passed++; Write-Host "ok $script:passed - $Name"
}
function Assert-Throws([scriptblock]$Action, [string]$Name, [string]$Pattern = '') {
    try { & $Action; throw "FAIL: $Name (did not throw)" }
    catch {
        if ($_.Exception.Message -like 'FAIL:*') { throw }
        if ($Pattern -and $_.Exception.Message -notmatch $Pattern) { throw "FAIL: $Name (wrong error: $($_.Exception.Message))" }
    }
    $script:passed++; Write-Host "ok $script:passed - $Name"
}
function New-Fixture([string]$Html) {
    $d = Join-Path $temp ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Join-Path $d 'assets') | Out-Null
    [IO.File]::WriteAllText((Join-Path $d 'index.html'), $Html, (New-Object Text.UTF8Encoding $false))
    return $d
}

try {
    New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA,$env:APPDATA | Out-Null
    $cases = @(
        @('<script type="module" src="./assets/x.js"></script>', './assets/x.js'),
        @('<script type="module" src="/assets/x.js"></script>', '/assets/x.js'),
        @('<script type="module" src="assets/x.js"></script>', 'assets/x.js'),
        @('<script type="module" src="/assets/x.js?q=1"></script>', '/assets/x.js'),
        @("<script src='/assets/x.js#h' type='module'></script>", '/assets/x.js')
    )
    foreach ($c in $cases) {
        $m = Find-RtlAppBundleMatch $c[0]
        Assert-True ([bool]$m -and $m.Value -match [regex]::Escape($c[1])) "matcher accepts $($c[1])"
    }
    Assert-True (-not (Find-RtlAppBundleMatch '<script type="module" src="./assets/desktop-rtl-patch.js"></script>')) 'matcher skips own payload'
    Assert-True (-not (Find-RtlAppBundleMatch '<script type="module" src="https://cdn.test/assets/x.js"></script>')) 'matcher rejects CDN URL'
    Assert-True (-not (Find-RtlAppBundleMatch '<html></html>')) 'matcher returns no match without bundle'

    $patch = Join-Path $temp 'patch.js'; $cfg = Join-Path $temp 'config.js'
    [IO.File]::WriteAllText($patch, 'window.__payloadSentinel = 1;', (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText($cfg, 'window.__codexRtlConfig = {"enabled":true};', (New-Object Text.UTF8Encoding $false))

    $dirProfile = Get-RtlProfile 'traycer'
    $dirRoot = Join-Path $dirProfile.Staging 'resources\renderer'
    New-Item -ItemType Directory -Force -Path (Join-Path $dirRoot 'assets') | Out-Null
    [IO.File]::WriteAllText((Join-Path $dirRoot 'index.html'), '<html><head><script type="module" src="./assets/app.js"></script></head></html>', (New-Object Text.UTF8Encoding $false))
    Invoke-RtlDirInject -RendererDir $dirRoot -Profile $dirProfile -PatchJs $patch -ConfigJs $cfg
    Assert-True (Test-RtlDirInjection $dirRoot) 'dir injection verifies'
    $dh = [IO.File]::ReadAllText((Join-Path $dirRoot 'index.html'))
    Assert-True ($dh.IndexOf('desktop-rtl-config.js') -lt $dh.IndexOf('desktop-rtl-patch.js') -and $dh.IndexOf('desktop-rtl-patch.js') -lt $dh.IndexOf('app.js')) 'dir config and payload precede bundle'
    Invoke-RtlDirInject -RendererDir $dirRoot -Profile $dirProfile -PatchJs $patch -ConfigJs $cfg
    $dh = [IO.File]::ReadAllText((Join-Path $dirRoot 'index.html'))
    Assert-True (([regex]::Matches($dh, 'desktop-rtl-patch\.js')).Count -eq 1 -and ([regex]::Matches($dh, 'desktop-rtl-config\.js')).Count -eq 1) 'dir reinjection is idempotent'

    $inlineProfile = Get-RtlProfile 't3code'
    $inlineRoot = Join-Path $inlineProfile.Staging $inlineProfile.RendererDirRel
    New-Item -ItemType Directory -Force -Path $inlineRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $inlineRoot 'index.html'), '<html><head><script type="module" src="/assets/app.js"></script></head></html>', (New-Object Text.UTF8Encoding $false))
    Invoke-RtlInlineInject -RendererDir $inlineRoot -Profile $inlineProfile -PatchJs $patch -ConfigJs $cfg
    Assert-True (Test-RtlInlineInjection $inlineRoot) 'inline injection verifies'
    Assert-True (-not (Test-Path (Join-Path $inlineRoot 'assets'))) 'inline injection writes no assets'
    $ih = [IO.File]::ReadAllText((Join-Path $inlineRoot 'index.html'))
    Assert-True ($ih.IndexOf('desktop-rtl-config') -lt $ih.IndexOf('desktop-rtl-payload') -and $ih.IndexOf('desktop-rtl-payload') -lt $ih.IndexOf('/assets/app.js')) 'inline config, payload and bundle order'
    Invoke-RtlInlineInject -RendererDir $inlineRoot -Profile $inlineProfile -PatchJs $patch -ConfigJs $cfg
    $ih = [IO.File]::ReadAllText((Join-Path $inlineRoot 'index.html'))
    Assert-True (([regex]::Matches($ih, 'id="desktop-rtl-config"')).Count -eq 1 -and ([regex]::Matches($ih, 'id="desktop-rtl-payload"')).Count -eq 1) 'inline reinjection is idempotent'
    $payloadBefore = [regex]::Match($ih, (Get-RtlInlineTagRegex 'desktop-rtl-payload')).Value
    $copyRoot = $inlineProfile.CopyRoot
    New-Item -ItemType Directory -Force -Path (Split-Path (Join-Path $copyRoot $inlineProfile.RendererDirRel) -Parent) | Out-Null
    Copy-Item -LiteralPath $inlineRoot -Destination (Split-Path (Join-Path $copyRoot $inlineProfile.RendererDirRel) -Parent) -Recurse -Force
    Set-RtlActiveApp t3code | Out-Null
    $configObj = Get-RtlDefaultConfig; $configObj.apps.t3code.enabled = $false; Write-RtlConfig $configObj
    Update-CodexRtlConfigAsset -AppId t3code
    $liveHtml = [IO.File]::ReadAllText((Join-Path (Join-Path $copyRoot $inlineProfile.RendererDirRel) 'index.html'))
    Assert-True ($liveHtml -match '"enabled":false' -and [regex]::Match($liveHtml, (Get-RtlInlineTagRegex 'desktop-rtl-payload')).Value -eq $payloadBefore) 'config-only update preserves payload bytes'

    $noBundle = New-Fixture '<script id="desktop-rtl-config">window.__codexRtlConfig={};</script><script type="module" id="desktop-rtl-payload">x</script>'
    Assert-Throws { Test-RtlInlineInjection $noBundle } 'inline verification fails without bundle' 'bundle'
    $badDir = New-Fixture '<script src="./assets/desktop-rtl-config.js"></script><script type="module" src="./assets/desktop-rtl-patch.js"></script>'
    Copy-Item $patch (Join-Path $badDir 'assets\desktop-rtl-patch.js'); Copy-Item $cfg (Join-Path $badDir 'assets\desktop-rtl-config.js')
    Assert-Throws { Test-RtlDirInjection $badDir } 'dir verification fails without bundle' 'bundle'
    $after = New-Fixture '<script type="module" src="/assets/app.js"></script><script id="desktop-rtl-config">window.__codexRtlConfig={};</script><script type="module" id="desktop-rtl-payload">x</script>'
    Assert-Throws { Test-RtlInlineInjection $after } 'inline verification fails after bundle' 'ordering'
    $dup = New-Fixture '<script id="desktop-rtl-config">window.__codexRtlConfig={};</script><script id="desktop-rtl-config">window.__codexRtlConfig={};</script><script type="module" id="desktop-rtl-payload">x</script><script type="module" src="/assets/app.js"></script>'
    Assert-Throws { Test-RtlInlineInjection $dup } 'inline verification fails duplicate tag' 'duplicated'

    $layout = Join-Path $temp 'layout'; $renderer = Join-Path $layout $inlineProfile.RendererDirRel
    New-Item -ItemType Directory -Force -Path $renderer | Out-Null
    [IO.File]::WriteAllText((Join-Path $renderer 'index.html'), '<script type="module" src="/assets/app.js"></script>')
    $source = [pscustomobject]@{ AppDir = $layout }
    Assert-True (Assert-RtlT3Layout -Source $source -Profile $inlineProfile) 'T3 layout accepts supported fixture'
    New-Item -ItemType Directory -Force -Path (Join-Path $layout 'resources') | Out-Null; [IO.File]::WriteAllText((Join-Path $layout 'resources\server.asar'), 'x')
    Assert-Throws { Assert-RtlT3Layout -Source $source -Profile $inlineProfile } 'T3 layout rejects server.asar' '^\[UNSUPPORTED\]'
    Remove-Item (Join-Path $layout 'resources\server.asar'); Remove-Item (Join-Path $renderer 'index.html')
    Assert-Throws { Assert-RtlT3Layout -Source $source -Profile $inlineProfile } 'T3 layout rejects missing index' '^\[LAYOUT\]'

    foreach ($id in @(Get-RtlAppIds)) {
        Set-RtlActiveApp $id | Out-Null
        Assert-True (Test-RtlWatchCommandLine "powershell -File Watch-DesktopRtl.ps1 -App $id -Loop") "watcher predicate owns $id"
    }
    $sigRoot = $inlineProfile.SourceRoots[0]
    $sigRenderer = Join-Path $sigRoot $inlineProfile.RendererDirRel
    New-Item -ItemType Directory -Force -Path $sigRenderer,(Join-Path $sigRoot 'resources') | Out-Null
    [IO.File]::WriteAllText((Join-Path $sigRoot $inlineProfile.ExeLeaf), 'x')
    [IO.File]::WriteAllBytes((Join-Path $sigRoot $inlineProfile.AsarRelPath), [byte[]](4,0,0,0))
    $sigIndex = Join-Path $sigRenderer 'index.html'
    [IO.File]::WriteAllText($sigIndex, '<script type="module" src="/assets/a.js"></script>')
    $sig1 = (Resolve-RtlSource -Profile $inlineProfile).Signature
    [IO.File]::AppendAllText($sigIndex, ' ')
    $sig2 = (Resolve-RtlSource -Profile $inlineProfile).Signature
    Assert-True ($sig1 -ne $sig2) 'direct source signature includes renderer index'

    Assert-True ((Get-RtlAppIds) -join ',' -eq 'codex,opencode,traycer,t3code,grokbot,herdr') 'profile catalog is app-id source of truth'

    # Grok Bot: asar-injection profile (like OpenCode) whose copy must always be launched
    # with SAND_DISABLE_UPDATES=1 so its own updater cannot overwrite the patched asar.
    $grok = Get-RtlProfile 'grokbot'
    Assert-True ($grok.ExeRelPath -eq 'Grok Bot.exe') 'grokbot exe rel path'
    Assert-True ($grok.AsarRelPath -eq 'resources\app.asar') 'grokbot asar rel path'
    Assert-True ($grok.NodeStrategy -eq 'electron-as-node') 'grokbot runs its own exe as node'
    Assert-True ($grok.SharedSingleInstance -eq $true) 'grokbot shares a single-instance lock'
    Assert-True ($grok.LaunchEnv.SAND_DISABLE_UPDATES -eq '1') 'grokbot disables its self-updater via LaunchEnv'
    Assert-True ($grok.LaunchScript -eq 'Launch-GrokBotRtl.vbs') 'grokbot declares a launcher script'
    Assert-True (-not $grok.RendererMode) 'grokbot patches the asar renderer (no loose/inline mode)'

    # Regression guard: extending the launch mechanism must not change how the four
    # existing apps start - they keep a direct exe shortcut and no environment override.
    foreach ($id in @('codex', 'opencode', 'traycer', 't3code')) {
        $q = Get-RtlProfile $id
        Assert-True ($null -eq $q.LaunchEnv) "$id has no launch environment"
        Assert-True ($null -eq $q.LaunchScript) "$id has no launcher script"
    }

    # The launcher is generated only for LaunchEnv profiles, sets exactly the declared
    # variables, and launches the copy's exe from the copy root.
    Set-RtlActiveApp t3code | Out-Null
    Assert-True ($null -eq (New-RtlLaunchScript)) 'no launcher is generated without LaunchEnv'
    Set-RtlActiveApp grokbot | Out-Null
    $launcher = New-RtlLaunchScript
    Assert-True ($launcher -eq (Join-Path $grok.StateDir 'Launch-GrokBotRtl.vbs')) 'launcher lands in the app state dir'
    $vbs = [IO.File]::ReadAllText($launcher)
    Assert-True ($vbs -match '(?m)^env\("SAND_DISABLE_UPDATES"\) = "1"\r?$') 'launcher sets SAND_DISABLE_UPDATES=1'
    Assert-True ($vbs -match [regex]::Escape('sh.Run """' + (Join-Path $grok.CopyRoot 'Grok Bot.exe') + '"""')) 'launcher runs the copy exe quoted'
    Assert-True ($vbs -match [regex]::Escape('sh.CurrentDirectory = "' + $grok.CopyRoot + '"')) 'launcher works from the copy root'
    Assert-True ($vbs -match 'env\.Remove "ELECTRON_RUN_AS_NODE"' -and $vbs -match 'env\.Remove "ELECTRON_NO_ASAR"') 'launcher strips the electron-as-node flags'

    # Uninstall removes the launcher even though it keeps the logs folder.
    Assert-True (Test-Path $launcher) 'launcher exists before uninstall'
    New-Item -ItemType Directory -Force -Path $grok.CopyRoot | Out-Null
    Invoke-CodexRtlUninstall | Out-Null
    Assert-True (-not (Test-Path $launcher)) 'plain uninstall removes the launcher'


    # ---- uninstall: partial (locked file) reports leftovers, not success -----
    Set-RtlActiveApp grokbot | Out-Null
    New-Item -ItemType Directory -Force -Path $grok.CopyRoot | Out-Null
    $locked = Join-Path $grok.CopyRoot 'locked.bin'
    [IO.File]::WriteAllText($locked, 'x')
    $fs = [IO.File]::Open($locked, 'Open', 'Read', 'None')   # exclusive: blocks deletion
    try {
        $res = Invoke-CodexRtlUninstall
        Assert-True (-not $res.Certain) 'uninstall with a locked file reports Certain=$false'
        Assert-True (@($res.Leftovers).Count -ge 1) 'uninstall with a locked file lists leftovers'
    } finally { $fs.Close() }
    $res2 = Invoke-CodexRtlUninstall
    Assert-True ($res2.Certain) 'uninstall after the lock is released reports Certain=$true'
    Assert-True (-not (Test-Path $grok.CopyRoot)) 'the copy root is gone after the clean uninstall'

    # ---- blocked.json: consecutive-failure latch, tool-version awareness, read-only status ----
    Set-RtlActiveApp grokbot | Out-Null
    New-Item -ItemType Directory -Force -Path $grok.StateDir | Out-Null
    Set-RtlBlocked -Signature 'sigA' -ErrorMessage '[FUSE] test'
    Assert-True ($null -eq (Test-RtlUpdateBlocked -Signature 'sigA')) 'one structural failure does NOT latch a block (transient tolerance)'
    Assert-True ((Get-RtlBlockRecord -Signature 'sigA').count -eq 1) 'the first failure is recorded (count 1) so a streak can accumulate'
    Set-RtlBlocked -Signature 'sigA' -ErrorMessage '[FUSE] test'
    Assert-True ((Get-RtlBlockRecord -Signature 'sigA').count -eq 2) 'a second consecutive same-build failure increments the count'
    Assert-True ($null -ne (Test-RtlUpdateBlocked -Signature 'sigA')) 'block latches once it reaches the consecutive threshold'
    Assert-True ($null -eq (Test-RtlUpdateBlocked -Signature 'sigB')) 'block is ignored for a different source signature (app updated)'
    # A block written by a different (older) tool version must be treated as stale.
    $stale = [ordered]@{ signature = 'sigA'; patchVersion = '0.0.0-old'; error = '[FUSE] old'; at = (Get-Date).ToString('o'); count = 9 }
    [IO.File]::WriteAllText($script:BlockedFile, (([pscustomobject]$stale) | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    Assert-True ($null -eq (Test-RtlUpdateBlocked -Signature 'sigA')) 'block from a different tool version is stale (a newer tool may handle it)'
    Assert-True ($null -eq (Get-RtlBlockRecord -Signature 'sigA')) 'a different-tool-version record is not a same-build record'
    Clear-RtlBlocked
    Assert-True (-not (Test-Path $script:BlockedFile)) 'Clear-RtlBlocked removes the file'

    # The latch set is single-sourced in Test-RtlShouldLatchError. EVERY deterministic code that
    # can reach Invoke-CodexRtlUpdate's catch must latch (or a future layout/release change storms
    # uncapped, as [ASAR]/[VERIFY]/[ARTIFACT] each did before they were added); EVERY transient or
    # out-of-scope code must NOT (or one blip disables auto-updates).
    foreach ($code in @('FUSE', 'LAYOUT', 'UNSUPPORTED', 'NODE', 'ASAR', 'VERIFY', 'ARTIFACT')) {
        Assert-True (Test-RtlShouldLatchError "[$code] something deterministic") "latch set includes deterministic [$code]"
    }
    foreach ($code in @('LOCK', 'DISK', 'AV', 'STAGING', 'INTEGRITY', 'PACKAGE', 'SAFETY', 'PROFILE', 'NOCODEX')) {
        Assert-True (-not (Test-RtlShouldLatchError "[$code] something transient or out of scope")) "latch set excludes [$code]"
    }
    Assert-True (-not (Test-RtlShouldLatchError 'a bare uncoded error')) 'an uncoded error never latches'

    # SourceMissing beats a stale block, and status never mutates state (read-only).
    Set-RtlActiveApp grokbot | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path (Join-Path $grok.CopyRoot $grok.ExeRelPath) -Parent) | Out-Null
    [IO.File]::WriteAllText((Join-Path $grok.CopyRoot $grok.ExeRelPath), 'exe')   # copy present, no source installed
    Set-RtlBlocked -Signature 'whatever' -ErrorMessage '[FUSE] leftover'
    $st = Get-CodexRtlStatus
    Assert-True ($st.State -eq 'SourceMissing') 'copy present + source gone => SourceMissing (beats a stale block)'
    Assert-True (Test-Path $script:BlockedFile) 'Get-CodexRtlStatus does NOT delete blocked.json (read-only)'
    Remove-Item $script:BlockedFile -Force -ErrorAction SilentlyContinue
    Remove-Item $grok.CopyRoot -Recurse -Force -ErrorAction SilentlyContinue

    # ---- Get-CodexRtlStatus returns the real 'Blocked' state (resolvable source + valid state
    #      + latched block) and stays read-only there - the path the SourceMissing case never reaches.
    Set-RtlActiveApp grokbot | Out-Null
    $grokSrc = $grok.SourceRoots[0]
    New-Item -ItemType Directory -Force -Path (Join-Path $grokSrc 'resources') | Out-Null
    [IO.File]::WriteAllText((Join-Path $grokSrc 'resources\app.asar'), 'fake-asar')   # resolvable source (asar + exe)
    [IO.File]::WriteAllText((Join-Path $grokSrc $grok.ExeLeaf), 'exe')
    $bsrc = Resolve-RtlSource
    Assert-True ($null -ne $bsrc) 'grokbot source resolves from a faked install tree'
    New-Item -ItemType Directory -Force -Path (Split-Path (Join-Path $grok.CopyRoot $grok.ExeRelPath) -Parent) | Out-Null
    [IO.File]::WriteAllText((Join-Path $grok.CopyRoot $grok.ExeRelPath), 'exe')   # copy present
    $stateObj = [ordered]@{ schemaVersion = $script:SchemaVersion; sourceSignature = $bsrc.Signature; codexVersion = $bsrc.Version; patchVersion = $script:PatchVersion }
    [IO.File]::WriteAllText($script:StateFile, (([pscustomobject]$stateObj) | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    Set-RtlBlocked -Signature $bsrc.Signature -ErrorMessage '[VERIFY] injected payload missing'
    Set-RtlBlocked -Signature $bsrc.Signature -ErrorMessage '[VERIFY] injected payload missing'   # reach the threshold
    $stB = Get-CodexRtlStatus
    Assert-True ($stB.State -eq 'Blocked') 'resolvable source + valid state + latched block => Blocked'
    Assert-True ($stB.BlockedError -match 'VERIFY') 'Blocked status surfaces the recorded error'
    Assert-True (Test-Path $script:BlockedFile) 'status does NOT delete blocked.json on the Blocked path (read-only)'
    Assert-True ($null -ne (Get-RtlBlockRecord -Signature $bsrc.Signature)) 'blocked.json still a valid same-build record after a status read'
    Remove-Item $script:BlockedFile -Force -ErrorAction SilentlyContinue
    Remove-Item $script:StateFile -Force -ErrorAction SilentlyContinue
    Remove-Item $grokSrc -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $grok.CopyRoot -Recurse -Force -ErrorAction SilentlyContinue

    # ---- enumeration / logging must not create state folders -----------------
    Set-RtlActiveApp opencode | Out-Null
    Remove-Item $script:StateDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $script:CopyRoot $script:ActiveProfile.ExeRelPath) -Force -ErrorAction SilentlyContinue
    [void](Get-RtlInstalledApps)
    Assert-True (-not (Test-Path $script:StateDir)) 'Get-RtlInstalledApps does not create a state folder'
    Write-RtlLog 'harness: log with no state dir'
    Assert-True (-not (Test-Path $script:StateDir)) 'Write-RtlLog does not create the state folder when it is absent'

    # ---- fuseoff: flips one byte, idempotent, refuses paths outside --root ----
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if ($node) {
        $fuseDir = Join-Path $temp 'fuse'; New-Item -ItemType Directory -Force -Path $fuseDir | Out-Null
        # Copy the editor into the ASCII temp tree: node on Windows can fail to resolve a
        # module path that contains non-ASCII characters (the repo path has Hebrew), which
        # is a test-harness artifact, not a product issue (the deployed bin path is ASCII).
        # NB: $repo is clobbered after the dot-source ($script:Repo in the lib aliases it,
        # PS vars are case-insensitive), so derive the source path from $PSScriptRoot.
        $editor = Join-Path $fuseDir 'asar-edit.mjs'
        Copy-Item (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\lib\asar-edit.mjs') $editor -Force
        $fake = Join-Path $fuseDir 'fake.bin'
        $sentinel = [Text.Encoding]::ASCII.GetBytes('dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX')  # sentinel is pure ASCII (PS 5.1 has no ::Latin1)
        $bytes = [byte[]]@(0x41) * 64 + $sentinel + [byte[]]@(1, 9) + [Text.Encoding]::ASCII.GetBytes('010011001') + [byte[]]@(0x42) * 16
        [IO.File]::WriteAllBytes($fake, $bytes)
        $before = (Get-Item $fake).Length
        # node writes to stderr on the refusal path; under -ErrorActionPreference Stop that
        # becomes a terminating NativeCommandError, so relax it just for these native calls.
        $savedEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            & $node $editor fuseoff $fake '--root' $fuseDir *> $null
            Assert-True ($LASTEXITCODE -eq 0) 'fuseoff exits 0 on a valid wire under --root'
            Assert-True ((Get-Item $fake).Length -eq $before) 'fuseoff keeps the file length unchanged'
            & $node $editor fusestate $fake *> $null
            Assert-True ($LASTEXITCODE -eq 0) 'fusestate reports the fuse disabled after the flip'
            & $node $editor fuseoff $fake '--root' $fuseDir *> $null
            Assert-True ($LASTEXITCODE -eq 0) 'fuseoff is a no-op success when already disabled'
            & $node $editor fuseoff $fake '--root' (Join-Path $temp 'other-root') *> $null
            Assert-True ($LASTEXITCODE -eq 22) 'fuseoff refuses a target outside --root'
        } finally { $ErrorActionPreference = $savedEap }
    } else {
        Write-Host '  (node not on PATH; skipping fuseoff CLI checks)'
    }

    # ---- tray quit event: signal, dispose, reopen must be un-signaled --------
    # Use a UNIQUE per-run name, NEVER the production 'Local\DesktopRtlTrayQuit'. That event
    # is session-global, so on a machine with a live tray this test would (a) Set() it and quit
    # the real tray, and (b) never destroy the object on Dispose (the tray still holds a handle),
    # breaking the isolation check. A unique name verifies the same create/Set/Dispose/reopen
    # semantics without touching a running tray.
    $quitName = "Local\DesktopRtlTrayQuitTest_$([guid]::NewGuid().ToString('N'))"
    $ev = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $quitName)
    [void]$ev.Set(); $ev.Dispose()
    $ev2 = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $quitName)
    try { Assert-True (-not $ev2.WaitOne(0)) 'a fresh quit-event handle is not signaled after the prior one was disposed' } finally { $ev2.Dispose() }

    New-Item -ItemType Directory -Force -Path (Join-Path $temp 'empty-artifact') | Out-Null

    # ---- Herdr: prebuilt native-binary profile -------------------------------
    $herdr = Get-RtlProfile 'herdr'
    Assert-True ($herdr.RendererMode -eq 'prebuilt') 'herdr installs a prebuilt binary'
    Assert-True ($herdr.SourceKind -eq 'herdr') 'herdr uses its own source resolver'
    Assert-True ($herdr.ExeRelPath -eq 'herdr.exe') 'herdr exe rel path'
    Assert-True ($null -eq $herdr.AsarRelPath) 'herdr declares no asar'
    Assert-True ($herdr.NodeStrategy -eq 'none') 'herdr needs no node runtime'
    Assert-True ($herdr.AssertFuseOff -eq $false) 'herdr has no fuse guard'
    Assert-True ($null -eq $herdr.UserDataDir) 'herdr has no electron cache to clear'
    Assert-True ($herdr.WatcherRunName -eq 'HerdrRtlPatchWatcher') 'herdr watcher run name'
    Assert-True ($herdr.PrebuiltRepo -eq 'ElazarKrispel/herdr') 'herdr prebuilt repo'

    # Version parsing off a standalone release path.
    Assert-True ((Get-HerdrVersionFromPath -Path 'C:\u\.herdr\packages\standalone\releases\0.8.2-x86_64-pc-windows-msvc\herdr.exe') -eq '0.8.2') 'herdr version parsed from release path'
    Assert-True ($null -eq (Get-HerdrVersionFromPath -Path 'C:\tools\herdr.exe')) 'herdr version parse declines a plain path'

    # Settings mapping.
    Assert-True ((Get-HerdrBidiValue -Config ([pscustomobject]@{ enabled = $true; direction = [pscustomobject]@{ policy = 'anyHebrew' } })) -eq 'ltr') 'anyHebrew maps to bidi=ltr'
    Assert-True ((Get-HerdrBidiValue -Config ([pscustomobject]@{ enabled = $true; direction = [pscustomobject]@{ policy = 'firstStrong' } })) -eq 'auto') 'firstStrong maps to bidi=auto'
    Assert-True ((Get-HerdrBidiValue -Config ([pscustomobject]@{ enabled = $false; direction = [pscustomobject]@{ policy = 'anyHebrew' } })) -eq 'off') 'disabled maps to bidi=off'
    Assert-True ((Get-HerdrBidiValue -Config $null) -eq 'ltr') 'missing settings default to bidi=ltr'
    # Regression: Read-RtlConfig hands back ordered dictionaries, not PSCustomObjects,
    # and reading them as objects silently reported every app as enabled.
    Set-RtlActiveApp 'herdr' | Out-Null
    $liveCfg = Read-RtlConfig
    Assert-True ($liveCfg.apps.herdr -is [System.Collections.IDictionary]) 'live settings are a dictionary'
    Assert-True ((Get-HerdrBidiValue -Config $liveCfg.apps.herdr) -eq 'ltr') 'live default settings map to bidi=ltr'
    $liveCfg.apps.herdr.enabled = $false
    Assert-True ((Get-HerdrBidiValue -Config $liveCfg.apps.herdr) -eq 'off') 'live disabled settings map to bidi=off'
    $liveCfg.apps.herdr.enabled = $true
    $liveCfg.apps.herdr.direction.policy = 'firstStrong'
    Assert-True ((Get-HerdrBidiValue -Config $liveCfg.apps.herdr) -eq 'auto') 'live firstStrong maps to bidi=auto'

    # TOML key writer: append, replace, and never disturb the rest of the file.
    $t1 = Set-HerdrTomlKey -Text '' -Section 'terminal' -Key 'bidi' -Value 'ltr'
    Assert-True ($t1 -match '(?m)^\[terminal\]\r?$' -and $t1 -match '(?m)^bidi = "ltr"\r?$') 'toml writer creates the table'
    $t2 = Set-HerdrTomlKey -Text $t1 -Section 'terminal' -Key 'bidi' -Value 'auto'
    Assert-True (($t2 -split "`r`n|`n" | Where-Object { $_ -match '^bidi = ' }).Count -eq 1) 'toml writer replaces rather than duplicates'
    Assert-True ($t2 -match '(?m)^bidi = "auto"\r?$') 'toml writer wrote the new value'
    $existing = "[terminal]`r`ndefault_shell = `"pwsh`"`r`n`r`n[ui.toast]`r`ndelivery = `"off`"`r`n"
    $t3 = Set-HerdrTomlKey -Text $existing -Section 'terminal' -Key 'bidi' -Value 'ltr'
    Assert-True ($t3 -match 'default_shell = "pwsh"') 'toml writer keeps other keys in the table'
    Assert-True ($t3 -match '\[ui\.toast\]' -and $t3 -match 'delivery = "off"') 'toml writer keeps later tables'
    Assert-True ($t3 -match '(?m)^bidi = "ltr"\r?$') 'toml writer adds the key to an existing table'
    $t4 = Set-HerdrTomlKey -Text "[ui]`r`nx = 1`r`n" -Section 'terminal' -Key 'bidi' -Value 'off'
    Assert-True ($t4 -match '(?m)^\[terminal\]\r?$' -and $t4 -match 'x = 1') 'toml writer appends a missing table'

    # Source resolution against a fake standalone install.
    $fakeRel = Join-Path $temp 'fakeherdr\packages\standalone\releases\9.9.9-x86_64-pc-windows-msvc'
    New-Item -ItemType Directory -Force -Path $fakeRel | Out-Null
    [IO.File]::WriteAllText((Join-Path $fakeRel 'herdr.exe'), 'not a real binary')
    $fakeProfile = Get-RtlProfile 'herdr'
    $fakeProfile.SourceRoots = @($fakeRel)
    $fakeSrc = Resolve-HerdrSource -Profile $fakeProfile
    Assert-True ($null -ne $fakeSrc) 'herdr source resolves from a standalone release tree'
    Assert-True ($fakeSrc.Version -eq '9.9.9') 'herdr source reports the release version'
    Assert-True ($fakeSrc.Type -eq 'Herdr') 'herdr source type'
    Assert-True ($fakeSrc.Signature -like 'herdr:9.9.9|rtl=*') 'herdr signature folds in version and rtl build'
    Assert-True ($null -eq $fakeSrc.AsarPath) 'herdr source has no asar path'
    $missing = Get-RtlProfile 'herdr'
    $missing.SourceRoots = @((Join-Path $temp 'nope'))
    Assert-True ($null -eq (Resolve-HerdrSource -Profile $missing)) 'herdr source returns null when not installed'

    # Watch paths follow the binary, not an asar.
    Assert-True ((Get-RtlSourceWatchPaths -Profile $fakeProfile -Source $fakeSrc) -contains $fakeSrc.ExePath) 'herdr watches the installed binary'

    # Structural validation accepts a binary-only source and rejects a missing exe.
    Assert-True (Test-CodexSource -Source $fakeSrc -Profile $fakeProfile) 'herdr source passes validation'
    $broken = [pscustomobject]@{ Type = 'Herdr'; Version = '1'; Signature = 's'; AppDir = $fakeRel; AsarPath = $null; ExePath = (Join-Path $fakeRel 'gone.exe') }
    Assert-Throws { Test-CodexSource -Source $broken -Profile $fakeProfile } 'herdr validation rejects a missing binary' 'LAYOUT'

    # Artifact discovery.
    $artRoot = Join-Path $temp 'artifact-root'
    New-Item -ItemType Directory -Force -Path (Join-Path $artRoot 'inner') | Out-Null
    [IO.File]::WriteAllText((Join-Path $artRoot 'inner\herdr.exe'), 'x')
    Assert-True ((Find-HerdrExeRoot -Root $artRoot) -eq (Join-Path $artRoot 'inner')) 'artifact root found one level down'
    Assert-Throws { Find-HerdrExeRoot -Root (Join-Path $temp 'empty-artifact') } 'artifact root rejects a tree without herdr.exe' 'ARTIFACT'

    # The safety guard still refuses to write outside our own staging or copy.
    Set-RtlActiveApp 'herdr' | Out-Null
    Assert-Throws { Assert-RtlWriteAllowed -Path (Join-Path $fakeRel 'herdr.exe') -Profile $herdr } 'herdr write guard refuses the official install' 'SAFETY'
    Assert-True (Assert-RtlWriteAllowed -Path (Join-Path $herdr.Staging 'herdr.exe') -Profile $herdr) 'herdr write guard allows staging'

    # Private data locations never overlap the official ones.
    $dataDir = Get-HerdrRtlDataDir -Profile $herdr
    $cfgPath = Get-HerdrRtlConfigPath -Profile $herdr
    Assert-True ($dataDir.StartsWith($herdr.StateDir, [StringComparison]::OrdinalIgnoreCase)) 'herdr private data lives under our state dir'
    Assert-True ($cfgPath -like '*\data\herdr\config.toml') 'herdr private config path'
    Assert-True (-not $cfgPath.StartsWith((Join-Path $env:APPDATA 'herdr'), [StringComparison]::OrdinalIgnoreCase)) 'herdr private config is not the official one'

    # The generated launcher isolates config and state, and runs the copy.
    $cmdPath = New-HerdrRtlLauncher -Profile $herdr
    $cmdText = [IO.File]::ReadAllText($cmdPath)
    Assert-True ($cmdText -match 'set "XDG_CONFIG_HOME=') 'launcher sets XDG_CONFIG_HOME'
    Assert-True ($cmdText -match 'set "XDG_STATE_HOME=') 'launcher sets XDG_STATE_HOME'
    Assert-True ($cmdText -match [regex]::Escape($herdr.CopyRoot)) 'launcher runs the RTL copy'
    Assert-True (-not ($cmdText -match [regex]::Escape((Join-Path $env:APPDATA 'herdr')))) 'launcher never points at the official state'

    # The shortcut window closes the instant the script ends, so a failure would be
    # invisible. Both failure paths have to hold the window open instead.
    Assert-True ($cmdText -match '(?m)^if not exist ') 'launcher checks the exe is there'
    Assert-True ($cmdText -match '(?m)^if errorlevel 1 \(') 'launcher reacts to a non-zero exit'
    Assert-True (([regex]::Matches($cmdText, '(?m)^\s*pause\s*$')).Count -eq 2) 'both launcher failure paths pause'

    # The shortcut must be launchable. Windows Terminal starts its command with
    # CreateProcess, which cannot execute a .cmd at all, so handing the launcher
    # straight to wt.exe fails with "the system cannot find the file specified".
    New-HerdrRtlShortcut -Profile $herdr
    Assert-True (Test-Path $script:ShortcutStart) 'herdr shortcut is created'
    $shellLink = (New-Object -ComObject WScript.Shell).CreateShortcut($script:ShortcutStart)
    Assert-True ($shellLink.TargetPath -like '*\cmd.exe') 'herdr shortcut runs the launcher through cmd.exe'
    Assert-True ($shellLink.Arguments -match '(?i)^/c "') 'herdr shortcut passes /c to the shell'
    Assert-True ($shellLink.Arguments -match [regex]::Escape('Herdr-RTL.cmd')) 'herdr shortcut points at the launcher'
    Assert-True (-not ($shellLink.TargetPath -like '*wt.exe')) 'herdr shortcut never hands a .cmd to Windows Terminal'
    # A shortcut window that starts inside the copy pins that folder for as long
    # as it is open, and then the copy can be neither replaced nor removed.
    Assert-True ($shellLink.WorkingDirectory -ne $herdr.CopyRoot -and -not $shellLink.WorkingDirectory.StartsWith($herdr.CopyRoot)) 'herdr shortcut never starts inside the copy'
    # herdr.exe has no icon resource, so the shortcut must carry our wordmark .ico,
    # placed in the state dir (never inside the copy).
    Assert-True ($shellLink.IconLocation -match 'herdr-rtl\.ico') 'herdr shortcut uses the wordmark icon'
    Assert-True (Test-Path (Join-Path $herdr.StateDir 'herdr-rtl.ico')) 'wordmark icon is placed in the state dir'

    # Settings write end to end.
    $written = Sync-HerdrRtlConfig -Source $fakeSrc -Profile $herdr
    Assert-True ($written -eq 'ltr') 'config sync returns the applied mode'
    Assert-True ((([IO.File]::ReadAllText($cfgPath)) -match '(?m)^bidi = "ltr"\r?$')) 'config sync wrote bidi into the private config'

    # Uninstall clears everything we created for herdr.
    New-Item -ItemType Directory -Force -Path $herdr.CopyRoot | Out-Null
    Invoke-CodexRtlUninstall | Out-Null
    Assert-True (-not (Test-Path $herdr.CopyRoot)) 'herdr uninstall removes the copy'
    Assert-True (-not (Test-Path $cmdPath)) 'herdr uninstall removes the launcher'

    # The suite must never touch the real Start menu or Desktop.
    Set-RtlActiveApp 'herdr' | Out-Null
    $realPrograms = [Environment]::GetFolderPath('Programs')
    Assert-True (-not $script:ShortcutStart.StartsWith($realPrograms, [StringComparison]::OrdinalIgnoreCase)) 'tests never write to the real Start menu'
    Assert-True ($script:ShortcutStart.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) 'test shortcuts stay in the temp tree'

    Write-Host "PASS: $script:passed assertions"
} finally {
    $env:LOCALAPPDATA = $oldLocal; $env:APPDATA = $oldRoam
    if (Test-Path $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
