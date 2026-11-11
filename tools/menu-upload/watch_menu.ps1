# Автозагрузка меню столовой: следит за рабочим столом (или папкой из
# settings.txt) и сама отправляет на сервер каждый новый файл меню из 1С.
#
# Запускается при входе в Windows ярлыком из папки «Автозагрузка», который
# создаёт «Включить автозагрузку.bat». Окна нет — только значок у часов и
# всплывающие уведомления: «меню загружено» или что пошло не так.
#
# Какие файлы берёт: Excel, имя начинается с «Меню» или содержит «Меню №»
# (бывает «Копия Меню № …»), изменён или создан сегодня. 1С
# называет их «Меню № БК000000245 от 04.11.2026».
#
# На какой день ставит меню: на дату из имени файла («от 04.11.2026»), а если
# её там нет — на сегодня. Дата внутри таблицы 1С проставляет по своему
# расписанию, поэтому ей не верим. Если же в файле сразу несколько дней,
# раскладываем их по датам из таблицы, как ярлык «Загрузить меню».
#
# Файл сохранён в UTF-8 С BOM: Windows PowerShell 5.1 читает .ps1 без BOM
# как ANSI, и кириллица ломается ещё на разборе скрипта.

param([switch]$Announce)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logPath = Join-Path $scriptDir 'upload_log.txt'
$statePath = Join-Path $scriptDir 'watch_state.txt'

function Write-Log($text) {
    try {
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -Path $logPath -Value "$stamp  [авто] $text" -Encoding UTF8
    } catch { }
}

try {
    . (Join-Path $scriptDir 'common.ps1')
    # Windows 7 со встроенным PowerShell 2.0: перезапуск на .NET 4, где есть
    # TLS 1.2. Копия запускается сама, эта — выходит.
    $argLine = ''
    if ($Announce) { $argLine = '-Announce' }
    if ((Restart-OnNet4 $MyInvocation.MyCommand.Path $argLine -NoWait) -ne $null) { exit 0 }

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    if (-not (Enable-Tls12)) { Write-Log 'TLS 1.2 недоступен на этом .NET' }
    Write-Log "PowerShell $($PSVersionTable.PSVersion), .NET $($PSVersionTable.CLRVersion)"
} catch {
    Write-Log "ОШИБКА запуска: $($_.Exception.Message)"
    exit 1
}

# Одна копия на пользователя: ярлык в автозагрузке плюс ручной запуск не
# должны отправлять один и тот же файл дважды.
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\SE-mobile-menu-watch', [ref]$createdNew)
if (-not $createdNew) {
    Write-Log 'уже запущено, вторая копия не нужна'
    exit 0
}

# --- настройки -------------------------------------------------------------
$settings = @{}
try {
    $settings = Read-Settings $scriptDir
} catch {
    Write-Log "ОШИБКА настроек: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show(
        "Автозагрузка меню не запустилась.`n`n$($_.Exception.Message)",
        'Меню столовой', 'OK', 'Error') | Out-Null
    exit 1
}

if ($settings.ContainsKey('folder') -and $settings['folder'] -ne '' -and (Test-Path -LiteralPath $settings['folder'])) {
    $script:watchDir = $settings['folder']
} else {
    # С учётом OneDrive: рабочий стол может лежать не в профиле.
    $script:watchDir = [Environment]::GetFolderPath('Desktop')
}
Write-Log "запуск, слежу за папкой: $script:watchDir"

# --- что уже отправлено ----------------------------------------------------
# Ключ — путь, время изменения и размер: исправленный и пересохранённый файл
# с тем же именем — это новый ключ, и он уйдёт снова. Сервер заменит день
# целиком и второй раз оповещать всех не станет.
$script:done = @{}
if (Test-Path $statePath) {
    foreach ($line in Get-Content $statePath -Encoding UTF8) {
        $parts = $line -split "`t"
        if ($parts.Count -ge 2) { $script:done[$parts[0]] = $parts[1] }
    }
}

function Set-Done($key, $result) {
    $script:done[$key] = $result
    # Отказ запоминаем только до перезапуска: исправили settings.txt, снова
    # нажали «Включить автозагрузку» — и тот же файл уходит ещё раз.
    if ($result -ne 'ok') { return }
    try { Add-Content -Path $statePath -Value "$key`t$result" -Encoding UTF8 } catch { }
}

$script:seenOnce = @{}   # путь -> ключ на прошлой проверке
$script:retryAt = @{}    # ключ -> когда пробовать снова
$script:attempts = @{}   # ключ -> сколько раз не удалось из-за сети
$script:busy = $false
$script:loginRefused = $false   # сервер не принял логин — до перезапуска молчим

# --- значок у часов ---------------------------------------------------------
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = [System.Drawing.SystemIcons]::Application
$script:tray.Text = 'Автозагрузка меню столовой'
$script:tray.Visible = $true

function Show-Note($title, $text, $icon) {
    if ($text.Length -gt 250) { $text = $text.Substring(0, 247) + '...' }
    $script:tray.BalloonTipTitle = $title
    $script:tray.BalloonTipText = $text
    $script:tray.BalloonTipIcon = $icon
    $script:tray.ShowBalloonTip(15000)
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$openItem = $menu.Items.Add('Открыть журнал загрузок')
$openItem.add_Click({
    if (Test-Path $logPath) { Start-Process notepad.exe -ArgumentList "`"$logPath`"" }
})
$exitItem = $menu.Items.Add('Остановить до следующего входа в Windows')
$exitItem.add_Click({
    Write-Log 'остановлено из меню у часов'
    $script:timer.Stop()
    $script:tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})
$script:tray.ContextMenuStrip = $menu

# --- отправка ---------------------------------------------------------------
function Get-DateFromName($name) {
    $m = [regex]::Match($name, '(\d{1,2})\.(\d{1,2})\.(\d{4})')
    if (-not $m.Success) { return $null }
    try {
        $year = [int]$m.Groups[3].Value
        $month = [int]$m.Groups[2].Value
        $day = [int]$m.Groups[1].Value
        return (New-Object DateTime -ArgumentList $year, $month, $day)
    } catch {
        return $null
    }
}

# Возвращает @{ Ok; Status (0 — до сервера не достучались); Text }.
function Send-Menu($path, $forceDate) {
    try {
        $url = $settings['server'].TrimEnd('/') + '/api/menu/import-excel'
        $fields = @{ login = $settings['login']; password = $settings['password'] }
        $dateNote = 'даты из файла'
        if ($forceDate) {
            $fields['force_date'] = $forceDate.ToString('yyyy-MM-dd')
            $dateNote = $forceDate.ToString('dd.MM.yyyy')
        }
        Write-Log "отправка $path на $url ($dateNote)"
        $bytes = Read-SharedBytes $path
        $r = Send-Form $url $fields $path $bytes 180
        Write-Log "ответ $($r.Status): $($r.Body)"
        return $r
    } catch {
        # Настоящая причина сетевого сбоя лежит во вложенном исключении.
        $e = $_.Exception
        $network = $false
        while ($e.InnerException) {
            if ($e -is [System.Net.WebException]) { $network = $true }
            $e = $e.InnerException
        }
        if ($e -is [System.Net.WebException]) { $network = $true }
        Write-Log "ОШИБКА отправки: $($e.GetType().FullName): $($e.Message)"
        $text = $e.Message
        if ($network) { $text += (Get-OldNetHint) }
        return @{ Ok = $false; Status = 0; Text = $text }
    }
}

function Send-File($file, $key) {
    $forceDate = Get-DateFromName $file.Name
    if (-not $forceDate) { $forceDate = (Get-Date).Date }

    $r = Send-Menu $file.FullName $forceDate
    if ($r.Status -eq 422 -and $r.Text -match 'несколько дней') {
        $r = Send-Menu $file.FullName $null
    }

    if ($r.Ok) {
        Set-Done $key 'ok'
        Show-Note 'Меню загружено' $r.Text 'Info'
        return
    }

    if (@(401, 403, 429) -contains $r.Status) {
        # Неверный пароль, чужой логин или вход уже закрыт. Дальше не шлём
        # ничего — ни этот файл, ни следующие: каждая попытка с неверным
        # паролем засчитывается как ошибка входа, после пяти сервер закрывает
        # вход, и каждая новая удваивает замок. Под ним остаётся и сам технолог
        # в приложении. Снова пробуем только после перезапуска, то есть после
        # того, как settings.txt поправили.
        $script:loginRefused = $true
        Write-Log "вход не принят ($($r.Status)), отправка остановлена до перезапуска"
        Show-Note 'Меню НЕ загружено' "$($r.Text)`nАвтозагрузка остановлена. Проверьте логин и пароль в settings.txt и снова запустите «Включить автозагрузку»." 'Error'
        return
    }

    if ($r.Status -ge 400 -and $r.Status -lt 500) {
        # Файл без блюд, не тот формат — повтор этого же файла не поможет.
        Set-Done $key 'failed'
        Show-Note 'Меню НЕ загружено' "$($file.Name)`n$($r.Text)" 'Error'
        return
    }

    # Нет связи или сервер просыпается — пробуем ещё, всё реже.
    $n = 1 + [int]$script:attempts[$key]
    $script:attempts[$key] = $n
    $delays = 1, 2, 5, 10, 15
    $minutes = $delays[[Math]::Min($n - 1, $delays.Count - 1)]
    $script:retryAt[$key] = (Get-Date).AddMinutes($minutes)
    Write-Log "не удалось ($n-й раз), повтор через $minutes мин."
    if ($n -eq 1) {
        Show-Note 'Меню пока не загружено' "Нет связи с сервером: $($r.Text)`nПопробую ещё раз сам." 'Warning'
    }
}

# Технолог может держать файл открытым в Excel — читать его это не мешает
# (Read-SharedBytes в common.ps1). Что 1С файл дописала, видно по тому, что
# он две проверки подряд не меняется.
function Test-Readable($path) {
    try {
        $stream = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $stream.Close()
        return $true
    } catch {
        return $false
    }
}

function Find-NewFiles {
    if ($script:loginRefused) { return }
    if (-not (Test-Path -LiteralPath $script:watchDir)) { return }
    $today = (Get-Date).Date
    $files = Get-ChildItem -LiteralPath $script:watchDir -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.PSIsContainer -and
            # «Меню № БК…» где угодно в имени: файл бывает и «Копия Меню № …».
            # Просто «меню» не берём — на рабочем столе столовой полно
            # других таблиц, и чужая ушла бы в приложение как меню дня.
            ($_.Name -match '^Меню' -or $_.Name -match 'Меню\s*№') -and
            @('.xlsx', '.xlsm', '.xls') -contains $_.Extension.ToLower() -and
            # Скопированный файл сохраняет старое время изменения, а время
            # создания у копии — сегодняшнее.
            ($_.LastWriteTime -ge $today -or $_.CreationTime -ge $today)
        }
    foreach ($file in $files) {
        $key = "$($file.FullName)|$($file.LastWriteTimeUtc.Ticks)|$($file.Length)"
        if ($script:done.ContainsKey($key)) { continue }
        if ($script:retryAt.ContainsKey($key) -and (Get-Date) -lt $script:retryAt[$key]) { continue }
        # Файл должен две проверки подряд не меняться — 1С могла ещё не дописать.
        if ($script:seenOnce[$file.FullName] -ne $key) {
            $script:seenOnce[$file.FullName] = $key
            continue
        }
        if (-not (Test-Readable $file.FullName)) { continue }
        Send-File $file $key
        if ($script:loginRefused) { return }
    }
}

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 5000
$script:timer.add_Tick({
    if ($script:busy) { return }
    $script:busy = $true
    try {
        Find-NewFiles
    } catch {
        Write-Log "ОШИБКА проверки папки: $($_.Exception.Message)"
    } finally {
        $script:busy = $false
    }
})
$script:timer.Start()

if ($Announce) {
    Show-Note 'Автозагрузка меню включена' "Слежу за папкой:`n$script:watchDir`nФайлы «Меню … .xlsx» из 1С будут загружаться сами." 'Info'
}

[System.Windows.Forms.Application]::Run()

$script:tray.Visible = $false
$script:tray.Dispose()
$mutex.ReleaseMutex()
