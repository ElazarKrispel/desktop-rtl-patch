$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('rtl-renderer-tests-' + [guid]::NewGuid().ToString('N'))
$oldLocal = $env:LOCALAPPDATA; $oldRoam = $env:APPDATA
$env:LOCALAPPDATA = Join-Path $temp 'local'; $env:APPDATA = Join-Path $temp 'roaming'
. (Join-Path $repo 'scripts\lib\desktop-rtl-lib.ps1')

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

    Assert-True ((Get-RtlAppIds) -join ',' -eq 'codex,opencode,traycer,t3code,grokbot') 'profile catalog is app-id source of truth'

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

    Write-Host "PASS: $script:passed assertions"
} finally {
    $env:LOCALAPPDATA = $oldLocal; $env:APPDATA = $oldRoam
    if (Test-Path $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
