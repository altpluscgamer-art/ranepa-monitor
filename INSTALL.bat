@echo off
title RANEPA Service Monitor - INSTALL
cd /d "%~dp0"

if not exist "%~dp0monitor_services.ps1" (
  echo [ERROR] Files not found. Run INSTALL.bat from the extracted folder.
  pause
  exit /b 1
)

set "DEST=%LOCALAPPDATA%\RanepaMonitor"
echo Step 1 of 4: copying files to %DEST% ...
if not exist "%DEST%" mkdir "%DEST%"
copy /y "%~dp0monitor_services.ps1" "%DEST%\" >nul
copy /y "%~dp0run_monitor.bat" "%DEST%\" >nul
copy /y "%~dp0stop_monitor.bat" "%DEST%\" >nul
copy /y "%~dp0make_widget.bat" "%DEST%\" >nul
if exist "%DEST%\run_check_hidden.vbs" del /q "%DEST%\run_check_hidden.vbs"
if exist "%DEST%\start_server_hidden.vbs" del /q "%DEST%\start_server_hidden.vbs"
if exist "%DEST%\run_auth_hidden.vbs" del /q "%DEST%\run_auth_hidden.vbs"
if exist "%~dp0setup_creds.ps1" copy /y "%~dp0setup_creds.ps1" "%DEST%\" >nul
if exist "%~dp0auth_config.csv" copy /y "%~dp0auth_config.csv" "%DEST%\" >nul
if exist "%~dp0CHANGELOG.md" copy /y "%~dp0CHANGELOG.md" "%DEST%\" >nul
if exist "%~dp0ranepa-monitor-ext" (
  if not exist "%DEST%\ranepa-monitor-ext" mkdir "%DEST%\ranepa-monitor-ext"
  copy /y "%~dp0ranepa-monitor-ext\*.*" "%DEST%\ranepa-monitor-ext\" >nul
)
echo   copied.

echo Step 2 of 4: removing the internet "blocked" mark ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%DEST%' -Recurse -File | Unblock-File"
echo   done.

echo Step 3 of 4: creating the desktop widget shortcut ...
call "%DEST%\make_widget.bat" -quiet

echo Step 4 of 4: ready.
echo.
echo Everything is installed in: %DEST%
echo.
echo To start:    run_monitor.bat   (schedule + autostart + page)
echo To stop:     stop_monitor.bat  (removes schedule, autostart, closes all)
echo Widget:      make_widget.bat   (re-creates the desktop shortcut)
echo.
choice /C YN /M "Start monitoring right now? Y - yes, N - no"
if errorlevel 2 (
  echo You can start later: double-click %DEST%\run_monitor.bat
) else (
  call "%DEST%\run_monitor.bat"
)
exit /b 0
