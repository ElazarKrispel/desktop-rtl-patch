param([string]$Repo=(Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path)
$ErrorActionPreference='Stop'
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'scripts\lib\desktop-rtl-lib.ps1'),[ref]$null,[ref]$null)
foreach($name in @('Assert-RtlWriteAllowed','Assert-RtlAsarFuseOff','Invoke-RtlNodeCli')){
 $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 . ([scriptblock]::Create($fn.Extent.Text))
}
function Get-AsarEditPath {Join-Path $Repo 'scripts\lib\asar-edit.mjs'}
function Write-RtlLog {param($Message)$script:Logs+=$Message}
$script:Logs=@()
$fixture=Join-Path $PSScriptRoot ('fixture-wrapper-'+[guid]::NewGuid().ToString('N'))
foreach($part in @('staging','outside','temp')){[void][IO.Directory]::CreateDirectory((Join-Path $fixture $part))}
$root=Join-Path $fixture 'staging';$outside=Join-Path $fixture 'outside';$target=Join-Path $outside 'fixture.bin'
$junction=Join-Path $root 'link';New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
$raw=[Text.Encoding]::ASCII.GetBytes('fixture-onlydL7pKGdnNz796PbbjQWNKmHXBZaB9tsX')+[byte[]]@(1,8)+[Text.Encoding]::ASCII.GetBytes('00001000fixture-tail')
[IO.File]::WriteAllBytes($target,$raw)
$profile=[pscustomobject]@{Mode='copy';CopyRoot=(Join-Path $fixture 'copy');Staging=$root;FuseFlipInCopy=$true;DisplayName='fixture'}
$tempSaved=$env:TEMP;$tmpSaved=$env:TMP
try {
 $env:TEMP=Join-Path $fixture 'temp';$env:TMP=$env:TEMP
 # Actual child is only node on production asar editor + synthetic binary.
 Assert-RtlAsarFuseOff -Node (Get-Command node.exe).Source -ScanPath (Join-Path $junction 'fixture.bin') -Profile $profile
 $after=[IO.File]::ReadAllBytes($target);$changes=@(0..($raw.Length-1)|Where-Object {$raw[$_] -ne $after[$_]})
 $result=@{environment=$PSVersionTable.PSVersion.ToString();scope='Exact AST production PowerShell fuse wrapper -> exact Invoke-RtlNodeCli -> full production Node editor; only synthetic binary and junction';outsideFixtureChangedOffsets=$changes;logs=@($script:Logs|ForEach-Object {$_.Replace($fixture,'<fixture>')});limitations='Not robocopy/staging install E2E; no real app binary, TOCTOU or elevated permissions'}
 if($changes.Count -ne 1 -or $changes[0] -ne 50){throw 'Wrapper bypass not reproduced'}
 $json=$result|ConvertTo-Json -Depth 5
 [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'fuse-wrapper-results.json'),$json,[Text.UTF8Encoding]::new($false));$json
}finally{$env:TEMP=$tempSaved;$env:TMP=$tmpSaved}
