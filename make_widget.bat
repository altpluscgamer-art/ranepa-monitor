@echo off
setlocal
rem Creates a desktop shortcut that opens the monitoring page
rem as a standalone app window (no address bar, no tabs).
rem Sound is ON by default (snd=on) and the favicon acts as a status indicator.

set "URL=http://localhost:8765/?snd=on"
set "LNK=%USERPROFILE%\Desktop\Monitoring RANEPA.lnk"

set "EXE="
if exist "%LOCALAPPDATA%\Yandex\YandexBrowser\Application\browser.exe" set "EXE=%LOCALAPPDATA%\Yandex\YandexBrowser\Application\browser.exe"
if not defined EXE if exist "%PROGRAMFILES%\Yandex\YandexBrowser\Application\browser.exe" set "EXE=%PROGRAMFILES%\Yandex\YandexBrowser\Application\browser.exe"
if not defined EXE if exist "%PROGRAMFILES(X86)%\Yandex\YandexBrowser\Application\browser.exe" set "EXE=%PROGRAMFILES(X86)%\Yandex\YandexBrowser\Application\browser.exe"
if not defined EXE if exist "%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe" set "EXE=%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"
if not defined EXE if exist "%PROGRAMFILES%\Google\Chrome\Application\chrome.exe" set "EXE=%PROGRAMFILES%\Google\Chrome\Application\chrome.exe"
if not defined EXE if exist "%PROGRAMFILES(X86)%\Microsoft\Edge\Application\msedge.exe" set "EXE=%PROGRAMFILES(X86)%\Microsoft\Edge\Application\msedge.exe"
if not defined EXE if exist "%PROGRAMFILES%\Microsoft\Edge\Application\msedge.exe" set "EXE=%PROGRAMFILES%\Microsoft\Edge\Application\msedge.exe"

if not defined EXE (
  echo Browser not found. Open the page manually: %URL%
  if /i not "%~1"=="-quiet" pause
  exit /b 1
)

echo Found browser: %EXE%
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ws = New-Object -ComObject WScript.Shell; $sc = $ws.CreateShortcut('%LNK%'); $sc.TargetPath = '%EXE%'; $sc.Arguments = '--app=%URL%'; $sc.IconLocation = '%EXE%,0'; $sc.Save()"

if exist "%LNK%" (
  echo Shortcut created: %LNK%
  echo Double-click it to open the monitoring window.
) else (
  echo Failed to create shortcut.
)
if /i not "%~1"=="-quiet" pause
