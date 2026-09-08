param([string]$RepoRoot = 'C:\rtl-audit-20260907')
$ErrorActionPreference = 'Stop'
$root = Join-Path 'C:\rtl-audit-20260907-fixtures' ('packaging-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$rows = @()
$lib = Join-Path $RepoRoot 'scripts\lib\desktop-rtl-lib.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($lib,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Parse error' }
foreach ($name in @('Get-RtlUpdateDecision','Test-RtlPackage')) {
    $fn = $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | Where-Object Name -eq $name
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:PatchVersion = '2.5.0'
$assets = @(
    [pscustomobject]@{name='desktop-rtl-patch-2.5.1.zip';browser_download_url='https://fixture.invalid/product.zip'},
    [pscustomobject]@{name='debug-symbols.zip';browser_download_url='https://fixture.invalid/debug.zip'},
    [pscustomobject]@{name='SHA256SUMS.txt';browser_download_url='https://fixture.invalid/SHA256SUMS.txt'})
$decision = Get-RtlUpdateDecision -Tag v2.5.1 -Assets $assets
$rows += [pscustomobject]@{id='F10-asset';expected='product.zip';actual=$decision.ZipUrl;reproduced=($decision.ZipUrl -eq 'https://fixture.invalid/debug.zip');scope='Exact pure production function, synthetic metadata'}

$condition = $ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.StartLineNumber -eq 2896},$true)
if (-not $condition) { throw 'Checksum predicate source moved' }
$have = 'a' * 64
$sums = "$have  unrelated.zip"
$rejects = & ([scriptblock]::Create($condition.Clauses[0].Item1.Extent.Text))
$rows += [pscustomobject]@{id='F10-checksum';expected='Reject wrong filename';actual=('Rejected=' + $rejects);reproduced=(-not $rejects);scope='Exact production condition only; not a network or authenticity test'}

$minimal = Join-Path $root 'minimal-package'
foreach ($rel in @('scripts\lib\desktop-rtl-lib.ps1','scripts\lib\asar-edit.mjs','src\desktop-rtl-patch.js','scripts\Watch-DesktopRtl.ps1')) {
    $p = Join-Path $minimal $rel
    [IO.Directory]::CreateDirectory((Split-Path $p -Parent)) | Out-Null
    [IO.File]::WriteAllText($p,'fixture')
}
$accepted = Test-RtlPackage -RepoRoot $minimal
$rows += [pscustomobject]@{id='F10-package-validator';expected='Reject absent GUI, tray, Herdr dependency';actual=$accepted;reproduced=[bool]$accepted;scope='Exact production helper on four dummy files'}

$buildRoot = Join-Path $root 'build'
[IO.Directory]::CreateDirectory((Join-Path $buildRoot 'scripts')) | Out-Null
Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts\Build-Release.ps1') -Destination (Join-Path $buildRoot 'scripts\Build-Release.ps1')
# The copied build script derives every output/delete target from its own PSScriptRoot.
# buildRoot is a fresh unique descendant of this fixture; no preexisting dist is touched.
$buildLog = & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -File (Join-Path $buildRoot 'scripts\Build-Release.ps1') -Version 0.0.0 2>&1
$exit = $LASTEXITCODE
$rows += [pscustomobject]@{id='F10-build-missing';expected='Nonzero, no distributable';actualExit=$exit;zipExists=(Test-Path (Join-Path $buildRoot 'dist\desktop-rtl-patch-0.0.0.zip'));reproduced=($exit -eq 0);scope='Unchanged full build script in fresh fixture missing src, launchers and runtime; never published'}
[IO.File]::WriteAllLines((Join-Path $PSScriptRoot 'build-missing.log'),[string[]]$buildLog)

$bootstrap = Join-Path $RepoRoot 'install.ps1'
$previousTemp = $env:TEMP
$env:TEMP = Join-Path $root 'bootstrap-temp'
[IO.Directory]::CreateDirectory($env:TEMP) | Out-Null
$auditRequests = New-Object 'System.Collections.Generic.List[string]'
function Invoke-WebRequest {
    param($Uri,$OutFile,[switch]$UseBasicParsing)
    $auditRequests.Add([string]$Uri)
    if ([string]$Uri -like '*SHA256SUMS.txt') { throw 'Fixture timeout downloading checksum' }
    if ($OutFile) {
        if (-not ([IO.Path]::GetFullPath($OutFile).StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase))) { throw 'Fixture path escape' }
        [IO.File]::WriteAllText($OutFile,'fixture only')
    }
}
function Expand-Archive { param($Path,$DestinationPath,[switch]$Force) throw 'FIXTURE_STOP_BEFORE_EXTRACTION' }
function Start-Process { throw 'Unexpected launch forbidden' }
try { & $bootstrap; throw 'Expected fixture stop' }
catch { if ($_.Exception.Message -ne 'FIXTURE_STOP_BEFORE_EXTRACTION') { throw } }
finally { $env:TEMP = $previousTemp }
$fallback = @($auditRequests | Where-Object {$_ -like '*archive/refs/tags/*'}).Count -gt 0
$rows += [pscustomobject]@{id='F10-bootstrap-fallback';expected='Fail on checksum request timeout';actual='Source archive requested then fixture stopped before extraction';reproduced=$fallback;requests=@($auditRequests.ToArray());scope='Full bootstrap with only network/extraction/process boundaries stubbed; no install or real network'}

$out = [pscustomobject]@{sourceCommit='02cc70a8b750de4bc88b740cf8a64f292a5c0325';os=[Environment]::OSVersion.VersionString;psVersion=$PSVersionTable.PSVersion.ToString();tests=$rows;fixturePolicy='No registry, events, shortcuts or application processes; fixture retained, no recursive cleanup'}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'probe-packaging-results.json'),($out | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding $false))
$rows | Format-Table id,reproduced -AutoSize
if (@($rows | Where-Object {-not $_.reproduced}).Count) { exit 1 }
