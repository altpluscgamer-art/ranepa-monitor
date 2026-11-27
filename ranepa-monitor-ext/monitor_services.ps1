# =============================================================
# Version: 2026-11-26-R8.20
#  Мониторинг доступности сервисов РАНХиГС — версия на PowerShell.
#  Работает на любой Windows без установки Python.
#
#  Режимы:
#    powershell -NoProfile -ExecutionPolicy Bypass -File monitor_services.ps1
#        — разовая проверка: печатает таблицу, пишет HTML-отчёт и CSV-историю.
#    ... -Serve -Port 8000
#        — страница с кнопкой "Проверить сейчас" на http://localhost:8000
#        (мини-сервер на TcpListener — прав администратора не нужно)
#    ... -AutoSec 300 (вместе с -Serve)
#        — автообновление страницы каждые 300 секунд.
#
#  Автоматизация без сервера: задача Планировщика запускает этот скрипт
#  по расписанию, а файл services_status.html сам перечитывается в браузере
#  (в отчёт встроено автообновление раз в 5 минут) — см. monitoring_guide.txt.
# =============================================================
param(
    [switch]$Serve,
    [int]$Port = 8765,
    [int]$TimeoutSec = 15,
    [int]$AutoSec = 0,
    [switch]$AuthCheck,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# --- Пути к файлам — рядом со скриптом ------------------------
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$CsvPath   = Join-Path $ScriptDir ('services_history_' + (Get-Date -Format 'yyyy-MM-dd') + '.csv')
$OutPath   = Join-Path $ScriptDir 'services_status.html'
$LastStatePath = Join-Path $ScriptDir 'last_state.txt'
$LockPath      = Join-Path $ScriptDir 'monitor.lock'

# --- TLS: включаем TLS 1.2 (важно для старых Windows) ---
try {
    [Net.ServicePointManager]::SecurityProtocol = [Enum]::ToObject([Net.SecurityProtocolType], 3072)
} catch { }

# --- Параллельные проверки: доступны при .NET 4.5+ (HttpClient) ---
# Если сборка не загрузилась (очень старый .NET) — монитор тихо работает
# в привычном последовательном режиме, ничего не ломается.
$script:UseParallel = $false
try {
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    $script:UseParallel = $true
} catch { }
$script:CheckSb = { param($svc) Test-Service-Http $svc }

# --- Список сервисов. Добавляйте/правьте здесь. ---------------
$Services = @(
    @{ name = '1С:КАС';              url = 'https://kas.ranepa.ru/kas/';                  expect_auth = $true  ; sm = 'Жундриков Е., +7(916)353-75-33' },
    @{ name = 'ЛК Сотрудника';       url = 'https://my.ranepa.ru/profile/';               expect_auth = $true  ; sm = 'Жундриков Е., +7(916)353-75-33' },
    @{ name = 'ЛК Студента';         url = 'https://my.ranepa.ru/student/';               expect_auth = $true  ; sm = 'Жундриков Е., +7(916)353-75-33' },
    @{ name = 'ЛК ДПО';              url = 'https://my.ranepa.ru/online/';                expect_auth = $true  ; sm = 'Жундриков Е., +7(916)353-75-33' },
    @{ name = 'Партнёрская система'; url = 'https://edtech.ranepa.ru/login';              expect_auth = $true  ; sm = 'Жундриков Е., +7(916)353-75-33' },
    @{ name = 'ИАС';                 url = 'https://trudvsem.ranepa.ru/applications/';    expect_auth = $true  ; sm = 'Жундриков Е., +7(916)353-75-33' },
    @{ name = 'Антиплагиат';         url = 'https://ranepa.antiplagiat.ru/';              expect_auth = $true  ; sm = 'Жундриков Е., +7(916)353-75-33' },
    @{ name = 'Почта';               url = 'https://mail.yandex.ru/';                     expect_auth = $true  ; sm = 'Иншаков С., +7(916)500-05-77' },
    @{ name = 'СДО ВО';              url = 'https://lms.ranepa.ru';                       expect_auth = $true  ; sm = 'Жундриков Е., +7(916)353-75-33' },
    @{ name = 'СДО ДПО';             url = 'https://lms-dpo.ranepa.ru';                   expect_auth = $true  ; sm = 'Жундриков Е., +7(916)353-75-33' },
    @{ name = 'Сайт академии';       url = 'https://www.ranepa.ru/';                      expect_auth = $false ; sm = 'Шпоркин Г., +7(915)186-31-24' },
    @{ name = 'Директум';            url = 'https://directum.ranepa.ru/';                 expect_auth = $true  ; sm = 'Вершинин В., +7(927)686-89-99' },
    @{ name = 'Платформа LPD';       url = 'https://lpd.ranepa.ru/';                      expect_auth = $true  ; sm = 'Жовнир М., +7(985)838-10-69; доп: Чирковская Е.Г.' },
    @{ name = 'Платформа LPD2';      url = 'https://lpd.ranepa.ru/monitor';               expect_auth = $false ; sm = 'Жовнир М., +7(985)838-10-69; доп: Чирковская Е.Г.' },
    @{ name = 'БУК Перспектива';     url = 'https://buk.ranepa.ru/';                      expect_auth = $true  ; sm = 'Жовнир М., +7(985)838-10-70; доп: Харьков А.Г.' },
    @{ name = 'БУК Перспектива2';    url = 'https://buk.ranepa.ru/landing';               expect_auth = $true  ; sm = 'Жовнир М., +7(985)838-10-70; доп: Харьков А.Г.' },
    @{ name = 'АИС УПСО';            url = 'https://portal.gosedu.ru/';                   expect_auth = $true  ; sm = 'Жовнир М., +7(985)838-10-71; доп: Лаврова Т.Б.' },
    @{ name = 'ММИС.Университет';    url = 'https://vo.ranepa.ru/';                       expect_auth = $true  ; sm = 'Жундриков Е., +7(916)353-75-33' },
    @{ name = 'Битрикс24';           url = 'https://crm.ranepa.ru/';                      expect_auth = $true  }
)

# --- Признаки страницы входа ----------------------------------
$AuthMarkers = @('login', 'auth', '/sso', 'saml', 'signin', 'passport.yandex',
                 'вход', 'авторизац', 'пароль', 'password')

$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'

$VerdictLabels = @{
    'OK'       = @{ label = 'OK, страница отвечает';              cls = 'ok'    }
    'AUTH'     = @{ label = 'Отвечает, редирект на вход (норма)'; cls = 'ok'    }
    'WARN_4XX' = @{ label = 'Отвечает ошибкой 4xx - проверить';   cls = 'warn'  }
    'HTTP_5XX' = @{ label = 'Ошибка сервера 5xx';                 cls = 'error' }
    'NET_FAIL' = @{ label = 'Недоступен: сеть/DNS/SSL/таймаут';   cls = 'error' }
}

$scriptVersion = 'R8.20'
Write-Host ("Service monitor script version: " + $scriptVersion)

# --- Вспомогательные функции ----------------------------------
function Escape-Html {
    param([string]$s)
    if ($null -eq $s) { return '' }
    return ($s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;'))
}

function Truncate {
    param([string]$s, [int]$n)
    if ($null -eq $s) { return '' }
    if ($s.Length -gt $n) { return $s.Substring(0, $n) }
    return $s
}

function Test-AuthUrl {
    param([string]$u, [string]$b)
    $lu = ''
    if ($u) { $lu = $u.ToLowerInvariant() }
    foreach ($m in $AuthMarkers) {
        if ($lu -and $lu.Contains($m)) { return $true }
        if ($b  -and $b.Contains($m))  { return $true }
    }
    return $false
}


# --- Блокировка от параллельных экземпляров ---------------------
# Планировщик запускает проверку каждые 5 минут независимо от того,
# завершилась ли предыдущая; сервер может одновременно делать полную
# проверку по кнопке «Проверить сейчас». Два процесса, пишущих в одни и
# те же CSV/отчёты, ломают историю и дают ложные тревоги звука.
# Механика: monitor.lock создаётся эксклюзивно (FileMode::CreateNew +
# FileShare::None) — второй процесс не сможет его создать и уйдёт.
# Внутри файла: PID;ticks. Если владелец мёртв или файл старше 10 минут
# (краш, kill из stop_monitor.bat) — замок снимается как протухший.
function Acquire-Lock {
    try {
        if (Test-Path -LiteralPath $LockPath) {
            $stale = $false
            try {
                $content = [System.IO.File]::ReadAllText($LockPath)
                $parts = $content.Split(';')
                $oldPid = [int]$parts[0]
                $oldTicks = [long]$parts[1]
                $ageMin = ((Get-Date).Ticks - $oldTicks) / 1e7 / 60.0
                $procAlive = $false
                try { $procAlive = [bool](Get-Process -Id $oldPid -ErrorAction Stop) } catch { $procAlive = $false }
                if ($ageMin -gt 10 -or (-not $procAlive)) { $stale = $true }
            } catch { $stale = $true }
            if ($stale) {
                try { Remove-Item -LiteralPath $LockPath -Force } catch { }
            }
        }
        $fs = New-Object System.IO.FileStream($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $line = ('{0};{1}' -f $PID, (Get-Date).Ticks)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
            $fs.Write($bytes, 0, $bytes.Length)
        } finally {
            $fs.Close()
        }
        return $true
    } catch {
        return $false
    }
}

function Release-Lock {
    try {
        if (Test-Path -LiteralPath $LockPath) {
            $content = ''
            try { $content = [System.IO.File]::ReadAllText($LockPath) } catch { }
            if ($content.StartsWith(("$PID;"))) {
                Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }
}

# Ожидание замка с таймаутом: для старта сервера, чтобы первая страница
# не была пустой, если в этот момент идёт проверка из Планировщика.
function Wait-Lock {
    param([int]$TimeoutSec = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        if (Acquire-Lock) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds 3
    }
}

# --- Журнал событий монитора (то, что раньше терялось в скрытых запусках) ---
# Короткая причина сетевого сбоя для поля «Код» истории:
# при NET_FAIL HTTP-ответа нет, кода не существует — пишем категорию,
# чтобы в CSV сразу было видно, что именно случилось.
function Get-NetFailLabel {
    param($ex)
    try {
        $msg = ''
        if ($ex) { $msg = [string]$ex.Message }
        $inner = $ex
        $guard = 0
        while (($null -ne $inner) -and ($null -ne $inner.InnerException) -and ($guard -lt 5)) {
            $inner = $inner.InnerException; $guard++
        }
        $all = $msg + ' ' + ([string]$inner.Message)
        if ($all -match 'истек|timed out|TimeoutException|TaskCanceled') { return 'таймаут' }
        if ($inner -is [System.Net.Sockets.SocketException]) {
            switch ([string]$inner.SocketErrorCode) {
                'HostNotFound'      { return 'DNS' }
                'TimedOut'          { return 'таймаут' }
                'ConnectionRefused' { return 'отказ в соединении' }
                'NetworkDown'       { return 'сеть недоступна' }
                'ConnectionReset'   { return 'соединение разорвано' }
                default             { return 'ошибка сети' }
            }
        }
        if ($all -match 'SSL|TLS|certificate|Сертификат|SecurityProtocol') { return 'SSL/TLS' }
        if ($all -match 'no such host|NameResolution|UnknownHost') { return 'DNS' }
        if ($all -match 'refused|Отказано') { return 'отказ в соединении' }
    } catch { }
    return 'нет ответа'
}

function Write-EventLog {
    param([string]$text)
    try {
        $logPath = Join-Path $ScriptDir ('monitor_events_' + (Get-Date -Format 'yyyy-MM-dd') + '.log')
        $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '; ' + $text
        [System.IO.File]::AppendAllText($logPath, $line + [char]13 + [char]10, (New-Object System.Text.UTF8Encoding $false))
    } catch { }
}

# --- Настройки звука: мост между браузером и Планировщиком -----
# Браузер шлёт /mute?muted=1|0 или /mute?snooze=1|0 → сервер пишет
# sound_prefs.json → следующая проверка из Планировщика читает файл
# и пропускает системный бип, если звук выключен или режим тишины.
function Get-SoundPrefs {
    $prefsPath = Join-Path $ScriptDir 'sound_prefs.json'
    $muted = $false
    $snoozeUntil = [long]0
    try {
        if (Test-Path -LiteralPath $prefsPath) {
            $raw = [System.IO.File]::ReadAllText($prefsPath)
            $obj = $raw | ConvertFrom-Json
            if ($obj.PSObject.Properties['muted'] -and $obj.muted -eq $true) { $muted = $true }
            if ($obj.PSObject.Properties['snooze_until']) { $snoozeUntil = [long]$obj.snooze_until }
        }
    } catch { }
    return [PSCustomObject]@{ muted = $muted; snooze_until = $snoozeUntil }
}

function Save-SoundPrefs {
    param([bool]$Muted, [long]$SnoozeUntil)
    $prefsPath = Join-Path $ScriptDir 'sound_prefs.json'
    $obj = [PSCustomObject]@{ muted = $Muted; snooze_until = $SnoozeUntil }
    $json = $obj | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($prefsPath, $json, (New-Object System.Text.UTF8Encoding $false))
}

# --- История: дописывание и чтение ----------------------------

function Append-History {
    param($rows)
    try {
        # автообрезка: не даём файлу истории расти бесконечно
        try {
            $item = Get-Item -LiteralPath $CsvPath -ErrorAction Stop
            if ($item.Length -gt 3MB) {
                $lines = Get-Content -LiteralPath $CsvPath -ErrorAction Stop
                $keep = @($lines | Select-Object -Last 20000)
                Set-Content -LiteralPath $CsvPath -Value $keep -Encoding UTF8 -ErrorAction Stop
            }
        } catch { }
        foreach ($r in $rows) {
            $r | Export-Csv -Path $CsvPath -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8
        }
    } catch {
        Write-Host '[ВНИМАНИЕ] Не удалось дописать историю в' $CsvPath
        Write-Host ' — возможно, файл открыт в Excel. Проверки выполнены, история не записана.'
    }
}

function Load-History {
    param([int]$Hours = 6)
    $now0 = Get-Date
    $files = @()
    foreach ($delta in 0, 1) {
        $fname = Join-Path $ScriptDir ('services_history_' + $now0.AddDays(-$delta).ToString('yyyy-MM-dd') + '.csv')
        if (Test-Path -LiteralPath $fname) { $files += $fname }
    }
    if ($files.Count -eq 0) { return @() }
    $since = $now0.AddHours(-$Hours)
    $out = @()
    foreach ($f in $files) {
        try { $all = Import-Csv -LiteralPath $f -Delimiter ';' -ErrorAction Stop } catch { continue }
        foreach ($p in $all) {
            $d = $null
            try { $d = [datetime]::ParseExact($p.datetime, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } catch { continue }
            if ($d -ge $since) { $out += $p }
        }
    }
    return $out
}

# --- Архивация истории старше недели ---------------------------
function Archive-Old-History {
    $cutoff = (Get-Date).Date.AddDays(-7)
    $old = @()
    $csvItems = Get-ChildItem -LiteralPath $ScriptDir -Filter '*.csv' -ErrorAction SilentlyContinue
    $logItems = Get-ChildItem -LiteralPath $ScriptDir -Filter '*.log' -ErrorAction SilentlyContinue
    $candidates = @($csvItems) + @($logItems)
    foreach ($f in $candidates) {
        $m = [regex]::Match($f.Name, '(?:services_history|monitoring_report)_\d{4}-\d{2}-\d{2}\.csv$|monitor_events_\d{4}-\d{2}-\d{2}\.log$')
        if (-not $m.Success) { continue }
        try { $d = [datetime]::ParseExact(([regex]::Match($f.Name, '\d{4}-\d{2}-\d{2}')).Value, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) } catch { continue }
        if ($d -lt $cutoff) { $old += $f }
    }
    if ($old.Count -eq 0) { return }
    $zipPath = Join-Path $ScriptDir 'services_history_archive.zip'
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $zipPath) {
            $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Update)
        } else {
            $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        }
        try {
            foreach ($f in $old) {
                $entry = $zip.GetEntry($f.Name)
                if ($entry) { $entry.Delete() }
                [void]$zip.CreateEntryFromFile($f.FullName, $f.Name)
            }
        } finally {
            $zip.Dispose()
        }
        foreach ($f in $old) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch {
                Write-Host '[ВНИМАНИЕ] Не удалось удалить (файл занят?):' $f.Name
            }
        }
        Write-Host ('[архив] Файлов истории старше 7 дней перенесено в архив: ' + $old.Count)
    } catch {
        Write-Host '[ВНИМАНИЕ] Не удалось заархивировать старую историю:' $_.Exception.Message
    }
}

function Uptime-Pct {
    param($points)
    if (-not $points -or $points.Count -eq 0) { return '' }
    $okc = ($points | Where-Object { $_.verdict -eq 'OK' -or $_.verdict -eq 'AUTH' }).Count
    $pct = [int](100.0 * $okc / $points.Count)
    return ('' + $pct + '%')
}

function Spark-Svg {
    param($points)
    if (-not $points -or $points.Count -eq 0) { return '<span class="nohist">нет данных</span>' }
    $w = 130; $h = 26; $pad = 2
    $n = $points.Count
    $vals = @(); $isErr = @(); $isWarn = @()
    foreach ($p in $points) {
        $v = 0
        try { $v = [int]$p.latency_ms } catch { $v = 0 }
        $vals += $v
        $isErr  += ($p.verdict -eq 'HTTP_5XX' -or $p.verdict -eq 'NET_FAIL')
        $isWarn += ($p.verdict -eq 'WARN_4XX')
    }
    $scale = @()
    for ($i = 0; $i -lt $n; $i++) { if (-not $isErr[$i]) { $scale += $vals[$i] } }
    if ($scale.Count -eq 0) { $scale = @(1) }
    $min = ($scale | Measure-Object -Minimum).Minimum
    $max = ($scale | Measure-Object -Maximum).Maximum
    if (($max - $min) -lt 40) { $span = $min + 40 } else { $span = $max }
    if ($min -gt 0) { $min = 0 }
    $step = 0
    if ($n -gt 1) { $step = ($w - 2 * $pad) / ($n - 1) }
    $svg = '<svg class="spark" width="' + $w + '" height="' + $h + '">'
    $path = ''
    for ($i = 0; $i -lt $n; $i++) {
        $x = [int]($pad + $i * $step)
        if ($isErr[$i]) { $y = $pad }
        else { $y = [int]($h - $pad - ($vals[$i] - $min) * ($h - 2 * $pad) / ($span - $min)) }
        if ($i -eq 0) { $path = 'M' + $x + ',' + $y } else { $path = $path + ' L' + $x + ',' + $y }
    }
    $svg = $svg + '<path d="' + $path + '" fill="none" stroke="#9ab" stroke-width="1"/>'
    for ($i = 0; $i -lt $n; $i++) {
        $x = [int]($pad + $i * $step)
        if ($isErr[$i]) {
            $svg = $svg + '<circle cx="' + $x + '" cy="' + $pad + '" r="2.6" fill="#c62828"/>'
        } elseif ($isWarn[$i]) {
            $y = [int]($h - $pad - ($vals[$i] - $min) * ($h - 2 * $pad) / ($span - $min))
            $svg = $svg + '<circle cx="' + $x + '" cy="' + $y + '" r="2.2" fill="#e6a700"/>'
        }
    }
    $svg = $svg + '</svg>'
    return $svg
}

# --- Звук: сигнал при новых проблемах -------------------------

function Alert-NewFailures {
    param($results)
    $info = ''
    try {
        $prev = @()
        if (Test-Path -LiteralPath $LastStatePath) {
            $prev = @(Get-Content -LiteralPath $LastStatePath -ErrorAction Stop | Where-Object { $_ -ne '' })
        }
        $now = @($results | Where-Object { $_.verdict -eq 'HTTP_5XX' -or $_.verdict -eq 'NET_FAIL' } | ForEach-Object { $_.service })
        $newFails = @($now | Where-Object { $prev -notcontains $_ })
        $recovered = @($prev | Where-Object { $now -notcontains $_ })
        Set-Content -LiteralPath $LastStatePath -Value $now -Encoding UTF8 -ErrorAction Stop
        $quietHours = ((Get-Date).Hour -ge 22) -or ((Get-Date).Hour -lt 8)
        # настройки звука из браузера (кнопка «звук» / «тихо на час»)
        $prefs = Get-SoundPrefs
        $snoozeActive = ($prefs.snooze_until -gt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        $soundOff = $prefs.muted -or $snoozeActive
        if ($newFails.Count -gt 0) {
            Write-Host ('[ТРЕВОГА] Новые проблемы: ' + ($newFails -join ', '))
            Write-EventLog ('ТРЕВОГА: новые проблемы: ' + ($newFails -join ', '))
            if ($quietHours) { Write-EventLog 'тихие часы (22:00-08:00): без звукового сигнала' }
            elseif ($soundOff) { Write-EventLog ('звук отключён пользователем (mute=' + $prefs.muted + ', snooze=' + $snoozeActive + '): без системного сигнала') }
            else {
                for ($i = 0; $i -lt 3; $i++) {
                    try { [console]::Beep(880, 220) } catch { }
                    try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
                    Start-Sleep -Milliseconds 300
                }
            }
        } elseif ($recovered.Count -gt 0) {
            Write-Host ('[восстановление] Снова работают: ' + ($recovered -join ', '))
            Write-EventLog ('восстановление: снова работают: ' + ($recovered -join ', '))
            if (-not $quietHours -and -not $soundOff) {
                try { [console]::Beep(660, 120) } catch { }
                try { [console]::Beep(880, 180) } catch { }
            }
        }
        $infoParts = @()
        if ($newFails.Count -gt 0) { $infoParts += ('новые проблемы: ' + ($newFails -join ', ')) }
        if ($recovered.Count -gt 0) { $infoParts += ('восстановлены: ' + ($recovered -join ', ')) }
        $info = ($infoParts -join '; ')
    } catch { }
    return $info
}

# --- Проверка одного сервиса ----------------------------------
function Test-Service {
    param($svc)
    $rec = [ordered]@{
        'datetime'   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        'service'    = $svc.name
        'verdict'    = ''
        'status'     = ''
        'latency_ms' = $null
        'detail'     = ''
        'url'        = $svc.url
        'final_url'  = ''
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        # своя сессия на каждый сервис: копит куки при цепочках редиректов
        # (это важно для ИАС: там сервер требует cookie на повторном заходе)
        $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        $r = Invoke-WebRequest -Uri $svc.url -TimeoutSec $TimeoutSec -UseBasicParsing `
                 -WebSession $session -UserAgent $UserAgent -MaximumRedirection 10 `
                 -Headers @{ 'Accept-Language' = 'ru,en;q=0.8' } -ErrorAction Stop
        $sw.Stop()
        $rec.latency_ms = [int]$sw.ElapsedMilliseconds
        $rec.status  = [string]$r.StatusCode
        try { $rec.final_url = [string]$r.BaseResponse.ResponseUri.AbsoluteUri } catch { $rec.final_url = $svc.url }

        $body = ''
        if ($r.Content -is [byte[]]) { $body = [System.Text.Encoding]::UTF8.GetString($r.Content) }
        else { $body = [string]$r.Content }
        if ($body.Length -gt 4000) { $body = $body.Substring(0, 4000) }
        # слова «вход/login» в теле ищем только там, где вход ожидается:
        # на публичных страницах (сайт академии) это обычный текст — источник ложных тревог
        if ($svc.expect_auth) {
            $isAuth = Test-AuthUrl -u $rec.final_url -b $body.ToLowerInvariant()
        } else {
            $isAuth = Test-AuthUrl -u $rec.final_url -b ''
        }

        if (($r.StatusCode -ge 200) -and ($r.StatusCode -lt 300)) {
            if ($isAuth -and $svc.expect_auth) {
                $rec.verdict = 'AUTH'
            } elseif ($isAuth) {
                $rec.verdict = 'WARN_4XX'
                $rec.detail  = 'неожиданно редиректит на страницу входа'
            } else {
                $rec.verdict = 'OK'
            }
        } elseif ($r.StatusCode -lt 500) {
            $rec.verdict = 'WARN_4XX'; $rec.detail = ('HTTP ' + $r.StatusCode)
        } else {
            $rec.verdict = 'HTTP_5XX'; $rec.detail = ('HTTP ' + $r.StatusCode)
        }
    } catch {
        $sw.Stop()
        $rec.latency_ms = [int]$sw.ElapsedMilliseconds
        $resp = $_.Exception.Response
        $code = 0
        if ($resp) { try { $code = [int]$resp.StatusCode } catch { $code = 0 } }
        if ($code -gt 0) {
            $rec.status = [string]$code
            $loc = ''
            try { $loc = [string]$resp.Headers['Location'] } catch { $loc = '' }
            if (($code -ge 300) -and ($code -lt 400) -and $loc -and `
                    (Test-AuthUrl -u $loc -b '') -and $svc.expect_auth) {
                # например, 302 на страницу логина — это нормальное поведение
                $rec.verdict = 'AUTH'
                try {
                    $rec.final_url = (New-Object System.Uri([System.Uri]$svc.url, $loc)).AbsoluteUri
                } catch { $rec.final_url = $loc }
            } elseif ($code -lt 500) {
                $rec.verdict = 'WARN_4XX'; $rec.detail = ('HTTP ' + $code)
            } else {
                $rec.verdict = 'HTTP_5XX'; $rec.detail = ('HTTP ' + $code)
            }
        } else {
            $rec.verdict = 'NET_FAIL'
            $rec.status  = Get-NetFailLabel $_.Exception
            $rec.detail = $_.Exception.Message
            if ($rec.detail.Length -gt 120) { $rec.detail = $rec.detail.Substring(0, 120) }
        }
    }
    return [PSCustomObject]$rec
}

# --- Проверка одного сервиса через HttpClient (параллельный) --
# Те же вердикты, что у Test-Service. Отличие: HttpClient из .NET
# позволяет гонять все сервисы одновременно (прогон 15-40 с -> 5-15 с).
# Куки ведутся своим контейнером на каждый сервис, редиректы следуют
# автоматически — поведение совпадает с WebRequestSession в Test-Service.
function Test-Service-Http {
    param($svc)
    $rec = [ordered]@{
        'datetime'   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        'service'    = $svc.name
        'verdict'    = ''
        'status'     = ''
        'latency_ms' = $null
        'detail'     = ''
        'url'        = $svc.url
        'final_url'  = ''
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = $null
    try {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AutomaticDecompression = ([System.Net.DecompressionMethods]::Gzip -bor [System.Net.DecompressionMethods]::Deflate)
        $client = New-Object System.Net.Http.HttpClient($handler, $true)
        $client.Timeout = [System.TimeSpan]::FromSeconds($TimeoutSec)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd($UserAgent)
        $client.DefaultRequestHeaders.AcceptLanguage.ParseAdd('ru,en;q=0.8')
        $respTask = $client.GetAsync($svc.url)
        if (-not $respTask.Wait()) {
            throw (New-Object System.Exception 'таймаут запроса')
        }
        $r = $respTask.GetAwaiter().GetResult()
        $sw.Stop()
        $rec.latency_ms = [int]$sw.ElapsedMilliseconds
        $code = [int]$r.StatusCode
        $rec.status = [string]$code
        try { $rec.final_url = [string]$r.RequestMessage.RequestUri.AbsoluteUri } catch { $rec.final_url = $svc.url }
        $body = ''
        try { $body = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { }
        if ($body.Length -gt 4000) { $body = $body.Substring(0, 4000) }
        # те же правила, что в Test-Service: слова «вход/login» в теле
        # ищем только там, где вход ожидается (иначе ложные тревоги)
        $isAuth = $false
        if ($svc.expect_auth) { $isAuth = Test-AuthUrl -u $rec.final_url -b $body.ToLowerInvariant() }
        else { $isAuth = Test-AuthUrl -u $rec.final_url -b '' }
        if (($code -ge 200) -and ($code -lt 300)) {
            if ($isAuth -and $svc.expect_auth) {
                $rec.verdict = 'AUTH'
            } elseif ($isAuth) {
                $rec.verdict = 'WARN_4XX'
                $rec.detail  = 'неожиданно редиректит на страницу входа'
            } else {
                $rec.verdict = 'OK'
            }
        } elseif ($code -lt 500) {
            $rec.verdict = 'WARN_4XX'; $rec.detail = ('HTTP ' + $code)
        } else {
            $rec.verdict = 'HTTP_5XX'; $rec.detail = ('HTTP ' + $code)
        }
    } catch {
        $sw.Stop()
        $rec.latency_ms = [int]$sw.ElapsedMilliseconds
        $rec.verdict = 'NET_FAIL'
        $rec.status  = Get-NetFailLabel $_.Exception
        $rec.detail = $_.Exception.Message
        if ($rec.detail.Length -gt 120) { $rec.detail = $rec.detail.Substring(0, 120) }
    } finally {
        if ($client) { try { $client.Dispose() } catch { } }
    }
    return [PSCustomObject]$rec
}

# Все сервисы одновременно: старт задач, затем сбор результатов в порядке
# списка. Если отдельная задача упала катастрофически — этот сервис
# перепроверяется последовательно старым способом, строка не теряется.
function Test-Services-Parallel {
    $tasks = @{}
    foreach ($svc in $Services) {
        $tasks[$svc.name] = [System.Threading.Tasks.Task]::Run($script:CheckSb, $svc)
    }
    $out = @()
    foreach ($svc in $Services) {
        $t = $tasks[$svc.name]
        $r = $null
        try { $r = $t.GetAwaiter().GetResult() } catch { $r = $null }
        if ($null -eq $r) { $r = Test-Service $svc }
        $out += $r
    }
    return ,$out
}

# --- Проверка всех сервисов + история -------------------------
# --- Автоотчёт в формате часовой проверки ----------------------
# Худший вердикт часа: падение в 09:05 с восстановлением в 09:55 не
# затирается — в ячейке остаётся худший вердикт, успехи копятся флагами.
function Verdict-Rank {
    param([string]$v)
    if ($v -eq 'OK' -or $v -eq 'AUTH') { return 1 }
    elseif ($v -eq 'WARN_4XX') { return 2 }
    else { return 3 }
}

function Merge-HourSlot {
    param($svc, [int]$hour, [string]$verdict, [string]$detail,
          [hashtable]$slots, [hashtable]$slotRank, [hashtable]$slotAvail, [hashtable]$slotAuthF)
    if (-not $slots.ContainsKey($svc)) {
        $slots[$svc] = (@('') * 24); $slotRank[$svc] = (@(0) * 24)
        $slotAvail[$svc] = (@($false) * 24); $slotAuthF[$svc] = (@($false) * 24)
    }
    if ($verdict -eq 'OK') { $slotAvail[$svc][$hour] = $true }
    if ($verdict -eq 'AUTH') { $slotAuthF[$svc][$hour] = $true }
    $r = Verdict-Rank $verdict
    $cur = $slotRank[$svc][$hour]
    if ($r -lt $cur) { return }
    if ($r -gt $cur) {
        $slotRank[$svc][$hour] = $r
        $vtxt = ''
        if ($verdict -eq 'OK') { $vtxt = 'Доступность +' }
        elseif ($verdict -eq 'AUTH') { $vtxt = 'Авторизация +' }
        elseif ($verdict -eq 'WARN_4XX') { $vtxt = '4xx' }
        else { $vtxt = 'СБОЙ' }
        if ($detail) { $vtxt = $vtxt + ' (' + ($detail -replace '[;\r\n]', ',') + ')' }
        $slots[$svc][$hour] = $vtxt
        return
    }
    # равный ранг: успехи копятся флагами, негативный текст не дублируем
    if ($r -eq 1 -and $cur -eq 1) {
        $fl = @()
        if ($slotAvail[$svc][$hour]) { $fl += 'Доступность +' }
        if ($slotAuthF[$svc][$hour]) { $fl += 'Авторизация +' }
        if ($fl.Count -gt 0) { $slots[$svc][$hour] = ($fl -join '; ') }
    }
    return
}

function Update-HourlyReport {
    param($results)
    try {
        $today = Get-Date
        $repPath = Join-Path $ScriptDir ('monitoring_report_' + $today.ToString('yyyy-MM-dd') + '.csv')
        $hIdx = @()
        for ($h = 0; $h -lt 24; $h++) { $hIdx += ('{0:D2}:00' -f $h) }
        $slots = @{}; $slotRank = @{}; $slotAvail = @{}; $slotAuthF = @{}
        $svcNames = @()
        foreach ($s in $Services) {
            $svcNames += $s.name
            $slots[$s.name] = (@('') * 24); $slotRank[$s.name] = (@(0) * 24)
            $slotAvail[$s.name] = (@($false) * 24); $slotAuthF[$s.name] = (@($false) * 24)
        }
        $hist = Load-History -Hours 24
        foreach ($p in $hist) {
            $d3 = $null
            try { $d3 = [datetime]::ParseExact($p.datetime, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } catch { continue }
            if ($d3.ToString('yyyy-MM-dd') -ne $today.ToString('yyyy-MM-dd')) { continue }
            if (-not $slots.ContainsKey($p.service)) { $svcNames += $p.service }
            Merge-HourSlot -svc $p.service -hour $d3.Hour -verdict $p.verdict -detail $p.detail `
                -slots $slots -slotRank $slotRank -slotAvail $slotAvail -slotAuthF $slotAuthF
        }
        foreach ($r in $results) {
            Merge-HourSlot -svc $r.service -hour (Get-Date).Hour -verdict $r.verdict -detail $r.detail `
                -slots $slots -slotRank $slotRank -slotAvail $slotAvail -slotAuthF $slotAuthF
        }
        # авто-логин: успех «Авторизация +» перекладываем в строку самой системы,
        # строка «X (авто-логин)» остаётся в отчёте только при провале авторизации
        foreach ($k in @($slotAuthF.Keys)) {
            if (-not $k.EndsWith(' (авто-логин)')) { continue }
            $base = $k.Substring(0, $k.Length - 13)
            if (-not $slots.ContainsKey($base)) {
                $slots[$base] = (@('') * 24); $slotRank[$base] = (@(0) * 24)
                $slotAvail[$base] = (@($false) * 24); $slotAuthF[$base] = (@($false) * 24)
                $svcNames += $base
            }
            for ($h = 0; $h -lt 24; $h++) {
                if ($slotRank[$k][$h] -eq 1) {
                    if ($slotAuthF[$k][$h]) { $slotAuthF[$base][$h] = $true }
                    if ($slotAvail[$k][$h]) { $slotAvail[$base][$h] = $true }
                    $slots[$k][$h] = ''
                    $slotRank[$k][$h] = 0
                }
            }
            # строка авто-логина без единого провала за день не нужна в отчёте
            $hasFail = $false
            for ($h = 0; $h -lt 24; $h++) { if ($slotRank[$k][$h] -gt 0) { $hasFail = $true; break } }
            if (-not $hasFail) {
                $svcNames = @($svcNames | Where-Object { $_ -ne $k })
                $slots.Remove($k)
            }
        }
        $lines = @()
        $lines += 'Мониторинг систем (автоматически, монитор R8.20);;' + $today.ToString('yyyy-MM-dd HH:mm')
        $lines += 'Система;Адрес;' + ($hIdx -join ';')
        foreach ($n in $svcNames) {
            $addr = ''
            foreach ($s in $Services) { if ($s.name -eq $n) { $addr = $s.url } }
            $cells = @()
            for ($h = 0; $h -lt 24; $h++) {
                $t = $slots[$n][$h]
                if ($slotRank[$n][$h] -eq 1) {
                    $fl = @()
                    if ($slotAvail[$n][$h]) { $fl += 'Доступность +' }
                    if ($slotAuthF[$n][$h]) { $fl += 'Авторизация +' }
                    $t = $fl -join '; '
                }
                $cells += $t
            }
            $lines += ($n + ';' + $addr + ';' + ($cells -join ';'))
        }
        $enc2 = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllLines($repPath, $lines, $enc2)
    } catch {
        Write-Host '[ВНИМАНИЕ] Не удалось сформировать часовой отчёт:' $_.Exception.Message
    }
}

function Run-AllChecks {
    $out = @()
    if ($script:UseParallel) {
        try {
            $out = Test-Services-Parallel
        } catch {
            Write-Host ('[ВНИМАНИЕ] параллельный режим не удался, последовательный прогон: ' + $_.Exception.Message)
            Write-EventLog ('параллельный режим: ошибка, откат на последовательный: ' + ($_.Exception.Message -replace '[;\r\n]', ','))
            $out = @()
            foreach ($svc in $Services) { $out += (Test-Service $svc) }
        }
    } else {
        foreach ($svc in $Services) { $out += (Test-Service $svc) }
    }
    Append-History -rows $out
    $alertInfo = Alert-NewFailures -results $out
    Update-HourlyReport -results $out
    $okC = ($out | Where-Object { $_.verdict -eq 'OK' -or $_.verdict -eq 'AUTH' }).Count
    $warnC = ($out | Where-Object { $_.verdict -eq 'WARN_4XX' }).Count
    $errC = ($out | Where-Object { $_.verdict -eq 'HTTP_5XX' -or $_.verdict -eq 'NET_FAIL' }).Count
    $alertPart = ''
    if ($alertInfo) { $alertPart = '; ' + $alertInfo }
    Write-EventLog ('полная проверка: ' + $out.Count + ' сервисов; OK/AUTH=' + $okC + '; 4xx=' + $warnC + '; ошибки=' + $errC + $alertPart)
    return ,$out
}

# --- Проверка с авторизацией (уровень 4) -----------------------
function Invoke-AuthChecks {
    $cfgPath = Join-Path $ScriptDir 'auth_config.csv'
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        Write-Host '[авто-логин] Файл auth_config.csv не найден - проверка с авторизацией пропущена.'
        return
    }
    $credsDir = Join-Path $ScriptDir 'auth_creds'
    $cfg = @()
    try {
        $cfg = Import-Csv -LiteralPath $cfgPath -Delimiter ';' -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Host '[ВНИМАНИЕ] Не удалось прочитать auth_config.csv:' $_.Exception.Message
        return
    }
    foreach ($c in $cfg) {
        $svc = $Services | Where-Object { $_.name -eq $c.service } | Select-Object -First 1
        if (-not $svc) { continue }
        $credPath = Join-Path $credsDir (($c.service -replace '[^\w]', '_') + '.txt')
        if (-not (Test-Path -LiteralPath $credPath)) {
            Write-Host ('[авто-логин] Нет учётных данных для: ' + $c.service)
            continue
        }
        $rec = [ordered]@{
            'datetime'   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            'service'    = ($c.service + ' (авто-логин)')
            'verdict'    = ''
            'status'     = ''
            'latency_ms' = $null
            'detail'     = ''
            'url'        = $c.login_url
            'final_url'  = ''
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $enc = @(Get-Content -LiteralPath $credPath -ErrorAction Stop)
            $secL = ConvertTo-SecureString $enc[0]
            $secP = ConvertTo-SecureString $enc[1]
            $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secL)
            $login = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
            $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secP)
            $pass = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
            $body = $c.user_field + '=' + [System.Uri]::EscapeDataString($login) + '&' + $c.pass_field + '=' + [System.Uri]::EscapeDataString($pass)
            $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            $post = Invoke-WebRequest -Uri $c.login_url -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -WebSession $session -UserAgent $UserAgent -TimeoutSec $TimeoutSec -MaximumRedirection 10 -ErrorAction Stop
            $sw.Stop()
            $rec.latency_ms = [int]$sw.ElapsedMilliseconds
            $rec.status = [string]$post.StatusCode
            $page = Invoke-WebRequest -Uri $svc.url -WebSession $session -UserAgent $UserAgent -TimeoutSec $TimeoutSec -MaximumRedirection 10 -ErrorAction Stop
            $pbody = ''
            if ($page.Content -is [byte[]]) { $pbody = [System.Text.Encoding]::UTF8.GetString($page.Content) } else { $pbody = [string]$page.Content }
            if ($pbody.Length -gt 8000) { $pbody = $pbody.Substring(0, 8000) }
            $pbodyL = $pbody.ToLowerInvariant()
            if ($c.success_marker -and $pbodyL.Contains($c.success_marker.ToLowerInvariant())) {
                $rec.verdict = 'OK'; $rec.detail = 'логин прошёл (авто)'
            } elseif ($c.fail_marker -and $pbodyL.Contains($c.fail_marker.ToLowerInvariant())) {
                $rec.verdict = 'WARN_4XX'; $rec.detail = 'логин не прошёл: увидели ' + $c.fail_marker
            } else {
                $rec.verdict = 'WARN_4XX'; $rec.detail = 'логин не подтвердился: маркер не найден'
            }
        } catch {
            $sw.Stop()
            $rec.latency_ms = [int]$sw.ElapsedMilliseconds
            $rec.verdict = 'WARN_4XX'
            $rec.detail = 'авто-логин не удался: ' + $_.Exception.Message
            if ($rec.detail.Length -gt 120) { $rec.detail = $rec.detail.Substring(0, 120) }
        }
        try { $rec | Export-Csv -Path $CsvPath -Append -NoTypeInformation -Delimiter ';' -Encoding UTF8 } catch { }
        Write-Host ('[авто-логин] ' + $c.service + ': ' + $rec.verdict + ' ' + $rec.detail)
        Write-EventLog ('авто-логин ' + $c.service + ': ' + $rec.verdict + ' ' + ($rec.detail -replace '[;\r\n]', ','))
    }
}

# --- Отрисовка страницы ---------------------------------------
$Css = @'
 body { font-family: -apple-system, "Segoe UI", Roboto, Arial, sans-serif;
        max-width: 1100px; margin: 24px auto; padding: 0 16px; color: #222; }
 h1 { font-size: 22px; }
 .meta { color: #777; margin-bottom: 16px; }
 table { border-collapse: collapse; width: 100%; font-size: 14px; }
 th, td { border-bottom: 1px solid #e8e8e8; padding: 8px 10px; text-align: left; }
 th { background: #f5f5f7; }
 .lat { white-space: nowrap; font-variant-numeric: tabular-nums; color: #555; }
 .badge { padding: 3px 10px; border-radius: 12px; font-size: 12px; white-space: nowrap; }
 .badge.ok { background: #e6f7ec; color: #1a7f37; }
 .badge.warn { background: #fff4d5; color: #9a6700; }
 .badge.error { background: #ffe5e5; color: #c62828; }
 .down { color: #c62828; font-size: 11px; white-space: nowrap; margin-top: 2px; }
 .url { color: #666; font-size: 12px; }
 .summary { margin-bottom: 14px; font-size: 14px; }
 .summary b.ok { color: #1a7f37; } .summary b.warn { color: #9a6700; }
 .summary b.error { color: #c62828; }
 .legend { font-size: 13px; color: #555; background: #f7f8fa;
        border: 1px solid #e8e8e8; border-radius: 8px;
        padding: 10px 14px; margin: 0 0 16px 0; line-height: 1.7; }
 .legend .badge { font-size: 11px; padding: 2px 8px; margin: 0 2px; }
 .legend b { color: #333; }
 .toolbar { display: flex; align-items: center; gap: 12px;
        flex-wrap: wrap; margin: 0 0 18px 0; }
 .period { font-size: 13px; color: #444; white-space: nowrap;
        background: #f1f4f8; border: 1px solid #d0d7e2; border-radius: 8px;
        padding: 6px 10px; }
 .period select { padding: 4px 6px; border-radius: 6px;
        border: 1px solid #c4cedb; font-size: 13px; background: #fff; font-weight: bold; }
 .btn { display: inline-block; padding: 9px 18px; border-radius: 8px;
        background: #2f6fed; color: #fff; text-decoration: none; font-size: 14px; }
 .btn:hover { background: #2059c8; }
 .btn.stopbtn { background: #c62828; margin-left: auto; }
 .btn.stopbtn:hover { background: #a91e1e; }
 .svclink { color: #2f6fed; text-decoration: none; }
 .svclink:hover { text-decoration: underline; }
 .chkbtn { display: inline-block; margin-left: 8px; padding: 0 8px;
        border: 1px solid #2f6fed; border-radius: 10px; color: #2f6fed;
        text-decoration: none; font-size: 12px; line-height: 18px; }
 .chkbtn:hover { background: #eef4ff; }
 .chkcol { text-align: center; white-space: nowrap; }
 .chkhead { text-align: center; font-size: 13px; }
 .sm { color: #888; font-size: 11px; white-space: nowrap; }
 .tlwrap { margin: 0 0 14px 0; }
 .tlcap { font-size: 12px; color: #777; margin-bottom: 4px; }
 .link { font-size: 13px; color: #2f6fed; margin-left: 12px; }
 .link a { color: #2f6fed; }
 .checking { color: #777; font-size: 13px; }
 .sparkcell { min-width: 140px; }
 svg.spark { display: block; }
 .nohist { color: #bbb; font-size: 12px; }
 .tlname { fill: #888; }
 .tltime { fill: #aaa; }
 .btn2 { padding: 5px 12px; border-radius: 8px; border: 1px solid #cdd6e0;
         background: #fff; color: #556; cursor: pointer; font-size: 13px;
         margin-left: 10px; vertical-align: middle; }
 .btn2.on { background: #eef4ff; border-color: #2f6fed; color: #2f6fed; }
 #evlog { margin: 0 0 16px 0; }
 #evlog pre { font-family: Consolas, "Courier New", monospace; font-size: 12px;
        background: #f7f8fa; border: 1px solid #e8e8e8; border-radius: 8px;
        padding: 10px 14px; max-height: 300px; overflow: auto; white-space: pre-wrap; }
'@


$DarkCss = @'
 body.dark { background: #101418; color: #d7dde2; }
 body.dark h1 { color: #eceff2; }
 body.dark .meta { color: #93a0aa; }
 body.dark th, body.dark td { border-bottom: 1px solid #232a31; }
 body.dark th { background: #171d23; color: #c8d1d9; }
 body.dark .lat { color: #9fabb5; }
 body.dark .url { color: #8593a0; }
 body.dark .summary b.ok { color: #57c47f; }
 body.dark .summary b.warn { color: #e8b64c; }
 body.dark .summary b.error { color: #ff7b72; }
 body.dark .badge.ok { background: rgba(76, 175, 110, 0.18); color: #6fc98e; }
 body.dark .badge.warn { background: rgba(230, 167, 0, 0.18); color: #e2b455; }
 body.dark .badge.error { background: rgba(198, 40, 40, 0.24); color: #ff8a80; }
 body.dark .legend { background: #14191e; border-color: #232a31; color: #a3aeb8; }
 body.dark .legend b { color: #d0d8de; }
 body.dark .period { background: #171d23; border-color: #2b343c; color: #c8d1d9; }
 body.dark .period select { background: #101418; color: #eceff2; border-color: #3a434d; }
 body.dark .btn2 { background: #171d23; border-color: #3a434d; color: #aeb8c1; }
 body.dark .btn2.on { background: #1a2c46; border-color: #4d84f0; color: #86b3ff; }
 body.dark .svclink { color: #86b3ff; }
 body.dark .chkbtn { color: #86b3ff; border-color: #4d84f0; }
 body.dark .chkbtn:hover { background: #1a2c46; }
 body.dark #evlog pre { background: #14191e; border-color: #232a31; color: #c8d1d9; }
 body.dark .sm { color: #7d8893; }
 body.dark .tlcap { color: #93a0aa; }
 body.dark .nohist { color: #5a6672; }
 body.dark .down { color: #ff7b72; }
 body.dark svg.spark path { stroke: #64798a; }
 body.dark .tlname { fill: #93a0aa; }
 body.dark .tltime { fill: #7d8893; }
'@

$SndJs = @'
<script>
(function(){
  var soundOn = false;
  try { soundOn = (localStorage.getItem('mon_sound') === '1'); } catch(e) {}
  try { if (/[?&]snd=on/.test(location.search)) { soundOn = true; localStorage.setItem('mon_sound', '1'); } } catch(ex) {}
  function ctx(){ try { return new (window.AudioContext||window.webkitAudioContext)(); } catch(e) { return null; } }
  function beepSeq(freqs){
    var a = ctx(); if (!a) return;
    if (a.resume) { try { a.resume(); } catch(e) {} }
    var t = a.currentTime + 0.05;
    for (var i = 0; i < freqs.length; i++) {
      var o = a.createOscillator(), g = a.createGain();
      o.connect(g); g.connect(a.destination);
      o.type = 'sine'; o.frequency.value = freqs[i];
      g.gain.setValueAtTime(0.001, t);
      g.gain.exponentialRampToValueAtTime(0.15, t + 0.02);
      g.gain.exponentialRampToValueAtTime(0.001, t + 0.22);
      o.start(t); o.stop(t + 0.24);
      t += 0.3;
    }
  }
  function updBtn(){
    var b = document.getElementById('sndbtn');
    if (!b) return;
    b.textContent = soundOn ? '\u266a звук: вкл' : 'звук: выкл';
    b.className = 'btn2' + (soundOn ? ' on' : '');
  }
  window.addEventListener('load', function(){
    updBtn();
    var b = document.getElementById('sndbtn');
    if (b) { b.addEventListener('click', function(){
      soundOn = !soundOn;
      try { localStorage.setItem('mon_sound', soundOn ? '1' : '0'); } catch(e) {}
      try { fetch('/mute?muted=' + (soundOn ? '0' : '1'), { cache: 'no-store' }); } catch(e) {}
      updBtn();
      if (soundOn) { beepSeq([660, 880]); }
    }); }
    var red = document.querySelectorAll('.badge.error').length;
    if (red > 0 && soundOn) {
      var snoozeUntil = 0;
      try { snoozeUntil = parseInt(localStorage.getItem('mon_snooze_until') || '0', 10) || 0; } catch(e) {}
      if (Date.now() >= snoozeUntil) { beepSeq([880, 880, 880]); }
    }
  });
})();
</script>
'@

$ThemeJs = @'
<script>
(function(){
  var btn = document.getElementById('themebtn'); if (!btn) return;
  function cur(){ try { var p = localStorage.getItem('mon_theme'); return (p==='dark'||p==='light') ? p : 'auto'; } catch(e) { return 'auto'; } }
  function apply(){
    var pref = cur(); var h = new Date().getHours();
    var dark = (pref==='dark') || (pref==='auto' && (h >= 22 || h < 7));
    document.body.classList.toggle('dark', dark);
    btn.textContent = (pref==='auto' ? 'тема: авто' : (pref==='dark' ? 'тема: тёмная' : 'тема: светлая'));
  }
  btn.addEventListener('click', function(){
    var pref = cur(); var next = (pref==='auto') ? 'dark' : (pref==='dark' ? 'light' : 'auto');
    try { localStorage.setItem('mon_theme', next); } catch(e) {}
    apply();
  });
  apply();
})();
</script>
'@

$SnoozeJs = @'
<script>
(function(){
  var btn = document.getElementById('snoozebtn'); if (!btn) return;
  function until(){ try { return parseInt(localStorage.getItem('mon_snooze_until') || '0', 10) || 0; } catch(e) { return 0; } }
  function upd(){
    var u = until();
    if (u > Date.now()) {
      var d = new Date(u);
      btn.textContent = 'тихо до ' + ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2);
      btn.classList.add('on');
    } else { btn.textContent = 'тихо на час'; btn.classList.remove('on'); }
  }
  btn.addEventListener('click', function(){
    if (until() > Date.now()) {
      try { localStorage.removeItem('mon_snooze_until'); } catch(e) {}
      try { fetch('/mute?snooze=0', { cache: 'no-store' }); } catch(e) {}
    } else {
      try { localStorage.setItem('mon_snooze_until', String(Date.now() + 3600000)); } catch(e) {}
      try { fetch('/mute?snooze=1', { cache: 'no-store' }); } catch(e) {}
    }
    upd();
  });
  upd();
})();
</script>
'@

$EvJs = @'
<script>
(function(){
  var btn = document.getElementById('evbtn'); if (!btn) return;
  var box = document.getElementById('evlog');
  btn.addEventListener('click', function(){
    if (box.style.display === 'block') { box.style.display = 'none'; return; }
    box.style.display = 'block';
    var pre = document.getElementById('evpre');
    pre.textContent = 'Загрузка...';
    fetch('/events?tail=100', { cache: 'no-store' })
      .then(function(r){ return r.text(); })
      .then(function(t){ pre.textContent = t; })
      .catch(function(){ pre.textContent = 'Не удалось загрузить журнал'; });
  });
})();
</script>
'@

function Render-Page {
    param($results, [bool]$ServerMode, [int]$AutoInterval)
    $ts  = ''
    if ($results.Count -gt 0) { $ts = $results[0].datetime }
    $ok   = ($results | Where-Object { $_.verdict -eq 'OK'    -or $_.verdict -eq 'AUTH'    }).Count
    $warn = ($results | Where-Object { $_.verdict -eq 'WARN_4XX' }).Count
    $err  = ($results | Where-Object { $_.verdict -eq 'HTTP_5XX' -or $_.verdict -eq 'NET_FAIL' }).Count

    $hist = Load-History -Hours 6
    $byService = @{}
    foreach ($h in $hist) {
        if (-not $byService.ContainsKey($h.service)) { $byService[$h.service] = @() }
        $byService[$h.service] += $h
    }

    # общий график доступности: строка сервиса = 24 клетки по 15 минут за 6 ч
    $nowTs = Get-Date
    $bucketMap = @{}
    foreach ($h in $hist) {
        $d2 = $null
        try { $d2 = [datetime]::ParseExact($h.datetime, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } catch { continue }
        $ageSec = [int]((New-TimeSpan -Start $d2 -End $nowTs).TotalSeconds)
        if ($ageSec -lt 0) { $ageSec = 0 }
        $bi = 23 - [int][Math]::Floor($ageSec / 900.0)
        if ($bi -lt 0 -or $bi -gt 23) { continue }
        if (-not $bucketMap.ContainsKey($h.service)) { $bucketMap[$h.service] = @(0) * 24 }
        $v2 = 1
        if ($h.verdict -eq 'WARN_4XX') { $v2 = 2 }
        elseif ($h.verdict -eq 'HTTP_5XX' -or $h.verdict -eq 'NET_FAIL') { $v2 = 3 }
        if ($v2 -gt $bucketMap[$h.service][$bi]) { $bucketMap[$h.service][$bi] = $v2 }
    }
    $tl = '<div class="tlwrap"><div class="tlcap">Доступность за 6 часов: клетка = 15 минут &middot; зелёный = успех, жёлтый = 4xx, красный = ошибка, серый = нет данных &middot; справа — сейчас</div>'
    $tlLabelW = 170
    $tlX0 = $tlLabelW + 6
    $tlRowsH = $results.Count * 12
    $tl += '<svg width="' + ($tlX0 + 24 * 14) + '" height="' + (4 + $tlRowsH + 16) + '" xmlns="http://www.w3.org/2000/svg">'
    $ri = 0
    foreach ($r in $results) {
        $arr2 = @()
        if ($bucketMap.ContainsKey($r.service)) { $arr2 = $bucketMap[$r.service] }
        $yPos = 4 + $ri * 12
        $nm = [string]$r.service
        if ($nm.Length -gt 24) { $nm = $nm.Substring(0, 23) + '…' }
        $tl += '<text class="tlname" x="0" y="' + ($yPos + 8) + '" font-size="10.5">' + (Escape-Html $nm) + '</text>'
        for ($ci = 0; $ci -lt 24; $ci++) {
            $v3 = 0
            if ($arr2.Count -ge 24) { $v3 = $arr2[$ci] }
            $col2 = '#eceff1'
            if ($v3 -eq 1) { $col2 = '#a5d6a7' }
            elseif ($v3 -eq 2) { $col2 = '#ffd54f' }
            elseif ($v3 -eq 3) { $col2 = '#e57373' }
            $tl += '<rect x="' + ($tlX0 + $ci * 14) + '" y="' + $yPos + '" width="13" height="9" rx="2" fill="' + $col2 + '"><title>' + (Escape-Html $r.service) + '</title></rect>'
        }
        $ri++
    }
    # шкала времени под сеткой: отметки каждые 1,5 часа, самая правая — сейчас
    $tlTickY = 4 + $tlRowsH + 12
    $tlTicks = @(@([int]0, '-6 ч'), @([int]6, '-4,5 ч'), @([int]12, '-3 ч'), @([int]18, '-1,5 ч'))
    foreach ($tk in $tlTicks) {
        $tl += '<text class="tltime" x="' + ($tlX0 + $tk[0] * 14) + '" y="' + $tlTickY + '" font-size="9">' + $tk[1] + '</text>'
    }
    $tl += '<text class="tltime" x="' + ($tlX0 + 23 * 14 + 13) + '" y="' + $tlTickY + '" font-size="9" text-anchor="end">сейчас</text>'
    $tl += '</svg></div>'

    $chkHead = ''
    if ($ServerMode) { $chkHead = '<th class="chkhead" title="Проверить только этот сервис">&#10227;</th>' }
    $rows = New-Object System.Text.StringBuilder
    $smMap = @{}
    foreach ($s in $Services) { if ($s.ContainsKey('sm')) { $smMap[$s.name] = $s.sm } }
    foreach ($r in $results) {
        $entry = $VerdictLabels[$r.verdict]
        $label = $entry.label
        $cls   = $entry.cls
        $pts = @()
        if ($byService.ContainsKey($r.service)) { $pts = @($byService[$r.service]) }
        $spark = Spark-Svg -points $pts
        $up = Uptime-Pct -points $pts
        # длительность текущей проблемы: идём от свежих проверок назад до первого успеха
        $downText = ''
        if ($pts.Count -gt 0) {
            try { $sorted = @($pts | Sort-Object { [datetime]::ParseExact($_.datetime, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) }) } catch { $sorted = @($pts) }
            $problemSince = $null
            for ($pi = $sorted.Count - 1; $pi -ge 0; $pi--) {
                $pv = [string]$sorted[$pi].verdict
                if ($pv -eq 'OK' -or $pv -eq 'AUTH') { break }
                try { $problemSince = [datetime]::ParseExact($sorted[$pi].datetime, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
            }
            if ($problemSince) {
                $allBad = $true
                foreach ($ptmp in $sorted) {
                    $pv2 = [string]$ptmp.verdict
                    if ($pv2 -eq 'OK' -or $pv2 -eq 'AUTH') { $allBad = $false; break }
                }
                if ($allBad) {
                    $downText = 'проблема более 6 ч'
                } else {
                    $ageMin = [int][Math]::Floor((New-TimeSpan -Start $problemSince -End $nowTs).TotalMinutes)
                    if ($ageMin -lt 1) { $downText = 'проблема: только что' }
                    elseif ($ageMin -lt 60) { $downText = 'проблема: ' + $ageMin + ' мин (с ' + $problemSince.ToString('HH:mm') + ')' }
                    else { $downText = 'проблема: ' + [int][Math]::Floor($ageMin / 60.0) + ' ч ' + ($ageMin % 60) + ' мин (с ' + $problemSince.ToString('HH:mm') + ')' }
                }
            }
        }
                $chkCell = ''
        if ($ServerMode) {
            $chkCell = '<td class="chkcol"><a class="chkbtn" href="/check?svc=' + (Escape-Html ([System.Uri]::EscapeDataString($r.service))) + '" title="Проверить только этот сервис">&#10227;</a></td>'
        }
        $smText = ''
        if ($smMap.ContainsKey($r.service)) { $smText = $smMap[$r.service] }
        $smCell = '<td class="sm"></td>'
        if ($smText) { $smCell = '<td class="sm">' + ((Escape-Html $smText) -replace '; ', ';<br>') + '</td>' }
        $detail = Escape-Html $r.detail
        if ($r.verdict -eq 'AUTH') {
            $detail = '&rarr; ' + (Escape-Html (Truncate $r.final_url 70))
        } elseif ($r.verdict -eq 'OK') {
            $detail = Escape-Html (Truncate $r.final_url 70)
        }
        $statusCell = '<td><span class="badge ' + $cls + '">' + (Escape-Html $label) + '</span>'
        if ($downText) { $statusCell += '<div class="down">' + (Escape-Html $downText) + '</div>' }
        $statusCell += '</td>'
        [void]$rows.AppendLine('<tr><td><a class="svclink" href="' + (Escape-Html $r.url) + '" target="_blank" rel="noopener">' + (Escape-Html $r.service) + '</a></td>' + $chkCell + $smCell + '<td class="lat">' + $r.latency_ms + ' мс</td>' + '<td class="lat">' + (Escape-Html $r.status) + '</td>' + $statusCell + '<td class="sparkcell">' + $spark + '</td>' + '<td class="lat">' + $up + '</td>' + '<td class="url">' + $detail + '</td></tr>')
    }

    $toolbar = ''
    $autoLink = ''
    $autoJs = ''
    $periodJs = ''
    $favJs = ''
    $metaRefresh = ''
    $sndBtn = '<button id="sndbtn" class="btn2">звук: выкл</button>'
    $themeBtn = '<button id="themebtn" class="btn2">тема: авто</button>'
    $snoozeBtn = '<button id="snoozebtn" class="btn2">тихо на час</button>'
    $evBtn = ''
    if ($ServerMode) { $evBtn = '<button id="evbtn" class="btn2">журнал</button>' }
    $favJs = '<script>(function(){'
    $favJs += 'var err=' + $err + ';var warn=' + $warn + ';'
    $favJs += 'var cv=document.createElement("canvas");cv.width=64;cv.height=64;var cx=cv.getContext("2d");'
    $favJs += 'var col=(err>0)?"#c62828":((warn>0)?"#e6a700":"#1a7f37");'
    $favJs += 'cx.fillStyle=col;cx.beginPath();cx.arc(32,32,28,0,6.3);cx.fill();'
    $favJs += 'if(err>0){cx.fillStyle="#fff";cx.font="bold 36px Arial";cx.textAlign="center";cx.fillText(String(err),32,44);}'
    $favJs += 'var ln=document.createElement("link");ln.rel="icon";ln.href=cv.toDataURL("image/png");'
    $favJs += 'var old=document.querySelector("link[rel=icon]");if(old)old.remove();document.head.appendChild(ln);'
    $favJs += 'var t0=document.title;if(err>0){setInterval(function(){document.title=(document.title===t0)?("\u26A0 "+err+" недоступно"):t0;},1200);}'
    $favJs += '})();</script>'
    if ($ServerMode) {
        $btnHref = '/?refresh=1'
        if ($AutoInterval -gt 0) { $btnHref = '/?refresh=1&auto=' + $AutoInterval }
        $toolbar = '<div class="toolbar">'
        $toolbar += '<a class="btn" href="' + $btnHref + '" ' ` + "onclick=`"this.textContent='Проверяю...';this.style.pointerEvents='none'`">" ` + '&#10227; Проверить сейчас</a>'
        $toolbar += '<label class="period" title="Влияет только на перезагрузку этой страницы в браузере. Проверки сервисов идут по расписанию каждые 5 минут независимо от этого выбора.">Обновление страницы: <select id="periodSel">'
        $defaultMin = 0
        if ($AutoInterval -gt 0) { $defaultMin = [int][Math]::Round($AutoInterval / 60.0) }
        $offOpt = ''
        if ($AutoInterval -le 0) { $offOpt = ' selected' }
        $toolbar += '<option value="0"' + $offOpt + '>выкл</option>'
        foreach ($m in @(1, 2, 3, 5, 10, 15, 30, 60)) {
            $selOpt = ''
            if ($m -eq $defaultMin) { $selOpt = ' selected' }
            $toolbar += '<option value="' + ($m * 60) + '"' + $selOpt + '>' + $m + ' мин</option>'
        }
        $toolbar += '</select></label>'
        $periodJs = '<script>(function(){var ps=document.getElementById("periodSel");var q=new URLSearchParams(location.search);var saved=null;try{saved=localStorage.getItem("ranepaPeriod")}catch(e){}if(!q.get("auto")&&saved){location.replace("/?auto="+saved+"&n="+Date.now());return}if(ps){ps.addEventListener("change",function(){var v=parseInt(ps.value,10);try{if(v>0){localStorage.setItem("ranepaPeriod",String(v))}else{localStorage.removeItem("ranepaPeriod")}}catch(e){}location.href="/?refresh=1&auto="+ps.value+"&n="+Date.now();});}})();</script>'
        if ($AutoInterval -gt 0) {
            $autoJs = '<script>setTimeout(function(){location.href="/?refresh=1&auto=' ` + $AutoInterval + '&n="+Date.now()}, ' + ($AutoInterval * 1000) + ');</script>'
        }
        $toolbar += '<a class="btn stopbtn" href="/stop" onclick="return confirm(''Остановить мониторинг? Задача в Планировщике будет удалена, проверки прекратятся.'')">Остановить мониторинг</a>'
        if ($AutoInterval -gt 0) {
            $autoLink = ' &middot; автообновление страницы: каждые ' + [int][Math]::Round($AutoInterval / 60.0) + ' мин'
        } else {
            $autoLink = ' &middot; <span style="color:#8a6d3b">автообновление страницы выключено — выберите период в тулбаре</span>'
        }
        $toolbar += '</div>'
    } else {
        # файл открывается в браузере: сам перечитывается раз в 5 минут,
        # а свежие данные в него кладёт Планировщик (см. -InstallTask в справке)
        $metaRefresh = '<meta http-equiv="refresh" content="300">'
        $toolbar = '<div class="legend"><b>Файловый режим:</b> кнопки «Проверить сейчас» и «Остановить мониторинг» работают только на живой странице. Запустите run_monitor.bat — он поднимет страницу по адресу http://localhost:8765/. Сам этот файл обновляется автоматически раз в 5 минут задачей Планировщика.</div>'
    }

    $legend = '<div class="legend"><b>Легенда:</b> '
    $legend += '<span class="badge ok">OK</span> — сервис отвечает (страница открывается или переводит на вход); '
    $legend += '<span class="badge warn">4xx</span> — сервер отвечает ошибкой клиента, стоит проверить; '
    $legend += '<span class="badge error">5xx / сеть</span> — ошибка сервера или сервис недоступен (сеть / DNS / SSL / таймаут). '
$legend += '<br>Коды: 2xx — сервер отвечает; 3xx — перенаправление; 4xx — ошибка запроса (403 — доступ запрещён, 404 — не найдено); 5xx — ошибка сервера (500, 502/503 — перегрузка или недоступность); «сеть» — DNS, SSL или таймаут. '
    $legend += '<br>График за последние 6 часов: серая линия — время ответа; <span style="color:#c62828">&#9679;</span> — падение (5xx / сеть); '
    $legend += '<span style="color:#e6a700">&#9679;</span> — ошибка 4xx; у успешных проверок точка не ставится. '
    $legend += '«Дост.» — доля успешных проверок за 6 часов. Названия сервисов — ссылки, открываются в новой вкладке.</div>'

    $title = 'Мониторинг сервисов РАНХиГС'
    $page = '<!DOCTYPE html>' + [char]10 + '<html lang="ru"><head><meta charset="utf-8">'
    $page += $metaRefresh
    $page += '<title>' + (Escape-Html $title) + '</title>'
    $page += '<style>' + $Css + $DarkCss + '</style>' + $autoJs + '</head><body>' + [char]10
    $page += '<h1>' + (Escape-Html $title) + '</h1>' + [char]10
    $page += $toolbar + [char]10
    $page += $tl + [char]10
    $page += '<div class="meta">Проверено: ' + $ts + ' &middot; Всего сервисов: ' + $results.Count + $autoLink + $sndBtn + $themeBtn + $snoozeBtn + $evBtn + '</div>' + [char]10
    $page += '<div class="summary">Доступны: <b class="ok">' + $ok + '</b> &middot; Требуют внимания: <b class="warn">' + $warn + '</b> &middot; Недоступны: <b class="error">' + $err + '</b></div>' + [char]10
    $page += '<table><tr><th>Сервис</th>' + $chkHead + '<th>Контакты</th><th>Время</th><th>Код</th><th>Статус</th><th>История</th><th>Дост.</th><th>Куда ведёт</th></tr>' + [char]10
    $page += $rows.ToString()
    $evLogDiv = ''
    if ($ServerMode) {
        $evLogDiv = '<div id="evlog" style="display:none"><div class="tlcap">Журнал событий — последние строки (сегодня, при отсутствии — вчера)</div><pre id="evpre"></pre></div>'
    }
    $page += '</table>' + [char]10 + $evLogDiv + [char]10 + $legend + [char]10 + $periodJs + $favJs + $SndJs + $ThemeJs + $SnoozeJs + $EvJs + '</body></html>'
    return $page
}

function Write-HtmlReport {
    param($results)
    $page = Render-Page -Results $results -ServerMode $false -AutoInterval 0
    [System.IO.File]::WriteAllText($OutPath, $page, (New-Object System.Text.UTF8Encoding $false))
}

# --- Режим разовой проверки ------------------------------------
function Invoke-OneShot {
    param([switch]$NoExit)
    if (-not (Acquire-Lock)) {
        Write-EventLog 'пропуск разовой проверки: другая проверка уже выполняется (lock)'
        Write-Host '[пропуск] Другая проверка уже выполняется - этот запуск пропущен.'
        if ($NoExit) { return 0 }
        exit 0
    }
    $errCount = 0
    try {
        $results = Run-AllChecks
        Write-HtmlReport $results
        if (-not $Quiet) {
            foreach ($r in $results) {
                $l = $VerdictLabels[$r.verdict].label
                $tail = ''
                if ($r.detail) { $tail = ' — ' + $r.detail }
                Write-Host ("{0,-22} {1,6} мс  {2}{3}" -f $r.service, $r.latency_ms, $l, $tail)
            }
            $errCount = ($results | Where-Object { $_.verdict -eq 'HTTP_5XX' -or $_.verdict -eq 'NET_FAIL' }).Count
            Write-Host ''
            Write-Host ("Отчёт: {0} | История: {1} | Недоступны: {2}" -f $OutPath, $CsvPath, $errCount)
        }
        $errCount = ($results | Where-Object { $_.verdict -eq 'HTTP_5XX' -or $_.verdict -eq 'NET_FAIL' }).Count
    } finally {
        Release-Lock
    }
    if ($NoExit) { return $errCount }
    if ($errCount -gt 0) { exit 1 } else { exit 0 }
}

# --- Архивация старой истории (один раз при старте) ------------
Archive-Old-History

# --- Режим авто-логина (задача Планировщика, раз в час) ---------
if ($AuthCheck) {
    if (Acquire-Lock) {
        try { Invoke-AuthChecks } finally { Release-Lock }
    } else {
        Write-EventLog 'авто-логин: пропуск, другая проверка уже выполняется (lock)'
    }
    exit 0
}

# --- Режим страницы с кнопкой ----------------------------------
if ($Serve) {
    # Свой мини-сервер на TcpListener: привязка к 127.0.0.1 не требует
    # прав администратора (HttpListener требует urlacl — потому и падал).
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Start()
    } catch {
        Write-Host '[ОШИБКА] Не удалось открыть порт' $Port 'на этом компьютере.'
        Write-Host ('Причина: ' + $_.Exception.Message)
        Write-Host ''
        Write-Host 'Перехожу в файловый режим: выполняю проверку и открываю отчёт.'
        $ec = Invoke-OneShot -NoExit
        try { Start-Process -FilePath $OutPath } catch { }
        Write-Host ''
        Write-Host 'В файловом режиме на странице нет кнопок "Проверить сейчас"'
        Write-Host 'и "Остановить мониторинг" — они работают только при живом сервере.'
        Write-Host 'Автопроверки каждые 5 минут при этом работают (задача Планировщика).'
        Write-Host 'Остановить автоматические проверки: stop_monitor.bat'
        Read-Host 'Нажмите Enter, чтобы закрыть это окно'
        exit 0
    }
    Write-Host ('Страница мониторинга: http://localhost:' + $Port + '/')
    Write-EventLog ('сервер запущен на порту ' + $Port)
    Write-Host 'Идёт первая проверка (15-30 секунд), страница станет доступна после неё.'
    Write-Host 'Остановить сервер: Ctrl+C'
    $enc = [System.Text.Encoding]::UTF8
    $cache = $null
    $cache = @()
    if (Wait-Lock -TimeoutSec 90) {
        try { $cache = Run-AllChecks } catch { $cache = @(); Write-Host ('[ОШИБКА] первая проверка: ' + $_.Exception.Message) }
        finally { Release-Lock }
    } else {
        Write-EventLog 'первая проверка сервера: пропуск, замок не освободился за 90 с (lock)'
        Write-Host '[пропуск] Первая проверка: другая проверка не завершилась за 90 с - страница обновится при следующем опросе.'
    }
    while ($true) {
        try {
            $client = $listener.AcceptTcpClient()
        } catch {
            break
        }
        try {
            $client.ReceiveTimeout = 5000
            $stream = $client.GetStream()
            $reqText = ''
            $buf = New-Object byte[] 8192
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not $reqText.Contains("`r`n`r`n")) {
                if ($stream.DataAvailable) {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $reqText = $reqText + [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
                } else {
                    if ([DateTime]::UtcNow -gt $deadline) { break }
                    Start-Sleep -Milliseconds 15
                }
            }
            if (-not $reqText) {
                # соединение без запроса (браузеры так делают про запас) — закрываем
                $client.Close()
                continue
            }
            $first = ($reqText.Split("`n")[0]).Trim()
            $parts = $first.Split(' ')
            $target = '/'
            if ($parts.Length -ge 2) { $target = $parts[1] }
            $q = ''
            $qi = $target.IndexOf('?')
            if ($qi -ge 0) { $q = $target.Substring($qi); $target = $target.Substring(0, $qi) }

            $ct = 'text/html; charset=utf-8'
            if ($target -eq '/stop') {
                & schtasks.exe /Delete /TN 'RanepaServiceMonitor' /F 2>$null | Out-Null
                & schtasks.exe /Delete /TN 'RanepaServiceMonitorAuth' /F 2>$null | Out-Null
                try { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'RanepaServiceMonitor' -ErrorAction Stop } catch { }
                Write-EventLog 'мониторинг остановлен со страницы (/stop): задачи Планировщика и автозапуск удалены'
                $page = '<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"><title>Мониторинг остановлен</title><style>body{font-family:Arial,sans-serif;max-width:640px;margin:60px auto;color:#222}h1{color:#c62828}</style></head><body><h1>Мониторинг остановлен</h1><p>Удалены: обе задачи Планировщика (проверки и авто-логин) и ключ автозапуска в реестре.</p><p>Сервер страницы остановлен, это окно можно закрыть.</p><p>Запустить снова: двойной клик по run_monitor.bat</p></body></html>'
            } elseif ($target -eq '/status') {
                # JSON-статус для браузерного расширения: только кэш, проверку не запускает
                $tsCache = ''
                if ($cache -and $cache.Count -gt 0) { $tsCache = [string]$cache[0].datetime }
                $items = @()
                if ($cache) {
                    $items = @($cache | ForEach-Object { [PSCustomObject]@{ service = [string]$_.service; verdict = [string]$_.verdict; status = [string]$_.status; latency_ms = $_.latency_ms; datetime = [string]$_.datetime } })
                }
                $obj = [PSCustomObject]@{ updated = $tsCache; services = $items }
                $page = ConvertTo-Json -InputObject $obj -Depth 3 -Compress
                $ct = 'application/json; charset=utf-8'
            } elseif ($target -eq '/hist') {
                # 6-часовая карта для виджета: 24 клетки по 15 минут на сервис
                $tsCache = ''
                if ($cache -and $cache.Count -gt 0) { $tsCache = [string]$cache[0].datetime }
                $histJ = Load-History -Hours 6
                $nowJ = Get-Date
                $bmap = @{}
                foreach ($hj in $histJ) {
                    $dj = $null
                    try { $dj = [datetime]::ParseExact($hj.datetime, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } catch { continue }
                    $ageSec = [int]((New-TimeSpan -Start $dj -End $nowJ).TotalSeconds)
                    if ($ageSec -lt 0) { $ageSec = 0 }
                    $bi = 23 - [int][Math]::Floor($ageSec / 900.0)
                    if ($bi -lt 0 -or $bi -gt 23) { continue }
                    if (-not $bmap.ContainsKey($hj.service)) { $bmap[$hj.service] = @(0) * 24 }
                    $vj = 1
                    if ($hj.verdict -eq 'WARN_4XX') { $vj = 2 }
                    elseif ($hj.verdict -eq 'HTTP_5XX' -or $hj.verdict -eq 'NET_FAIL') { $vj = 3 }
                    if ($vj -gt $bmap[$hj.service][$bi]) { $bmap[$hj.service][$bi] = $vj }
                }
                $histItems = @()
                foreach ($k in @($bmap.Keys)) {
                    $histItems += [PSCustomObject]@{ service = $k; cells = $bmap[$k] }
                }
                $hObj = [PSCustomObject]@{ updated = $tsCache; services = $histItems }
                $page = ConvertTo-Json -InputObject $hObj -Depth 3 -Compress
                $ct = 'application/json; charset=utf-8'
            } elseif ($target -eq '/events') {
                # хвост журнала событий для страницы (диагностика без открытия файлов)
                $tailN = 100
                if ($q -match 'tail=(\d+)') { $tailN = [int]$Matches[1]; if ($tailN -gt 500) { $tailN = 500 } }
                $evText = ''
                foreach ($delta in 0, 1) {
                    $evPath = Join-Path $ScriptDir ('monitor_events_' + (Get-Date).AddDays(-$delta).ToString('yyyy-MM-dd') + '.log')
                    if (Test-Path -LiteralPath $evPath) {
                        # журнал пишется в UTF-8 без BOM: читаем явно как UTF-8,
                        # иначе Get-Content в PS 5.1 возьмёт Windows-1251 и кириллица сломается
                        $evAll = [System.IO.File]::ReadAllLines($evPath, [System.Text.Encoding]::UTF8)
                        $evLines = @()
                        if ($evAll.Count -gt $tailN) { $evLines = @($evAll[($evAll.Count - $tailN)..($evAll.Count - 1)]) }
                        else { $evLines = @($evAll) }
                        $evText = ($evLines -join "`r`n")
                        break
                    }
                }
                if (-not $evText) { $evText = 'журнал пуст' }
                $page = $evText
                $ct = 'text/plain; charset=utf-8'
            } elseif ($target -eq '/mute') {
                # настройки звука из браузера (кнопки «звук» / «тихо на час»)
                # → sound_prefs.json → следующая проверка из Планировщика
                $p = Get-SoundPrefs
                if ($q -match 'muted=(\d)') { $p.muted = ($Matches[1] -eq '1') }
                if ($q -match 'snooze=(\d)') {
                    if ($Matches[1] -eq '1') { $p.snooze_until = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 3600000 }
                    else { $p.snooze_until = [long]0 }
                }
                Save-SoundPrefs -Muted $p.muted -SnoozeUntil $p.snooze_until
                Write-EventLog ('звук: настройки из браузера muted=' + $p.muted + ', snooze_ms=' + $p.snooze_until)
                $page = '{"ok":true}'
                $ct = 'application/json; charset=utf-8'
            } elseif ($target -eq '/check') {
                # точечная проверка одного сервиса (кнопка на строке)
                $svcName = ''
                if ($q -match 'svc=([^&]+)') { $svcName = $Matches[1].Replace('+', ' ') }
                try { $svcName = [System.Uri]::UnescapeDataString($svcName) } catch { }
                if ($cache) {
                    for ($i = 0; $i -lt $cache.Count; $i++) {
                        if ($cache[$i].service -eq $svcName) {
                            $svcDef = $null
                            foreach ($s in $Services) {
                                if ($s.name -eq $svcName) { $svcDef = $s }
                            }
                            if ($svcDef) {
                                Write-Host ('[точечно] проверка: ' + $svcName)
                                if (Acquire-Lock) {
                                    try {
                                        $newRec = Test-Service $svcDef
                                        $cache[$i] = $newRec
                                        Append-History -rows @($newRec)
                                    } finally { Release-Lock }
                                } else {
                                    Write-EventLog ('точечная проверка ' + $svcName + ': пропуск, другая проверка уже выполняется (lock)')
                                    Write-Host '[пропуск] Точечная проверка: другая проверка уже выполняется.'
                                }
                            }
                            break
                        }
                    }
                }
                $auto = 0
                if ($q -match 'auto=(\d+)') { $auto = [int]$Matches[1] }
                elseif ($AutoSec -gt 0) { $auto = $AutoSec }
                try {
                    $page = Render-Page -Results $cache -ServerMode $true -AutoInterval $auto
                } catch {
                    Write-Host ('[ОШИБКА] формирование страницы: ' + $_.Exception.Message)
                    $page = '<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"><title>Ошибка</title></head><body><h1>Внутренняя ошибка монитора</h1><p>Пришлите этот текст:</p><pre>' + (Escape-Html $_.Exception.Message) + '</pre><p>Строка: ' + $_.InvocationInfo.ScriptLineNumber + '</p></body></html>'
                }
            } else {
                $auto = 0
                if ($q -match 'auto=(\d+)') { $auto = [int]$Matches[1] }
                elseif ($AutoSec -gt 0) { $auto = $AutoSec }
                try {
                    if ($q -match 'refresh') {
                        if (Acquire-Lock) {
                            try { $cache = Run-AllChecks } finally { Release-Lock }
                        } else {
                            Write-EventLog 'refresh: пропуск полной проверки, другая проверка уже выполняется (lock)'
                            Write-Host '[пропуск] Полная проверка уже идёт в другом процессе - показываю кэш.'
                        }
                    }
                    $page = Render-Page -Results $cache -ServerMode $true -AutoInterval $auto
                } catch {
                    Write-Host ('[ОШИБКА] формирование страницы: ' + $_.Exception.Message)
                    $page = '<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8"><title>Ошибка</title></head><body><h1>Внутренняя ошибка монитора</h1><p>Пришлите этот текст:</p><pre>' + (Escape-Html $_.Exception.Message) + '</pre><p>Строка: ' + $_.InvocationInfo.ScriptLineNumber + '</p></body></html>'
                }
            }
            $bytes = $enc.GetBytes($page)
            $head = 'HTTP/1.1 200 OK' + "`r`n" + ('Content-Type: ' + $ct) + "`r`n" + ('Content-Length: ' + $bytes.Length) + "`r`n" + 'Connection: close' + "`r`n" + "`r`n"
            $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
            $stream.Write($headBytes, 0, $headBytes.Length)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        } catch {
            $msg = $_.Exception.Message
            $type = $_.Exception.GetType().Name
            $clientGone = (($msg -match 'разорвала установленное подключение') -or
                           ($msg -match 'удал.нный хост') -or
                           ($msg -match 'Невозможно записать данные') -or
                           ($type -eq 'IOException') -or
                           ($type -eq 'SocketException') -or
                           ($type -eq 'ObjectDisposedException'))
            if ($clientGone) {
                Write-Host '[норма] клиент отключился, не дождавшись ответа - это ожидаемо'
            } else {
                Write-Host ('[ВНИМАНИЕ] соединение оборвалось: ' + $msg)
            }
        } finally {
            try { $client.Close() } catch { }
        }
    }
    try { $listener.Stop() } catch { }
    exit 0
}

Invoke-OneShot
