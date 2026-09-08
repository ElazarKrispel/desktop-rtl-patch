# Dot-source only from a disposable test process. This is a fixture boundary,
# not a security sandbox for untrusted PowerShell or arbitrary .NET calls.
function Initialize-RtlTestSandbox {
    param([Parameter(Mandatory)][string]$RepositoryRoot)
    $script:RtlTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('desktop-rtl-test-' + [guid]::NewGuid().ToString('N'))
    $script:RtlTestRepository = [IO.Path]::GetFullPath($RepositoryRoot)
    $script:RtlTestViolations = New-Object System.Collections.Generic.List[string]
    $script:RtlTestShortcuts = @{}
    $script:RtlTestEnvironment = @{}
    foreach ($name in @('LOCALAPPDATA','APPDATA','USERPROFILE','ProgramFiles','ProgramFiles(x86)','TEMP','TMP',
                         'ELECTRON_RUN_AS_NODE','ELECTRON_NO_ASAR','HERDR_RTL_ARTIFACT','HERDR_RTL_BUILD_TAG',
                         'XDG_CONFIG_HOME','XDG_STATE_HOME','HERDR_BIN_PATH','SAND_DISABLE_UPDATES')) {
        $script:RtlTestEnvironment[$name] = [Environment]::GetEnvironmentVariable($name,'Process')
    }
    [void][IO.Directory]::CreateDirectory($script:RtlTestRoot)
    foreach ($entry in @{'LOCALAPPDATA'='local';'APPDATA'='roaming';'USERPROFILE'='user';'ProgramFiles'='programs';'ProgramFiles(x86)'='programs-x86';'TEMP'='temp';'TMP'='temp'}.GetEnumerator()) {
        $path = Join-Path $script:RtlTestRoot $entry.Value
        [void][IO.Directory]::CreateDirectory($path)
        [Environment]::SetEnvironmentVariable($entry.Key,$path,'Process')
    }
    foreach ($name in @('HERDR_RTL_ARTIFACT','HERDR_RTL_BUILD_TAG','XDG_CONFIG_HOME','XDG_STATE_HOME','HERDR_BIN_PATH','SAND_DISABLE_UPDATES')) {
        [Environment]::SetEnvironmentVariable($name,$null,'Process')
    }
    # GetFolderPath may expand the redirected environment and return an empty
    # string until those special folders exist. Create only redirected paths.
    foreach ($folder in @('Programs','Desktop')) {
        $special = [Environment]::GetFolderPath($folder,[Environment+SpecialFolderOption]::DoNotVerify)
        if ($special -and $special.StartsWith($script:RtlTestRoot + '\',[StringComparison]::OrdinalIgnoreCase)) { [void][IO.Directory]::CreateDirectory($special) }
    }
    $script:RtlTestIpcPrefix = 'Local\DesktopRtlTest_' + [guid]::NewGuid().ToString('N') + '_'
    return $script:RtlTestRoot
}

function Deny-RtlTestOperation {
    param([string]$Operation)
    $script:RtlTestViolations.Add($Operation)
    throw "[TEST-ISOLATION] Forbidden operating-system boundary: $Operation"
}

function Assert-RtlTestPath {
    param([Parameter(Mandatory)][string]$Path, [switch]$ReadOnly)
    if ($Path -match '^(?i)(HKCU:|HKLM:|Registry:|Microsoft\.PowerShell\.Core\\Registry::)') { Deny-RtlTestOperation "registry path $Path" }
    try { $full = [IO.Path]::GetFullPath($Path) } catch { Deny-RtlTestOperation "invalid fixture path $Path" }
    $allowed = $full.StartsWith($script:RtlTestRoot + '\',[StringComparison]::OrdinalIgnoreCase) -or $full -eq $script:RtlTestRoot
    if ($ReadOnly) { $allowed = $allowed -or $full.StartsWith($script:RtlTestRepository + '\',[StringComparison]::OrdinalIgnoreCase) }
    if (-not $allowed) { Deny-RtlTestOperation "outside fixture path $Path" }
    # Refuse a linked root or ancestor before a recursive delete/copy. Link-specific
    # tests need their own audited cleanup; they must not weaken this shared guard.
    $cursor = $full
    while ($cursor -and $cursor.Length -ge $script:RtlTestRoot.Length) {
        if ([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)) {
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Deny-RtlTestOperation "reparse point $cursor" }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}

function Assert-RtlTestIsolation {
    if ($script:RtlTestViolations.Count) { throw ('[TEST-ISOLATION] Forbidden calls occurred, even if product code caught them: ' + ($script:RtlTestViolations -join '; ')) }
}

function Complete-RtlTestSandbox {
    try {
        if ($script:LockStream) { $script:LockStream.Dispose(); $script:LockStream = $null }
        if ($script:RtlTestRoot -and [IO.Directory]::Exists($script:RtlTestRoot)) {
            $safe = Assert-RtlTestPath $script:RtlTestRoot
            # Check descendants too: a future fixture must not make cleanup follow links.
            $directories = New-Object System.Collections.Generic.Stack[string]
            $directories.Push($safe)
            while ($directories.Count) {
                foreach ($entry in (Microsoft.PowerShell.Management\Get-ChildItem -LiteralPath $directories.Pop() -Force)) {
                    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Deny-RtlTestOperation 'linked cleanup descendant' }
                    if ($entry.PSIsContainer) { $directories.Push($entry.FullName) }
                }
            }
            Microsoft.PowerShell.Management\Remove-Item -LiteralPath $safe -Recurse -Force -ErrorAction Stop
        }
    } finally {
        foreach ($entry in $script:RtlTestEnvironment.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key,$entry.Value,'Process') }
    }
    Assert-RtlTestIsolation
}

# Deny instead of silently replacing unexpected operating-system effects with
# success. Violations remain observable even when production has catch {}.
function Get-Process { Deny-RtlTestOperation 'Get-Process' }
function Get-CimInstance { Deny-RtlTestOperation 'Get-CimInstance' }
function Get-WmiObject { Deny-RtlTestOperation 'Get-WmiObject' }
function Start-Process { Deny-RtlTestOperation 'Start-Process' }
function Stop-Process { Deny-RtlTestOperation 'Stop-Process' }
function Get-AppxPackage { Deny-RtlTestOperation 'Get-AppxPackage' }
function Invoke-WebRequest { Deny-RtlTestOperation 'Invoke-WebRequest' }
function Invoke-RestMethod { Deny-RtlTestOperation 'Invoke-RestMethod' }
function Add-Type { Deny-RtlTestOperation 'Add-Type' }
function reg { Deny-RtlTestOperation 'reg' }
function reg.exe { Deny-RtlTestOperation 'reg.exe' }
function schtasks { Deny-RtlTestOperation 'schtasks' }
function Remove-ItemProperty { Deny-RtlTestOperation 'Remove-ItemProperty' }
function Set-ItemProperty { Deny-RtlTestOperation 'Set-ItemProperty' }
function New-ItemProperty { Deny-RtlTestOperation 'New-ItemProperty' }
function Get-ItemProperty {
    [CmdletBinding()] param([string]$Path,[string]$Name)
    # Uninstall reads one legacy Run value. Model an empty test-only Run key.
    if ($Path -ne $script:RtlTestRunKey) { Deny-RtlTestOperation 'Get-ItemProperty outside fake Run key' }
    return [pscustomobject]@{}
}

function Remove-Item {
    [CmdletBinding()] param([Parameter(Position=0)][string[]]$Path,[string[]]$LiteralPath,[switch]$Recurse,[switch]$Force)
    $targets = if ($LiteralPath) { $LiteralPath } else { $Path }
    foreach ($target in $targets) {
        if ($target -match '^Env:\\(ELECTRON_RUN_AS_NODE|ELECTRON_NO_ASAR)$') {
            [Environment]::SetEnvironmentVariable($matches[1],$null,'Process')
            continue
        }
        $safe = Assert-RtlTestPath $target
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $safe -Recurse:$Recurse -Force:$Force -ErrorAction $ErrorActionPreference
    }
}

function Test-Path {
    [CmdletBinding()] param([Parameter(Position=0)][string[]]$Path,[string[]]$LiteralPath,[string]$PathType='Any')
    foreach ($p in $(if($LiteralPath){$LiteralPath}else{$Path})) { [void](Assert-RtlTestPath $p -ReadOnly) }
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function Get-Item {
    [CmdletBinding()] param([Parameter(Position=0)][string[]]$Path,[string[]]$LiteralPath,[switch]$Force)
    foreach ($p in $(if($LiteralPath){$LiteralPath}else{$Path})) { [void](Assert-RtlTestPath $p -ReadOnly) }
    Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
}
function Get-ChildItem {
    [CmdletBinding()] param([Parameter(Position=0)][string[]]$Path,[string[]]$LiteralPath,[switch]$Force,[switch]$Recurse,[switch]$Directory,[switch]$File,[string]$Filter)
    foreach ($p in $(if($LiteralPath){$LiteralPath}else{$Path})) { [void](Assert-RtlTestPath $p -ReadOnly) }
    Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
}
function New-Item {
    [CmdletBinding()] param([Parameter(Position=0)][string[]]$Path,[Alias('Type')][string]$ItemType,[switch]$Force)
    foreach ($p in $Path) { [void](Assert-RtlTestPath $p) }
    if ($ItemType -notin @('Directory','File')) { Deny-RtlTestOperation "New-Item type $ItemType" }
    Microsoft.PowerShell.Management\New-Item @PSBoundParameters
}
function Copy-Item {
    [CmdletBinding()] param([Parameter(Position=0)][string[]]$Path,[string[]]$LiteralPath,[Parameter(Position=1)][string]$Destination,[switch]$Force,[switch]$Recurse)
    foreach ($p in $(if($LiteralPath){$LiteralPath}else{$Path})) { [void](Assert-RtlTestPath $p -ReadOnly) }
    [void](Assert-RtlTestPath $Destination)
    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
}
function Move-Item {
    [CmdletBinding()] param([Parameter(Position=0)][string[]]$Path,[string[]]$LiteralPath,[Parameter(Position=1)][string]$Destination,[switch]$Force)
    foreach ($p in $(if($LiteralPath){$LiteralPath}else{$Path})) { [void](Assert-RtlTestPath $p) }
    [void](Assert-RtlTestPath $Destination)
    Microsoft.PowerShell.Management\Move-Item @PSBoundParameters
}
function Rename-Item {
    [CmdletBinding()] param([Parameter(Position=0)][string]$Path,[string]$LiteralPath,[Parameter(Position=1)][string]$NewName,[switch]$Force)
    $source = if ($LiteralPath) { $LiteralPath } else { $Path }
    [void](Assert-RtlTestPath $source)
    [void](Assert-RtlTestPath (Join-Path (Split-Path $source -Parent) $NewName))
    Microsoft.PowerShell.Management\Rename-Item @PSBoundParameters
}
function Get-Content {
    [CmdletBinding()] param([Parameter(Position=0)][string[]]$Path,[string[]]$LiteralPath,[switch]$Raw,[string]$Encoding)
    foreach ($p in $(if($LiteralPath){$LiteralPath}else{$Path})) { [void](Assert-RtlTestPath $p -ReadOnly) }
    Microsoft.PowerShell.Management\Get-Content @PSBoundParameters
}
function Set-Content {
    [CmdletBinding()] param([Parameter(Position=0)][string[]]$Path,[string[]]$LiteralPath,[Parameter(Position=1)]$Value,[string]$Encoding,[switch]$NoNewline)
    foreach ($p in $(if($LiteralPath){$LiteralPath}else{$Path})) { [void](Assert-RtlTestPath $p) }
    Microsoft.PowerShell.Management\Set-Content @PSBoundParameters
}
function Add-Content {
    [CmdletBinding()] param([Parameter(Position=0)][string[]]$Path,[string[]]$LiteralPath,[Parameter(Position=1)]$Value,[string]$Encoding)
    foreach ($p in $(if($LiteralPath){$LiteralPath}else{$Path})) { [void](Assert-RtlTestPath $p) }
    Microsoft.PowerShell.Management\Add-Content @PSBoundParameters
}

function New-RtlTestShortcut {
    param([string]$Path)
    [void](Assert-RtlTestPath $Path)
    if ($script:RtlTestShortcuts.ContainsKey($Path)) { return $script:RtlTestShortcuts[$Path] }
    $link = [pscustomobject]@{Path=$Path;TargetPath='';Arguments='';WorkingDirectory='';IconLocation='';Description=''}
    $link | Add-Member -MemberType ScriptMethod -Name Save -Value {
        $safe = Assert-RtlTestPath $this.Path
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($safe))
        [IO.File]::WriteAllText($safe,'synthetic shortcut recorder; not a Windows shortcut')
    }
    $script:RtlTestShortcuts[$Path] = $link
    return $link
}

function New-Object {
    [CmdletBinding(DefaultParameterSetName='Type')]
    param([Parameter(Position=0,ParameterSetName='Type')][string]$TypeName,
          [Parameter(Position=1,ParameterSetName='Type')][object[]]$ArgumentList,
          [Parameter(ParameterSetName='Com')][string]$ComObject)
    if ($ComObject) {
        if ($ComObject -ne 'WScript.Shell') { Deny-RtlTestOperation "COM $ComObject" }
        $shell = [pscustomobject]@{}
        $shell | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value {param($Path) New-RtlTestShortcut $Path}
        return $shell
    }
    if ($TypeName -match '(?i)EventWaitHandle|Threading\.Mutex') {
        $name = [string]$ArgumentList[-1]
        if (-not $name.StartsWith($script:RtlTestIpcPrefix,[StringComparison]::Ordinal)) { Deny-RtlTestOperation "IPC $name" }
    }
    if ($TypeName -match '(?i)Diagnostics\.Process|Management\.|Windows\.UI|Windows\.Forms') { Deny-RtlTestOperation "type $TypeName" }
    Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList
}

# Call AFTER dot-sourcing the product. Safe boundary models are explicit, while
# low-level OS commands above remain traps against a missed/new call path.
function Set-RtlTestProductBoundaries {
    $script:RtlTestSetActive = ${function:Set-RtlActiveApp}
    $script:RtlTestRunKey = Join-Path $script:RtlTestRoot 'fake-registry-run'
    $script:AgentSetupMutexName = $script:RtlTestIpcPrefix + 'setup'
    $script:AgentTrayMutexName = $script:RtlTestIpcPrefix + 'tray'
    $script:AgentQuitEventName = $script:RtlTestIpcPrefix + 'quit'
    # This broad suite uses only ordinary fixture files and does not test native
    # link metadata. The dedicated path harness runs the actual Windows helper.
    Set-Item Function:script:Assert-RtlSingleLink { param($Path) [void](Assert-RtlTestPath $Path -ReadOnly) }
    Set-Item Function:script:Test-CodexRtlRunning { return $false }
    Set-Item Function:script:Stop-CodexRtlWatcher { }
    Set-Item Function:script:Remove-RtlCopyShellRegistrations { param($CopyRoot) [void](Assert-RtlTestPath $CopyRoot); return @() }
    Set-Item Function:script:Get-HerdrExeVersion { param($Exe) Deny-RtlTestOperation "Herdr version process $Exe" }
    Set-Item Function:script:Set-RtlActiveApp {
        param([string]$AppId='codex')
        & $script:RtlTestSetActive $AppId | Out-Null
        foreach ($root in @($script:CopyRoot,$script:Staging,$script:OldRoot,$script:StateDir) + @($script:ActiveProfile.SourceRoots)) { if ($root) { [void](Assert-RtlTestPath $root) } }
        $script:RunKey = $script:RtlTestRunKey
        $shortcutDir = Join-Path $script:RtlTestRoot 'shortcuts'
        [void][IO.Directory]::CreateDirectory($shortcutDir)
        $script:ShortcutStart = Join-Path $shortcutDir ($script:ShortcutLabel + '.lnk')
        $script:ShortcutDesktop = Join-Path $shortcutDir ('Desktop - ' + $script:ShortcutLabel + '.lnk')
        $script:ShortcutPath = $script:ShortcutStart
        $script:LegacyShortcuts = @()
        $script:ShortcutPaths = @($script:ShortcutStart,$script:ShortcutDesktop)
    }
    Set-RtlActiveApp 'codex'
}
