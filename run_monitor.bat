@echo off
title RANEPA Service Monitor
cd /d "%~dp0"

if not exist "%~dp0monitor_services.ps1" (
    echo.
    echo [ERROR] monitor_services.ps1 not found next to this file.
    echo Put the files into one folder and run again.
    echo.
    pause
    exit /b 1
)

rem -- Remove the internet "blocked" mark so PowerShell does not ask about trust.
powershell -NoProfile -Command "Unblock-File -LiteralPath '%~dp0monitor_services.ps1'" >nul 2>nul

echo Checking script version...
powershell -NoProfile -Command "(Select-String -LiteralPath '%~dp0monitor_services.ps1' -Pattern 'Version:' | Select-Object -First 1).Line"
echo.

echo Step 1 of 6: cleaning up old runs (processes, ports, schedule, old wrappers)...
powershell -NoProfile -Command "foreach($u in 'http://localhost:8765/stop','http://localhost:8000/stop'){try{$null=Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 3}catch{}}" >nul 2>nul
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -match 'monitor_services' -and $_.ProcessId -ne $PID } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Write-Host ('  stopped: PID ' + $_.ProcessId) } catch {} }"
schtasks /Change /TN "RanepaServiceMonitor" /Disable 2>nul
schtasks /Delete /TN "RanepaServiceMonitor" /F 2>nul
schtasks /Change /TN "RanepaServiceMonitorAuth" /Disable 2>nul
schtasks /Delete /TN "RanepaServiceMonitorAuth" /F 2>nul
if exist "%~dp0run_check_hidden.vbs" del /q "%~dp0run_check_hidden.vbs"
if exist "%~dp0start_server_hidden.vbs" del /q "%~dp0start_server_hidden.vbs"
if exist "%~dp0run_auth_hidden.vbs" del /q "%~dp0run_auth_hidden.vbs"
echo Cleanup done.
echo.

echo Step 2 of 6: creating the scheduled task (check every 5 minutes, direct powershell)...
schtasks /Create /F /SC MINUTE /MO 5 /TN "RanepaServiceMonitor" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%~dp0monitor_services.ps1\""
echo.

echo Step 3 of 6: creating the hourly authorization check (auth_config.csv)...
schtasks /Create /F /SC HOURLY /TN "RanepaServiceMonitorAuth" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%~dp0monitor_services.ps1\" -AuthCheck"
echo   (this task only does real work when auth_config.csv and saved credentials exist).
echo.

echo Step 4 of 6: enabling autostart at logon (current user, no admin rights)...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v RanepaServiceMonitor /t REG_SZ /d "\"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe\" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%~dp0monitor_services.ps1\" -Serve -Port 8765" /f
echo   autostart is ON: the monitor starts hidden at every logon.
echo   To turn it off later: run stop_monitor.bat.
echo.

echo Step 5 of 6: starting the status page (hidden server window)...
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0monitor_services.ps1" -Serve -Port 8765
echo Waiting for the page to respond (up to 60 seconds)...
set /a tries=0
:waitloop
timeout /t 2 /nobreak >nul
set /a tries+=1
powershell -NoProfile -Command "try{$null=Invoke-WebRequest -Uri 'http://localhost:8765/' -UseBasicParsing -TimeoutSec 30; exit 0}catch{exit 1}" >nul 2>nul
if errorlevel 1 (
    if %tries% lss 20 goto waitloop
    echo.
    echo [PROBLEM] The page does not respond. Switching to file mode...
    echo The check is running now, please wait a moment.
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor_services.ps1"
    start "" "%~dp0services_status.html"
    echo.
    echo The report is open as a file: the "Check now" and "Stop monitoring"
    echo buttons do not work on a file page.
    echo Auto checks every 5 minutes still run (Task Scheduler).
    echo To stop everything: run stop_monitor.bat.
    echo If the report failed too, copy the red text above and send it.
    echo.
    pause
    exit /b 0
)

echo Step 6 of 6: opening the page...
start "" "http://localhost:8765/"
echo.
echo Done. Everything is up and running:
echo   - checks run automatically every 5 minutes (Task Scheduler, powershell direct);
echo   - authorization checks run every hour (when configured);
echo   - the monitor starts at every logon (autostart ON);
echo   - the status page opens in the browser (localhost:8765);
echo   - history is one file per day: services_history_YYYY-MM-DD.csv.
echo.
echo To stop everything (including autostart): stop_monitor.bat
echo.
echo This window can be closed with any key.
pause >nul
exit /b 0
