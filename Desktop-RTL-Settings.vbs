' Desktop-RTL-Settings.vbs - open the RTL settings dialog with no console window.
' Self-locating: runs DesktopRtlSettings.ps1 from the same folder (bin) or scripts\.
Option Explicit
Dim sh, fso, scriptDir, ps1, cmd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(scriptDir, "DesktopRtlSettings.ps1")
If Not fso.FileExists(ps1) Then
  ps1 = fso.BuildPath(fso.BuildPath(scriptDir, "scripts"), "DesktopRtlSettings.ps1")
End If
cmd = "powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & ps1 & """"
' Forward an optional first argument as the -App id (codex|opencode|traycer) so the unified
' tray can open per-app settings with no console window.
If WScript.Arguments.Count > 0 Then
  cmd = cmd & " -App " & WScript.Arguments(0)
End If
sh.Run cmd, 0, False
