# Management metadata is separate from installed-version state and user settings.
# Paths stored in receipts are diagnostics only; cleanup uses profile-owned paths.
function Get-RtlManagementReceipt {
    param($Profile = $script:ActiveProfile)
    $path = Join-Path $Profile.StateDir 'management.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $receipt = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($receipt.schemaVersion -ne 1 -or $receipt.appId -ne $Profile.Id -or
            $receipt.phase -notin @('Managed','CleanupPending','VerificationPending')) { throw 'Unsupported management receipt.' }
        return $receipt
    } catch {
        # Reading status must never quarantine/delete evidence or authorize an update.
        return [pscustomobject]@{ schemaVersion=0; appId=$Profile.Id; phase='CleanupPending'; installationId=$null; leftovers=@('management.json unreadable or unsupported; retry cleanup with a compatible tool') }
    }
}

function Write-RtlManagementReceipt {
    param([ValidateSet('Managed','CleanupPending','VerificationPending')][string]$Phase,
          [string[]]$Leftovers=@())
    $existing = Get-RtlManagementReceipt
    $installationId = if ($existing -and $existing.installationId) { $existing.installationId } else { [guid]::NewGuid().ToString('N') }
    $value = [ordered]@{ schemaVersion=1; appId=$script:ActiveProfile.Id; installationId=$installationId;
        phase=$Phase; updatedAt=[DateTime]::UtcNow.ToString('o'); leftovers=@($Leftovers) }
    [void][IO.Directory]::CreateDirectory((Get-RtlSafePath -Path $script:StateDir))
    $path = Join-Path $script:StateDir 'management.json'
    $tmp = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText((Get-RtlSafePath -Path $tmp), ($value | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace((Get-RtlSafePath -Path $tmp),(Get-RtlSafePath -Path $path),[NullString]::Value) }
        else { [IO.File]::Move((Get-RtlSafePath -Path $tmp),(Get-RtlSafePath -Path $path)) }
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-RtlSafeItem -LiteralPath $tmp -Force -ErrorAction Stop } }
}

function Test-RtlManagedArtifacts {
    param($Profile = $script:ActiveProfile)
    # Retained data, user config, logs and an idle lock file alone are not installs.
    foreach ($path in @($Profile.CopyRoot,$Profile.Staging,$Profile.OldRoot,
        (Join-Path $Profile.StateDir 'bin'), (Join-Path $Profile.StateDir 'bin.staging'),
        (Join-Path $Profile.StateDir 'bin.old'), (Join-Path $Profile.StateDir 'state.json'),
        (Join-Path $Profile.StateDir 'management.json'))) {
        if (Test-Path -LiteralPath $path) { return $true }
    }
    return $false
}

function Test-RtlCleanupPending {
    param($Profile = $script:ActiveProfile)
    $receipt = Get-RtlManagementReceipt -Profile $Profile
    if ($receipt) { return ($receipt.phase -eq 'CleanupPending') }
    # Adopt legacy partial removals without rewriting their state during enumeration.
    return ((-not (Test-Path -LiteralPath (Join-Path $Profile.CopyRoot $Profile.ExeRelPath))) -and (Test-RtlManagedArtifacts -Profile $Profile))
}
