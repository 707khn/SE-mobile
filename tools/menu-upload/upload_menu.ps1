# Загрузка меню столовой из Excel в приложение SE-mobile.
#
# Запускается через "Загрузить меню.bat" — перетаскиванием файла на ярлык
# либо двойным щелчком (тогда откроется окно выбора файла).
#
# С ключом -Today (ярлык "Меню на сегодня.bat") дата из файла не важна: меню
# ложится на сегодняшний день, чтобы оно сразу было видно в приложении.
#
# Файл сохранён в UTF-8 С BOM: Windows PowerShell 5.1 читает .ps1 без BOM
# как ANSI, и кириллица ломается ещё на разборе скрипта.
#
# Разбор таблицы делает сервер: если 1С поменяет разметку выгрузки, править
# нужно только сервер, а этот скрипт на компьютере в столовой — нет.

param([string]$FilePath, [switch]$Today)

$logPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'upload_log.txt'

function Write-Log($text) {
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Add-Content -Path $logPath -Value "$stamp  $text" -Encoding UTF8
}

function Show-Message($text, $title, $icon) {
    # Окно, если формы доступны; иначе — консоль, чтобы сообщение не пропало.
    try {
        [System.Windows.Forms.MessageBox]::Show($text, $title, 'OK', $icon) | Out-Null
    } catch {
        Write-Host ""
        Write-Host "$title : $text"
    }
}

# Всё в одном try: раньше Add-Type стоял снаружи, и при сбое показывать ошибку
# было уже нечем — окно просто не появлялось.
try {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    . (Join-Path $scriptDir 'common.ps1')

    # Windows 7 со встроенным PowerShell 2.0 работает на .NET 2.0, где нет
    # TLS 1.2. Если новый .NET установлен — перезапускаемся на нём.
    $argLine = ''
    if ($FilePath) { $argLine += "-FilePath `"$FilePath`" " }
    if ($Today) { $argLine += '-Today' }
    $code = Restart-OnNet4 $MyInvocation.MyCommand.Path $argLine
    if ($code -ne $null) { exit $code }

    Write-Log "--- запуск, аргумент: '$FilePath', на сегодня: $Today, PowerShell $($PSVersionTable.PSVersion), .NET $($PSVersionTable.CLRVersion) ---"

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    if (-not (Enable-Tls12)) { Write-Log 'TLS 1.2 недоступен на этом .NET' }

    # --- настройки ---------------------------------------------------------
    $settings = Read-Settings $scriptDir
    Write-Log "сервер: $($settings['server']), логин: $($settings['login'])"

    # --- выбор файла -------------------------------------------------------
    if (-not $FilePath -or $FilePath.Trim() -eq '') {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        if ($Today) {
            $dialog.Title = 'Выберите файл меню — оно встанет на сегодня'
        } else {
            $dialog.Title = 'Выберите файл меню, выгруженный из 1С'
        }
        $dialog.Filter = 'Excel (*.xlsx;*.xlsm;*.xls)|*.xlsx;*.xlsm;*.xls'
        if ($settings.ContainsKey('folder') -and $settings['folder'] -ne '' -and (Test-Path $settings['folder'])) {
            $dialog.InitialDirectory = $settings['folder']
        } else {
            $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
        }
        if ($dialog.ShowDialog() -ne 'OK') { Write-Log "выбор файла отменён"; exit 0 }
        $FilePath = $dialog.FileName
    }
    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Файл не найден: $FilePath"
    }
    Write-Log "файл: $FilePath"

    # --- отправка ----------------------------------------------------------
    $url = $settings['server'].TrimEnd('/') + '/api/menu/import-excel'
    $fields = @{ login = $settings['login']; password = $settings['password'] }
    if ($settings.ContainsKey('default_date') -and $settings['default_date'] -ne '') {
        $fields['date'] = $settings['default_date']
    }
    if ($Today) {
        $fields['force_date'] = (Get-Date).ToString('yyyy-MM-dd')
        Write-Log "меню ставится на сегодня: $($fields['force_date'])"
    }

    Write-Log "отправка на $url ..."
    $bytes = Read-SharedBytes $FilePath
    # Сервер может просыпаться — первый запрос ждёт дольше обычного.
    $r = Send-Form $url $fields $FilePath $bytes 180
    Write-Log "ответ $($r.Status): $($r.Body)"

    if ($r.Ok) {
        Show-Message $r.Text 'Меню загружено' 'Information'
        exit 0
    }
    throw $r.Text
}
catch {
    # У сетевых сбоев внешнее сообщение всегда одно — «Произошла ошибка при
    # отправке запроса», и по нему не понять ничего. Настоящая причина —
    # недоверенный сертификат, закрытый порт, неизвестное имя — лежит во
    # вложенном исключении, поэтому разворачиваем всю цепочку.
    $messages = @()
    $network = $false
    $error_ = $_.Exception
    while ($error_) {
        $messages += $error_.Message
        if ($error_ -is [System.Net.WebException]) { $network = $true }
        Write-Log ("ОШИБКА: " + $error_.GetType().FullName + ': ' + $error_.Message)
        $error_ = $error_.InnerException
    }
    Write-Log $_.ScriptStackTrace

    # Человеку — только текст, без имён классов. Когда причина вложена,
    # показываем и её: внешнее сообщение у сетевых сбоев неинформативно.
    $detail = $messages[0]
    if ($messages.Count -gt 1) {
        $detail = $messages[0] + [Environment]::NewLine + [Environment]::NewLine +
                  'Причина: ' + $messages[-1]
    }
    if ($network -and (Get-Command Get-OldNetHint -ErrorAction SilentlyContinue)) {
        $detail += Get-OldNetHint
    }
    Show-Message ("Не удалось загрузить меню." + [Environment]::NewLine + [Environment]::NewLine + $detail + [Environment]::NewLine + [Environment]::NewLine + "Подробности в файле upload_log.txt") 'Меню столовой' 'Error'
    exit 1
}
