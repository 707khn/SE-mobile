# Автозагрузка справочника: следит за рабочим столом, «Документами» и
# «Загрузками» (или папками из settings.txt) и сама предлагает загрузить в
# приложение каждый новый файл справочника предприятия.
#
# Запускается при входе в Windows ярлыком из папки «Автозагрузка», который
# создаёт «Включить автозагрузку.bat». Окна нет — только значок у часов,
# вопрос «Загрузить?» и всплывающие уведомления.
#
# Какие файлы берёт: Excel (.xlsx, .xlsm), изменён сегодня, и внутри —
# справочник: есть заголовки «ФИО», «Должность» и столбец с телефоном. По
# имени не судим: справочник присылают почтой под любым именем.
#
# Перед загрузкой сервер только проверяет файл (dry_run) и говорит: сколько
# записей, кто появился, кто пропал, у скольких поменялся номер или
# должность. Если файл совпадает с загруженным — ничего не спрашиваем и не
# грузим. Иначе офис-менеджер видит разницу в окне и нажимает «Да».
# Отключается в settings.txt: confirm = нет. Но если в новом файле вдвое
# меньше записей, чем сейчас в приложении, спрашиваем всё равно: справочник
# заменяется целиком, и обрывок файла стёр бы половину предприятия.
#
# Вход тот же, что в приложении: логин и пароль офис-менеджера. Сервер сам
# проверит, что ей можно менять справочник.
#
# Файл сохранён в UTF-8 С BOM: Windows PowerShell 5.1 читает .ps1 без BOM
# как ANSI, и кириллица ломается ещё на разборе скрипта.

param([switch]$Announce)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logPath = Join-Path $scriptDir 'upload_log.txt'
$statePath = Join-Path $scriptDir 'watch_state.txt'
$title = 'Справочник'

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

# Одна копия на пользователя.
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\SE-mobile-directory-watch', [ref]$createdNew)
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
        "Автозагрузка справочника не запустилась.`n`n$($_.Exception.Message)",
        $title, 'OK', 'Error') | Out-Null
    exit 1
}

$script:confirm = $true
if ($settings.ContainsKey('confirm') -and $settings['confirm'] -match '^(нет|no|0|false)$') {
    $script:confirm = $false
}

# Папки: из settings.txt (можно несколько через «;»), иначе рабочий стол,
# «Документы» и «Загрузки» — справочник обычно приходит почтой и
# сохраняется туда.
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
        [Environment]::GetFolderPath('MyDocuments'),
        (Join-Path $env:USERPROFILE 'Downloads'))
}
Write-Log "запуск, слежу за папками: $($script:watchDirs -join '; ')"

# --- что уже обработано ----------------------------------------------------
# Ключ — путь, время изменения и размер: исправленный и заново сохранённый
# файл с тем же именем — новый ключ, его предложим снова.
$script:done = @{}
if (Test-Path $statePath) {
    foreach ($line in Get-Content $statePath -Encoding UTF8) {
        $parts = $line -split "`t"
        if ($parts.Count -ge 2) { $script:done[$parts[0]] = $parts[1] }
    }
}

function Set-Done($key, $result) {
    $script:done[$key] = $result
    # Отказ сервера помним только до перезапуска: исправили пароль в
    # settings.txt, снова нажали «Включить автозагрузку» — и тот же файл
    # пробуется ещё раз.
    if ($result -notin 'ok', 'declined', 'same') { return }
    try { Add-Content -Path $statePath -Value "$key`t$result" -Encoding UTF8 } catch { }
}

$script:seenOnce = @{}
$script:notDirectory = @{}
$script:retryAt = @{}
$script:attempts = @{}
$script:busy = $false

# --- значок у часов ---------------------------------------------------------
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = [System.Drawing.SystemIcons]::Application
$script:tray.Text = 'Автозагрузка справочника'
$script:tray.Visible = $true

function Show-Note($noteTitle, $text, $icon) {
    if ($text.Length -gt 250) { $text = $text.Substring(0, 247) + '...' }
    $script:tray.BalloonTipTitle = $noteTitle
    $script:tray.BalloonTipText = $text
    $script:tray.BalloonTipIcon = $icon
    $script:tray.ShowBalloonTip(15000)
}

# Вопрос поверх всех окон: своего окна у скрипта нет, и без владельца с
# TopMost вопрос прятался бы за почтой.
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
# Файл может быть открыт в Excel — читать это не мешает.
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

# Справочник ли это — по содержимому: заголовки «ФИО» и «Должность» и
# столбец с телефоном (внутренний или мобильный). Список сотрудников из
# отдела кадров с ФИО и должностью, но без телефонов, сюда не попадёт.
# Слова те же, что ищет сервер (parser_directory_excel.py).
function Test-Directory($bytes) {
    $zip = $null
    try {
        $memory = New-Object System.IO.MemoryStream -ArgumentList (, $bytes)
        $zip = New-Object System.IO.Compression.ZipArchive -ArgumentList $memory, ([System.IO.Compression.ZipArchiveMode]::Read)
        $text = ''
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -ne 'xl/sharedStrings.xml' -and
                -not $entry.FullName.StartsWith('xl/worksheets/')) { continue }
            $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
            try { $text += $reader.ReadToEnd() } finally { $reader.Close() }
        }
        # Excel пишет кириллицу как есть, а другие программы (openpyxl,
        # выгрузки из учётных систем) — ссылками вида &#1060;.
        $text = [System.Net.WebUtility]::HtmlDecode($text)
        return ($text -match 'Ф\.?И\.?О') -and
               ($text -match 'Должност') -and
               ($text -match 'Вн[/. ]?(номер|№)|Внутрен|Мобильн|Сотов')
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
function Send-Directory($client, $path, $bytes, [bool]$dryRun) {
    $url = $settings['server'].TrimEnd('/') + '/api/directory/import-excel'
    $content = New-Object System.Net.Http.MultipartFormDataContent
    $content.Add((New-Object System.Net.Http.StringContent($settings['login'])), 'login')
    $content.Add((New-Object System.Net.Http.StringContent($settings['password'])), 'password')
    if ($dryRun) {
        $content.Add((New-Object System.Net.Http.StringContent('1')), 'dry_run')
    }
    $fileContent = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $bytes)
    $fileContent.Headers.ContentType =
        [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
    $content.Add($fileContent, 'file', [System.IO.Path]::GetFileName($path))

    $what = if ($dryRun) { 'проверка' } else { 'загрузка' }
    Write-Log "$what $path"
    try {
        $response = $client.PostAsync($url, $content).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $parsed = Get-Json $body
        $text = if ($parsed -and $parsed.message) { [string]$parsed.message } else { $body }
        # Пароль в журнал не пишем; ответ сервера без него.
        $logged = if ($dryRun -and $parsed) { "count=$($parsed.count) unchanged=$($parsed.unchanged)" } else { $text }
        Write-Log "ответ $([int]$response.StatusCode): $logged"
        return @{ Ok = $response.IsSuccessStatusCode; Status = [int]$response.StatusCode
                  Text = $text; Data = $parsed }
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        Write-Log "ОШИБКА связи: $($e.GetType().FullName): $($e.Message)"
        return @{ Ok = $false; Status = 0; Text = $e.Message; Data = $null }
    }
}

function Format-Names($names) {
    $list = @($names)
    $text = ($list | Select-Object -First 5) -join ', '
    if ($list.Count -gt 5) { $text += " и ещё $($list.Count - 5)" }
    return $text
}

function Format-Summary($data) {
    $lines = @("В файле: $($data.count) записей, $($data.departments) подразделений " +
               "(сейчас в приложении $($data.current_count)).")
    $added = @($data.added)
    $removed = @($data.removed)
    if ($added.Count -gt 0) { $lines += "Новые ($($added.Count)): $(Format-Names $added)" }
    if ($removed.Count -gt 0) { $lines += "Пропадут ($($removed.Count)): $(Format-Names $removed)" }
    if ([int]$data.changed -gt 0) { $lines += "Изменились номер, должность или отдел: $($data.changed)" }
    return ($lines -join "`n")
}

# --- одна попытка над одним файлом -----------------------------------------
function Send-File($file, $key, $bytes) {
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(180)
    try {
        $r = Send-Directory $client $file.FullName $bytes $true
        if ($r.Ok) {
            if ($r.Data.unchanged) {
                # Тот же справочник, что уже в приложении: пересохранили,
                # переслали — тревожить не о чем.
                Write-Log "не изменился, не загружаю: $($file.FullName)"
                Set-Done $key 'same'
                return
            }
            $summary = Format-Summary $r.Data
            $shrinks = [int]$r.Data.current_count -gt 0 -and
                       ([int]$r.Data.count * 2) -lt [int]$r.Data.current_count
            if ($script:confirm -or $shrinks) {
                $warning = ''
                if ($shrinks) {
                    $warning = "ВНИМАНИЕ: в файле вдвое меньше записей, чем сейчас в приложении. " +
                               "Проверьте, тот ли это файл.`n`n"
                }
                $question = "Найден новый справочник:`n$($file.Name)`n`n$summary`n`n$warning" +
                    "Загрузить в приложение? Справочник заменится целиком у всех сотрудников."
                if (-not (Ask-YesNo $question)) {
                    Write-Log "офис-менеджер отказалась загружать $($file.FullName)"
                    Set-Done $key 'declined'
                    Show-Note 'Справочник не загружен' "$($file.Name)`nВы нажали «Нет». Чтобы загрузить, сохраните файл заново или перетащите его на «Загрузить справочник»." 'Info'
                    return
                }
            }
            $r = Send-Directory $client $file.FullName $bytes $false
            if ($r.Ok) {
                Set-Done $key 'ok'
                Show-Note 'Справочник загружен' $r.Text 'Info'
                return
            }
        }

        if ($r.Status -ge 400 -and $r.Status -lt 500) {
            # Неверный пароль, нет прав, файл не разобрался — повтор не
            # поможет, а повтор с неверным паролем ещё и закроет вход.
            Set-Done $key 'failed'
            Show-Note 'Справочник НЕ загружен' "$($file.Name)`n$($r.Text)`nЕсли дело в settings.txt — исправьте его и снова запустите «Включить автозагрузку»." 'Error'
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
            Show-Note 'Справочник пока не загружен' "Нет связи с сервером: $($r.Text)`nПопробую ещё раз сам." 'Warning'
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
                $_.Extension -in '.xlsx', '.xlsm' -and
                -not $_.Name.StartsWith('~$') -and
                $_.Length -gt 0 -and
                $_.LastWriteTime -ge $today
            }
        foreach ($file in $files) {
            $key = "$($file.FullName)|$($file.LastWriteTimeUtc.Ticks)|$($file.Length)"
            if ($script:done.ContainsKey($key)) { continue }
            if ($script:notDirectory.ContainsKey($key)) { continue }
            if ($script:retryAt.ContainsKey($key) -and (Get-Date) -lt $script:retryAt[$key]) { continue }
            # Файл должен две проверки подряд не меняться — его могли ещё
            # не дописать.
            if ($script:seenOnce[$file.FullName] -ne $key) {
                $script:seenOnce[$file.FullName] = $key
                continue
            }
            if (-not (Test-Readable $file.FullName)) { continue }
            $bytes = Read-Shared $file.FullName
            if (-not (Test-Directory $bytes)) {
                $script:notDirectory[$key] = $true
                continue
            }
            Write-Log "найден файл справочника: $($file.FullName)"
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
    Show-Note 'Автозагрузка справочника включена' "Слежу за папками:`n$($script:watchDirs -join "`n")`nСохраните новый справочник в Excel — остальное я сделаю сам." 'Info'
}

[System.Windows.Forms.Application]::Run()

$script:tray.Visible = $false
$script:tray.Dispose()
$mutex.ReleaseMutex()
