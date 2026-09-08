[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$source = Join-Path $repo 'scripts\lib\desktop-rtl-lib.ps1'
if ((Get-FileHash $source -Algorithm SHA256).Hash -ne '863933955B0A29462925040950C9B7111AA57181B70A7A966182885C10BB0549') { throw 'Source changed: audit extraction and assumptions before running.' }
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'Product source parse failed.' }
$defs = @{}
$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object { $defs[$_.Name] = $_.Extent.Text }
$run = Join-Path $PSScriptRoot ('fixture-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($run)
$results = @()
function Assert-FixturePath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($run + '\',[StringComparison]::OrdinalIgnoreCase)) { throw ('Outside fixture: ' + $full) }
    return $full
}
function Write-Fixture([string]$Path,[string]$Text='synthetic') {
    $full = Assert-FixturePath $Path
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    [IO.File]::WriteAllText($full,$Text)
}
# Uninstall boundaries are stubbed. Only fixture-owned file deletion is real.
$results += & {
    foreach($name in @('Invoke-CodexRtlUninstall','Get-RtlInstalledApps')) { . ([scriptblock]::Create($defs[$name])) }
    function Test-CodexRtlRunning { return $false }
    function Enter-RtlLock { return $true }
    function Exit-RtlLock {}
    function Stop-CodexRtlWatcher {}
    function Remove-RtlCopyShellRegistrations { param($CopyRoot) return @() }
    function Get-ItemProperty { param($Path,$Name,$ErrorAction) return $null }
    function Write-RtlLog { param($Message) }
    function Write-RtlAgentLog { param($Message) }
    function Get-RtlAppIds { return 'fixture' }
    function Get-RtlProfile { param($id) return $script:ActiveProfile }
    function Remove-Item {
        [CmdletBinding()] param([string]$LiteralPath,[switch]$Recurse,[switch]$Force)
        $safe = Assert-FixturePath $LiteralPath
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $safe -Recurse:$Recurse -Force:$Force -ErrorAction Stop
    }
    function Reset-Fixture([string]$Case,[string]$Mode) {
        $script:StateDir = Join-Path $run $Case
        $script:CopyRoot = Join-Path $script:StateDir 'copy'
        $script:Staging = Join-Path $script:StateDir 'staging'
        $script:OldRoot = Join-Path $script:StateDir 'old'
        $script:BinDir = Join-Path $script:StateDir 'bin'
        $script:StateFile = Join-Path $script:StateDir 'state.json'
        $script:ConfigFile = Join-Path $script:StateDir 'config.json'
        $script:ConfigAppliedMarker = Join-Path $script:StateDir 'config-applied'
        $script:BlockedFile = Join-Path $script:StateDir 'blocked.json'
        $script:LogsDir = Join-Path $script:StateDir 'logs'
        $script:ShortcutPaths = @(Join-Path $script:StateDir 'fake-shortcut.lnk')
        $script:RunKey = 'STUB-ONLY'
        $script:ActiveProfile = [pscustomobject]@{ Id='fixture';DisplayName='Fixture';CopyRoot=$script:CopyRoot;StateDir=$script:StateDir;ExeRelPath='app.exe';RendererMode=$Mode;LaunchScript=$null;WatcherRunName='FixtureOnly' }
        Write-Fixture (Join-Path $script:CopyRoot 'app.exe')
        Write-Fixture $script:StateFile '{}'
        Write-Fixture $script:ConfigFile '{}'
        Write-Fixture $script:ShortcutPaths[0]
    }
    Reset-Fixture 'partial' 'asar'
    $lockPath = Join-Path $script:CopyRoot 'z-locked.dat'
    Write-Fixture $lockPath
    $lock = [IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $before = @(Get-RtlInstalledApps)
        $res = Invoke-CodexRtlUninstall
        [pscustomobject]@{id='F02';scenario='Real Windows file lock inside synthetic copy; real recursive deletion';certain=$res.Certain;leftoverCount=@($res.Leftovers).Count;exeExists=(Test-Path (Join-Path $script:CopyRoot 'app.exe'));lockedFileExists=(Test-Path $lockPath);stateExists=(Test-Path $script:StateFile);configExists=(Test-Path $script:ConfigFile);shortcutExists=(Test-Path $script:ShortcutPaths[0]);installedBefore=$before;installedAfter=@(Get-RtlInstalledApps);expected='Partial must preserve a discoverable management record';limitations='Function extracted via AST; registry, watchers, locks and log sinks stubbed. Windows non-exe file lock and filesystem removal are real; UI restart not run.'}
    } finally { $lock.Dispose() }
    Reset-Fixture 'herdr' 'prebuilt'
    $config = Join-Path $script:StateDir 'data\herdr\config.toml'
    $session = Join-Path $script:StateDir 'data\herdr\session.json'
    $state = Join-Path $script:StateDir 'state\session-marker'
    Write-Fixture $config 'theme = "custom-user-theme"'
    Write-Fixture $session '{"fixture":"user-session"}'
    Write-Fixture $state 'private-state'
    $res = Invoke-CodexRtlUninstall
    [pscustomobject]@{id='F03';scenario='Default prebuilt uninstall; synthetic private user data';certain=$res.Certain;customConfigExists=(Test-Path $config);sessionExists=(Test-Path $session);privateStateExists=(Test-Path $state);expected='Default software removal preserves valuable private data';limitations='Actual synthetic file deletion through extracted uninstall; no Herdr process, upstream binary or original profile involved.'}
}
$results += & {
    . ([scriptblock]::Create($defs['Invoke-CodexRtlUpdate']))
    function Enter-RtlLock { return $false }
    function Write-RtlLog { param($Message) }
    $out = @(Invoke-CodexRtlUpdate -Force)
    [pscustomobject]@{id='F04';scenario='Lock acquisition returns false';outputCount=$out.Count;threw=$false;expected='Explicit Busy result, without downstream success';limitations='Lock boundary is stubbed. Underlying OS lock contention and GUI rendering not run.'}
}
$results += & {
    . ([scriptblock]::Create($defs['Get-CodexRtlStatus']))
    function Resolve-RtlSource { return [pscustomobject]@{Version='fixture';Signature='fixture'} }
    function Read-RtlState { return $null }
    function Test-CodexRtlRunning { return $false }
    function Test-RtlUpdateBlocked { param($Signature) return [pscustomobject]@{error='[ASAR] fixture block'} }
    $script:CopyRoot = Join-Path $run 'blocked-status\copy'
    $script:StateFile = Join-Path $run 'blocked-status\state.json'
    $script:ActiveProfile = [pscustomobject]@{ExeRelPath='app.exe'}
    $st = Get-CodexRtlStatus
    [pscustomobject]@{id='N03';scenario='Valid current block; source exists; missing state and exe';state=$st.State;blockedError=$st.BlockedError;expected='Installation state may be Fresh but valid update block must remain visible';limitations='Extracted status, source/state/block boundaries stubbed; UI analyzed statically.'}
}
$results += & {
    foreach($name in @('Remove-RtlCopyShellRegistrations','Get-RtlCommandExePath','Test-RtlPathUnderRoot','ConvertTo-RtlCanonicalPath')) { . ([scriptblock]::Create($defs[$name])) }
    $copyRoot = Join-Path $run 'registry-copy'
    $key = 'HKEY_CURRENT_USER\Software\Classes\CLSID\{00000000-0000-0000-0000-000000000001}'
    $psKey = 'Microsoft.PowerShell.Core\Registry::' + $key
    $fakeKeys = @{}
    $fakeKeys[$psKey] = @{''='Unowned display value'}
    $fakeKeys[$psKey + '\LocalServer32'] = @{''=('"' + $copyRoot + '\app.exe"')}
    $fakeKeys[$psKey + '\ForeignSibling'] = @{''='unowned data'}
    $deletes = New-Object System.Collections.Generic.List[object]
    function reg { return ($key + '\LocalServer32') }
    function Join-Path { param([string]$Path,[string]$ChildPath) return ($Path.TrimEnd('\') + '\' + $ChildPath) }
    function Test-Path { param([string]$LiteralPath) return $fakeKeys.ContainsKey($LiteralPath) }
    function Get-Item {
        param([string]$LiteralPath,$ErrorAction)
        if (-not $fakeKeys.ContainsKey($LiteralPath)) { throw 'Absent fake key' }
        $o = [pscustomobject]@{Values=$fakeKeys[$LiteralPath]}
        $o | Add-Member -MemberType ScriptMethod -Name GetValue -Value {param($Name) return $this.Values[$Name]}
        return $o
    }
    function Remove-Item { param([string]$LiteralPath,[switch]$Recurse,[switch]$Force,$ErrorAction) $deletes.Add([pscustomobject]@{parentDeleted=($LiteralPath -eq $psKey);recursive=[bool]$Recurse;unownedSiblingWouldBeDeleted=($LiteralPath -eq $psKey -and [bool]$Recurse)}) }
    function Write-RtlLog {param($Message)}
    $left = @(Remove-RtlCopyShellRegistrations -CopyRoot $copyRoot)
    [pscustomobject]@{id='N01';scenario='Fake CLSID with owned LocalServer32 and foreign sibling/value';deleteCount=$deletes.Count;deletions=@($deletes.ToArray());leftovers=@($left);expected='Owned command does not authorize deletion of foreign siblings';limitations='Registry commands/provider calls fully replaced with in-memory stubs. Proves requested delete granularity, not real registry behavior or real foreign entry prevalence.'}
}
$results += & {
    . ([scriptblock]::Create($defs['Invoke-CodexRtlUpdate']))
    $script:CopyRoot = Join-Path $run 'postverify\copy'
    $script:Staging = Join-Path $run 'postverify\staging'
    $script:OldRoot = Join-Path $run 'postverify\old'
    $script:BlockedFile = Join-Path $run 'postverify\blocked.json'
    $script:ShortcutStart = Join-Path $run 'postverify\start.lnk'
    $script:ShortcutDesktop = Join-Path $run 'postverify\desktop.lnk'
    $script:PatchVersion='fixture-patch'
    $script:ActiveProfile = [pscustomobject]@{Id='fixture';DisplayName='Fixture';ExeRelPath='app.exe';AsarRelPath='resources\app.asar';RendererMode='asar';AppSubdir='';ExeLeaf='app.exe'}
    Write-Fixture (Join-Path $script:CopyRoot 'app.exe')
    Write-Fixture (Join-Path $script:Staging 'app.exe')
    Write-Fixture (Join-Path $script:Staging '.codexrtl-sig') 'fixture-signature|patch=fixture-patch'
    Write-Fixture $script:ShortcutStart
    Write-Fixture $script:ShortcutDesktop
    $script:FakeState=$null
    $script:VerifyCalls=0
    $script:Steps=New-Object System.Collections.Generic.List[string]
    function Enter-RtlLock {return $true}
    function Exit-RtlLock {}
    function Resolve-RtlSource {return [pscustomobject]@{Signature='fixture-signature';Version='fixture-version';Type='Direct';AppDir='fixture-source'}}
    function Test-CodexSource {param($Source) return $true}
    function Read-RtlState {return $script:FakeState}
    function Get-PatchJsPath {return 'unused-fixture-payload'}
    function Join-RtlTree {param($Root,$Rel) if(-not $Rel){return $Root};return (Join-Path $Root $Rel)}
    function Test-RtlInjection {param($AsarPath,[switch]$AllowExternalNodeFallback) $script:VerifyCalls++; if($AsarPath.StartsWith($script:CopyRoot + '\')){throw '[VERIFY] synthetic post-swap failure'};return [pscustomobject]@{payloadSha256='fixture';asarSha256='fixture'}}
    function Test-CodexRtlRunning {return $false}
    function Invoke-AtomicSwap {param([switch]$ReseedStaging)}
    function New-RtlShortcut {}
    function Clear-RtlRendererCache {param($Profile)}
    function Write-RtlState {param($Values) $Values.patchVersion=$script:PatchVersion;$script:FakeState=[pscustomobject]$Values}
    function Set-RtlConfigApplied {}
    function Clear-RtlBlocked {}
    function Write-RtlLog {param($Message)}
    function Set-RtlStep {param($Key,$Percent,[switch]$Marquee) $script:Steps.Add($Key)}
    function Sync-RtlConfigAsset {param($AppId,[switch]$AllowExternalNodeFallback) return $false}
    function Show-RtlToast {param($Title,$Body)}
    Invoke-CodexRtlUpdate -Force
    $afterFirst = $script:VerifyCalls
    $firstDone = $script:Steps.Contains('done')
    Invoke-CodexRtlUpdate -Auto
    [pscustomobject]@{id='N02';scenario='Warm staging verifies; live ASAR verify throws; next Auto poll';firstPassDone=$firstDone;stateWritten=($null -ne $script:FakeState);recordedPayloadHash=$script:FakeState.payloadSha256;firstPassVerifyCalls=$afterFirst;nextPassVerifyCalls=($script:VerifyCalls-$afterFirst);expected='Failed live verification remains unhealthy/pending and must be retried';limitations='Extracted full update function with filesystem fixtures, no-op atomic swap and system boundaries; verify failure injected. No actual ASAR corruption or process restart.'}
}
$out = [ordered]@{sourceCommit='02cc70a8b750de4bc88b740cf8a64f292a5c0325';sourceSha256=(Get-FileHash $source -Algorithm SHA256).Hash;os=[Environment]::OSVersion.VersionString;powershell=$PSVersionTable.PSVersion.ToString();runDate=[DateTime]::UtcNow.ToString('o');fixtureRootLeaf=(Split-Path $run -Leaf);safety='No product library dot-source, real registry, shell links, named event, app launch/stop or original profile access. Files remain in unique local fixture directory.';results=$results}
$out | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'results.json') -Encoding UTF8
$out | ConvertTo-Json -Depth 8
$checks = @{
 F02 = (-not $results[0].certain -and -not $results[0].exeExists -and $results[0].lockedFileExists -and -not $results[0].stateExists -and @($results[0].installedAfter).Count -eq 0)
 F03 = ($results[1].certain -and -not $results[1].customConfigExists -and -not $results[1].sessionExists -and -not $results[1].privateStateExists)
 F04 = ($results[2].outputCount -eq 0 -and -not $results[2].threw)
 N03 = ($results[3].state -eq 'Fresh' -and $null -eq $results[3].blockedError)
 N01 = ($results[4].deleteCount -eq 1 -and $results[4].deletions[0].unownedSiblingWouldBeDeleted)
 N02 = ($results[5].firstPassDone -and $results[5].stateWritten -and $results[5].nextPassVerifyCalls -eq 0)
}
$failed = @($checks.Keys | Where-Object { -not $checks[$_] })
if ($failed.Count) { throw ('Baseline observations differed for: ' + ($failed -join ', ')) }
Write-Output 'Six baseline observations reproduced; this is evidence of current defects, not a passing product acceptance suite.'
