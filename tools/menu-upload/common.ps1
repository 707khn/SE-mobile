# Общее для upload_menu.ps1 и watch_menu.ps1: отправка файла на сервер так,
# чтобы работало и на Windows 7 со встроенным PowerShell 2.0.
#
# Чего в PowerShell 2.0 нет и чем заменено:
#   System.Net.Http (HttpClient)  -> HttpWebRequest с телом multipart вручную;
#   ConvertFrom-Json              -> регулярное выражение на поле "message";
#   Stream.CopyTo, оператор -in   -> не используются.
#
# TLS 1.2, без которого сервер не пускает, есть только в .NET 4.5 и новее.
# PowerShell 2.0 работает на .NET 2.0, даже если 4.x установлен, поэтому
# Restart-OnNet4 перезапускает скрипт на .NET 4 — через файл настроек среды
# в папке TEMP, без прав администратора.
#
# Файл сохранён в UTF-8 С BOM: Windows PowerShell читает .ps1 без BOM как
# ANSI, и кириллица ломается ещё на разборе скрипта.

# Установленный .NET 4.x: номер выпуска из реестра, 0 — если его нет.
# 378389 — это 4.5, с него появляется TLS 1.2.
function Get-Net4Release {
    try {
        $key = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
        if ($key.Release) { return [int]$key.Release }
        return 1
    } catch {
        return 0
    }
}

# Если скрипт запущен на старом .NET, а новый установлен — запускает его
# заново на новом и возвращает код выхода копии. Иначе возвращает $null, и
# скрипт продолжает работу как есть.
function Restart-OnNet4($scriptPath, $argLine, [switch]$NoWait) {
    if ($PSVersionTable.CLRVersion.Major -ge 4) { return $null }
    if ($env:SE_MOBILE_NET4 -eq '1') { return $null }   # уже пробовали — не зацикливаемся
    if ((Get-Net4Release) -lt 378389) { return $null }

    $configDir = Join-Path $env:TEMP 'se-mobile-net4'
    if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir | Out-Null }
    $config = '<?xml version="1.0" encoding="utf-8"?>' + [Environment]::NewLine +
        '<configuration><startup useLegacyV2RuntimeActivationPolicy="true">' +
        '<supportedRuntime version="v4.0"/><supportedRuntime version="v2.0.50727"/>' +
        '</startup></configuration>'
    [IO.File]::WriteAllText((Join-Path $configDir 'powershell.exe.activation_config'), $config)

    $env:COMPLUS_ApplicationMigrationRuntimeActivationConfigPath = $configDir
    $env:SE_MOBILE_NET4 = '1'

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $fullArgs = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$scriptPath`" $argLine"
    if ($NoWait) {
        Start-Process -FilePath $powershell -ArgumentList $fullArgs -WindowStyle Hidden | Out-Null
        return 0
    }
    $child = Start-Process -FilePath $powershell -ArgumentList $fullArgs -Wait -PassThru -WindowStyle Hidden
    return $child.ExitCode
}

function Enable-Tls12 {
    # 3072 — это Tls12; по имени его нет в .NET 2.0, и там присвоение упадёт.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]3072
        return $true
    } catch {
        return $false
    }
}

function Read-Settings($scriptDir) {
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
    return $settings
}

# Файл целиком, даже если он открыт в Excel: читаем с разрешением чужой записи.
function Read-SharedBytes($path) {
    $stream = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $length = [int]$stream.Length
        $bytes = New-Object byte[] $length
        $offset = 0
        while ($offset -lt $length) {
            $read = $stream.Read($bytes, $offset, $length - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }
        return , $bytes
    } finally {
        $stream.Close()
    }
}

# Поле "message" из ответа сервера, без ConvertFrom-Json. Сервер отдаёт
# кириллицу как \uXXXX — Regex.Unescape это раскрывает.
function Get-ServerMessage($body) {
    if (-not $body) { return '' }
    $m = [regex]::Match($body, '"message"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if ($m.Success) {
        try { return [regex]::Unescape($m.Groups[1].Value) } catch { return $m.Groups[1].Value }
    }
    return $body
}

# Отправляет поля и файл как multipart/form-data.
# Возвращает @{ Ok; Status (0 — до сервера не достучались); Text; Body }.
# Исключение — только когда до сервера не достучались вовсе.
function Send-Form($url, $fields, $filePath, $bytes, $timeoutSeconds) {
    $boundary = '----SEmobile' + [Guid]::NewGuid().ToString('N')
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $buffer = New-Object System.IO.MemoryStream

    $parts = ''
    foreach ($name in $fields.Keys) {
        $parts += "--$boundary`r`nContent-Disposition: form-data; name=`"$name`"`r`n`r`n$($fields[$name])`r`n"
    }
    $fileName = [System.IO.Path]::GetFileName($filePath)
    $parts += "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"$fileName`"`r`n" +
              "Content-Type: application/octet-stream`r`n`r`n"
    $head = $utf8.GetBytes($parts)
    $tail = $utf8.GetBytes("`r`n--$boundary--`r`n")
    $buffer.Write($head, 0, $head.Length)
    $buffer.Write($bytes, 0, $bytes.Length)
    $buffer.Write($tail, 0, $tail.Length)
    $payload = $buffer.ToArray()

    [Net.ServicePointManager]::Expect100Continue = $false
    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.Method = 'POST'
    $request.ContentType = "multipart/form-data; boundary=$boundary"
    $request.ContentLength = $payload.Length
    $request.Timeout = $timeoutSeconds * 1000
    $request.ReadWriteTimeout = $timeoutSeconds * 1000

    $out = $request.GetRequestStream()
    try { $out.Write($payload, 0, $payload.Length) } finally { $out.Close() }

    $response = $null
    try {
        $response = $request.GetResponse()
    } catch {
        # 4xx и 5xx .NET выдаёт исключением; ответ сервера лежит внутри.
        $e = $_.Exception
        while ($e -and -not ($e -is [System.Net.WebException])) { $e = $e.InnerException }
        if ($e -and $e.Response) { $response = $e.Response } else { throw }
    }
    try {
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), $utf8)
        $body = $reader.ReadToEnd()
        $reader.Close()
        $status = [int]$response.StatusCode
    } finally {
        $response.Close()
    }
    return @{
        Ok = ($status -ge 200 -and $status -lt 300)
        Status = $status
        Text = (Get-ServerMessage $body)
        Body = $body
    }
}

# Понятная причина, если до сервера не достучались на старом .NET.
function Get-OldNetHint {
    if ((Get-Net4Release) -ge 378389) { return '' }
    return [Environment]::NewLine + [Environment]::NewLine +
        'На этом компьютере нет .NET Framework 4.5 или новее, а без него Windows ' +
        'не умеет защищённое соединение, которого требует сервер. Нужно установить ' +
        '.NET Framework 4.8 (для этого нужны права администратора).'
}
