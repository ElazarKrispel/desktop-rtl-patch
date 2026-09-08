# Extract the actual registry-cleanup function; every Registry/native call is modeled.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
function Load-Function([string]$Text) {
    $ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$null,[ref]$null)
    $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-RtlCopyShellRegistrations'},$true)
    if (-not $fn) { throw 'Registry function not found.' }
    Set-Item Function:script:Remove-RtlCopyShellRegistrations ([scriptblock]::Create($fn.Body.Extent.Text.Substring(1,$fn.Body.Extent.Text.Length-2)))
}
function Test-Path { param($LiteralPath,$ErrorAction) return $script:hiveExists }
function reg {
    $script:queries++
    if ($script:queryMode -eq 'failure') { throw 'synthetic Registry access failure' }
    if ($script:queryMode -eq 'empty-error') { $global:LASTEXITCODE=1; return }
    $global:LASTEXITCODE=1
    return 'End of search: 0 match(es) found.'
}
function Remove-Item { throw 'No deletion is authorized by these discovery fixtures.' }
function Get-Item { throw 'No candidate reads are authorized by these discovery fixtures.' }
function Check($Condition,$Label) { if (-not $Condition) { throw "FAIL: $Label" }; $script:checks++ }
$checks=0; $queries=0; $hiveExists=$true; $queryMode='failure'
$baseline=(& git -C $repo show '02cc70a8b750de4bc88b740cf8a64f292a5c0325:scripts/lib/desktop-rtl-lib.ps1') -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Baseline history is required.' }
Load-Function $baseline
Check (@(Remove-RtlCopyShellRegistrations -CopyRoot 'C:\synthetic-copy').Count -eq 0) 'baseline silently treats failed discovery as no leftovers'
Load-Function ([IO.File]::ReadAllText((Join-Path $repo 'scripts\lib\desktop-rtl-lib.ps1')))
Check (@(Remove-RtlCopyShellRegistrations -CopyRoot 'C:\synthetic-copy').Count -eq 3) 'each failed hive discovery becomes a leftover'
$queryMode='empty-error'
Check (@(Remove-RtlCopyShellRegistrations -CopyRoot 'C:\synthetic-copy').Count -eq 3) 'native failure without readable output remains uncertain'
$queryMode='no-matches'
Check (@(Remove-RtlCopyShellRegistrations -CopyRoot 'C:\synthetic-copy').Count -eq 0) 'modeled native zero-match response is not a failure'
$hiveExists=$false; $queries=0
Check (@(Remove-RtlCopyShellRegistrations -CopyRoot 'C:\synthetic-copy').Count -eq 0) 'absent hives contain no registrations'
Check ($queries -eq 0) 'absent hives do not invoke native discovery'
Write-Output "PASS: $checks Registry outcome assertions; all Registry/native boundaries modeled."
