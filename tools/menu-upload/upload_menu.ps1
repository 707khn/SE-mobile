# Загрузка меню столовой из Excel в приложение SE-mobile.
#
# Запускается через "Загрузить меню.bat" — либо перетаскиванием файла на ярлык,
# либо двойным щелчком (тогда откроется окно выбора файла).
#
# Разбор таблицы делает сервер: если 1С поменяет разметку выгрузки, править
# нужно только сервер, а этот скрипт на компьютере в столовой трогать не надо.

param([string]$FilePath)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms | Out-Null

function Show-Message($text, $title, $icon) {
    [System.Windows.Forms.MessageBox]::Show($text, $title, 'OK', $icon) | Out-Null
}

try {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

    # --- настройки ---------------------------------------------------------
    $settingsPath = Join-Path $scriptDir 'settings.txt'
    if (-not (Test-Path $settingsPath)) {
        Show-Message "Не найден файл settings.txt рядом со скриптом.`n`nЗаполните его по образцу из README.txt." 'Меню столовой' 'Error'
        exit 1
    }

    $settings = @{}
    foreach ($line in Get-Content $settingsPath -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $parts = $trimmed -split '=', 2
        if ($parts.Count -eq 2) { $settings[$parts[0].Trim()] = $parts[1].Trim() }
    }

    foreach ($key in 'server', 'login', 'password') {
        if (-not $settings.ContainsKey($key) -or $settings[$key] -eq '') {
            Show-Message "В settings.txt не заполнено поле '$key'." 'Меню столовой' 'Error'
            exit 1
        }
    }

    # --- выбор файла -------------------------------------------------------
    if (-not $FilePath) {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Выберите файл меню, выгруженный из 1С'
        $dialog.Filter = 'Excel (*.xlsx;*.xlsm;*.xls)|*.xlsx;*.xlsm;*.xls'
        # Открываем сразу там, куда 1С обычно кладёт выгрузки.
        $dialog.InitialDirectory = if ($settings.ContainsKey('folder') -and (Test-Path $settings['folder'])) {
            $settings['folder']
        } else {
            [Environment]::GetFolderPath('MyDocuments')
        }
        if ($dialog.ShowDialog() -ne 'OK') { exit 0 }
        $FilePath = $dialog.FileName
    }

    if (-not (Test-Path $FilePath)) {
        Show-Message "Файл не найден:`n$FilePath" 'Меню столовой' 'Error'
        exit 1
    }

    # --- отправка ----------------------------------------------------------
    # Через HttpClient, а не Invoke-RestMethod -Form: параметр -Form есть
    # только в PowerShell 7, а в Windows встроен 5.1.
    Add-Type -AssemblyName System.Net.Http | Out-Null

    $url = $settings['server'].TrimEnd('/') + '/api/menu/import-excel'
    $client = New-Object System.Net.Http.HttpClient
    # Render на бесплатном тарифе засыпает — первый запрос ждёт пробуждения.
    $client.Timeout = [TimeSpan]::FromSeconds(180)

    $content = New-Object System.Net.Http.MultipartFormDataContent
    $content.Add((New-Object System.Net.Http.StringContent($settings['login'])), 'login')
    $content.Add((New-Object System.Net.Http.StringContent($settings['password'])), 'password')
    # Дата для блюд, перечисленных до первой даты в файле.
    if ($settings.ContainsKey('default_date') -and $settings['default_date'] -ne '') {
        $content.Add((New-Object System.Net.Http.StringContent($settings['default_date'])), 'date')
    }

    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $fileContent = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $bytes)
    $fileContent.Headers.ContentType =
        [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
    $content.Add($fileContent, 'file', [System.IO.Path]::GetFileName($FilePath))

    $response = $client.PostAsync($url, $content).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $client.Dispose()

    $parsed = $null
    try { $parsed = $body | ConvertFrom-Json } catch { }
    $text = if ($parsed -and $parsed.message) { $parsed.message } else { $body }

    if ($response.IsSuccessStatusCode) {
        Show-Message $text 'Меню загружено' 'Information'
    } else {
        Show-Message "Не удалось загрузить меню.`n`n$text" 'Меню столовой' 'Error'
        exit 1
    }
}
catch {
    Show-Message "Не удалось загрузить меню.`n`n$($_.Exception.Message)" 'Меню столовой' 'Error'
    exit 1
}
