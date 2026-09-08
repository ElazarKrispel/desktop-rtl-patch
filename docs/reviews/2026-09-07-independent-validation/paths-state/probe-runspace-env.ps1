param([string]$Repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path)
$ErrorActionPreference='Stop'
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'scripts\lib\desktop-rtl-lib.ps1'),[ref]$null,[ref]$null)
$selector=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-RtlActiveApp'},$true).Extent.Text
$fixture=Join-Path $PSScriptRoot ('fixture-env-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$setup=@'
param($Selector,$Root)
. ([scriptblock]::Create($Selector))
function Write-RtlLog {param($Message)}
function Get-RtlProfile {param($AppId)
 return [pscustomobject]@{Id=$AppId;DisplayName='fixture';StateDir=$Root;CopyRoot=(Join-Path $Root 'copy');Staging=(Join-Path $Root 'staging');OldRoot=(Join-Path $Root 'old');WatcherRunName='fixture-never-used';ShortcutLabel='fixture-never-created';NodeStrategy=$(if($AppId -eq 'fixture-electron'){'electron-as-node'}else{'none'})}
}
$script:ActiveProfile=[pscustomobject]@{Id='initial'}
'@
$savedRun=$env:ELECTRON_RUN_AS_NODE;$savedAsar=$env:ELECTRON_NO_ASAR
$rsA=[runspacefactory]::CreateRunspace();$rsA.Open()
$rsB=[runspacefactory]::CreateRunspace();$rsB.Open()
$psA=[powershell]::Create();$psA.Runspace=$rsA
$psB=[powershell]::Create();$psB.Runspace=$rsB
try{
 [void]$psA.AddScript($setup).AddArgument($selector).AddArgument($fixture).Invoke();if($psA.HadErrors){throw 'A setup failed'};$psA.Commands.Clear()
 [void]$psB.AddScript($setup).AddArgument($selector).AddArgument($fixture).Invoke();if($psB.HadErrors){throw 'B setup failed'};$psB.Commands.Clear()
 [void]$psA.AddScript("Set-RtlActiveApp 'fixture-electron'").Invoke();$psA.Commands.Clear()
 $initialRun=$env:ELECTRON_RUN_AS_NODE;$initialAsar=$env:ELECTRON_NO_ASAR
 [void]$psB.AddScript("Set-RtlActiveApp 'fixture-other'").Invoke();$psB.Commands.Clear()
 $observed=@($psA.AddScript('[pscustomobject]@{profile=$script:ActiveProfile.Id;run=$env:ELECTRON_RUN_AS_NODE;asar=$env:ELECTRON_NO_ASAR}').Invoke())[0]
 $result=@{environment=$PSVersionTable.PSVersion.ToString();scope='Controlled interleaving of two real runspaces and exact production selector body; profiles/loggers synthetic; no app, child launcher, named event, registry or shortcuts';afterA=@{run=$initialRun;asar=$initialAsar};afterBObservedByA=@{profile=$observed.profile;run=$observed.run;asar=$observed.asar};limitation='Proves process environment interference, not real tray timing or application startup failure'}
 if($initialRun -ne '1' -or $observed.profile -ne 'fixture-electron' -or $observed.run){throw 'Environment interference not reproduced'}
 $json=$result|ConvertTo-Json -Depth 5
 [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'runspace-env-results.json'),$json,[Text.UTF8Encoding]::new($false));$json
}finally{
 $psA.Dispose();$psB.Dispose();$rsA.Dispose();$rsB.Dispose()
 [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE',$savedRun,'Process');[Environment]::SetEnvironmentVariable('ELECTRON_NO_ASAR',$savedAsar,'Process')
}
