# Выгрузка меню столовой из приложения SE-mobile в файл для Excel.
#
# Обратная к upload_menu.ps1: та отправляет меню на сервер, эта забирает
# обратно — посмотреть или распечатать, что на сегодня в приложении.
#
# Запускается через "Выгрузить меню.bat" двойным щелчком. Без аргумента
# берёт сегодняшний день; можно передать другую дату: ГГГГ-ММ-ДД.
#
# Файл сохранён в UTF-8 С BOM: Windows PowerShell 5.1 читает .ps1 без BOM
# как ANSI, и кириллица ломается ещё на разборе скрипта.

param([string]$DateArg)

$logPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'upload_log.txt'

function Write-Log($text) {
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Add-Content -Path $logPath -Value "$stamp  $text" -Encoding UTF8
}

function Show-Message($text, $title, $icon) {
    try {
        [System.Windows.Forms.MessageBox]::Show($text, $title, 'OK', $icon) | Out-Null
    } catch {
        Write-Host ""
        Write-Host "$title : $text"
    }
}

# Поле для CSV: в кавычках, внутренние кавычки удваиваются.
function Format-CsvField($value) {
    if ($null -eq $value) { return '""' }
    return '"' + ([string]$value).Replace('"', '""') + '"'
}

try {
    Write-Log "--- выгрузка меню, аргумент: '$DateArg' ---"

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop

    # .NET Framework по умолчанию может брать TLS 1.0, а сервер принимает 1.2.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

    # --- настройки ---------------------------------------------------------
    # Тот же settings.txt, что и у загрузки: адрес и учётные данные одни.
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

    # --- дата --------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($DateArg)) {
        $day = Get-Date
    } else {
        $parsed = [DateTime]::MinValue
        if (-not [DateTime]::TryParseExact($DateArg.Trim(), 'yyyy-MM-dd',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            throw "Дату нужно писать как ГГГГ-ММ-ДД, например 2026-08-19. Получено: '$DateArg'"
        }
        $day = $parsed
    }
    $isoDate = $day.ToString('yyyy-MM-dd')
    $humanDate = $day.ToString('dd.MM.yyyy')
    $server = $settings['server'].TrimEnd('/')
    Write-Log "сервер: $server, логин: $($settings['login']), дата: $isoDate"

    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(180)

    # --- вход --------------------------------------------------------------
    # Меню отдаётся только по пропуску. Без входа запрос сейчас прошёл бы, но
    # попал бы в журнал как "Unauthenticated request" — по этому счётчику
    # смотрят, все ли обновились, и он перестал бы обнуляться.
    $loginJson = @{ login = $settings['login']; password = $settings['password'] } | ConvertTo-Json -Compress
    $loginBody = New-Object System.Net.Http.StringContent($loginJson, [Text.Encoding]::UTF8, 'application/json')
    $loginResp = $client.PostAsync("$server/login", $loginBody).GetAwaiter().GetResult()
    $loginText = $loginResp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    Write-Log "вход $($loginResp.StatusCode)"

    $loginData = $null
    try { $loginData = $loginText | ConvertFrom-Json } catch { }
    if (-not $loginResp.IsSuccessStatusCode -or -not $loginData -or $loginData.message -ne 'Success') {
        throw "Не удалось войти: проверьте логин и пароль в settings.txt."
    }
    $token = $loginData.token
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Сервер не выдал пропуск. Обновите сервер до последней версии."
    }

    # --- запрос меню -------------------------------------------------------
    $request = New-Object System.Net.Http.HttpRequestMessage(
        [System.Net.Http.HttpMethod]::Get, "$server/api/menu?date=$isoDate")
    $request.Headers.Authorization =
        New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $token)
    $menuResp = $client.SendAsync($request).GetAwaiter().GetResult()
    $menuText = $menuResp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $client.Dispose()
    Write-Log "меню $($menuResp.StatusCode): $menuText"

    if (-not $menuResp.IsSuccessStatusCode) {
        throw "Сервер ответил $($menuResp.StatusCode)."
    }
    $menu = $menuText | ConvertFrom-Json
    $items = @($menu.items)

    if ($items.Count -eq 0) {
        Show-Message "На $humanDate меню в приложении не заполнено.$([Environment]::NewLine)$([Environment]::NewLine)Сначала загрузите его через «Загрузить меню»." 'Меню столовой' 'Information'
        Write-Log "меню на $isoDate пустое"
        exit 0
    }

    # --- файл --------------------------------------------------------------
    # Разделитель «;» и запятая в цене — так Excel с русскими настройками
    # раскладывает CSV по столбцам без «Мастера импорта текста».
    $ru = [Globalization.CultureInfo]::GetCultureInfo('ru-RU')
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((@('Раздел', 'Блюдо', 'Порция', 'Цена') | ForEach-Object { Format-CsvField $_ }) -join ';')

    $summary = New-Object System.Collections.Generic.List[string]
    foreach ($group in $items | Group-Object category) {
        foreach ($item in $group.Group) {
            $price = if ($null -eq $item.price) { '' } else { ([double]$item.price).ToString('0.00', $ru) }
            $lines.Add((@($group.Name, $item.name, $item.portion, $price) |
                        ForEach-Object { Format-CsvField $_ }) -join ';')
        }
        $summary.Add("$($group.Name) $($group.Count)")
    }

    $outDir = if ($settings.ContainsKey('export_folder') -and $settings['export_folder'] -ne '' -and (Test-Path $settings['export_folder'])) {
        $settings['export_folder']
    } else {
        $scriptDir
    }
    $outPath = Join-Path $outDir "Меню $isoDate.csv"

    # UTF-8 с BOM: без него Excel читает файл как ANSI и кириллица ломается.
    [System.IO.File]::WriteAllText($outPath, ($lines -join "`r`n") + "`r`n",
        (New-Object System.Text.UTF8Encoding($true)))
    Write-Log "сохранено: $outPath ($($items.Count) блюд)"

    Show-Message ("Выгружено:" + [Environment]::NewLine + [Environment]::NewLine +
        "$humanDate — $($items.Count) блюд ($($summary -join ', '))" + [Environment]::NewLine + [Environment]::NewLine +
        "Файл: $outPath") 'Меню выгружено' 'Information'

    # Открываем в том, чем в системе открываются .csv — обычно Excel.
    try { Start-Process -FilePath $outPath } catch { Write-Log "открыть файл не удалось: $($_.Exception.Message)" }
    exit 0
}
catch {
    $detail = $_.Exception.Message
    Write-Log "ОШИБКА: $detail"
    Write-Log $_.ScriptStackTrace
    Show-Message ("Не удалось выгрузить меню." + [Environment]::NewLine + [Environment]::NewLine + $detail + [Environment]::NewLine + [Environment]::NewLine + "Подробности в файле upload_log.txt") 'Меню столовой' 'Error'
    exit 1
}
