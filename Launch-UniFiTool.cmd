@echo off
REM ===========================================================================
REM  UniFi Troubleshooter - launcher
REM
REM  -STA is REQUIRED. WinForms will not run reliably in a multi-threaded
REM  apartment, and the failure is intermittent rather than obvious.
REM
REM  -WindowStyle Hidden is deliberately NOT used. It hides the FORM as well as
REM  the console, and the tool then looks like it never started. The script
REM  hides its own console window in-process instead. Pass -NoHideConsole to
REM  keep the console visible for debugging.
REM
REM  -ExecutionPolicy Bypass is scoped to this launcher only, so the tool still
REM  runs on an unknown machine and on files carrying a mark-of-the-web.
REM ===========================================================================
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0UniFi-Troubleshooter-Gui.ps1" %*
if errorlevel 1 (
  echo.
  echo The tool exited with an error. Re-run with the console visible to see it:
  echo   powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0UniFi-Troubleshooter-Gui.ps1" -NoHideConsole
  echo.
  pause
)
