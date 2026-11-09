# Автозагрузка расчётных листков: следит за папкой «Документы\Расчетные
# листы» (вместе с вложенными папками), а заодно за рабочим столом и самими
# «Документами» — или за папками из settings.txt — и сама отправляет на
# сервер каждый новый отчёт 1С «Расчетный листок», сохранённый в Excel.
#
# Запускается при входе в Windows ярлыком из папки «Автозагрузка», который
# создаёт «Включить автозагрузку.bat». Окна нет — только значок у часов,
# вопрос «Отправить?» и всплывающие уведомления.
#
# Какие файлы берёт: Excel (.xls, .xlsx), изменён за последние три дня (если
# компьютер выключили сразу после сохранения, файл уйдёт на следующий день),
# и внутри — отчёт
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
# Работает и на Windows 7 со встроенным PowerShell 2.0: всё, чего там нет,
# заменено в common.ps1 (см. там же). Поэтому здесь нет HttpClient,
# ConvertFrom-Json, оператора -in и Get-ChildItem -File.
#
# Файл сохранён в UTF-8 С BOM: Windows PowerShell читает .ps1 без BOM как
# ANSI, и кириллица ломается ещё на разборе скрипта.

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
$mutex = New-Object System.Threading.Mutex($true, 'Local\SE-mobile-payslip-watch', [ref]$createdNew)
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

# Папки: из settings.txt (можно несколько через «;»), иначе «Документы\
# Расчетные листы» — её бухгалтер завела под листки, — плюс рабочий стол и
# сами «Документы»: туда 1С предлагает сохранить отчёт. С учётом OneDrive:
# они могут лежать не в профиле. Свою папку смотрим вместе с вложенными
# (вдруг листки разложат по годам), остальные — только верхний уровень.
$script:watchDirs = @()     # @{ Path; Recurse }
if ($settings.ContainsKey('folder') -and $settings['folder'] -ne '') {
    foreach ($dir in $settings['folder'] -split ';') {
        $dir = $dir.Trim()
        if ($dir -ne '') { $script:watchDirs += @{ Path = $dir; Recurse = $true } }
    }
}
if ($script:watchDirs.Count -eq 0) {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $ownDir = Join-Path $documents 'Расчетные листы'
    # Если папку назвали через «ё», берём её.
    $altDir = Join-Path $documents 'Расчётные листы'
    if (-not (Test-Path -LiteralPath $ownDir) -and (Test-Path -LiteralPath $altDir)) { $ownDir = $altDir }
    if (-not (Test-Path -LiteralPath $ownDir)) {
        try {
            New-Item -ItemType Directory -Path $ownDir -ErrorAction Stop | Out-Null
            Write-Log "создана папка $ownDir"
        } catch {
            Write-Log "не удалось создать папку $($ownDir): $($_.Exception.Message)"
        }
    }
    $script:watchDirs = @(
        @{ Path = $ownDir; Recurse = $true },
        @{ Path = [Environment]::GetFolderPath('Desktop'); Recurse = $false },
        @{ Path = $documents; Recurse = $false })
}
$script:watchNames = @()
foreach ($w in $script:watchDirs) { $script:watchNames += $w.Path }
Write-Log "запуск, слежу за папками: $($script:watchNames -join '; ')"

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
    if (@('ok', 'declined', 'baseline') -notcontains $result) { return }
    try { Add-Content -Path $statePath -Value "$key`t$result" -Encoding UTF8 } catch { }
}

# Когда файл появился в папке. Сохранённый из 1С — по времени изменения.
# Скопированный — по времени создания: копия сохраняет старое время
# изменения, а создана она сейчас.
function Get-Stamp($file) {
    if ($file.CreationTime -gt $file.LastWriteTime) { return $file.CreationTime }
    return $file.LastWriteTime
}

function Get-Key($file) {
    return "$($file.FullName)|$($file.LastWriteTimeUtc.Ticks)|$($file.Length)"
}

function Get-ExcelFiles($w) {
    if ($w.Recurse) {
        $items = Get-ChildItem -LiteralPath $w.Path -Recurse -ErrorAction SilentlyContinue
    } else {
        $items = Get-ChildItem -LiteralPath $w.Path -ErrorAction SilentlyContinue
    }
    return $items | Where-Object {
        -not $_.PSIsContainer -and
        @('.xls', '.xlsx') -contains $_.Extension.ToLower() -and
        -not $_.Name.StartsWith('~$') -and
        $_.Length -gt 0
    }
}

# В папке под листки смотрим не на дату, а на то, был ли файл там раньше:
# файл, перенесённый туда мышью, сохраняет и старое время изменения, и
# старое время создания. Поэтому при первом запуске запоминаем, что в папке
# уже лежит со старых времён (старше трёх дней), а всё, что появится
# потом, — сохранённое, скопированное или перенесённое — отправляем.
$script:since = (Get-Date).Date.AddDays(-2)
foreach ($w in $script:watchDirs) {
    if (-not $w.Recurse -or -not (Test-Path -LiteralPath $w.Path)) { continue }
    $marker = "baseline|$($w.Path)"
    if ($script:done.ContainsKey($marker)) { continue }
    $old = 0
    foreach ($file in @(Get-ExcelFiles $w)) {
        if ((Get-Stamp $file) -lt $script:since) {
            Set-Done (Get-Key $file) 'baseline'
            $old++
        }
    }
    Set-Done $marker 'baseline'
    Write-Log "первый запуск для $($w.Path): старых файлов $old, их не трогаю"
}

$script:seenOnce = @{}   # путь -> ключ на прошлой проверке
$script:notPayslip = @{} # ключ -> $true: Excel, но не расчётные листки
$script:retryAt = @{}    # ключ -> когда пробовать снова
$script:attempts = @{}   # ключ -> сколько раз не удалось из-за сети
$script:token = $null
$script:loginRefused = $false   # сервер не принял логин — до перезапуска молчим
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
# Бухгалтер может держать файл открытым в Excel — читать его это не мешает
# (Read-SharedBytes в common.ps1).
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

function Import-Zip {
    if ($script:zipReady -ne $null) { return $script:zipReady }
    try {
        [void][Reflection.Assembly]::Load('System.IO.Compression, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')
        $script:zipReady = $true
    } catch {
        Write-Log 'нет System.IO.Compression: .xlsx узнаю только по имени'
        $script:zipReady = $false
    }
    return $script:zipReady
}

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
    # .xlsx — это zip. Читать его умеет .NET 4.5 (он же нужен для TLS 1.2);
    # если сборки нет, решаем по имени файла.
    if (-not (Import-Zip)) {
        return ($script:fileName -match 'расч|листк|листы')
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
# Возвращает @{ Ok; Status (0 — до сервера не достучались); Text; Data; Body }.
function Invoke-Server([scriptblock]$call) {
    try {
        $r = & $call
        $r['Data'] = Read-Json $r.Body
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
        Write-Log "ОШИБКА связи: $($e.GetType().FullName): $($e.Message)"
        $text = $e.Message
        if ($network) { $text += (Get-OldNetHint) }
        return @{ Ok = $false; Status = 0; Text = $text; Data = $null; Body = '' }
    }
}

function Get-Token {
    $url = $settings['server'].TrimEnd('/') + '/login'
    $data = @{ login = $settings['login']; password = $settings['password'] }
    $r = Invoke-Server { Send-Json $url $data 60 }
    # Пароль в журнал не пишем — только итог.
    if ($r.Status -eq 0) { return $r }
    if ($r.Status -eq 429) {
        $minutes = 1
        $wait = Get-Field $r.Data 'retry_after'
        if ($wait) { $minutes = [Math]::Max(1, [Math]::Ceiling([double]$wait / 60)) }
        Write-Log "вход: слишком много неверных попыток"
        return @{ Ok = $false; Status = 429; Text = "Слишком много неверных попыток входа. Попробуйте через $minutes мин." }
    }
    $token = Get-Field $r.Data 'token'
    if ($r.Ok -and $token) {
        $script:token = [string]$token
        Write-Log "вход выполнен: $(Get-Field $r.Data 'full_name')"
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

function Send-Payslips($path, $bytes, [bool]$dryRun) {
    $url = $settings['server'].TrimEnd('/') + '/api/payslips/import-excel'
    $r = $null
    for ($try = 0; $try -lt 2; $try++) {
        if (-not $script:token) {
            $login = Get-Token
            if (-not $login.Ok) { return $login }
        }
        $fields = @{}
        if ($dryRun) { $fields['dry_run'] = '1' }
        $headers = @{ Authorization = "Bearer $script:token" }

        $what = 'отправка'
        if ($dryRun) { $what = 'проверка' }
        Write-Log "$what $path ($([Math]::Round($bytes.Length / 1MB, 1)) МБ)"
        # 25 МБ по медленной сети плюс разбор на сервере.
        $r = Invoke-Server { Send-Form $url $fields $path $bytes 600 $headers }
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
    $periods = @(Get-Field $data 'periods') -join ', '
    $lines = @("$periods — листков: $(Get-Field $data 'count')")
    $replaced = [int](Get-Field $data 'replaced')
    if ($replaced -gt 0) {
        $lines += "Из них заменят уже загруженные: $replaced"
    }
    $unknown = @()
    $list = Get-Field $data 'unknown'
    if ($list) { foreach ($u in $list) { $unknown += [string](Get-Field $u 'full_name') } }
    if ($unknown.Count -gt 0) {
        $names = ($unknown | Select-Object -First 5) -join ', '
        if ($unknown.Count -gt 5) { $names += " и ещё $($unknown.Count - 5)" }
        $lines += "Нет в приложении ($($unknown.Count)): $names"
    }
    return ($lines -join "`n")
}

# --- одна попытка над одним файлом -----------------------------------------
function Send-File($file, $key, $bytes) {
        $r = Send-Payslips $file.FullName $bytes $true
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
            $r = Send-Payslips $file.FullName $bytes $false
            if ($r.Ok) {
                Set-Done $key 'ok'
                Show-Note 'Расчётные листки отправлены' $summary 'Info'
                return
            }
        }

        if (@(401, 403, 429) -contains $r.Status) {
            # Неверный пароль, нет прав или вход уже закрыт. Дальше не шлём
            # ничего — ни этот файл, ни следующие: каждая попытка с неверным
            # паролем засчитывается как ошибка входа, и сервер закрывает вход
            # и бухгалтеру в приложении. После исправления settings.txt и
            # «Включить автозагрузку» этот же файл уйдёт снова.
            $script:loginRefused = $true
            Set-Done $key 'failed'
            Show-Note 'Листки НЕ отправлены' "$($file.Name)`n$($r.Text)`nИсправьте settings.txt и снова запустите «Включить автозагрузку»." 'Error'
            return
        }

        if ($r.Status -ge 400 -and $r.Status -lt 500) {
            # Файл не разобрался или слишком большой — повтор не поможет.
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
}

function Find-NewFiles {
    if ($script:loginRefused) { return }
    $since = (Get-Date).Date.AddDays(-2)
    foreach ($w in $script:watchDirs) {
        if (-not (Test-Path -LiteralPath $w.Path)) { continue }
        foreach ($file in @(Get-ExcelFiles $w)) {
            if ($script:loginRefused) { return }
            # На рабочем столе и в «Документах» — только свежие файлы; в
            # папке под листки — любой новый (см. «первый запуск» выше).
            if (-not $w.Recurse -and (Get-Stamp $file) -lt $since) { continue }
            $key = Get-Key $file
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
            $bytes = Read-SharedBytes $file.FullName
            $script:fileName = $file.Name
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
    Show-Note 'Автозагрузка листков включена' "Слежу за папками:`n$($script:watchNames -join "`n")`nСохраните «Расчетный листок» из 1С в Excel — остальное я сделаю сам." 'Info'
}

[System.Windows.Forms.Application]::Run()

$script:tray.Visible = $false
$script:tray.Dispose()
$mutex.ReleaseMutex()
