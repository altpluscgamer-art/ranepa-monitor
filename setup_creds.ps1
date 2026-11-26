# setup_creds.ps1 — сохранение учётных данных для авто-логина.
# Данные шифруются ключом Windows (DPAPI) для ТЕКУЩЕГО пользователя:
# расшифровать их может только он и только на этом компьютере.
# В открытом виде пароли нигде не сохраняются.
#
# Запуск:  powershell -NoProfile -ExecutionPolicy Bypass -File setup_creds.ps1
param([string]$Service)
$ErrorActionPreference = 'Stop'
$dir = Join-Path $PSScriptRoot 'auth_creds'
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
if (-not $Service) { $Service = Read-Host 'Название сервиса (точно как на странице мониторинга)' }
$svc = ($Service -replace '[^\w]', '_')
Write-Host ''
Write-Host ('Сервис: ' + $Service)
Write-Host 'Данные будут зашифрованы (DPAPI, текущий пользователь).'
Write-Host 'В открытом виде пароль нигде не сохраняется.'
Write-Host ''
$login = Read-Host 'Логин'
$secP = Read-Host 'Пароль' -AsSecureString
$secL = ConvertTo-SecureString $login -AsPlainText -Force
$el = $secL | ConvertFrom-SecureString
$ep = $secP | ConvertFrom-SecureString
[System.IO.File]::WriteAllLines((Join-Path $dir ($svc + '.txt')), @($el, $ep))
Write-Host ''
Write-Host ('Сохранено: ' + (Join-Path $dir ($svc + '.txt')))
Write-Host 'Дальше: добавьте строку в auth_config.csv с полями этого сервиса'
Write-Host '(login_url, имена полей формы, маркеры успеха/неудачи).'
pause
