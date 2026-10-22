# Загрузка остатков на складах в приложение SE-mobile.
#
# Запускается через "Загрузить остатки.bat" — перетаскиванием файла на
# ярлык либо двойным щелчком (тогда откроется окно выбора файла).
#
# Файл сохранён в UTF-8 С BOM: Windows PowerShell 5.1 читает .ps1 без BOM
# как ANSI, и кириллица ломается ещё на разборе скрипта.
#
# Разбор отчёта делает сервер: раскладка отчёта 1С меняется вместе с его
# настройками, и когда это случится, править нужно будет сервер, а не
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

try {
    Write-Log "--- запуск, аргумент: '$FilePath' ---"

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop

    # .NET Framework по умолчанию может брать TLS 1.0, а сервер принимает 1.2.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

    # --- настройки ---------------------------------------------------------
    $settingsPath = Join-Path $scriptDir 'settings.txt'
    if (-not (Test-Path $settingsPath)) {
        throw "Не найден файл settings.txt рядом со скриптом."
    }

    $settings = @{}
    foreach ($line in Get-Content $settingsPath) {
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
    Write-Log "сервер: $($settings['server']), логин: $($settings['login'])"

    # --- выбор файла -------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Выберите отчёт об остатках'
        $dialog.Filter = 'Excel (*.xlsx;*.xlsm)|*.xlsx;*.xlsm'
        $dialog.InitialDirectory =
            if ($settings.ContainsKey('folder') -and $settings['folder'] -ne '' -and (Test-Path $settings['folder'])) {
                $settings['folder']
            } else {
                [Environment]::GetFolderPath('MyDocuments')
            }
        if ($dialog.ShowDialog() -ne 'OK') { Write-Log "выбор файла отменён"; exit 0 }
        $FilePath = $dialog.FileName
    }
    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Файл не найден: $FilePath"
    }
    Write-Log "файл: $FilePath"

    # --- отправка ----------------------------------------------------------
    # Через HttpClient, а не Invoke-RestMethod -Form: параметр -Form есть
    # только в PowerShell 7, а в Windows встроен 5.1.
    $url = $settings['server'].TrimEnd('/') + '/api/stock-balances/import-excel'
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(180)

    $content = New-Object System.Net.Http.MultipartFormDataContent
    $content.Add((New-Object System.Net.Http.StringContent($settings['login'])), 'login')
    $content.Add((New-Object System.Net.Http.StringContent($settings['password'])), 'password')

    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $fileContent = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $bytes)
    $fileContent.Headers.ContentType =
        [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
    $content.Add($fileContent, 'file', [System.IO.Path]::GetFileName($FilePath))

    Write-Log "отправка на $url ..."
    $response = $client.PostAsync($url, $content).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $client.Dispose()
    Write-Log "ответ $($response.StatusCode): $body"

    $parsed = $null
    try { $parsed = $body | ConvertFrom-Json } catch { }
    $text = if ($parsed -and $parsed.message) { $parsed.message } else { $body }

    if ($response.IsSuccessStatusCode) {
        Show-Message $text 'Остатки загружены' 'Information'
        exit 0
    }
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
    Show-Message ("Не удалось загрузить остатки." + [Environment]::NewLine + [Environment]::NewLine + $detail + [Environment]::NewLine + [Environment]::NewLine + "Подробности в файле upload_log.txt") 'Остатки' 'Error'
    exit 1
}
