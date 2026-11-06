# Включает и выключает автозагрузку справочника (watch_directory.ps1).
#
# Включение кладёт ярлык в личную папку «Автозагрузка» пользователя — так
# слежение стартует при каждом входе в Windows. Прав администратора не
# нужно: это та же папка, куда программы кладут себя «запускаться вместе
# с Windows». Планировщик заданий для входа в систему их как раз требует.
#
# Файл сохранён в UTF-8 С BOM: Windows PowerShell читает .ps1 без BOM
# как ANSI, и кириллица ломается ещё на разборе скрипта.

param([switch]$Enable, [switch]$Disable)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logPath = Join-Path $scriptDir 'upload_log.txt'
$watchScript = Join-Path $scriptDir 'watch_directory.ps1'
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Автозагрузка справочника.lnk'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$watchArgs = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchScript`""

function Write-Log($text) {
    try {
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -Path $logPath -Value "$stamp  [автозагрузка] $text" -Encoding UTF8
    } catch { }
}

function Show-Message($text, $icon) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show($text, 'Справочник', 'OK', $icon) | Out-Null
    } catch {
        Write-Host $text
    }
}

function Stop-Watcher {
    # Только свои процессы: чужие сеансы на этом компьютере не трогаем.
    $mine = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    # Get-WmiObject, а не Get-CimInstance: того нет в PowerShell 2.0 (Windows 7).
    Get-WmiObject Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*watch_directory.ps1*' -and $_.SessionId -eq $mine } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Log "остановлено слежение, процесс $($_.ProcessId)"
        }
}

try {
    if ($Enable) {
        if (-not (Test-Path $watchScript)) { throw "Рядом нет файла watch_directory.ps1." }
        if (-not (Test-Path (Join-Path $scriptDir 'common.ps1'))) { throw "Рядом нет файла common.ps1." }
        $settingsPath = Join-Path $scriptDir 'settings.txt'
        if (-not (Test-Path $settingsPath)) { throw "Рядом нет файла settings.txt." }

        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $powershell
        $shortcut.Arguments = $watchArgs
        $shortcut.WorkingDirectory = $scriptDir
        $shortcut.WindowStyle = 7
        $shortcut.Description = 'Загружает новый справочник предприятия в приложение SE-mobile'
        $shortcut.Save()
        Write-Log "ярлык создан: $shortcutPath"

        # Перезапуск — чтобы после обновления скрипта работала новая версия.
        Stop-Watcher
        Start-Sleep -Seconds 1
        Start-Process -FilePath $powershell -ArgumentList ($watchArgs + ' -Announce') -WindowStyle Hidden -WorkingDirectory $scriptDir
        Write-Log 'слежение запущено'

        Show-Message ("Автозагрузка справочника включена." + [Environment]::NewLine + [Environment]::NewLine +
            "Теперь достаточно сохранить новый справочник в Excel (.xlsx) на рабочий стол, " +
            "в «Документы» или в «Загрузки». Через несколько секунд программа покажет, кто " +
            "появился и кто пропал, и спросит, загружать ли справочник в приложение." +
            [Environment]::NewLine + [Environment]::NewLine +
            "Слежение запускается само при каждом входе в Windows.") 'Information'
        exit 0
    }

    if ($Disable) {
        if (Test-Path -LiteralPath $shortcutPath) {
            Remove-Item -LiteralPath $shortcutPath -Force
            Write-Log "ярлык удалён: $shortcutPath"
        }
        Stop-Watcher
        Show-Message ("Автозагрузка справочника выключена." + [Environment]::NewLine + [Environment]::NewLine +
            "Загружать справочник можно, как раньше: перетащите файл на «Загрузить справочник».") 'Information'
        exit 0
    }

    throw 'Запустите с ключом -Enable или -Disable.'
}
catch {
    Write-Log "ОШИБКА: $($_.Exception.Message)"
    Show-Message ("Не получилось: " + $_.Exception.Message) 'Error'
    exit 1
}
