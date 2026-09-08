param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot '..\install.ps1'),
    [string]$ResultPath
)
$ErrorActionPreference = 'Stop'
# Execute the complete bootstrap with network, archive and process boundaries replaced.
# Only synthetic files beneath this new directory are written. No product is launched.
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('rtl-bootstrap-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
$code = [scriptblock]::Create([IO.File]::ReadAllText((Resolve-Path -LiteralPath $ScriptPath)))
$bytes = [Text.Encoding]::ASCII.GetBytes('synthetic archive, never extracted')
$sha = [Security.Cryptography.SHA256]::Create()
try { $digest = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
$assetName = 'desktop-rtl-patch-2.5.0.zip'
$oldEnv = @{}
foreach ($key in @('TEMP', 'WINDIR', 'RTL_SILENT', 'RTL_APP')) { $oldEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
$results = New-Object Collections.Generic.List[object]
function Invoke-TestCli { $script:calls.Launch++; $global:LASTEXITCODE = 0 }
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing)
    $script:calls.Download++
    if ($Uri -like '*/archive/refs/tags/*') { $script:calls.Fallback++ }
    if ($OutFile) {
        if ($script:scenario -eq 'asset-unavailable' -and $Uri -like '*/releases/download/*') { throw 'Synthetic asset timeout' }
        [IO.File]::WriteAllBytes($OutFile, $bytes)
        return
    }
    if ($Uri -notlike '*/SHA256SUMS.txt') { throw "Unexpected test URL: $Uri" }
    if ($script:scenario -eq 'checksum-unavailable') { throw 'Synthetic checksum timeout' }
    $content = switch ($script:scenario) {
        'empty-checksum' { '' }
        'wrong-hash' { ('0' * 64) + '  ' + $assetName }
        'wrong-filename' { $digest + '  unrelated.zip' }
        'malformed-checksum' { 'not-a-checksum ' + $digest + ' trailer' }
        'duplicate-entry' { "$digest  $assetName`n$digest  $assetName" }
        'valid-byte-content' { ,([Text.Encoding]::ASCII.GetBytes("$digest  $assetName`r`n")) }
        'valid-binary-marker' { "$digest *$assetName`n" }
        'valid-extra-entry' { ('0' * 64) + "  unrelated.zip`n$digest  $assetName" }
        default { "$digest  $assetName`n" }
    }
    [pscustomobject]@{ Content = $content }
}
function Expand-Archive {
    param($Path, $DestinationPath, [switch]$Force)
    $script:calls.Extract++
    $scripts = Join-Path $DestinationPath 'synthetic-release\scripts'
    [IO.Directory]::CreateDirectory($scripts) | Out-Null
    foreach ($leaf in @('Install-DesktopRtl.ps1', 'Install-DesktopRtlGui.ps1')) { [IO.File]::WriteAllText((Join-Path $scripts $leaf), '# synthetic placeholder') }
}
function Start-Process { param($FilePath, $WindowStyle, $ArgumentList); $script:calls.Launch++ }
try {
    $env:TEMP = $fixtureRoot
    $env:WINDIR = $fixtureRoot
    $env:RTL_APP = 'herdr'
    # Even the call operator in the headless branch resolves to this alias, never an exe.
    $fakeExe = Join-Path $fixtureRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Set-Alias -Name $fakeExe -Value Invoke-TestCli
    foreach ($mode in @('gui', 'cli')) {
      foreach ($scenarioName in @('checksum-unavailable', 'asset-unavailable', 'empty-checksum', 'wrong-hash', 'wrong-filename', 'malformed-checksum', 'duplicate-entry', 'valid', 'valid-byte-content', 'valid-binary-marker', 'valid-extra-entry')) {
        $script:scenario = $scenarioName
        $script:calls = @{ Download = 0; Fallback = 0; Extract = 0; Launch = 0 }
        $env:RTL_SILENT = if ($mode -eq 'cli') { '1' } else { $null }
        $errorText = $null
        try { & $code | Out-Null } catch { $errorText = $_.Exception.Message }
        $valid = $scenarioName -like 'valid*'
        $passed = if ($valid) { -not $errorText -and $script:calls.Extract -eq 1 -and $script:calls.Launch -eq 1 -and $script:calls.Fallback -eq 0 } else { $errorText -like '[[]INTEGRITY[]]*' -and $script:calls.Extract -eq 0 -and $script:calls.Launch -eq 0 -and $script:calls.Fallback -eq 0 }
        $results.Add([pscustomobject]@{ Case = $scenarioName; Mode = $mode; Passed = [bool]$passed; Error = $errorText; Calls = $script:calls.Clone() })
      }
    }
} finally {
    foreach ($key in $oldEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $oldEnv[$key], 'Process') }
    if ($fakeExe) { Remove-Item -LiteralPath ('Alias:' + $fakeExe) -ErrorAction SilentlyContinue }
}
$report = [pscustomobject]@{
    PowerShell = $PSVersionTable.PSVersion.ToString()
    ScriptSHA256 = (Get-FileHash -LiteralPath $ScriptPath -Algorithm SHA256).Hash
    Isolation = 'Synthetic bytes; mocked network, extraction and GUI/CLI launch; no real installer execution.'
    Cases = @($results.ToArray())
}
if ($ResultPath) { [IO.File]::WriteAllText($ResultPath, ($report | ConvertTo-Json -Depth 6) + [Environment]::NewLine) }
$results | Format-Table Case, Mode, Passed, Error -AutoSize
Write-Host ('Synthetic fixtures retained at: ' + $fixtureRoot)
if (@($results | Where-Object { -not $_.Passed }).Count) { throw 'Bootstrap integrity regression checks failed.' }
