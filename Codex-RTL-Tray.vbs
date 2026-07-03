' Codex-RTL-Tray.vbs - launch the Codex RTL tray app with no console window.
' Self-locating: runs CodexRtlTray.ps1 from the same folder as this script, so the
' same launcher works both in the repo and after deployment to the per-user bin.
Option Explicit
Dim sh, fso, scriptDir, ps1, cmd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(scriptDir, "CodexRtlTray.ps1")
If Not fso.FileExists(ps1) Then
  ' Repo layout: the tray script lives under scripts\
  ps1 = fso.BuildPath(fso.BuildPath(scriptDir, "scripts"), "CodexRtlTray.ps1")
End If
cmd = "powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & ps1 & """"
sh.Run cmd, 0, False
