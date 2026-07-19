' Desktop-RTL-Settings.vbs - open the Codex RTL settings dialog with no console window.
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
sh.Run cmd, 0, False
