[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$testRepo = Split-Path $PSScriptRoot -Parent
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell)) { throw 'Windows PowerShell 5.1 is required.' }
    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}
$node = (Get-Command node -ErrorAction Stop).Source
if (-not $node) { throw 'Node.js is required; required checks cannot be skipped.' }
$psFiles = @((Get-Item (Join-Path $testRepo 'install.ps1'))) + @(Get-ChildItem (Join-Path $testRepo 'scripts'),$PSScriptRoot -Recurse -Filter '*.ps1' -File)
foreach ($file in $psFiles) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$errors)
    if ($errors.Count) { throw "PowerShell parse failed: $($file.FullName): $($errors.Message -join '; ')" }
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
    $text = [IO.File]::ReadAllText($file.FullName,[Text.Encoding]::UTF8)
    if ($text -match '[^\x00-\x7F]' -and -not $bom) { throw "Non-ASCII PowerShell needs UTF-8 BOM for PS5.1: $($file.Name)" }
    if ($file.Name -in @('desktop-rtl-lib.ps1','desktop-rtl-herdr.ps1') -and $text -match '[^\x00-\x7F]') { throw "Shared library must remain ASCII: $($file.Name)" }
}
foreach ($file in @('scripts\lib\asar-edit.mjs','src\desktop-rtl-patch.js')) {
    & $node --check (Join-Path $testRepo $file)
    if ($LASTEXITCODE -ne 0) { throw "Node syntax check failed: $file" }
}
Write-Host "PASS: $($psFiles.Count) PS5.1 parse/encoding checks; 2 Node syntax checks"
# Each harness owns process-wide environment and stubs. A fresh process prevents
# one suite's functions, environment or errors from leaking into the next one.
foreach ($suite in @('isolation.harness.ps1','renderer-injection.harness.ps1','herdr-lifecycle.harness.ps1','cleanup-receipt.tests.ps1')) {
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $suite)
    if ($LASTEXITCODE -ne 0) { throw "Test suite failed: $suite (exit $LASTEXITCODE)" }
}
Write-Host 'PASS: all required isolated suites'
