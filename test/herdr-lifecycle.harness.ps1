$ErrorActionPreference = 'Stop'
$testRepo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'isolated-test-support.ps1')
$testRoot = Initialize-RtlTestSandbox -RepositoryRoot $testRepo
$checks = 0
function Assert-HerdrCase([bool]$Value,[string]$Name) {
    if (-not $Value) { throw "FAIL: $Name" }
    $script:checks++
}
try {
    . (Join-Path $testRepo 'scripts\lib\desktop-rtl-lib.ps1')
    Set-RtlTestProductBoundaries
    Set-RtlActiveApp herdr
    $profile = Get-RtlProfile herdr
    [void][IO.Directory]::CreateDirectory($script:CopyRoot)
    [IO.File]::WriteAllText((Join-Path $script:CopyRoot 'herdr.exe'),'never execute this synthetic file')
    $config = Get-RtlDefaultConfig
    $config.apps.herdr.direction.policy = 'firstStrong'
    Write-RtlConfig $config
    $rtlConfigPath = $script:ConfigFile
    $rtlConfigBefore = [IO.File]::ReadAllText($rtlConfigPath)
    $cmd = New-HerdrRtlLauncher
    $userConfigPath = Get-HerdrRtlConfigPath
    [void][IO.Directory]::CreateDirectory((Split-Path $userConfigPath -Parent))
    $userConfig = "# personal settings`r`n[terminal]`r`nbidi = `"auto`"`r`ndefault_shell = `"pwsh`"`r`n[ui]`r`ntheme = `"custom`"`r`n"
    [IO.File]::WriteAllText($userConfigPath,$userConfig)
    $sessionPath = Join-Path (Split-Path $userConfigPath -Parent) 'session.json'
    [IO.File]::WriteAllText($sessionPath,'{"fixture":"saved session"}')
    $statePath = Join-Path (Get-HerdrRtlStateHome) 'valuable-state'
    [IO.File]::WriteAllText($statePath,'saved state')
    $logs = Join-Path $script:LogsDir 'fixture.log'
    [void][IO.Directory]::CreateDirectory($script:LogsDir)
    [IO.File]::WriteAllText($logs,'log to purge')
    $result = Invoke-CodexRtlUninstall -PurgeLogs
    Assert-HerdrCase $result.Certain 'synthetic uninstall completes'
    Assert-HerdrCase ([IO.File]::Exists($userConfigPath)) 'default uninstall preserves private config'
    Assert-HerdrCase ([IO.File]::ReadAllText($userConfigPath) -eq $userConfig) 'private config bytes survive uninstall'
    Assert-HerdrCase ([IO.File]::ReadAllText($sessionPath) -eq '{"fixture":"saved session"}') 'private session survives uninstall'
    Assert-HerdrCase ([IO.File]::ReadAllText($statePath) -eq 'saved state') 'private state survives uninstall'
    Assert-HerdrCase ([IO.File]::ReadAllText($rtlConfigPath) -eq $rtlConfigBefore) 'RTL preferences survive uninstall'
    Assert-HerdrCase (-not [IO.File]::Exists($logs)) 'PurgeLogs removes only synthetic logs'
    Assert-HerdrCase (@(Get-RtlInstalledApps).Count -eq 0) 'retained data alone is not an installed application'
    # Execute the CLI's actual operation/lifecycle tail after replacing only its
    # loading preamble with our already initialized library and agent boundaries.
    # In particular, this exercises the code AFTER engine uninstall with PurgeLogs.
    $cliAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $testRepo 'scripts\Uninstall-DesktopRtl.ps1'),[ref]$null,[ref]$null)
    $start = @($cliAst.EndBlock.Statements | Where-Object { $_.Extent.Text -match '^Start-RtlInstallLog ' })[0].Extent.StartOffset
    if (-not $start) { throw 'CLI operation boundary was not found; review the test extraction.' }
    $tail = $cliAst.Extent.Text.Substring($start)
    function Invoke-RtlAgentLastCleanup { }
    function Register-RtlAgent { }
    function Restart-RtlAgentTray { }
    $appName = 'Herdr'; $PurgeLogs = $true
    & ([scriptblock]::Create($tail))
    Assert-HerdrCase ([IO.File]::ReadAllText($userConfigPath) -eq $userConfig) 'CLI PurgeLogs keeps the private config after agent lifecycle'
    Assert-HerdrCase ([IO.File]::ReadAllText($rtlConfigPath) -eq $rtlConfigBefore) 'CLI PurgeLogs keeps RTL preferences'
    # Recreate only software; the real config sync must reuse personal settings.
    [void][IO.Directory]::CreateDirectory($script:CopyRoot)
    [IO.File]::WriteAllText((Join-Path $script:CopyRoot 'herdr.exe'),'synthetic')
    $mode = Sync-HerdrRtlConfig -Source $null
    Assert-HerdrCase ($mode -eq 'auto') 'reinstall keeps the user chosen RTL policy'
    Assert-HerdrCase ([IO.File]::ReadAllText($userConfigPath) -eq $userConfig) 'unchanged bidi policy preserves full TOML bytes'

    # Capture only the launch request; no application, cmd.exe or terminal starts.
    $script:CapturedLaunch = $null
    function Start-Process {
        [CmdletBinding()] param($FilePath,$ArgumentList,$WorkingDirectory)
        $script:CapturedLaunch = [pscustomobject]@{FilePath=$FilePath;Arguments=$ArgumentList;WorkingDirectory=$WorkingDirectory}
    }
    $beforeXdg = $env:XDG_CONFIG_HOME
    Assert-HerdrCase (Start-RtlCopyApp) 'central Open accepts the synthetic installed copy'
    Assert-HerdrCase ($script:CapturedLaunch.FilePath -like '*\cmd.exe') 'central Open goes through the terminal launcher'
    Assert-HerdrCase ($script:CapturedLaunch.Arguments -match 'Herdr-RTL\.cmd') 'central Open uses the isolated launcher'
    Assert-HerdrCase ($script:CapturedLaunch.WorkingDirectory -eq $env:USERPROFILE) 'central Open does not pin the copy directory'
    Assert-HerdrCase ($env:XDG_CONFIG_HOME -eq $beforeXdg) 'central Open leaves parent XDG unchanged'
    New-HerdrRtlShortcut
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($script:ShortcutStart)
    Assert-HerdrCase ($shortcut.TargetPath -eq $script:CapturedLaunch.FilePath -and $shortcut.Arguments -eq $script:CapturedLaunch.Arguments -and $shortcut.WorkingDirectory -eq $script:CapturedLaunch.WorkingDirectory) 'shortcut and central Open share the launch plan'
    $launcherText = [IO.File]::ReadAllText((Join-Path $script:StateDir 'Herdr-RTL.cmd'))
    Assert-HerdrCase ($launcherText.Contains('set "XDG_CONFIG_HOME=' + (Get-HerdrRtlDataDir) + '"')) 'launcher selects private config'
    Assert-HerdrCase ($launcherText.Contains('set "XDG_STATE_HOME=' + (Get-HerdrRtlStateHome) + '"')) 'launcher selects private state'
    function Start-Process { throw 'synthetic launch failure' }
    $failed = $false
    try { [void](Start-RtlCopyApp) } catch { $failed = $_.Exception.Message -eq 'synthetic launch failure' }
    Assert-HerdrCase $failed 'launch failure does not return success'

    # All profiles retain RTL preferences, not just Herdr. Shared profile fixtures
    # are outside their copy roots and must also survive ordinary uninstall.
    foreach ($appId in @(Get-RtlAppIds)) {
        Set-RtlActiveApp $appId
        $prefs = Get-RtlDefaultConfig
        $prefs.apps.$appId.enabled = $false
        Write-RtlConfig $prefs
        $prefsPath = $script:ConfigFile
        $prefsBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($prefsPath))
        $sharedMarker = $null
        if ($script:ActiveProfile.UserDataDir) {
            [void][IO.Directory]::CreateDirectory($script:ActiveProfile.UserDataDir)
            $sharedMarker = Join-Path $script:ActiveProfile.UserDataDir 'user-data-fixture'
            [IO.File]::WriteAllText($sharedMarker,'valuable data')
        }
        [void](Invoke-CodexRtlUninstall)
        Assert-HerdrCase ([Convert]::ToBase64String([IO.File]::ReadAllBytes($prefsPath)) -eq $prefsBytes) "$appId retains RTL preference bytes"
        if ($sharedMarker) { Assert-HerdrCase ([IO.File]::ReadAllText($sharedMarker) -eq 'valuable data') "$appId retains shared application data" }
    }
    Set-RtlActiveApp herdr
    $script:StateDir = Join-Path $testRoot ('user-' + [char]0x05e2 + [char]0x05d1 + [char]0x05e8 + [char]0x05d9 + [char]0x05ea + ' space')
    $unicodeLauncher = New-HerdrRtlLauncher
    $unicodeBytes = [IO.File]::ReadAllBytes($unicodeLauncher)
    $unicodeText = [Text.Encoding]::UTF8.GetString($unicodeBytes)
    Assert-HerdrCase ($unicodeText.Contains($script:StateDir)) 'UTF-8 launcher preserves a Hebrew path with spaces'
    Assert-HerdrCase ($unicodeText.StartsWith('@chcp 65001') -and $unicodeBytes[0] -eq 64) 'launcher keeps chcp first without a BOM'
    Assert-RtlTestIsolation
} finally { Complete-RtlTestSandbox }
Write-Host "PASS: $checks Herdr lifecycle assertions (synthetic files and captured launch only)"
