# Загрузка проходов через турникет в приложение SE-mobile.
#
# Запускается через "Загрузить проходы.bat" — перетаскиванием отчёта на
# ярлык либо двойным щелчком (тогда откроется окно выбора файла).
#
# Отчёт берётся из программы турникета: «Проходы ХО/Посетителей» за нужный
# период, сохранённый в Excel (.xls). Можно за любой период и с
# перекрытием: уже загруженные проходы второй раз не лягут.
#
# Файл сохранён в UTF-8 С BOM: Windows PowerShell 5.1 читает .ps1 без BOM
# как ANSI, и кириллица ломается ещё на разборе скрипта.
#
# Разбор отчёта делает сервер. Здесь файл только сжимается: отчёт за
# полтора месяца весит 50 МБ, сжатый — меньше одного, и отправляется
# быстро даже по медленной связи.

param([string]$FilePath)

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

# GZipStream есть и в .NET 2.0 — сжимаем без сторонних программ.
function Compress-Bytes($bytes) {
    $out = New-Object System.IO.MemoryStream
    $gzip = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionMode]::Compress)
    $gzip.Write($bytes, 0, $bytes.Length)
    $gzip.Close()
    return , $out.ToArray()
}

try {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    . (Join-Path $scriptDir 'common.ps1')

    $argLine = ''
    if ($FilePath) { $argLine = "-FilePath `"$FilePath`"" }
    $code = Restart-OnNet4 $MyInvocation.MyCommand.Path $argLine
    if ($code -ne $null) { exit $code }

    Write-Log "--- запуск, аргумент: '$FilePath', PowerShell $($PSVersionTable.PSVersion), .NET $($PSVersionTable.CLRVersion) ---"

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    if (-not (Enable-Tls12)) { Write-Log 'TLS 1.2 недоступен на этом .NET' }

    $settings = Read-Settings $scriptDir
    Write-Log "сервер: $($settings['server']), логин: $($settings['login'])"

    if (-not $FilePath -or $FilePath.Trim() -eq '') {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Выберите отчёт по проходам'
        $dialog.Filter = 'Отчёт Excel (*.xls;*.xlsx;*.xml)|*.xls;*.xlsx;*.xml'
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

    $bytes = Read-SharedBytes $FilePath
    $packed = Compress-Bytes $bytes
    Write-Log "размер: $($bytes.Length) байт, сжатый: $($packed.Length)"

    $url = $settings['server'].TrimEnd('/') + '/api/access/import-report'
    $fields = @{ login = $settings['login']; password = $settings['password'] }
    $sendName = [System.IO.Path]::GetFileName($FilePath) + '.gz'
    Write-Log "отправка на $url ..."
    try {
        $r = Send-Form $url $fields $sendName $packed 300
    } catch {
        $hint = Get-OldNetHint
        if ($hint) { throw ($_.Exception.Message + $hint) }
        throw
    }
    Write-Log "ответ $($r.Status): $($r.Text)"

    if ($r.Ok) {
        Show-Message $r.Text 'Проходы загружены' 'Information'
        exit 0
    }
    throw $r.Text
}
catch {
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
    Show-Message ("Не удалось загрузить проходы." + [Environment]::NewLine + [Environment]::NewLine + $detail + [Environment]::NewLine + [Environment]::NewLine + "Подробности в файле upload_log.txt") 'Проходы' 'Error'
    exit 1
}
