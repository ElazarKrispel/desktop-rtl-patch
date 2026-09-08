# Isolated Windows control-flow and verification regressions. No application launches.
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
# Compile the read-only file-link metadata helper before the generic Add-Type trap.
$pathLib=Join-Path $repo 'scripts\lib\desktop-rtl-paths.ps1'
if ([IO.File]::Exists($pathLib)) { . $pathLib; Assert-RtlSingleLink -Path $PSCommandPath }
$baselineText=(& git -C $repo show '02cc70a8b750de4bc88b740cf8a64f292a5c0325:scripts/lib/desktop-rtl-lib.ps1') -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Required baseline commit is missing; fetch full history.' }
$errs=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($baselineText,[ref]$null,[ref]$errs)
if ($errs.Count) { throw 'Baseline parse failed.' }
$baseline=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-CodexRtlUpdate'},$true).Extent.Text
$baselineCleanup=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-RtlAgentLastCleanup'},$true).Extent.Text
. (Join-Path $PSScriptRoot 'isolated-test-support.ps1')
$null=Initialize-RtlTestSandbox -RepositoryRoot $repo
$script:Checks=0
function Check([bool]$Condition,[string]$Label) { if(-not $Condition){throw "FAIL: $Label"}; $script:Checks++; Write-Output "PASS: $Label" }
function Fixture([string]$Path,[string]$Text='fixture') { $safe=Assert-RtlTestPath $Path; [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($safe)); [IO.File]::WriteAllText($safe,$Text) }
function Rename-Item {
 [CmdletBinding()]param([string]$LiteralPath,[string]$NewName,[switch]$Force)
 [void](Assert-RtlTestPath $LiteralPath); [void](Assert-RtlTestPath (Join-Path (Split-Path $LiteralPath -Parent) $NewName))
 Microsoft.PowerShell.Management\Rename-Item @PSBoundParameters
}
try {
 . (Join-Path $repo 'scripts\lib\desktop-rtl-lib.ps1')
 Set-RtlTestProductBoundaries
 function Write-RtlLog {param($Message)}
 function Set-RtlStep {param($Key,$Percent,[switch]$Marquee) $script:Steps+=@($Key)}
 function Show-RtlToast {param($Title,$Body)}
 function New-RtlShortcut {}
 function Clear-RtlRendererCache {param($Profile)}
 function Sync-RtlConfigAsset {param($AppId,[switch]$AllowExternalNodeFallback) return $true}
 function Resolve-RtlSource {return $script:Source}
 function Test-CodexSource {param($Source) return $true}
 function Invoke-Robocopy {throw 'Unexpected build path: synthetic staging should already be ready.'}
 function Reset-Case([string]$Name,[string]$App='traycer') {
  Set-RtlActiveApp $App
  $root=Join-Path $script:RtlTestRoot $Name
  $script:StateDir=$root
  foreach($pair in @(@('CopyRoot','copy'),@('Staging','staging'),@('OldRoot','old'))) {
   $value=Join-Path $root $pair[1]; Set-Variable -Name $pair[0] -Value $value -Scope Script; $script:ActiveProfile.($pair[0])=$value
  }
  $script:ActiveProfile.StateDir=$root
  foreach($pair in @(@('StateFile','state.json'),@('ConfigFile','config.json'),@('ConfigAppliedMarker','config-applied'),@('BlockedFile','blocked.json'),@('LockFile','op.lock'),@('ShortcutStart','start.lnk'),@('ShortcutDesktop','desktop.lnk'))) { Set-Variable -Name $pair[0] -Value (Join-Path $root $pair[1]) -Scope Script }
  $script:Source=[pscustomobject]@{Signature='fixture-source';Version='1.2.3';Type='Direct';AppDir=(Join-Path $root 'source')}
  $script:Steps=@()
  Fixture (Join-Path $script:CopyRoot $script:ActiveProfile.ExeRelPath) 'previous executable'
  Fixture $script:ShortcutStart; Fixture $script:ShortcutDesktop
 }
 function Seed-Staging {
  Fixture (Join-Path $script:Staging $script:ActiveProfile.ExeRelPath) 'replacement executable'
  Fixture (Join-Path $script:Staging '.codexrtl-sig') ($script:Source.Signature+'|patch='+$script:PatchVersion)
 }
 # Historical regressions execute only the original update function, not its library.
 & {
  . ([scriptblock]::Create($baseline))
  function Enter-RtlLock {return $false}
  Check (@(Invoke-CodexRtlUpdate -Force).Count -eq 0) 'baseline Busy returns no result'
 }
 & {
  Reset-Case 'baseline-live' 'opencode'; Seed-Staging
  . ([scriptblock]::Create($baseline))
  $script:FakeState=$null; $script:VerifyCount=0
  function Enter-RtlLock {return $true}; function Exit-RtlLock {}
  function Read-RtlState {return $script:FakeState}
  function Test-RtlInjection {param($AsarPath,[switch]$AllowExternalNodeFallback) $script:VerifyCount++; if($AsarPath.StartsWith($script:CopyRoot+'\')){throw '[VERIFY] injected live failure'}; return [pscustomobject]@{payloadSha256='fixture';asarSha256='fixture'}}
  function Invoke-AtomicSwap {param([switch]$ReseedStaging)} # Control-flow model, NOT rollback evidence.
  function Write-RtlState {param($State) $State.patchVersion=$script:PatchVersion; $script:FakeState=[pscustomobject]$State}
  function Set-RtlConfigApplied {}; function Clear-RtlBlocked {}
  Invoke-CodexRtlUpdate -Force
  Check ($script:Steps -contains 'done') 'baseline reports done after failed live verification'
  Check ($null -ne $script:FakeState) 'baseline writes installed state after failed live verification'
  $first=$script:VerifyCount; Invoke-CodexRtlUpdate -Auto
  Check ($script:VerifyCount -eq $first) 'baseline next Auto never verifies active copy'
 }
 Reset-Case 'lock'
 $held=[IO.File]::Open($script:LockFile,'OpenOrCreate','ReadWrite','None')
 try { $r=Invoke-CodexRtlUpdate -Auto; Check ($r.Status -eq 'Busy' -and -not $r.Success) 'real exclusive fixture lock yields Busy' } finally {$held.Dispose()}
 & {
  function Enter-RtlLock {throw [UnauthorizedAccessException]::new('fixture denied')}
  $r=Invoke-CodexRtlUpdate -Auto
  Check ($r.Status -eq 'Failed' -and $r.Reason -match 'fixture denied') 'permission failure is Failed, not Busy'
 }
 & {
  Reset-Case 'current-corrupt'
  Write-RtlState @{sourceSignature=$script:Source.Signature;payloadSha256='previous-hash'}
  function Confirm-RtlActiveCopy {param($Source,[switch]$AllowExternalNodeFallback) throw '[VERIFY] corrupted current payload'}
  $r=Invoke-CodexRtlUpdate -Auto
  Check ($r.Status -eq 'Failed' -and -not $r.Success) 'current-state fast path rejects failed verification'
  Check ((Get-RtlManagementReceipt).phase -eq 'VerificationPending') 'failed fast-path verification records pending receipt'
 }
 & {
  Reset-Case 'rollback'; Seed-Staging
  Fixture (Join-Path $script:CopyRoot 'preserve.txt') 'previous bytes'
  function Confirm-RtlActiveCopy {param($Source,[switch]$AllowExternalNodeFallback) throw '[VERIFY] injected post-rename failure'}
  $failed=$false; try { Invoke-RtlVerifiedSwap -Source $script:Source | Out-Null } catch {$failed=$_.Exception.Message -match '\[VERIFY\]'}
  Check $failed 'verified swap exposes injected confirmation failure'
  Check ([IO.File]::ReadAllText((Join-Path $script:CopyRoot 'preserve.txt')) -eq 'previous bytes') 'real directory renames restore previous bytes'
  Check ([IO.File]::ReadAllText((Join-Path $script:Staging $script:ActiveProfile.ExeRelPath)) -eq 'replacement executable') 'unverified replacement retained separately'
  Check (-not [IO.File]::Exists((Join-Path $script:Staging '.codexrtl-sig'))) 'unverified replacement loses warm staging signature'
  Check ((Get-RtlManagementReceipt).phase -eq 'VerificationPending') 'rollback retains verification-pending receipt'
  function Resolve-RtlSource {throw 'Pending guard must run before source inspection'}
  $r=Invoke-CodexRtlUpdate -Auto
  Check ($r.Status -eq 'Blocked' -and $r.Reason -match '\[VERIFY\]') 'next Auto blocks before source/build after verification failure'
 }
 & {
  Reset-Case 'full-update-recovery'; Seed-Staging
  Write-RtlState @{sourceSignature='previous-source';payloadSha256='previous-payload'}
  $before=[IO.File]::ReadAllText($script:StateFile)
  function Test-RtlDirInjection {param($RendererDir) return $true}
  function Confirm-RtlActiveCopy {param($Source,[switch]$AllowExternalNodeFallback) throw '[VERIFY] injected final verification failure'}
  $r=Invoke-CodexRtlUpdate -Force
  Check ($r.Status -eq 'Failed' -and $r.Reason -match '\[VERIFY\]') 'full update returns Failed after real swap and injected verification failure'
  Check ([IO.File]::ReadAllText($script:StateFile) -eq $before) 'full failed update leaves prior installed state bytes unchanged'
  Check ([IO.File]::ReadAllText((Join-Path $script:CopyRoot $script:ActiveProfile.ExeRelPath)) -eq 'previous executable') 'full failed update restores original fixture executable bytes'
  Check (-not ($script:Steps -contains 'done')) 'full failed update never reports done'
 }
 & {
  Reset-Case 'rollback-running'; Seed-Staging
  Fixture (Join-Path $script:CopyRoot 'previous.txt') 'keep old'
  function Confirm-RtlActiveCopy {param($Source,[switch]$AllowExternalNodeFallback) throw '[VERIFY] injected live failure'}
  function Test-CodexRtlRunning {return $true}
  $failed=$false; try {Invoke-RtlVerifiedSwap -Source $script:Source | Out-Null}catch{$failed=$_.Exception.Message -match 'Close the RTL copy'}
  Check $failed 'recovery refuses rename when running-copy boundary reports active'
  Check ([IO.File]::ReadAllText((Join-Path $script:OldRoot 'previous.txt')) -eq 'keep old') 'blocked rollback preserves previous copy in old root'
  Check ((Get-RtlManagementReceipt).phase -eq 'VerificationPending') 'blocked rollback remains pending'
 }
 & {
  Reset-Case 'successful-swap'; Seed-Staging
  Fixture (Join-Path $script:CopyRoot 'previous.txt') 'keep until confirmed'
  function Confirm-RtlActiveCopy {
   param($Source,[switch]$AllowExternalNodeFallback)
   if(-not [IO.File]::Exists((Join-Path $script:OldRoot 'previous.txt'))) {throw 'Previous copy discarded before verification'}
   return [pscustomobject]@{payloadSha256='confirmed-fixture';asarSha256=$null}
  }
  $v=Invoke-RtlVerifiedSwap -Source $script:Source
  Check ($v.payloadSha256 -eq 'confirmed-fixture') 'successful confirmation runs while previous tree still exists (mock confirmation)'
  Check ([IO.Directory]::Exists($script:OldRoot)) 'verified swap retains previous tree until explicit completion'
  Complete-RtlPreviousCopy -ReseedStaging
  Check ([IO.File]::ReadAllText((Join-Path $script:Staging 'previous.txt')) -eq 'keep until confirmed') 'completion reseeds previous tree using real rename'
 }
 & {
  Reset-Case 'already-current'
  Write-RtlState @{sourceSignature=$script:Source.Signature;payloadSha256='expected-fixture'}
  $script:CurrentVerified=0
  function Confirm-RtlActiveCopy {param($Source,[switch]$AllowExternalNodeFallback) $script:CurrentVerified++; return [pscustomobject]@{payloadSha256='expected-fixture';asarSha256=$null}}
  $r=Invoke-CodexRtlUpdate -Auto
  Check ($r.Status -eq 'AlreadyCurrent' -and $r.Success -and $script:CurrentVerified -eq 1) 'AlreadyCurrent requires confirmation on this pass (mock confirmation)'
 }
 foreach($app in @('traycer','t3code')) {
  Reset-Case ('hash-'+$app) $app
  $dir=Get-RtlRendererDir -Profile $script:ActiveProfile -Root $script:CopyRoot
  $index=Join-Path $dir 'index.html'
  Fixture $index '<html><head><script type="module" src="./assets/main-123.js"></script></head></html>'
  Fixture (Join-Path $dir 'assets\main-123.js') 'original bundle'
  $cfg=Join-Path $script:StateDir 'fixture-config.js'; Fixture $cfg 'window.__codexRtlConfig = {};'
  $patch=Get-PatchJsPath
  if($app -eq 'traycer') { Invoke-RtlDirInject -RendererDir $dir -Profile $script:ActiveProfile -PatchJs $patch -ConfigJs $cfg }
  else { Invoke-RtlInlineInject -RendererDir $dir -Profile $script:ActiveProfile -PatchJs $patch -ConfigJs $cfg }
  $v=Confirm-RtlActiveCopy -Source $script:Source
  Check ($v.payloadSha256 -eq (Get-FileHash -LiteralPath $patch).Hash) ($app+' actual renderer payload verifies')
  if($app -eq 'traycer') { Fixture (Join-Path $dir ('assets\'+$script:RtlDirPayloadName)) 'altered payload' }
  else { [IO.File]::WriteAllText($index,([IO.File]::ReadAllText($index).Replace('<script type="module" id="desktop-rtl-payload">','<script type="module" id="desktop-rtl-payload">/*tampered*/'))) }
  $failed=$false; try { Confirm-RtlActiveCopy -Source $script:Source | Out-Null } catch {$failed=$_.Exception.Message -match '\[VERIFY\]'}
  Check $failed ($app+' changed payload fails despite valid tags')
 }
 & {
  Reset-Case 'asar-hash' 'opencode'
  $script:AsarHash=(Get-FileHash -LiteralPath (Get-PatchJsPath)).Hash
  function Test-RtlInjection {param($AsarPath,[switch]$AllowExternalNodeFallback) return [pscustomobject]@{payloadSha256=$script:AsarHash;asarSha256='archive-fixture'}}
  $v=Confirm-RtlActiveCopy -Source $script:Source
  Check ($v.payloadSha256 -eq $script:AsarHash) 'ASAR verifier result accepted when expected payload digest matches (mock archive boundary)'
  $script:AsarHash='wrong'; $failed=$false; try {Confirm-RtlActiveCopy -Source $script:Source | Out-Null}catch{$failed=$_.Exception.Message -match '\[VERIFY\]'}
  Check $failed 'ASAR verifier digest mismatch rejected (mock archive boundary)'
 }
 & {
  Reset-Case 'electron-deferred'; Seed-Staging
  function Test-RtlDirInjection {param($RendererDir) return $true} # Stage verifier only: explicit boundary model.
  function Test-CodexRtlRunning {return $true}
  $r=Invoke-CodexRtlUpdate -Auto
  Check ($r.Status -eq 'Deferred' -and $r.Prepared -and -not $r.Success) 'Electron defer reports prepared staging (mock stage verifier)'
 }
 & {
  Reset-Case 'herdr-deferred' 'herdr'
  function Test-CodexRtlRunning {return $true}
  function Invoke-HerdrRtlBuild {throw 'Deferred Herdr must not prepare/download'}
  $r=Invoke-CodexRtlUpdate -Auto
  Check ($r.Status -eq 'Deferred' -and -not $r.Prepared -and -not $r.Success) 'Herdr defer reports no prepared build'
 }
 & {
  Reset-Case 'herdr-hash' 'herdr'
  function Test-HerdrRtlBuild {param($Root,$Source) return [pscustomobject]@{Version='1.2.3'}} # No executable is run.
  $exe=Join-Path $script:CopyRoot 'herdr.exe'
  $v=Confirm-RtlActiveCopy -Source $script:Source
  Check ($v.payloadSha256 -eq (Get-FileHash -LiteralPath $exe).Hash) 'Herdr confirmation records actual file digest (mock version boundary)'
  $held=[IO.File]::Open($exe,'Open','Read','None')
  try {
   $failed=$false; try {Confirm-RtlActiveCopy -Source $script:Source | Out-Null}catch{$failed=$_.Exception.Message -match '\[VERIFY\]'}
   Check $failed 'Herdr confirmation rejects unavailable digest under real file lock'
  } finally {$held.Dispose()}
 }
 & {
  Reset-Case 'pending-config' 'opencode'
  Write-RtlState @{sourceSignature=$script:Source.Signature;payloadSha256='expected-fixture'}
  Fixture $script:ConfigFile '{"fixture":"changed settings"}'
  Fixture $script:ConfigAppliedMarker 'old-config-digest'
  $before=[IO.File]::ReadAllText($script:StateFile)
  function Test-CodexRtlRunning {return $true}
  function Sync-RtlConfigAsset {throw 'Running ASAR config must not be written'}
  function Confirm-RtlActiveCopy {throw 'Pending configuration must not claim verification completion'}
  $r=Invoke-CodexRtlUpdate -Auto
  Check ($r.Status -eq 'Deferred' -and -not $r.Prepared -and -not $r.Success) 'current running ASAR with pending settings reports unprepared Deferred'
  Check ([IO.File]::ReadAllText($script:StateFile) -eq $before) 'pending settings defer preserves installed state'
  Check (-not ($script:Steps -contains 'done')) 'pending settings defer does not report done'
 }
 Reset-Case 'result-app' 'codex'
 $r=New-RtlOperationResult -Status Failed -Reason 'fixture' -App 'herdr'
 Check ($r.App -eq 'herdr' -and $script:ActiveProfile.Id -eq 'codex') 'explicit result App retains target identity independently of active profile'
 & {
  # Use the ordinary redirected profile so actual Get-RtlInstalledApps can rediscover it.
  Set-RtlActiveApp 'traycer'
  function Invoke-RtlWithSetupMutex {param($Body) & $Body}
  function Unregister-RtlAgent {}
  function Register-RtlAgent {}
  function Write-RtlAgentLog {param($Message)}
  Fixture $script:ConfigFile '{"fixture":"retain user preference"}'
  $locked=Join-Path $script:AgentBinDir 'z-retained-runtime.dat'
  Fixture $locked 'locked neutral runtime'
  $held=[IO.File]::Open($locked,'Open','Read','None')
  try {
   & {
    . ([scriptblock]::Create($baselineCleanup))
    $threw=$false; try {Invoke-RtlAgentLastCleanup}catch{$threw=$true}
    Check (-not $threw -and [IO.File]::Exists($locked)) 'baseline agent cleanup silently returns despite real locked runtime leftover'
   }
   $failure=$null; try {Invoke-RtlAgentLastCleanup}catch{$failure=$_.Exception}
   Check ($failure -and $failure.Message -match '\[PARTIAL\]') 'current agent cleanup exposes locked neutral runtime as Partial exception'
   Check (@($failure.Data['Leftovers']) -contains $script:AgentBinDir) 'agent cleanup exception identifies failed runtime root'
   Check ((Get-RtlManagementReceipt).phase -eq 'CleanupPending') 'failed neutral cleanup records selected app cleanup receipt'
   $record=Get-RtlLastOperation
   Check ($record.Result.Status -eq 'Partial' -and -not $record.Result.Success) 'failed neutral cleanup durably records truthful Partial result'
   Check (@(Get-RtlInstalledApps) -contains 'traycer') 'actual managed-app enumeration rediscovers pending neutral cleanup'
  } finally {$held.Dispose()}
  $removed=Invoke-CodexRtlUninstall
  Check $removed.Success 'retry completes selected app cleanup after runtime lock released'
  Invoke-RtlAgentLastCleanup
  Check (-not [IO.Directory]::Exists($script:AgentBinDir)) 'retry actually removes neutral runtime after file lock release'
  Check (-not (@(Get-RtlInstalledApps) -contains 'traycer')) 'completed cleanup is no longer managed'
  Check ([IO.File]::ReadAllText($script:ConfigFile) -eq '{"fixture":"retain user preference"}') 'neutral cleanup retry preserves user configuration'
 }
 Reset-Case 'operation-record'
 Save-RtlOperationResult -Result (New-RtlOperationResult -Status Partial -Leftovers @('fixture')) -Operation uninstall -OperationId 'first'
 Check ((Get-RtlLastOperation).Result.Status -eq 'Partial') 'result survives a fresh record read'
 Save-RtlOperationResult -Result (New-RtlOperationResult -Status Failed -Reason 'new failure') -Operation update -OperationId 'second'
 Acknowledge-RtlOperationResult -OperationId 'first'
 Check (-not (Get-RtlLastOperation).Acknowledged) 'stale acknowledgement leaves newer result unacknowledged'
 Acknowledge-RtlOperationResult -OperationId 'second'
 Check ((Get-RtlLastOperation).Acknowledged) 'matching acknowledgement marks exact operation'
 Assert-RtlTestIsolation
 Write-Output ("Operation engine assertions passed: {0}; PowerShell {1}" -f $script:Checks,$PSVersionTable.PSVersion)
} finally {Complete-RtlTestSandbox}
