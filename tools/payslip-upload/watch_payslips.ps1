# Автозагрузка расчётных листков: следит за рабочим столом и «Документами»
# (или папкой из settings.txt) и сама отправляет на сервер каждый новый отчёт
# 1С «Расчетный листок», сохранённый в Excel.
#
# Запускается при входе в Windows ярлыком из папки «Автозагрузка», который
# создаёт «Включить автозагрузку.bat». Окна нет — только значок у часов,
# вопрос «Отправить?» и всплывающие уведомления.
#
# Какие файлы берёт: Excel (.xls, .xlsx), изменён сегодня, и внутри — отчёт
# «Расчетный листок» (есть строка «Месяц начисления»). По имени не судим:
# бухгалтер может назвать файл как угодно, хоть «июль.xls».
#
# Перед отправкой сервер только проверяет файл (dry_run) и говорит: месяц,
# сколько листков, сколько заменят уже загруженные, кого нет в приложении.
# Бухгалтер видит это в окне и нажимает «Да» — тогда листки уходят
# сотрудникам вместе с уведомлением. Отключается в settings.txt: confirm = нет.
#
# Вход тот же, что в приложении: логин и пароль бухгалтера расчётной группы.
# Сервер сам проверит, что ей можно загружать листки.
#
# Файл сохранён в UTF-8 С BOM: Windows PowerShell 5.1 читает .ps1 без BOM
# как ANSI, и кириллица ломается ещё на разборе скрипта.

param([switch]$Announce)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logPath = Join-Path $scriptDir 'upload_log.txt'
$statePath = Join-Path $scriptDir 'watch_state.txt'
$title = 'Расчётные листки'

function Write-Log($text) {
    try {
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -Path $logPath -Value "$stamp  [авто] $text" -Encoding UTF8
    } catch { }
}

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Log "ОШИБКА запуска: $($_.Exception.Message)"
    exit 1
}

# Одна копия на пользователя: ярлык в автозагрузке плюс ручной запуск не
# должны отправлять один и тот же файл дважды.
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\SE-mobile-payslip-watch', [ref]$createdNew)
if (-not $createdNew) {
    Write-Log 'уже запущено, вторая копия не нужна'
    exit 0
}

# --- настройки -------------------------------------------------------------
$settings = @{}
try {
    $settingsPath = Join-Path $scriptDir 'settings.txt'
    if (-not (Test-Path $settingsPath)) {
        throw "Не найден файл settings.txt рядом со скриптом."
    }
    foreach ($line in Get-Content $settingsPath -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $parts = $trimmed -split '=', 2
        if ($parts.Count -eq 2) { $settings[$parts[0].Trim()] = $parts[1].Trim() }
    }
    foreach ($key in 'server', 'login', 'password') {
        if (-not $settings.ContainsKey($key) -or $settings[$key] -eq '') {
            throw "В settings.txt не заполнено поле '$key'."
        }
    }
} catch {
    Write-Log "ОШИБКА настроек: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show(
        "Автозагрузка расчётных листков не запустилась.`n`n$($_.Exception.Message)",
        $title, 'OK', 'Error') | Out-Null
    exit 1
}

# Спрашивать ли перед отправкой. По умолчанию — да: листки уходят сразу
# пятистам людям с уведомлением, и ошибочный файл назад уже не вернёшь.
$script:confirm = $true
if ($settings.ContainsKey('confirm') -and $settings['confirm'] -match '^(нет|no|0|false)$') {
    $script:confirm = $false
}

# Папки: из settings.txt (можно несколько через «;»), иначе рабочий стол и
# «Документы» — туда 1С предлагает сохранить отчёт. С учётом OneDrive:
# обе могут лежать не в профиле.
$script:watchDirs = @()
if ($settings.ContainsKey('folder') -and $settings['folder'] -ne '') {
    foreach ($dir in $settings['folder'] -split ';') {
        $dir = $dir.Trim()
        if ($dir -ne '') { $script:watchDirs += $dir }
    }
}
if ($script:watchDirs.Count -eq 0) {
    $script:watchDirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyDocuments'))
}
Write-Log "запуск, слежу за папками: $($script:watchDirs -join '; ')"

# --- что уже отправлено ----------------------------------------------------
# Ключ — путь, время изменения и размер: исправленный в 1С и заново
# сохранённый файл с тем же именем — это новый ключ, он уйдёт снова. Сервер
# заменит листки только тех людей, что есть в файле.
$script:done = @{}
if (Test-Path $statePath) {
    foreach ($line in Get-Content $statePath -Encoding UTF8) {
        $parts = $line -split "`t"
        if ($parts.Count -ge 2) { $script:done[$parts[0]] = $parts[1] }
    }
}

function Set-Done($key, $result) {
    $script:done[$key] = $result
    # Отказ сервера запоминаем только до перезапуска: исправили пароль в
    # settings.txt, снова нажали «Включить автозагрузку» — и тот же файл
    # уходит ещё раз. Запоминаем навсегда только отправленное и то, от чего
    # бухгалтер отказалась сама кнопкой «Нет».
    if ($result -ne 'ok' -and $result -ne 'declined') { return }
    try { Add-Content -Path $statePath -Value "$key`t$result" -Encoding UTF8 } catch { }
}

$script:seenOnce = @{}   # путь -> ключ на прошлой проверке
$script:notPayslip = @{} # ключ -> $true: Excel, но не расчётные листки
$script:retryAt = @{}    # ключ -> когда пробовать снова
$script:attempts = @{}   # ключ -> сколько раз не удалось из-за сети
$script:token = $null
$script:busy = $false

# --- значок у часов ---------------------------------------------------------
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = [System.Drawing.SystemIcons]::Application
$script:tray.Text = 'Автозагрузка расчётных листков'
$script:tray.Visible = $true

function Show-Note($noteTitle, $text, $icon) {
    if ($text.Length -gt 250) { $text = $text.Substring(0, 247) + '...' }
    $script:tray.BalloonTipTitle = $noteTitle
    $script:tray.BalloonTipText = $text
    $script:tray.BalloonTipIcon = $icon
    $script:tray.ShowBalloonTip(15000)
}

# Вопрос поверх всех окон: скрипт работает без своего окна, и без владельца
# с TopMost окно вопроса пряталось бы за 1С.
function Ask-YesNo($text) {
    $owner = New-Object System.Windows.Forms.Form
    try {
        $owner.TopMost = $true
        $owner.ShowInTaskbar = $false
        $owner.FormBorderStyle = 'None'
        $owner.StartPosition = 'Manual'
        $owner.Location = New-Object System.Drawing.Point(-32000, -32000)
        $owner.Size = New-Object System.Drawing.Size(1, 1)
        $owner.Show()
        $owner.Activate()
        $answer = [System.Windows.Forms.MessageBox]::Show($owner, $text, $title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button1)
        return $answer -eq [System.Windows.Forms.DialogResult]::Yes
    } finally {
        $owner.Close()
        $owner.Dispose()
    }
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

# --- чтение файла -----------------------------------------------------------
# Бухгалтер может держать файл открытым в Excel — читать его это не мешает,
# поэтому открываем с разрешением чужой записи.
function Read-Shared($path) {
    $stream = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $buffer = New-Object System.IO.MemoryStream
        $stream.CopyTo($buffer)
        return , $buffer.ToArray()
    } finally {
        $stream.Close()
    }
}

function Test-Readable($path) {
    try {
        $stream = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $stream.Close()
        return $true
    } catch {
        return $false
    }
}

# Расчётные ли это листки — по содержимому, а не по имени. Строка «Месяц
# начисления» стоит в шапке каждого листка отчёта 1С. В .xls кириллица
# лежит в UTF-16, в .xlsx — в UTF-8 внутри zip (sharedStrings или сам лист).
$script:markers = @('Месяц начисления', 'Расчетный листок', 'Расчётный листок')

function Test-Payslip($bytes, $extension) {
    if ($extension -eq '.xls') {
        # Строка может начинаться и с чётного байта, и с нечётного — читаем
        # файл в UTF-16 с обоих сдвигов.
        foreach ($shift in 0, 1) {
            $text = [System.Text.Encoding]::Unicode.GetString($bytes, $shift, $bytes.Length - $shift)
            foreach ($m in $script:markers) { if ($text.Contains($m)) { return $true } }
        }
        return $false
    }
    $zip = $null
    try {
        $memory = New-Object System.IO.MemoryStream -ArgumentList (, $bytes)
        $zip = New-Object System.IO.Compression.ZipArchive -ArgumentList $memory, ([System.IO.Compression.ZipArchiveMode]::Read)
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -ne 'xl/sharedStrings.xml' -and
                -not $entry.FullName.StartsWith('xl/worksheets/')) { continue }
            $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
            try { $text = $reader.ReadToEnd() } finally { $reader.Close() }
            foreach ($m in $script:markers) { if ($text.Contains($m)) { return $true } }
        }
        return $false
    } catch {
        return $false
    } finally {
        if ($zip) { $zip.Dispose() }
    }
}

# --- сервер -----------------------------------------------------------------
function Get-Json($body) {
    try { return ($body | ConvertFrom-Json) } catch { return $null }
}

# Возвращает @{ Ok; Status (0 — до сервера не достучались); Text; Data }.
function Invoke-Server($client, $request) {
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $parsed = Get-Json $body
        $text = if ($parsed -and $parsed.message) { [string]$parsed.message } else { $body }
        return @{ Ok = $response.IsSuccessStatusCode; Status = [int]$response.StatusCode
                  Text = $text; Data = $parsed; Body = $body }
    } catch {
        # Настоящая причина сетевого сбоя лежит во вложенном исключении.
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        Write-Log "ОШИБКА связи: $($e.GetType().FullName): $($e.Message)"
        return @{ Ok = $false; Status = 0; Text = $e.Message; Data = $null; Body = '' }
    }
}

function Get-Token($client) {
    $url = $settings['server'].TrimEnd('/') + '/login'
    $json = @{ login = $settings['login']; password = $settings['password'] } | ConvertTo-Json -Compress
    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $url)
    $request.Content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, 'application/json')
    $r = Invoke-Server $client $request
    # Пароль в журнал не пишем — только итог.
    if ($r.Status -eq 0) { return $r }
    if ($r.Status -eq 429) {
        $minutes = 1
        if ($r.Data -and $r.Data.retry_after) { $minutes = [Math]::Max(1, [Math]::Ceiling([double]$r.Data.retry_after / 60)) }
        Write-Log "вход: слишком много неверных попыток"
        return @{ Ok = $false; Status = 429; Text = "Слишком много неверных попыток входа. Попробуйте через $minutes мин." }
    }
    if ($r.Ok -and $r.Data -and $r.Data.token) {
        $script:token = [string]$r.Data.token
        Write-Log "вход выполнен: $($r.Data.full_name)"
        return @{ Ok = $true; Status = 200; Text = '' }
    }
    if ($r.Ok) {
        # Сервер на неверный пароль отвечает 200 и «Failure».
        Write-Log 'вход: неверный логин или пароль'
        return @{ Ok = $false; Status = 401; Text = 'Неверный логин или пароль в settings.txt.' }
    }
    Write-Log "вход: ответ $($r.Status): $($r.Body)"
    return $r
}

function Send-Payslips($client, $path, $bytes, [bool]$dryRun) {
    $url = $settings['server'].TrimEnd('/') + '/api/payslips/import-excel'
    for ($try = 0; $try -lt 2; $try++) {
        if (-not $script:token) {
            $login = Get-Token $client
            if (-not $login.Ok) { return $login }
        }
        $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $url)
        $request.Headers.Authorization =
            New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $script:token)
        $content = New-Object System.Net.Http.MultipartFormDataContent
        if ($dryRun) {
            $content.Add((New-Object System.Net.Http.StringContent('1')), 'dry_run')
        }
        $fileContent = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $bytes)
        $fileContent.Headers.ContentType =
            [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
        $content.Add($fileContent, 'file', [System.IO.Path]::GetFileName($path))
        $request.Content = $content

        $what = if ($dryRun) { 'проверка' } else { 'отправка' }
        Write-Log "$what $path ($([Math]::Round($bytes.Length / 1MB, 1)) МБ)"
        $r = Invoke-Server $client $request
        if ($r.Status -ne 0) { Write-Log "ответ $($r.Status): $($r.Text)" }
        # Пропуск истёк — входим заново, один раз.
        if ($r.Status -eq 401 -and $try -eq 0) {
            $script:token = $null
            continue
        }
        return $r
    }
    return $r
}

function Format-Summary($data) {
    $periods = @($data.periods) -join ', '
    $lines = @("$periods — листков: $($data.count)")
    if ([int]$data.replaced -gt 0) {
        $lines += "Из них заменят уже загруженные: $($data.replaced)"
    }
    $unknown = @($data.unknown)
    if ($unknown.Count -gt 0) {
        $names = ($unknown | Select-Object -First 5 | ForEach-Object { $_.full_name }) -join ', '
        if ($unknown.Count -gt 5) { $names += " и ещё $($unknown.Count - 5)" }
        $lines += "Нет в приложении ($($unknown.Count)): $names"
    }
    return ($lines -join "`n")
}

# --- одна попытка над одним файлом -----------------------------------------
function Send-File($file, $key, $bytes) {
    $client = New-Object System.Net.Http.HttpClient
    # 25 МБ по медленной сети плюс разбор на сервере.
    $client.Timeout = [TimeSpan]::FromSeconds(600)
    try {
        $r = Send-Payslips $client $file.FullName $bytes $true
        if ($r.Ok) {
            $summary = Format-Summary $r.Data
            if ($script:confirm) {
                $question = "Найден файл с расчётными листками:`n$($file.Name)`n`n$summary`n`n" +
                    "Отправить сотрудникам? Каждому придёт уведомление."
                if (-not (Ask-YesNo $question)) {
                    Write-Log "бухгалтер отказалась отправлять $($file.FullName)"
                    Set-Done $key 'declined'
                    Show-Note 'Листки не отправлены' "$($file.Name)`nВы нажали «Нет». Чтобы отправить, сохраните файл из 1С заново." 'Info'
                    return
                }
            }
            $r = Send-Payslips $client $file.FullName $bytes $false
            if ($r.Ok) {
                Set-Done $key 'ok'
                Show-Note 'Расчётные листки отправлены' $summary 'Info'
                return
            }
        }

        if ($r.Status -ge 400 -and $r.Status -lt 500) {
            # Неверный пароль, нет прав, файл не разобрался — повтор не
            # поможет, а повтор с неверным паролем ещё и закроет вход.
            Set-Done $key 'failed'
            Show-Note 'Листки НЕ отправлены' "$($file.Name)`n$($r.Text)`nЕсли дело в settings.txt — исправьте его и снова запустите «Включить автозагрузку»." 'Error'
            return
        }

        # Нет связи или сервер перезапускается — пробуем ещё, всё реже.
        $n = 1 + [int]$script:attempts[$key]
        $script:attempts[$key] = $n
        $delays = 1, 2, 5, 10, 15
        $minutes = $delays[[Math]::Min($n - 1, $delays.Count - 1)]
        $script:retryAt[$key] = (Get-Date).AddMinutes($minutes)
        Write-Log "не удалось ($n-й раз), повтор через $minutes мин."
        if ($n -eq 1) {
            Show-Note 'Листки пока не отправлены' "Нет связи с сервером: $($r.Text)`nПопробую ещё раз сам." 'Warning'
        }
    } finally {
        $client.Dispose()
    }
}

function Find-NewFiles {
    $today = (Get-Date).Date
    foreach ($dir in $script:watchDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $files = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -in '.xls', '.xlsx' -and
                -not $_.Name.StartsWith('~$') -and
                $_.Length -gt 0 -and
                $_.LastWriteTime -ge $today
            }
        foreach ($file in $files) {
            $key = "$($file.FullName)|$($file.LastWriteTimeUtc.Ticks)|$($file.Length)"
            if ($script:done.ContainsKey($key)) { continue }
            if ($script:notPayslip.ContainsKey($key)) { continue }
            if ($script:retryAt.ContainsKey($key) -and (Get-Date) -lt $script:retryAt[$key]) { continue }
            # Файл должен две проверки подряд не меняться — 1С могла ещё не
            # дописать: отчёт на всё предприятие весит 20–30 МБ.
            if ($script:seenOnce[$file.FullName] -ne $key) {
                $script:seenOnce[$file.FullName] = $key
                continue
            }
            if (-not (Test-Readable $file.FullName)) { continue }
            $bytes = Read-Shared $file.FullName
            if (-not (Test-Payslip $bytes $file.Extension.ToLower())) {
                $script:notPayslip[$key] = $true
                continue
            }
            Write-Log "найден файл с листками: $($file.FullName)"
            Send-File $file $key $bytes
        }
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
    Show-Note 'Автозагрузка листков включена' "Слежу за папками:`n$($script:watchDirs -join "`n")`nСохраните «Расчетный листок» из 1С в Excel — остальное я сделаю сам." 'Info'
}

[System.Windows.Forms.Application]::Run()

$script:tray.Visible = $false
$script:tray.Dispose()
$mutex.ReleaseMutex()
