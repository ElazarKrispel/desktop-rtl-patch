[CmdletBinding()]
param([string]$RepositoryRoot,[switch]$ExpectBaseline)
$ErrorActionPreference='Stop'
if (-not $RepositoryRoot) { $RepositoryRoot=Split-Path $PSScriptRoot -Parent }
. (Join-Path $PSScriptRoot 'isolated-test-support.ps1')
$root=Initialize-RtlTestSandbox -RepositoryRoot $RepositoryRoot
$checks=0
function Check($Condition,[string]$Message) { if (-not $Condition) { throw "FAIL: $Message" }; $script:checks++ }
try {
    . (Join-Path $RepositoryRoot 'scripts\lib\desktop-rtl-lib.ps1')
    Set-RtlTestProductBoundaries
    Set-RtlActiveApp opencode
    function Resolve-RtlSource { return $null }
    function Start-Sleep { param($Milliseconds) }
    [void][IO.Directory]::CreateDirectory($script:CopyRoot)
    [void][IO.Directory]::CreateDirectory($script:StateDir)
    $exe=Join-Path $script:CopyRoot $script:ActiveProfile.ExeRelPath
    $locked=Join-Path $script:CopyRoot 'locked-resource.dat'
    [IO.File]::WriteAllText($exe,'synthetic executable, never run')
    [IO.File]::WriteAllText($locked,'valuable locked resource')
    [IO.File]::WriteAllText($script:StateFile,'{"schemaVersion":2,"sourceSignature":"fixture"}')
    $handle=[IO.File]::Open($locked,'Open','Read','None')
    try { $result=Invoke-CodexRtlUninstall } finally { $handle.Dispose() }
    Check (-not $result.Certain) 'locked non-exe yields partial cleanup'
    # Delete the exe independently if enumeration order reached the lock first.
    if ([IO.File]::Exists($exe)) { [IO.File]::Delete($exe) }
    Check ([IO.File]::Exists($locked)) 'locked resource remains'
    $retainedState=[IO.File]::Exists($script:StateFile)
    # Reload all product definitions to lose every in-memory install object.
    . (Join-Path $RepositoryRoot 'scripts\lib\desktop-rtl-lib.ps1')
    Set-RtlTestProductBoundaries
    Set-RtlActiveApp opencode
    function Resolve-RtlSource { return $null }
    $visible=@(Get-RtlInstalledApps) -contains 'opencode'
    $status=Get-CodexRtlStatus
    if ($ExpectBaseline) {
        Check (-not $visible) 'baseline loses the partial install after exe removal'
        Check (-not $retainedState) 'baseline deletes installed-version evidence during partial cleanup'
        Check ($status.State -eq 'Fresh') 'baseline labels source-less leftover Fresh'
    } else {
        Check $visible 'partial install rediscovered after library reload without source/exe'
        Check $retainedState 'partial cleanup retains version evidence'
        Check ($status.State -eq 'CleanupPending') 'cleanup intent takes priority over source discovery'
        $blocked=$false
        try { Invoke-CodexRtlUpdate -Auto | Out-Null } catch { $blocked=$_.Exception.Message -match '\[CLEANUP\]' }
        Check $blocked 'auto update cannot resurrect a removal'
        Check ([IO.File]::Exists($locked)) 'auto guard preserves leftovers'
        $complete=Invoke-CodexRtlUninstall
        Check $complete.Certain 'second uninstall completes after releasing real lock'
        Check (-not (@(Get-RtlInstalledApps) -contains 'opencode')) 'completed removal no longer managed'
        # Retained user files do not keep the app or shared agent installed.
        [void][IO.Directory]::CreateDirectory((Join-Path $script:StateDir 'data'))
        [IO.File]::WriteAllText($script:ConfigFile,'{"enabled":false}')
        Check (-not (Test-RtlManagedArtifacts)) 'retained config/data alone are not managed resources'
        # Corrupt state is evidence, never moved by status.
        [IO.File]::WriteAllText($script:StateFile,'broken json')
        $null=Get-CodexRtlStatus
        Check ([IO.File]::ReadAllText($script:StateFile) -eq 'broken json') 'status leaves malformed state untouched'
        Check ((Get-CodexRtlStatus).State -eq 'CleanupPending') 'legacy orphan state remains discoverable'
        [IO.File]::WriteAllText((Join-Path $script:StateDir 'management.json'),'{"schemaVersion":999}')
        Check (Test-RtlCleanupPending) 'unknown receipt schema fails closed'
    }
    Assert-RtlTestIsolation
    Write-Output "PASS: $checks cleanup receipt assertions (baseline=$ExpectBaseline); real fixture file lock, mocked OS boundaries, no live app cycle."
} finally { Complete-RtlTestSandbox }
