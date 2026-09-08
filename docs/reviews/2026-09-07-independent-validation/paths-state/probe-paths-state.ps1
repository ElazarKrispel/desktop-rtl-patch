param([string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path)
$ErrorActionPreference = 'Stop'
# Do NOT dot-source the production library: load only exact AST function bodies.
$lib = Join-Path $Repo 'scripts\lib\desktop-rtl-lib.ps1'
$herdr = Join-Path $Repo 'scripts\lib\desktop-rtl-herdr.ps1'
$asts = @{}
foreach($p in @($lib,$herdr)) {
 $errors=$null; $asts[$p]=[Management.Automation.Language.Parser]::ParseFile($p,[ref]$null,[ref]$errors)
 if($errors.Count){throw 'Product parse failed'}
}
$functions = @('Assert-RtlWriteAllowed','ConvertTo-RtlCanonicalPath','Test-RtlPathUnderRoot','New-RtlLaunchScript','Join-RtlTree','Read-RtlState','Get-CodexRtlStatus','Get-RtlBlockRecord','Test-RtlUpdateBlocked','Set-RtlBlocked','Clear-RtlBlocked','Test-RtlShouldLatchError','Invoke-CodexRtlUpdate','Invoke-HerdrRtlInstall','Invoke-HerdrRtlBuild','Resolve-HerdrRtlArtifact','New-HerdrRtlLauncher','Get-HerdrRtlDataDir','Get-HerdrRtlStateHome','Start-RtlCopyApp')
$loaded=@()
foreach($name in $functions){
 $found=@(foreach($p in @($lib,$herdr)){$asts[$p].FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)})
 if($found.Count -ne 1){throw "Function count invalid: $name"}
 . ([scriptblock]::Create($found[0].Extent.Text))
 $loaded += @{name=$name;start=$found[0].Extent.StartLineNumber;end=$found[0].Extent.EndLineNumber}
}
$fixture=Join-Path $PSScriptRoot ('fixture-ps-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$script:StateDir=Join-Path $fixture 'state'
$script:CopyRoot=Join-Path $fixture 'copy'
$script:Staging=Join-Path $fixture 'staging'
$script:OldRoot=Join-Path $fixture 'old'
$script:StateFile=Join-Path $script:StateDir 'state.json'
$script:BlockedFile=Join-Path $script:StateDir 'blocked.json'
$script:PatchVersion='2.5.0';$script:SchemaVersion=1;$script:BlockThreshold=2
foreach($p in @($script:StateDir,$script:CopyRoot,$script:Staging)){[void][IO.Directory]::CreateDirectory($p)}
$script:ActiveProfile=[pscustomobject]@{Id='herdr';DisplayName='fixture';RendererMode='prebuilt';Mode='copy';ExeRelPath='herdr.exe';AsarRelPath='unused.asar';StateDir=$script:StateDir;CopyRoot=$script:CopyRoot;Staging=$script:Staging;LaunchEnv=$null;PrebuiltRepo='fixture/fixture'}
# All host boundaries stubbed; no network, locks, registry, shortcuts, apps or events.
function Write-RtlLog {param($Message)}
function Set-RtlStep {param($Step,$Percent,$Indeterminate)}
function Enter-RtlLock {return $true}
function Exit-RtlLock {}
function Resolve-RtlSource {return [pscustomobject]@{Signature='fixture:1';Version='1.0.0';AppDir=$fixture;Type='Herdr'}}
function Test-CodexSource {param($Source)return $true}
function Test-CodexRtlRunning {return $false}
function Get-HerdrRtlBuildTag {param($Profile)return 'fixture-build'}
function Invoke-WebRequest {param($Uri,$OutFile,[switch]$UseBasicParsing,$MaximumRedirection)
 $script:NetworkCalls++
 if($script:NetworkHealthy){throw 'HARNESS: downloader reached after simulated network recovery'}
 throw [Net.WebException]::new('Synthetic timeout', [Net.WebExceptionStatus]::Timeout)
}
$script:HerdrRtlAssetName='fixture.zip'
$script:NetworkCalls=0;$script:NetworkHealthy=$false
$savedArtifact=$env:HERDR_RTL_ARTIFACT
[Environment]::SetEnvironmentVariable('HERDR_RTL_ARTIFACT',$null,'Process')
$passes=@()
try {
 for($i=1;$i -le 3;$i++){
  if($i -eq 3){$script:NetworkHealthy=$true}
  $before=$script:NetworkCalls;$errorText=$null
  try {Invoke-CodexRtlUpdate -Auto | Out-Null}catch{$errorText=$_.Exception.Message.Replace($fixture,'<fixture>')}
  $block=Get-RtlBlockRecord 'fixture:1'
  $passes+=@{pass=$i;networkHealthy=$script:NetworkHealthy;downloadCalls=$script:NetworkCalls-$before;error=$errorText;failureCount=$block.count;blocked=[bool](Test-RtlUpdateBlocked 'fixture:1')}
 }
}finally{[Environment]::SetEnvironmentVariable('HERDR_RTL_ARTIFACT',$savedArtifact,'Process')}
if($script:NetworkCalls -ne 2 -or -not (Test-RtlUpdateBlocked 'fixture:1')){throw 'F05 pre-fix behavior not reproduced'}

# Status mutation with all detectors stubbed and data under owned fixture.
[IO.File]::WriteAllText($script:StateFile,'{invalid-json')
$st=Get-CodexRtlStatus
$status=@{result=$st.State;stateExists=[IO.File]::Exists($script:StateFile);quarantineExists=[IO.File]::Exists($script:StateFile+'.bad');blockedError=$st.BlockedError}
if($status.stateExists -or -not $status.quarantineExists){throw 'F08 status mutation not reproduced'}

# F01 guard checks on existing synthetic junction from the independently executed Node fixture.
$fuseFixture=Get-ChildItem -LiteralPath $PSScriptRoot -Directory -Filter 'fixture-fuse-*' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$profile=[pscustomobject]@{Mode='copy';CopyRoot=(Join-Path $fuseFixture.FullName 'copy');Staging=(Join-Path $fuseFixture.FullName 'staging')}
$guards=@()
foreach($pair in @(@('direct','outside\fixture.bin'),@('junction','staging\junction\fixture.bin'),@('hardlink','staging\hard.bin'),@('prefix','staging-lookalike\fixture.bin'))){
 $target=Join-Path $fuseFixture.FullName $pair[1];$accepted=$false
 try {$accepted=Assert-RtlWriteAllowed -Profile $profile -Path $target}catch{}
 $guards+=@{name=$pair[0];writeGuardAccepted=[bool]$accepted;ownershipGuardAccepted=(Test-RtlPathUnderRoot -Path $target -Roots @($profile.Staging))}
}

# F06 bytes only: never execute generated VBS or CMD / create actual shortcuts.
$hebrew=[string][char]0x05D0+[char]0x05D1+[char]0x05D2
$script:CopyRoot=Join-Path $fixture ($hebrew+' copy space')
$launchProfile=[pscustomobject]@{LaunchScript='fixture.vbs';LaunchEnv=@{SAND_DISABLE_UPDATES='1'};ExeRelPath='fixture.exe';AppSubdir='';DisplayName='fixture'}
$vbs=New-RtlLaunchScript -Profile $launchProfile
$vbsText=[IO.File]::ReadAllText($vbs)
$script:ActiveProfile.CopyRoot=$script:CopyRoot
$cmd=New-HerdrRtlLauncher -Profile $script:ActiveProfile
$cmdText=[IO.File]::ReadAllText($cmd,[Text.Encoding]::UTF8)
$encoding=@{vbsPreservesHebrew=$vbsText.Contains($hebrew);vbsContainsReplacement=$vbsText.Contains('??? copy space');herdrCmdPreservesHebrew=$cmdText.Contains($hebrew);herdrCmdFirstLine=($cmdText -split "`r?`n")[0]}
if($encoding.vbsPreservesHebrew -or -not $encoding.herdrCmdPreservesHebrew){throw 'F06 encoding control unexpected'}

# Supplemental Herdr launcher bypass: capture launch request, never spawn the application.
[void][IO.Directory]::CreateDirectory($script:CopyRoot)
[IO.File]::WriteAllText((Join-Path $script:CopyRoot 'herdr.exe'),'fixture text, not executable')
function Start-Process {param($FilePath,$WorkingDirectory)
 $script:LaunchCapture=@{file=(Split-Path $FilePath -Leaf);work=$WorkingDirectory.Replace($fixture,'<fixture>');xdgConfig=$env:XDG_CONFIG_HOME;xdgState=$env:XDG_STATE_HOME;herdrBin=$env:HERDR_BIN_PATH}
}
$savedEnv=@{}
foreach($k in @('XDG_CONFIG_HOME','XDG_STATE_HOME','HERDR_BIN_PATH')){$savedEnv[$k]=[Environment]::GetEnvironmentVariable($k,'Process');[Environment]::SetEnvironmentVariable($k,$null,'Process')}
try {$launchResult=Start-RtlCopyApp}finally{foreach($k in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($k,$savedEnv[$k],'Process')}}
$result=[ordered]@{baseline='02cc70a8b750de4bc88b740cf8a64f292a5c0325';environment=@{powershell=$PSVersionTable.PSVersion.ToString();os=[Environment]::OSVersion.VersionString};scope='Exact AST-loaded production function bodies, host boundaries stubbed; not GUI/install E2E';loaded=$loaded;F01=$guards;F05=$passes;F06=$encoding;F08Status=$status;N05HerdrOpen=@{result=$launchResult;capture=$script:LaunchCapture;generatedLauncherSetsXdg=$cmdText.Contains('set "XDG_CONFIG_HOME=')}}
$json=$result|ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'paths-state-results.json'),$json,[Text.UTF8Encoding]::new($false))
$json
