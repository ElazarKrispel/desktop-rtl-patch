# One result contract for CLI, installer, settings and background workers.
function New-RtlOperationResult {
    param([ValidateSet('Succeeded','AlreadyCurrent','Deferred','Busy','Blocked','Partial','Failed')][string]$Status,
          [string]$Reason='', [bool]$Prepared=$false, [string[]]$Leftovers=@(), [string]$NextAction='', [string]$App=$script:ActiveProfile.Id)
    $success=$Status -in @('Succeeded','AlreadyCurrent')
    if (-not $NextAction -and -not $success) {
        $NextAction=switch ($Status) {
            'Busy' { 'Wait for the active operation or close the RTL copy, then retry.' }
            'Deferred' { 'Close the RTL copy; the next update pass will continue.' }
            'Partial' { 'Close programs using the listed resources or reboot, then retry removal.' }
            default { 'Read the reported reason, then retry explicitly or collect diagnostics.' }
        }
    }
    return [pscustomobject]@{ App=$App; Status=$Status; Success=$success; Certain=$success;
        Reason=$Reason; Prepared=$Prepared; Leftovers=@($Leftovers); NextAction=$NextAction }
}
function Get-RtlOperationExitCode {
    param($Result)
    if ($Result -and $Result.Success) { return 0 }
    switch ($Result.Status) { 'Deferred' {2} 'Busy' {3} 'Blocked' {4} 'Partial' {5} default {1} }
}
function Format-RtlOperationResult {
    param($Result)
    if (-not $Result) { return 'Failed: operation returned no result.' }
    $parts=@([string]$Result.Status)
    if ($Result.Reason) { $parts += [string]$Result.Reason }
    if ($Result.Leftovers) { $parts += ('Remaining resources: ' + (@($Result.Leftovers) -join ', ')) }
    if ($Result.NextAction) { $parts += [string]$Result.NextAction }
    return ($parts -join "`r`n")
}
function Write-RtlOperationRecord {
    param($Record)
    [void][IO.Directory]::CreateDirectory((Get-RtlSafePath -Path $script:StateDir))
    $path=Join-Path $script:StateDir 'last-operation.json'
    $tmp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText((Get-RtlSafePath -Path $tmp),($Record | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding $false))
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace((Get-RtlSafePath -Path $tmp),(Get-RtlSafePath -Path $path),[NullString]::Value) }
        else { [IO.File]::Move((Get-RtlSafePath -Path $tmp),(Get-RtlSafePath -Path $path)) }
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-RtlSafeItem -LiteralPath $tmp -Force -ErrorAction Stop } }
}
function Save-RtlOperationResult {
    param([Parameter(Mandatory)]$Result,[ValidateSet('uninstall','update')][string]$Operation,
          [string]$OperationId=([guid]::NewGuid().ToString('N')))
    if (-not (Enter-RtlLock)) { throw '[LOCK] Cannot persist operation result while another operation is active.' }
    try {
        Write-RtlOperationRecord ([ordered]@{schemaVersion=1; App=$script:ActiveProfile.Id; Operation=$Operation;
            OperationId=$OperationId; CompletedAt=[DateTime]::UtcNow.ToString('o'); Acknowledged=$false; Result=$Result})
    } finally { Exit-RtlLock }
}
function Get-RtlLastOperation {
    param($Profile=$script:ActiveProfile)
    $path=Join-Path $Profile.StateDir 'last-operation.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $record=Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($record.schemaVersion -eq 1 -and $record.App -eq $Profile.Id -and $record.OperationId -and $record.Result) { return $record }
    } catch { Write-RtlLog "Cannot read operation result: $($_.Exception.Message)" }
    return $null
}
function Acknowledge-RtlOperationResult {
    param([Parameter(Mandatory)][string]$OperationId)
    # Serialize acknowledgement against a worker publishing a newer operation.
    if (-not (Enter-RtlLock)) { return }
    try {
        $record=Get-RtlLastOperation
        if ($record -and $record.OperationId -eq $OperationId) { $record.Acknowledged=$true; Write-RtlOperationRecord $record }
    } finally { Exit-RtlLock }
}

function Confirm-RtlActiveCopy {
    param($Source,[switch]$AllowExternalNodeFallback)
    Assert-RtlSafePath -Path $script:CopyRoot -Tree
    $p=$script:ActiveProfile
    if (-not (Test-Path -LiteralPath (Join-Path $script:CopyRoot $p.ExeRelPath))) { throw '[VERIFY] Active executable is missing.' }
    if ($p.RendererMode -eq 'prebuilt') {
        Test-HerdrRtlBuild -Root $script:CopyRoot -Source $Source | Out-Null
        $hash=Get-HerdrFileSha256 -Path (Join-Path $script:CopyRoot $p.ExeRelPath)
        if (-not $hash) { throw '[VERIFY] Active Herdr binary digest could not be read.' }
        return [pscustomobject]@{payloadSha256=$hash;asarSha256=$null}
    }
    $patch=Get-PatchJsPath
    if (-not $patch) { throw '[VERIFY] Expected payload is missing from this tool.' }
    $expected=(Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash
    if ($p.RendererMode -eq 'dir') {
        $dir=Get-RtlRendererDir -Profile $p -Root $script:CopyRoot
        Test-RtlDirInjection -RendererDir $dir | Out-Null
        $hash=(Get-FileHash -LiteralPath (Join-Path $dir ('assets\'+$script:RtlDirPayloadName)) -Algorithm SHA256).Hash
        $verified=[pscustomobject]@{payloadSha256=$hash;asarSha256=$null}
    } elseif ($p.RendererMode -eq 'inline') {
        $dir=Get-RtlRendererDir -Profile $p -Root $script:CopyRoot
        Test-RtlInlineInjection -RendererDir $dir | Out-Null
        $html=[IO.File]::ReadAllText((Join-Path $dir 'index.html'))
        $tag=[regex]::Match($html,(Get-RtlInlineTagRegex 'desktop-rtl-payload')).Value
        $body=$tag.Substring($tag.IndexOf('>')+1); $body=$body.Substring(0,$body.LastIndexOf('</script>',[StringComparison]::OrdinalIgnoreCase))
        if ($body -cne [IO.File]::ReadAllText($patch)) { throw '[VERIFY] Active inline payload differs from the tool payload.' }
        $verified=[pscustomobject]@{payloadSha256=$expected;asarSha256=$null}
    } else {
        $verified=Test-RtlInjection -AsarPath (Join-Path $script:CopyRoot $p.AsarRelPath) -AllowExternalNodeFallback:$AllowExternalNodeFallback
    }
    if (-not $verified.payloadSha256 -or $verified.payloadSha256 -ine $expected) { throw '[VERIFY] Active payload hash differs from the tool payload.' }
    return $verified
}

function Restore-RtlPreviousCopy {
    if (-not (Test-Path -LiteralPath $script:OldRoot)) { return }
    if (Test-CodexRtlRunning) { throw '[VERIFY] Close the RTL copy before restoring the previous version.' }
    if (Test-Path -LiteralPath $script:CopyRoot) {
        if (Test-Path -LiteralPath $script:Staging) { throw '[VERIFY] Recovery needs attention: both staging and the unverified copy exist. Previous copy retained.' }
        Rename-RtlSafeItem -LiteralPath $script:CopyRoot -NewName (Split-Path $script:Staging -Leaf) -ErrorAction Stop
    }
    Rename-RtlSafeItem -LiteralPath $script:OldRoot -NewName (Split-Path $script:CopyRoot -Leaf) -ErrorAction Stop
    # An unverified tree is never eligible for warm-staging reuse.
    $marker=Join-Path $script:Staging '.codexrtl-sig'
    if (Test-Path -LiteralPath $marker) { Remove-RtlSafeItem -LiteralPath $marker -Force -ErrorAction Stop }
}

function Invoke-RtlVerifiedSwap {
    param($Source,[switch]$AllowExternalNodeFallback)
    Write-RtlManagementReceipt -Phase VerificationPending
    Invoke-AtomicSwap -KeepPrevious
    try { return (Confirm-RtlActiveCopy -Source $Source -AllowExternalNodeFallback:$AllowExternalNodeFallback) }
    catch {
        $failure=$_.Exception.Message
        try { Restore-RtlPreviousCopy } catch { $failure += ' Recovery: ' + $_.Exception.Message }
        Write-RtlManagementReceipt -Phase VerificationPending -Leftovers @($script:OldRoot,$script:Staging)
        throw "[VERIFY] Active-copy verification failed. $failure"
    }
}
function Complete-RtlPreviousCopy {
    param([switch]$ReseedStaging)
    if (Test-Path -LiteralPath $script:OldRoot) {
        if ($ReseedStaging) { Rename-RtlSafeItem -LiteralPath $script:OldRoot -NewName (Split-Path $script:Staging -Leaf) -ErrorAction Stop }
        else { Remove-RtlSafeItem -LiteralPath $script:OldRoot -Recurse -Force -ErrorAction Stop }
    }
}
