# Загрузка телефонного справочника предприятия в приложение SE-mobile.
#
# Запускается через "Загрузить справочник.bat" — перетаскиванием файла на
# ярлык либо двойным щелчком (тогда откроется окно выбора файла).
#
# Файл сохранён в UTF-8 С BOM: Windows PowerShell 5.1 читает .ps1 без BOM
# как ANSI, и кириллица ломается ещё на разборе скрипта.
#
# Разбор таблицы делает сервер: справочник печатают вольно — ФИО кочует
# между двумя столбцами, отделы идут строками-заголовками, — и когда
# раскладка в очередной раз изменится, править нужно будет сервер, а не
# этот скрипт на чужом компьютере.

param([string]$FilePath)

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

# Всё в одном try: при сбое до окна выбора ошибку всё равно есть чем показать.
try {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    . (Join-Path $scriptDir 'common.ps1')

    # Windows 7 со встроенным PowerShell 2.0 работает на .NET 2.0, где нет
    # TLS 1.2. Если новый .NET установлен — перезапускаемся на нём.
    $argLine = ''
    if ($FilePath) { $argLine = "-FilePath `"$FilePath`"" }
    $code = Restart-OnNet4 $MyInvocation.MyCommand.Path $argLine
    if ($code -ne $null) { exit $code }

    Write-Log "--- запуск, аргумент: '$FilePath', PowerShell $($PSVersionTable.PSVersion), .NET $($PSVersionTable.CLRVersion) ---"

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    if (-not (Enable-Tls12)) { Write-Log 'TLS 1.2 недоступен на этом .NET' }

    # --- настройки ---------------------------------------------------------
    $settings = Read-Settings $scriptDir
    Write-Log "сервер: $($settings['server']), логин: $($settings['login'])"

    # --- выбор файла -------------------------------------------------------
    if (-not $FilePath -or $FilePath.Trim() -eq '') {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Выберите файл справочника'
        $dialog.Filter = 'Excel (*.xlsx;*.xlsm)|*.xlsx;*.xlsm'
        # В folder может быть несколько папок через «;» — для автозагрузки.
        # Окно выбора открываем в первой.
        $firstFolder = ''
        if ($settings.ContainsKey('folder')) { $firstFolder = ($settings['folder'] -split ';')[0].Trim() }
        if ($firstFolder -ne '' -and (Test-Path $firstFolder)) {
            $dialog.InitialDirectory = $firstFolder
        } else {
            $dialog.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
        }
        if ($dialog.ShowDialog() -ne 'OK') { Write-Log "выбор файла отменён"; exit 0 }
        $FilePath = $dialog.FileName
    }
    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Файл не найден: $FilePath"
    }
    Write-Log "файл: $FilePath"

    # --- отправка ----------------------------------------------------------
    # Send-Form из common.ps1: HttpClient и Invoke-RestMethod -Form есть не
    # везде, а HttpWebRequest — и в PowerShell 2.0 на Windows 7.
    $url = $settings['server'].TrimEnd('/') + '/api/directory/import-excel'
    $fields = @{ login = $settings['login']; password = $settings['password'] }
    $bytes = Read-SharedBytes $FilePath
    Write-Log "отправка на $url ..."
    try {
        $r = Send-Form $url $fields $FilePath $bytes 180
    } catch {
        $hint = Get-OldNetHint
        if ($hint) { throw ($_.Exception.Message + $hint) }
        throw
    }
    Write-Log "ответ $($r.Status): $($r.Text)"

    if ($r.Ok) {
        Show-Message $r.Text 'Справочник загружен' 'Information'
        exit 0
    }
    $text = $r.Text
    throw $text
}
catch {
    # У сетевых сбоев внешнее сообщение всегда одно — «Произошла ошибка при
    # отправке запроса», и по нему не понять ничего. Настоящая причина —
    # недоверенный сертификат, закрытый порт, неизвестное имя — лежит во
    # вложенном исключении, поэтому разворачиваем всю цепочку.
    $messages = @()
    $error_ = $_.Exception
    while ($error_) {
        $messages += $error_.Message
        Write-Log ("ОШИБКА: " + $error_.GetType().FullName + ': ' + $error_.Message)
        $error_ = $error_.InnerException
    }
    Write-Log $_.ScriptStackTrace

    $detail = $messages[0]
    if ($messages.Count -gt 1) {
        $detail = $messages[0] + [Environment]::NewLine + [Environment]::NewLine +
                  'Причина: ' + $messages[-1]
    }
    Show-Message ("Не удалось загрузить справочник." + [Environment]::NewLine + [Environment]::NewLine + $detail + [Environment]::NewLine + [Environment]::NewLine + "Подробности в файле upload_log.txt") 'Справочник' 'Error'
    exit 1
}
