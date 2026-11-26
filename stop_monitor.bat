@echo off
title RANEPA Service Monitor - STOP (full cleanup)
echo Stopping all monitoring on this PC...
echo.
echo 1. Disabling and deleting the scheduled tasks (check + auth)...
schtasks /Change /TN "RanepaServiceMonitor" /Disable 2>nul
schtasks /Delete /TN "RanepaServiceMonitor" /F 2>nul
schtasks /Change /TN "RanepaServiceMonitorAuth" /Disable 2>nul
schtasks /Delete /TN "RanepaServiceMonitorAuth" /F 2>nul
echo.
echo 2. Removing the autostart at logon (registry Run key)...
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v RanepaServiceMonitor /f 2>nul
echo   autostart removed (if it was set).
echo.
echo 3. Closing page servers on ports 8765 and 8000 (graceful)...
powershell -NoProfile -Command "foreach($u in 'http://localhost:8765/stop','http://localhost:8000/stop'){try{$null=Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 3}catch{}}" >nul 2>nul
echo.
echo 4. Killing any remaining monitor processes (including hidden ones)...
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -match 'monitor_services' -and $_.ProcessId -ne $PID } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Write-Host ('  stopped: PID ' + $_.ProcessId) } catch {} }"
echo.
echo Done. Automatic checks will not start anymore,
echo autostart at logon is removed,
echo no monitor processes remain.
echo To start again: run run_monitor.bat
echo.
pause
exit /b 0
