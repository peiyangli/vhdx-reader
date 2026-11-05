@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\preview-ui-windows.ps1"
if errorlevel 1 (
  echo.
  echo Build failed. See artifacts\windows-ui-preview-build.log
  pause
  exit /b 1
)
echo.
echo Preview ready: artifacts\gui-windows-ui-preview\vhdx_reader.exe
pause
