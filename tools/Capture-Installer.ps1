# Capture-Installer.ps1 - screenshot the graphical installer window.
# -----------------------------------------------------------------------------
# Launches scripts\Install-DesktopRtlGui.ps1, optionally drops the app-picker open
# (via CB_SHOWDROPDOWN, so no mouse or keyboard is driven), grabs the window plus the
# dropdown popup off the screen, and writes a PNG into tools\raw\.
#
# The dropdown is a separate top-level popup, so PrintWindow on the form alone would
# miss it. CopyFromScreen over the union rectangle is used instead, which means the
# window must be visible and unobscured while this runs.
#
#   .\Capture-Installer.ps1                      # normal state
#   .\Capture-Installer.ps1 -OpenPicker          # with the app list dropped down
#   .\Capture-Installer.ps1 -OpenPicker -AppIndex 3
#
# -AppIndex selects an entry in the picker before the grab, so the shot can show a
# specific app's state (for example an app with no patched copy yet, whose primary
# button then reads "install" rather than "update"). CB_SETCURSEL alone does not
# raise SelectedIndexChanged, so the CBN_SELCHANGE notification is posted to the
# combo's parent, where WinForms reflects it back to the control.
#
# Maintainer tooling: tools/ is NOT shipped in the release package. ASCII only.

[CmdletBinding()]
param(
    [switch]$OpenPicker,
    [int]$AppIndex = 0,
    [string]$Out,
    [int]$SettleSeconds = 6,
    [int]$ParkX = 120,
    [int]$ParkY = 90
)
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$gui      = Join-Path $repoRoot 'scripts\Install-DesktopRtlGui.ps1'
$rawDir   = Join-Path $PSScriptRoot 'raw'
if (-not $Out) { $Out = Join-Path $rawDir ($(if ($OpenPicker) { 'installer-picker.png' } else { 'installer-plain.png' })) }
if (-not (Test-Path $rawDir)) { New-Item -ItemType Directory -Force -Path $rawDir | Out-Null }

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class RtlShot {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hWnd);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out RECT r, int size);
    public delegate bool EnumProc(IntPtr hWnd, IntPtr p);
}
'@

# Without this, GetWindowRect and CopyFromScreen disagree on a scaled display and
# the grab lands on whatever window happens to sit at the virtualised coordinates.
[void][RtlShot]::SetProcessDPIAware()

$CB_SHOWDROPDOWN = 0x014F
$CB_SETCURSEL    = 0x014E
$WM_COMMAND      = 0x0111
$CBN_SELCHANGE   = 1
$HWND_TOPMOST    = [IntPtr](-1)
$HWND_NOTOPMOST  = [IntPtr](-2)
$SWP_NOMOVE      = 0x0002
$SWP_NOSIZE      = 0x0001
$SWP_SHOWWINDOW  = 0x0040

$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
# Pass a RELATIVE script path from -WorkingDirectory. An absolute path is mangled on
# the way through Start-Process when the repo lives under a non-ASCII directory
# (powershell.exe then refuses it: "the file does not have a '.ps1' extension").
$proc = Start-Process -FilePath $psExe -PassThru -WorkingDirectory $repoRoot -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', 'scripts\Install-DesktopRtlGui.ps1')
Write-Host "installer pid $($proc.Id), waiting ${SettleSeconds}s for it to settle..."

try {
    # Re-query the process each round: the cached object's MainWindowHandle does not
    # reliably refresh while the WinForms window is still coming up.
    $hwnd = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds($SettleSeconds)
    while ((Get-Date) -lt $deadline) {
        $p = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if ($p -and $p.MainWindowHandle -and [IntPtr]$p.MainWindowHandle -ne [IntPtr]::Zero) {
            $hwnd = [IntPtr]$p.MainWindowHandle
            break
        }
        Start-Sleep -Milliseconds 400
    }
    if ($hwnd -eq [IntPtr]::Zero) { throw 'the installer window never appeared' }
    Start-Sleep -Seconds 2                       # let the status probe finish

    # Windows blocks SetForegroundWindow from a background process, and CopyFromScreen
    # would then capture whatever app is really on top. Pin the window topmost, which
    # is not subject to the foreground lock, and drop the flag again afterwards.
    # Parking it at a fixed spot also keeps the form off a secondary monitor, whose
    # different scaling would change the captured size between runs.
    [void][RtlShot]::SetWindowPos($hwnd, $HWND_TOPMOST, $ParkX, $ParkY, 0, 0, ($SWP_NOSIZE -bor $SWP_SHOWWINDOW))
    [void][RtlShot]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 1400

    if ($OpenPicker -or $AppIndex -gt 0) {
        # The combo sits several layout panels deep (TableLayoutPanel > FlowLayoutPanel),
        # so recurse with EnumChildWindows rather than guessing the nesting depth.
        $script:combo = [IntPtr]::Zero
        $findCombo = [RtlShot+EnumProc]{
            param($h, $p)
            $sb = New-Object Text.StringBuilder 64
            [void][RtlShot]::GetClassName($h, $sb, 64)
            if ($sb.ToString() -like '*COMBOBOX*' -and $script:combo -eq [IntPtr]::Zero) { $script:combo = $h }
            return $true
        }
        [void][RtlShot]::EnumChildWindows($hwnd, $findCombo, [IntPtr]::Zero)
        $combo = $script:combo
        if ($combo -eq [IntPtr]::Zero) { throw 'app-picker ComboBox not found' }
    }

    if ($AppIndex -gt 0) {
        [void][RtlShot]::SendMessage($combo, $CB_SETCURSEL, [IntPtr]$AppIndex, [IntPtr]::Zero)
        # CB_SETCURSEL is silent by design. WinForms raises SelectedIndexChanged from the
        # CBN_SELCHANGE notification its parent reflects back, so send that notification.
        $parent = [RtlShot]::GetParent($combo)
        $wparam = [IntPtr](($CBN_SELCHANGE -shl 16) -bor ([RtlShot]::GetDlgCtrlID($combo) -band 0xFFFF))
        [void][RtlShot]::SendMessage($parent, $WM_COMMAND, $wparam, $combo)
        Start-Sleep -Seconds 3                   # the handler re-probes the app's status
        Write-Host "picker set to index $AppIndex"
    }

    # Read the rectangle only now: switching apps relabels the window and can resize it.
    # GetWindowRect reports the invisible resize border too, which drags a strip of
    # whatever sits behind the form into the grab. DWMWA_EXTENDED_FRAME_BOUNDS (9) is
    # the actually painted frame; fall back to GetWindowRect if DWM declines.
    $r = New-Object RtlShot+RECT
    $rectSize = [Runtime.InteropServices.Marshal]::SizeOf([Type]'RtlShot+RECT')
    if ([RtlShot]::DwmGetWindowAttribute($hwnd, 9, [ref]$r, $rectSize) -ne 0) {
        [void][RtlShot]::GetWindowRect($hwnd, [ref]$r)
        Write-Warning 'DWM frame bounds unavailable; using GetWindowRect (shadow margin included)'
    }
    $left = $r.Left; $top = $r.Top; $right = $r.Right; $bottom = $r.Bottom

    if ($OpenPicker) {
        [void][RtlShot]::SendMessage($combo, $CB_SHOWDROPDOWN, [IntPtr]1, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 900

        # The dropped list is a top-level ComboLBox popup; fold it into the capture box.
        $popup = [IntPtr]::Zero
        $cb = [RtlShot+EnumProc]{
            param($h, $p)
            $sb = New-Object Text.StringBuilder 64
            [void][RtlShot]::GetClassName($h, $sb, 64)
            if ($sb.ToString() -like '*COMBOLBOX*' -and [RtlShot]::IsWindowVisible($h)) { $script:popup = $h }
            return $true
        }
        [void][RtlShot]::EnumWindows($cb, [IntPtr]::Zero)
        # The grab is the form rectangle, nothing more. The dropdown paints inside it,
        # and GetWindowRect on the popup reports an invisible drop-shadow margin that
        # would only drag a strip of the desktop behind the form into the picture.
        if ($script:popup -and $script:popup -ne [IntPtr]::Zero) {
            Write-Host 'picker dropdown is open'
        } else {
            Write-Warning 'dropdown popup window not found; capturing the closed form'
        }
    }

    $w = $right - $left; $h = $bottom - $top
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($left, $top, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $g.Dispose()
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    [void][RtlShot]::SetWindowPos($hwnd, $HWND_NOTOPMOST, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE))
    Write-Host ("wrote {0}  {1}x{2}" -f $Out, $w, $h)
} finally {
    if (-not $proc.HasExited) { $proc.CloseMainWindow() | Out-Null; Start-Sleep -Seconds 1 }
    if (-not $proc.HasExited) { $proc | Stop-Process -Force -ErrorAction SilentlyContinue }
}
