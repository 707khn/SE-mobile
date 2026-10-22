# Выкладка документа предприятия в приложение SE-mobile: приказа,
# положения, графика смен, образца заявления.
#
# Запускается через "Выложить документ.bat" — перетаскиванием файла на
# ярлык либо двойным щелчком (тогда откроется окно выбора файла). Потом —
# одно окно: название, раздел, номер и дата, нужна ли отметка «ознакомлен».
#
# Файл сохранён в UTF-8 С BOM: Windows PowerShell 5.1 читает .ps1 без BOM
# как ANSI, и кириллица ломается ещё на разборе скрипта.

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

# Разделы — те же ключи, что на сервере (se-mobile-backend/documents.py).
$categories = [ordered]@{
    'order'      = 'Приказы'
    'regulation' = 'Положения'
    'schedule'   = 'Графики смен и праздничные дни'
    'template'   = 'Образцы заявлений'
    'other'      = 'Прочее'
}

# Окно с полями документа. Возвращает словарь или $null, если отменили.
function Ask-Details($fileName) {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Выложить документ'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(460, 300)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    # Строки окна идут сверху вниз; общая на всё окно позиция.
    $script:y = 14
    function Add-Label($text) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $text
        $label.Location = New-Object System.Drawing.Point(14, ($script:y + 3))
        $label.Size = New-Object System.Drawing.Size(120, 24)
        $form.Controls.Add($label)
    }

    Add-Label 'Название'
    $title = New-Object System.Windows.Forms.TextBox
    $title.Location = New-Object System.Drawing.Point(140, $script:y)
    $title.Size = New-Object System.Drawing.Size(305, 24)
    $title.Text = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    $form.Controls.Add($title)
    $script:y += 38

    Add-Label 'Раздел'
    $category = New-Object System.Windows.Forms.ComboBox
    $category.DropDownStyle = 'DropDownList'
    $category.Location = New-Object System.Drawing.Point(140, $script:y)
    $category.Size = New-Object System.Drawing.Size(305, 24)
    foreach ($name in $categories.Values) { [void]$category.Items.Add($name) }
    # По названию файла угадываем раздел: «Приказ №45» — в приказы.
    $lower = $fileName.ToLower()
    $category.SelectedIndex =
        if ($lower -match 'приказ') { 0 }
        elseif ($lower -match 'положени') { 1 }
        elseif ($lower -match 'график|праздн') { 2 }
        elseif ($lower -match 'образец|заявлени|бланк') { 3 }
        else { 4 }
    $form.Controls.Add($category)
    $script:y += 38

    Add-Label 'Номер'
    $number = New-Object System.Windows.Forms.TextBox
    $number.Location = New-Object System.Drawing.Point(140, $script:y)
    $number.Size = New-Object System.Drawing.Size(120, 24)
    if ($fileName -match '№\s*([\w\-/]+)') { $number.Text = $Matches[1] }
    $form.Controls.Add($number)
    $script:y += 38

    Add-Label 'Дата'
    $date = New-Object System.Windows.Forms.DateTimePicker
    $date.Format = 'Short'
    $date.ShowCheckBox = $true
    $date.Checked = $true
    $date.Location = New-Object System.Drawing.Point(140, $script:y)
    $date.Size = New-Object System.Drawing.Size(150, 24)
    $form.Controls.Add($date)
    $script:y += 42

    $ack = New-Object System.Windows.Forms.CheckBox
    $ack.Text = 'Нужна отметка «Ознакомлен» (важный приказ)'
    $ack.Location = New-Object System.Drawing.Point(14, $script:y)
    $ack.Size = New-Object System.Drawing.Size(430, 24)
    $ack.Checked = ($category.SelectedIndex -eq 0)
    $form.Controls.Add($ack)
    $script:y += 44

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Выложить'
    $ok.DialogResult = 'OK'
    $ok.Location = New-Object System.Drawing.Point(234, $script:y)
    $ok.Size = New-Object System.Drawing.Size(105, 32)
    $form.Controls.Add($ok)
    $form.AcceptButton = $ok

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Отмена'
    $cancel.DialogResult = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(345, $script:y)
    $cancel.Size = New-Object System.Drawing.Size(100, 32)
    $form.Controls.Add($cancel)
    $form.CancelButton = $cancel

    if ($form.ShowDialog() -ne 'OK') { return $null }
    return @{
        title        = $title.Text.Trim()
        category     = @($categories.Keys)[$category.SelectedIndex]
        number       = $number.Text.Trim()
        date         = if ($date.Checked) { $date.Value.ToString('yyyy-MM-dd') } else { '' }
        requires_ack = if ($ack.Checked) { '1' } else { '0' }
    }
}

try {
    Write-Log "--- запуск, аргумент: '$FilePath' ---"

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    [System.Windows.Forms.Application]::EnableVisualStyles()

    # .NET Framework по умолчанию может брать TLS 1.0, а сервер принимает 1.2.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

    # --- настройки ---------------------------------------------------------
    $settingsPath = Join-Path $scriptDir 'settings.txt'
    if (-not (Test-Path $settingsPath)) {
        throw "Не найден файл settings.txt рядом со скриптом."
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
            throw "В settings.txt не заполнено поле '$key'."
        }
    }
    Write-Log "сервер: $($settings['server']), логин: $($settings['login'])"

    # --- выбор файла -------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Выберите документ'
        $dialog.Filter = 'Документы (*.pdf;*.doc;*.docx;*.xls;*.xlsx;*.odt;*.rtf;*.txt;*.jpg;*.jpeg;*.png)|*.pdf;*.doc;*.docx;*.xls;*.xlsx;*.odt;*.rtf;*.txt;*.jpg;*.jpeg;*.png'
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

    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $details = Ask-Details $fileName
    if ($null -eq $details) { Write-Log "отменено в окне документа"; exit 0 }
    Write-Log ("поля: " + (($details.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))

    # --- отправка ----------------------------------------------------------
    # Через HttpClient, а не Invoke-RestMethod -Form: параметр -Form есть
    # только в PowerShell 7, а в Windows встроен 5.1.
    $url = $settings['server'].TrimEnd('/') + '/api/admin/documents'
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(180)

    $content = New-Object System.Net.Http.MultipartFormDataContent
    $content.Add((New-Object System.Net.Http.StringContent($settings['login'])), 'login')
    $content.Add((New-Object System.Net.Http.StringContent($settings['password'])), 'password')
    foreach ($key in $details.Keys) {
        $content.Add((New-Object System.Net.Http.StringContent($details[$key])), $key)
    }

    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $fileContent = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $bytes)
    $fileContent.Headers.ContentType =
        [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
    $content.Add($fileContent, 'file', $fileName)

    Write-Log "отправка на $url ..."
    $response = $client.PostAsync($url, $content).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $client.Dispose()
    Write-Log "ответ $($response.StatusCode): $body"

    $parsed = $null
    try { $parsed = $body | ConvertFrom-Json } catch { }
    $text = if ($parsed -and $parsed.message) { $parsed.message } else { $body }

    if ($response.IsSuccessStatusCode) {
        Show-Message $text 'Документ выложен' 'Information'
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
    Show-Message ("Не удалось выложить документ." + [Environment]::NewLine + [Environment]::NewLine + $detail + [Environment]::NewLine + [Environment]::NewLine + "Подробности в файле upload_log.txt") 'Документы' 'Error'
    exit 1
}
