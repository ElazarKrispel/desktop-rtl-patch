@echo off
rem ============================================================================
rem  Desktop RTL - friendly graphical installer (Hebrew / right-to-left support).
rem  Delegates to the VBS launcher so NO PowerShell/console window appears.
rem  (Double-clicking Install-Desktop-RTL.vbs directly is just as good.)
rem ============================================================================
start "" wscript.exe //nologo "%~dp0Install-Desktop-RTL.vbs"
