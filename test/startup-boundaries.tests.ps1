param([switch]$Baseline,[string]$SourceRoot)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
if (-not $SourceRoot) { $SourceRoot=$repo }
. (Join-Path $repo 'scripts\lib\desktop-rtl-paths.ps1')
$tray=Join-Path $SourceRoot 'scripts\DesktopRtlTray.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($tray,[ref]$null,[ref]$null)
$startup=$ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.IfStatementAst] } | Select-Object -First 1
if(-not $startup -or $startup.Extent.Text -notmatch 'Test-RtlBinFiles'){throw 'Startup AST not found'}
# Bind the script-root automatic variable to the production script's directory;
# the executed control flow and all mutations remain the actual AST source.
$boundSource=$startup.Extent.Text.Replace('$PSScriptRoot',("'"+(Split-Path $tray -Parent).Replace("'","''")+"'"))
$startupAction=[scriptblock]::Create($boundSource)
$fixture=Join-Path $env:TEMP ('rtl-startup-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$savedLocal=$env:LOCALAPPDATA
$script:launches=0; $script:diagnostics=@()
function Start-Process {
    param($FilePath,$ArgumentList)
    $script:launches++
    # Readiness is a fixture record, not an OS process or named event.
    [IO.File]::WriteAllText((Join-Path $script:caseHome 'ready.json'),'{"generation":"fixture","pid":123}')
}
function Get-Process {param($Id) return [pscustomobject]@{Id=123} }
function Start-Sleep {throw 'Unexpected readiness wait in fixture'}
function Write-Warning {param($Message) $script:diagnostics+= [string]$Message }
function Invoke-WebRequest {throw 'Network is forbidden'}
function New-Object {param($TypeName) throw "OS object creation forbidden: $TypeName"}
function New-Case {
    param([string]$Name,[switch]$Redirect)
    $base=Join-Path $fixture $Name
    $local=Join-Path $base 'local';[void][IO.Directory]::CreateDirectory($local)
    $agentFixtureHome=Join-Path $local 'DesktopRtlPatch'
    if($Redirect){$physical=Join-Path $base 'outside';[void][IO.Directory]::CreateDirectory($physical);New-Item -ItemType Junction -Path $agentFixtureHome -Target $physical|Out-Null}
    else{$physical=$agentFixtureHome;[void][IO.Directory]::CreateDirectory($agentFixtureHome)}
    foreach($dir in @('bin','bin.staging')){
        $path=Join-Path $physical $dir;[void][IO.Directory]::CreateDirectory($path)
        foreach($file in @('desktop-rtl-lib.ps1','desktop-rtl-paths.ps1','desktop-rtl-managed.ps1','desktop-rtl-results.ps1','asar-edit.mjs','desktop-rtl-patch.js','Watch-DesktopRtl.ps1','DesktopRtlTray.ps1','Desktop-RTL-Tray.vbs')){[IO.File]::WriteAllText((Join-Path $path $file),'synthetic fixture, never executed')}
        [IO.File]::WriteAllText((Join-Path $path 'identity.txt'),$dir)
        [IO.File]::WriteAllText((Join-Path $path 'generation.txt'),'fixture')
    }
    [IO.File]::WriteAllText((Join-Path $physical 'pending-selfupdate'),'fixture')
    return [pscustomobject]@{Local=$local;Home=$physical}
}
function Get-TreeSnapshot {
    param([string]$Root)
    return (@(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($Root.Length)+':'+[IO.File]::ReadAllText($_.FullName)
    }) -join "`n")
}
try{
    $SelfTest=$false;$NoRelaunch=$false
    $case=New-Case 'junction' -Redirect;$env:LOCALAPPDATA=$case.Local;$script:caseHome=$case.Home
    $before=Get-TreeSnapshot $case.Home
    & $startupAction
    $identity=[IO.File]::ReadAllText((Join-Path $case.Home 'bin\identity.txt'))
    if($Baseline){if($identity -ne 'bin.staging' -or $script:launches -ne 1){throw 'Baseline redirected startup mutation not reproduced'}}
    else{
        if($identity -ne 'bin' -or $script:launches -ne 0){throw 'Redirected startup mutated or launched'}
        if((Get-TreeSnapshot $case.Home) -cne $before){throw 'External tree changed'}
        if(-not (Test-Path (Join-Path $case.Home 'pending-selfupdate')) -or -not $script:diagnostics){throw 'Missing retained evidence or diagnostic'}
        $case=New-Case 'missing-helper';$env:LOCALAPPDATA=$case.Local;$script:caseHome=$case.Home
        # A single fixture file is deleted, never a recursive or original-app target.
        [IO.File]::Delete((Join-Path $case.Home 'bin.staging\desktop-rtl-managed.ps1'))
        & $startupAction
        if([IO.File]::ReadAllText((Join-Path $case.Home 'bin\identity.txt')) -ne 'bin' -or $script:launches -ne 0){throw 'Incomplete runtime swapped or launched'}
        $case=New-Case 'missing-launcher';$env:LOCALAPPDATA=$case.Local;$script:caseHome=$case.Home
        [IO.File]::Delete((Join-Path $case.Home 'bin.staging\Desktop-RTL-Tray.vbs'))
        & $startupAction
        if([IO.File]::ReadAllText((Join-Path $case.Home 'bin\identity.txt')) -ne 'bin' -or $script:launches -ne 0){throw 'Missing launcher still swapped'}
        $case=New-Case 'linked-rollback';$env:LOCALAPPDATA=$case.Local;$script:caseHome=$case.Home
        $rollbackOutside=Join-Path $fixture 'rollback-outside';[void][IO.Directory]::CreateDirectory($rollbackOutside)
        [IO.File]::WriteAllText((Join-Path $rollbackOutside 'sentinel'),'keep')
        New-Item -ItemType Junction -Path (Join-Path $case.Home 'bin.old') -Target $rollbackOutside|Out-Null
        & $startupAction
        if([IO.File]::ReadAllText((Join-Path $case.Home 'bin\identity.txt')) -ne 'bin' -or $script:launches -ne 0){throw 'Linked rollback caused partial swap'}
        if([IO.File]::ReadAllText((Join-Path $rollbackOutside 'sentinel')) -ne 'keep'){throw 'Outside rollback target changed'}
        $case=New-Case 'normal';$env:LOCALAPPDATA=$case.Local;$script:caseHome=$case.Home
        & $startupAction
        if([IO.File]::ReadAllText((Join-Path $case.Home 'bin\identity.txt')) -ne 'bin.staging' -or $script:launches -ne 1){throw 'Normal staged startup failed'}
        foreach($surface in @(@{File='Install-DesktopRtlGui.ps1';Variable='LogsDir'},@{File='DesktopRtlTray.ps1';Variable='AgentHome'})){
            $surfaceAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot ('scripts\'+$surface.File)),[ref]$null,[ref]$null)
            $variable=$surface.Variable
            $command=$surfaceAst.Find({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'New-Item' -and $n.Extent.Text.Contains('$script:'+$variable)},$true)
            if(-not $command){throw 'Logs directory command missing'}
            $outsideLogs=Join-Path $fixture ('log-outside-'+$variable);[void][IO.Directory]::CreateDirectory($outsideLogs)
            $linkLogs=Join-Path $fixture ('log-link-'+$variable);New-Item -ItemType Junction -Path $linkLogs -Target $outsideLogs|Out-Null
            Set-Variable -Scope Script -Name $variable -Value (Join-Path $linkLogs 'must-not-create')
            $rejected=$false
            try{ & ([scriptblock]::Create($command.Extent.Text))|Out-Null }catch{if($_.Exception.Message -notmatch '\[SAFETY\]'){throw};$rejected=$true}
            if(-not $rejected -or @(Get-ChildItem -LiteralPath $outsideLogs).Count){throw 'Logs action created outside directory'}
        }
    }
    [pscustomobject]@{mode=$(if($Baseline){'BEFORE'}else{'AFTER'});powershell=$PSVersionTable.PSVersion.ToString();cases=$(if($Baseline){1}else{7});fixture=$fixture;scope='Actual startup If AST and logs New-Item commands. Synthetic bin trees; process launch/readiness mocked; no real UI, Registry, network or named events. Fixture retained.'}|ConvertTo-Json
}finally{$env:LOCALAPPDATA=$savedLocal}
