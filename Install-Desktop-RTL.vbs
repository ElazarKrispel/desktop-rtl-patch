' Desktop RTL - friendly installer launcher.
' Double-click this file. It opens the graphical installer with NO PowerShell
' or console window at all, and requires no administrator rights.
Option Explicit
Dim sh, fso, dir, ps
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps = "powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & dir & "\scripts\Install-DesktopRtlGui.ps1"""
' Run with window style 0 (hidden) from the start, and do not wait.
sh.Run ps, 0, False
