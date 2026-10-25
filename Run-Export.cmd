@echo off
rem Double-click launcher. Pass extra flags through, e.g.  Run-Export.cmd -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Export-Win2Cachy.ps1" %*
pause
