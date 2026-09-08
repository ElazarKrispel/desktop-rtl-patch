param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent), [string]$ResultPath)
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('rtl-callers-' + [guid]::NewGuid().ToString('N'))
$libPath = Join-Path $fixture 'scripts\lib\desktop-rtl-lib.ps1'
[IO.Directory]::CreateDirectory((Split-Path $libPath -Parent)) | Out-Null
$stub = @'
function Set-RtlActiveApp($App) { $script:ActiveProfile = [pscustomobject]@{Id=$App;DisplayName=$App}; $script:ShortcutLabel='fixture'; $script:LogsDir='synthetic'; $script:LogFile='synthetic' }
function Invoke-CodexRtlUpdate { param([switch]$Force,[switch]$Auto,[switch]$AllowExternalNodeFallback); if($global:CallProbe.Throw){throw '[VERIFY] synthetic failure'}; $global:CallProbe.Result }
function Invoke-CodexRtlUninstall { param([switch]$PurgeLogs); if($global:CallProbe.Throw){throw '[LOCK] synthetic failure'}; $global:CallProbe.Result }
function Start-RtlInstallLog { }
function Test-RtlPackage { }
function Test-CodexRtlRunning { $false }
function Read-RtlState { [pscustomobject]@{codexVersion='stale';mode='copy'} }
function Install-RtlAgent { $global:CallProbe.Agent++ }
function Register-RtlAgent { $global:CallProbe.Agent++ }
function Restart-RtlAgentTray { $global:CallProbe.Agent++ }
function Invoke-RtlAgentLastCleanup { $global:CallProbe.Agent++; $global:CallProbe.Events.Add('cleanup') }
function Get-RtlInstalledApps { @() }
function Write-RtlUi { }
function Format-RtlOperationResult($Result) { $Result.Status + ': ' + $Result.Reason + '; ' + ($Result.Leftovers -join ',') + '; ' + $Result.NextAction }
function Get-RtlOperationExitCode($Result) { switch($Result.Status){Succeeded{0} AlreadyCurrent{0} Deferred{2} Busy{3} Blocked{4} Partial{5} default{1}} }
function Save-RtlOperationResult { param($Result,$Operation,$OperationId); if($global:CallProbe.SaveThrows){throw '[DISK] synthetic save failure'}; $global:CallProbe.Saved++; $global:CallProbe.Events.Add('saved') }
function New-RtlOperationResult { param($App,$Status,$Reason,$Leftovers,$NextAction); [pscustomobject]@{App=$App;Status=$Status;Reason=$Reason;Success=$false;Certain=$false;Leftovers=@($Leftovers);NextAction=$NextAction;Prepared=$false} }
'@
[IO.File]::WriteAllText($libPath, $stub)
. $libPath
function Read-Ast($relative) {
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $relative), [ref]$null, [ref]$errors)
    if ($errors) { throw ($errors | Out-String) }
    $ast
}
function Get-Worker($relative, $name) {
    $ast = Read-Ast $relative
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fn) { return $null }
    $call = $fn.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'AddScript'}, $true)
    if ($call) { return $call.Arguments[0].ScriptBlock.GetScriptBlock() }
}
$rows = New-Object Collections.Generic.List[object]
$workers = @(
    @{File='scripts/Install-DesktopRtlGui.ps1';Name='Start-Install';Kind='gui'},
    @{File='scripts/Install-DesktopRtlGui.ps1';Name='Start-Uninstall';Kind='gui'},
    @{File='scripts/DesktopRtlTray.ps1';Name='Start-TrayPass';Kind='pass'},
    @{File='scripts/DesktopRtlTray.ps1';Name='Start-AppUninstall';Kind='uninstall'}
)
foreach ($statusName in @('Succeeded','AlreadyCurrent','Deferred','Busy','Blocked','Partial','Failed','Thrown')) {
    $success = $statusName -in @('Succeeded','AlreadyCurrent')
    $result = [pscustomobject]@{App='herdr';Status=$statusName;Success=$success;Certain=$success;Reason='synthetic reason';Prepared=$false;Leftovers=@('synthetic locked item');NextAction='retry synthetic cleanup'}
    foreach ($worker in $workers) {
        $global:CallProbe = @{Result=$result;Agent=0;Saved=0;Throw=($statusName -eq 'Thrown');Events=(New-Object Collections.Generic.List[string])}
        $sync = @{Ok=$false;Done=$false;Err=$null;Results=$null;Lines=(New-Object Collections.Generic.List[string]);OperationId='synthetic-operation'}
        $AppsArg = @('herdr'); $AppId='herdr'; $DoForce=$true
        $body = Get-Worker $worker.File $worker.Name
        $passed = $false
        if ($body) {
            & $body | Out-Null
            $reported = switch($worker.Kind) {gui{[bool]$sync.Ok} pass{[bool]$sync.Results.herdr.ok} uninstall{[bool]$sync.Results.Success}}
            $passed = $sync.Done -and $reported -eq $success -and ($success -or $global:CallProbe.Agent -eq 0)
            if($worker.Kind -eq 'uninstall'){ $passed = $passed -and $global:CallProbe.Saved -eq 1 -and $global:CallProbe.Agent -eq 0 }
        }
        $rows.Add([pscustomobject]@{Case=($worker.Name+':'+$statusName);Passed=[bool]$passed;AgentCalls=$global:CallProbe.Agent;Saved=$global:CallProbe.Saved})
    }
    if($statusName -eq 'Thrown'){continue}
    foreach($leaf in @('Install-DesktopRtl.ps1','Update-DesktopRtl.ps1','Uninstall-DesktopRtl.ps1')) {
        $global:CallProbe = @{Result=$result;Agent=0;Saved=0;Throw=$false;Events=(New-Object Collections.Generic.List[string])}
        $path = Join-Path $fixture ('scripts\'+$leaf)
        [IO.File]::Copy((Join-Path $RepoRoot ('scripts\'+$leaf)), $path, $true)
        $global:LASTEXITCODE=0
        $output = & $path -App herdr 6>&1 | Out-String
        $expected = Get-RtlOperationExitCode $result
        $passed = $LASTEXITCODE -eq $expected -and ($success -or ($global:CallProbe.Agent -eq 0 -and $output -notmatch '\[OK\]'))
        $rows.Add([pscustomobject]@{Case=($leaf+':'+$statusName);Passed=[bool]$passed;ExitCode=$LASTEXITCODE;AgentCalls=$global:CallProbe.Agent})
    }
}
$settings = Read-Ast 'scripts/DesktopRtlSettings.ps1'
$fallback = $settings.Find({param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text -match '^\{\s*(\$res = )?Invoke-CodexRtlUpdate'},$true)
foreach($success in @($true,$false)) {
    $global:CallProbe=@{Result=[pscustomobject]@{Success=$success;Status='Deferred';Reason='fixture';Leftovers=@();NextAction='retry'};Throw=$false}
    $status=[pscustomobject]@{Text=''}
    $threw=$false
    if($fallback){$text=$fallback.Body.Extent.Text;try{& ([scriptblock]::Create($text.Substring(1,$text.Length-2)))}catch{$threw=$true}}
    $passed=$fallback -and $threw -eq (-not $success) -and ($success -or -not $status.Text)
    $rows.Add([pscustomobject]@{Case=('settings-fallback:'+ $success);Passed=[bool]$passed})
}
$global:CallProbe=@{Result=[pscustomobject]@{App='herdr';Success=$false;Status='Partial';Leftovers=@('synthetic locked item')};Throw=$false;SaveThrows=$true;Saved=0;Agent=0}
$sync=@{Done=$false;Results=$null;Err=$null;OperationId='save-failure'}
$body=Get-Worker 'scripts/DesktopRtlTray.ps1' 'Start-AppUninstall'
if($body){& $body | Out-Null}
$rows.Add([pscustomobject]@{Case='uninstall-save-failure';Passed=[bool]($sync.Done -and $sync.Results.Status -eq 'Failed' -and $sync.Results.Leftovers -contains 'synthetic locked item' -and $global:CallProbe.Agent -eq 0)})
# Execute the real tray completion function with a dialog double. No Forms are loaded.
$tray = Read-Ast 'scripts/DesktopRtlTray.ps1'
$completion = $tray.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-UninstallResult'},$true)
if ($completion) {
    . ([scriptblock]::Create($completion.Extent.Text))
    function Show-UninstallDialog { param($body,$title,$icon); $global:CallProbe.Events.Add('dialog'); $global:CallProbe.Message=$body }
    function Get-RtlAppLabel($id) { $id }
    function Invoke-AppAction($id,$body) { & $body }
    function Acknowledge-RtlOperationResult($OperationId) { $global:CallProbe.Events.Add('ack:'+ $OperationId) }
    function Invoke-Reconcile { param([switch]$Force) }
    foreach($success in @($true,$false)) {
        $global:CallProbe=@{Agent=0;Events=(New-Object Collections.Generic.List[string])}
        $result=[pscustomobject]@{App='herdr';Status= $(if($success){'Succeeded'}else{'Partial'});Success=$success;Reason='reason';Leftovers=@('synthetic locked item');NextAction='retry synthetic cleanup'}
        Show-UninstallResult $result -OperationId 'expected-id' -ReconcileAgent
        $events=$global:CallProbe.Events -join ','
        $passed=$events -eq $(if($success){'dialog,ack:expected-id,cleanup'}else{'dialog,ack:expected-id'}) -and $global:CallProbe.Message -match 'synthetic locked item' -and $global:CallProbe.Message -match 'retry synthetic cleanup'
        $rows.Add([pscustomobject]@{Case=('completion-order:'+ $success);Passed=[bool]$passed;Events=$events})
    }
} else { $rows.Add([pscustomobject]@{Case='completion-order';Passed=$false;Reason='No managed completion function'}) }
foreach($throwInWorker in @($false,$true)) {
    $body=Get-Worker 'scripts/DesktopRtlTray.ps1' 'Start-AppUninstall'
    $probe=@{Result=[pscustomobject]@{App='herdr';Status='Partial';Success=$false;Certain=$false;Reason='synthetic lock';Leftovers=@('synthetic locked item');NextAction='retry';Prepared=$false};Throw=$throwInWorker;Agent=0;Saved=0;Events=(New-Object Collections.Generic.List[string])}
    $workerSync=[hashtable]::Synchronized(@{Done=$false;Results=$null;Err=$null;OperationId='runspace-fixture'})
    if($body){
        $rs=[runspacefactory]::CreateRunspace(); $rs.Open()
        $ps=[powershell]::Create(); $ps.Runspace=$rs
        try {
            foreach($pair in @{CallProbe=$probe;Sync=$workerSync;LibPath=$libPath;AppId='herdr'}.GetEnumerator()){ $rs.SessionStateProxy.SetVariable($pair.Key,$pair.Value) }
            [void]$ps.AddScript($body.ToString())
            [void]$ps.Invoke()
        } finally { $ps.Dispose();$rs.Dispose() }
    }
    $expected=if($throwInWorker){'Failed'}else{'Partial'}
    $rows.Add([pscustomobject]@{Case=('actual-runspace:'+ $expected);Passed=[bool]($workerSync.Done -and $workerSync.Results.Status -eq $expected -and $probe.Saved -eq 1 -and $probe.Agent -eq 0)})
}
$hashes=@{}
foreach($file in @('Install-DesktopRtl.ps1','Update-DesktopRtl.ps1','Uninstall-DesktopRtl.ps1','Install-DesktopRtlGui.ps1','DesktopRtlTray.ps1','DesktopRtlSettings.ps1')){$hashes[$file]=(Get-FileHash -LiteralPath (Join-Path $RepoRoot ('scripts\'+$file)) -Algorithm SHA256).Hash}
$report=[pscustomobject]@{PowerShell=$PSVersionTable.PSVersion.ToString();Scripts=$hashes;Isolation='Real caller scriptblocks and CLI scripts, synthetic engine results, mocked agent lifecycle, persistence and dialog. Two actual runspace workers with synthetic dependencies. No actual UI, processes, Registry or events.';Cases=@($rows.ToArray())}
if($ResultPath){[IO.File]::WriteAllText($ResultPath,($report|ConvertTo-Json -Depth 6))}
$rows | Format-Table -AutoSize
Write-Host ('Synthetic fixtures retained at: '+$fixture)
if(@($rows|Where-Object {-not $_.Passed}).Count){throw 'Operation caller regression checks failed.'}
