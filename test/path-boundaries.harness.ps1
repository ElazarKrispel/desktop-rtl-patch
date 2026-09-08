param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent), [switch]$Baseline)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'scripts\lib\desktop-rtl-lib.ps1')
# Only synthetic filesystem targets. No OS integration functions are called.
function Write-RtlLog { param($Message) }
$fixture = Join-Path $env:TEMP ('rtl-path-ps-' + [guid]::NewGuid().ToString('N'))
foreach ($part in @('staging','outside','temp','state')) { [void][IO.Directory]::CreateDirectory((Join-Path $fixture $part)) }
$outside = Join-Path $fixture 'outside'
$root = Join-Path $fixture 'staging'
$junction = Join-Path $root 'link'
New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
$prof = [pscustomobject]@{Mode='copy';CopyRoot=(Join-Path $fixture 'copy');Staging=$root;FuseFlipInCopy=$true;DisplayName='fixture'}
$script:StateDir = Join-Path $fixture 'state'
$script:StateFile = Join-Path $script:StateDir 'state.json'
$script:ConfigFile = Join-Path $script:StateDir 'config.json'
$checks = New-Object System.Collections.Generic.List[string]
function Expect-SafetyBlock {
    param([string]$Name, [scriptblock]$Action)
    $blocked = $false
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -notmatch '\[SAFETY\]') { throw }; $blocked = $true }
    if (-not $blocked) { throw "Expected safety rejection: $Name" }
    $checks.Add($Name)
}
$tempSaved=$env:TEMP; $tmpSaved=$env:TMP
try {
    $env:TEMP=Join-Path $fixture 'temp'; $env:TMP=$env:TEMP
    $target=Join-Path $outside 'fixture.bin'
    $raw=[Text.Encoding]::ASCII.GetBytes('fixture-onlydL7pKGdnNz796PbbjQWNKmHXBZaB9tsX')+[byte[]]@(1,8)+[Text.Encoding]::ASCII.GetBytes('00001000tail')
    [IO.File]::WriteAllBytes($target,$raw)
    $fuse={ Assert-RtlAsarFuseOff -Node (Get-Command node.exe -ErrorAction Stop).Source -ScanPath (Join-Path $junction 'fixture.bin') -Profile $prof }
    if($Baseline){ & $fuse; if([Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -eq [Convert]::ToBase64String($raw)){throw 'Baseline bypass not reproduced'}; $checks.Add('BEFORE: actual PowerShell -> Node wrapper changed outside synthetic binary') }
    else {
        Expect-SafetyBlock 'full PowerShell -> Node fuse pipeline rejects junction' $fuse
        if([Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -ne [Convert]::ToBase64String($raw)){throw 'External binary changed'}
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $outside 'assets'))
    $html='<html><head><script type="module" src="./assets/main-a.js"></script></head></html>'
    [IO.File]::WriteAllText((Join-Path $outside 'index.html'),$html)
    $payload=Join-Path $fixture 'patch.js'; [IO.File]::WriteAllText($payload,'/* synthetic */')
    $dirInject={ Invoke-RtlDirInject -RendererDir $junction -Profile $prof -PatchJs $payload }
    if($Baseline){ & $dirInject; if([IO.File]::ReadAllText((Join-Path $outside 'index.html')) -eq $html){throw 'Baseline dir bypass not reproduced'}; $checks.Add('BEFORE: actual directory injection changed outside synthetic renderer') }
    else {
        Expect-SafetyBlock 'directory injection rejects junction before payload copy' $dirInject
        if([IO.File]::ReadAllText((Join-Path $outside 'index.html')) -ne $html){throw 'Outside HTML changed'}
        if(Test-Path (Join-Path $outside 'assets\desktop-rtl-patch.js')){throw 'Outside payload created'}
        Expect-SafetyBlock 'not-yet-created descendants reject junction ancestor' { Assert-RtlSafePath (Join-Path $junction 'new\nested\file') }
        Expect-SafetyBlock 'selected root itself is a junction' { Assert-RtlSafePath $junction }
        Expect-SafetyBlock 'recursive cleanup rejects child junction before deletion' { Remove-RtlSafeItem -LiteralPath $root -Recurse -Force }
        Expect-SafetyBlock 'recursive copy rejects destination child junction' { Copy-RtlSafeItem -LiteralPath $payload -Destination $root -Force }
        Expect-SafetyBlock 'mirror rejects destination child junction before robocopy' { Invoke-Robocopy -From $script:StateDir -To $root }
        Expect-SafetyBlock 'rename rejects nested junction before moving tree' { Rename-RtlSafeItem -LiteralPath $root -NewName 'renamed-staging' }
        $hardTarget=Join-Path $outside 'hard-state.json';[IO.File]::WriteAllText($hardTarget,'{}')
        $hardPath=Join-Path $script:StateDir 'hard-state.json'
        New-Item -ItemType HardLink -Path $hardPath -Target $hardTarget | Out-Null
        $script:StateFile=$hardPath
        Expect-SafetyBlock 'native metadata guard rejects hardlinked state file' { Write-RtlState @{} }
        if([IO.File]::ReadAllText($hardTarget) -ne '{}'){throw 'Hardlinked outside state changed'}
        $script:StateFile=Join-Path $junction 'new-state.json'
        Expect-SafetyBlock 'state writer rejects redirected destination' { Write-RtlState @{} }
        if(Test-Path $script:StateFile){throw 'Outside state written'}
        Expect-SafetyBlock 'copy-root lookalike is not authorized' { Assert-RtlWriteAllowed -Profile $prof -Path (Join-Path ($root+'-sibling') 'a') }
        $normal=Join-Path $root 'normal';[void][IO.Directory]::CreateDirectory((Join-Path $normal 'assets'))
        [IO.File]::WriteAllText((Join-Path $normal 'index.html'),$html)
        Invoke-RtlDirInject -RendererDir $normal -Profile $prof -PatchJs $payload -ConfigJs $payload
        if(-not (Test-RtlDirInjection -RendererDir $normal)){throw 'Normal dir injection failed'}
        $checks.Add('normal directory inject and verify pass')
    }
    [pscustomobject]@{mode=$(if($Baseline){'BEFORE'}else{'AFTER'});powershell=$PSVersionTable.PSVersion.ToString();checks=@($checks);fixture=$fixture;limitation='Synthetic files only; no production install, Registry, shortcuts, events, or concurrent rename test. Fixture retained.'}|ConvertTo-Json -Depth 4
} finally { $env:TEMP=$tempSaved; $env:TMP=$tmpSaved }
