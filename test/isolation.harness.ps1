$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'isolated-test-support.ps1')
$testRoot = Initialize-RtlTestSandbox -RepositoryRoot (Split-Path $PSScriptRoot -Parent)
$checks = 0
try {
    $denied = @(
        { Get-Process },
        { Get-CimInstance Win32_Process },
        { Start-Process 'never-launch.exe' },
        { Stop-Process -Id 123456 },
        { reg query HKCU },
        { Get-ItemProperty -Path 'HKCU:\Software' },
        { Get-Item 'HKCU:\Software' },
        { Remove-Item 'HKCU:\Software' -Recurse },
        { New-Object -ComObject 'Shell.Application' },
        { New-Object System.Threading.EventWaitHandle($false,[System.Threading.EventResetMode]::ManualReset,'Local\DesktopRtlTrayQuit') },
        { New-Object System.Threading.Mutex($false,'Local\DesktopRtlAgentSetup') },
        { New-Item -ItemType Directory -Path ($testRoot + '-sibling\forbidden') },
        { Rename-Item -LiteralPath ($testRoot + '-sibling\forbidden') -NewName 'renamed' },
        { Rename-Item -LiteralPath (Join-Path $testRoot 'ordinary') -NewName '..\outside-rename' },
        { Invoke-WebRequest 'https://example.invalid' }
    )
    foreach ($action in $denied) {
        # Deliberately swallow exactly as several product functions do; the final
        # violation check must still fail without ever reaching the real OS call.
        try { & $action } catch { if ($_.Exception.Message -notmatch '\[TEST-ISOLATION\]') { throw } }
        $caught = $false
        try { Assert-RtlTestIsolation } catch { $caught = $true }
        if (-not $caught -or $script:RtlTestViolations.Count -ne 1) { throw 'Isolation trap failed to retain one forbidden call.' }
        $checks++
        # Only the guard self-test resets intentional violations between cases.
        $script:RtlTestViolations.Clear()
    }
    $shortcut = New-RtlTestShortcut (Join-Path $testRoot 'recorded.lnk')
    $shortcut.TargetPath = 'synthetic.exe'; $shortcut.Save()
    if ([IO.File]::ReadAllText($shortcut.Path) -notmatch 'not a Windows shortcut') { throw 'Shortcut recorder escaped its fake representation.' }
    $checks++
    Assert-RtlTestIsolation
} finally { Complete-RtlTestSandbox }
if ([IO.Directory]::Exists($testRoot)) { throw 'Fixture cleanup did not finish.' }
Write-Host "PASS: $checks isolation assertions"
