"""Сборка лежит на сервере, и приложение само о ней говорит.

Приложение раздаётся руками: apk отправляют в переписке, ставит его тот, кто
дошёл. Из-за этого обязательную проверку пропуска (REQUIRE_AUTH=1) нельзя
включить — у необновившихся всё перестанет работать, — а обновиться им было
неоткуда.
"""

import os

import app as app_module


def _put(directory, name, size=16):
    path = os.path.join(str(directory), name)
    with open(path, 'wb') as f:
        f.write(b'x' * size)
    return path


def test_the_version_comes_from_the_file_name(app, client, tmp_path, monkeypatch):
    """Номер версии нигде не повторяется — он едет вместе с файлом.

    Отдельный файл с номером пришлось бы обновлять руками, а всякий номер,
    который надо где-то повторить, рано или поздно отстаёт.
    """
    monkeypatch.setattr(app_module, '_APK_DIR', str(tmp_path))
    _put(tmp_path, 'se-mobile-1.8.2+12.apk', size=1024)

    body = client.get('/api/app/latest').get_json()
    assert body['message'] == 'Success'
    latest = body['app']
    assert latest['available'] is True
    assert latest['version'] == '1.8.2' and latest['build'] == 12
    assert latest['url'].endswith('/app/se-mobile-1.8.2+12.apk')
    assert latest['size'] == 1024

    # Схема — та, по которой пришли снаружи. До gunicorn запрос доходит по
    # http всегда, и без этого заголовка ссылка на скачивание уходила бы без
    # шифрования даже тому, кто открыл приложение по https.
    secure = client.get('/api/app/latest', headers={
        'X-Forwarded-Proto': 'https',
        'X-Forwarded-Host': 'api.se-btrz.com',
    }).get_json()['app']
    assert secure['url'] == 'https://api.se-btrz.com/app/se-mobile-1.8.2+12.apk'


def test_the_newest_build_wins_not_the_newest_name(app, client, tmp_path, monkeypatch):
    """Выбираем по номеру сборки: только его смотрит Android.

    Версия 1.9.0 с меньшим номером сборки поверх 1.8.2 не встанет,
    поэтому «самый большой номер версии» — неверный ответ.
    """
    monkeypatch.setattr(app_module, '_APK_DIR', str(tmp_path))
    _put(tmp_path, 'se-mobile-1.8.0+10.apk')
    _put(tmp_path, 'se-mobile-1.8.2+12.apk')
    _put(tmp_path, 'se-mobile-1.8.1+11.apk')

    latest = client.get('/api/app/latest').get_json()['app']
    assert latest['build'] == 12 and latest['version'] == '1.8.2'


def test_nothing_on_the_server_is_said_plainly(app, client, tmp_path, monkeypatch):
    """Пустая папка — не ошибка, но и не молчание.

    Приложение в этом случае ничего не показывает, а администратор видит
    причину на экране «Обновление»: иначе «никто не обновляется» выглядело бы
    загадкой.
    """
    monkeypatch.setattr(app_module, '_APK_DIR', str(tmp_path))
    empty = client.get('/api/app/latest').get_json()['app']
    assert empty['available'] is False and empty['reason']

    # Посторонние файлы в папке за сборку не считаются.
    _put(tmp_path, 'app-release.apk')
    _put(tmp_path, 'se-mobile.apk')
    still = client.get('/api/app/latest').get_json()['app']
    assert still['available'] is False

    monkeypatch.setattr(app_module, '_APK_DIR', str(tmp_path / 'нет-такой'))
    missing = client.get('/api/app/latest').get_json()['app']
    assert missing['available'] is False and missing['reason']


def test_asking_about_the_build_needs_no_pass(app, client, tmp_path, monkeypatch):
    """Без пропуска: спросить про обновление нужнее всего тогда, когда
    пропуска уже нет — например, когда старая сборка перестала работать."""
    monkeypatch.setattr(app_module, '_APK_DIR', str(tmp_path))
    _put(tmp_path, 'se-mobile-2.0.0+20.apk')
    answer = client.get('/api/app/latest')
    assert answer.status_code == 200
    assert answer.get_json()['app']['build'] == 20


def test_the_windows_archive_is_offered_separately(app, client, tmp_path, monkeypatch):
    """Версия для компьютера лежит рядом с APK, но телефону её не предлагают,
    а компьютеру — APK."""
    monkeypatch.setattr(app_module, '_APK_DIR', str(tmp_path))
    _put(tmp_path, 'se-mobile-1.26.0+66.apk')
    _put(tmp_path, 'SemEng-windows-1.25.0+65.zip')
    _put(tmp_path, 'SemEng-windows-1.26.0+66.zip', size=2048)

    body = client.get('/api/app/latest').get_json()
    assert body['app']['file'] == 'se-mobile-1.26.0+66.apk'
    windows = body['windows']
    assert windows['available'] is True
    assert windows['build'] == 66 and windows['version'] == '1.26.0'
    assert windows['url'].endswith('/app/SemEng-windows-1.26.0+66.zip')
    assert windows['size'] == 2048


def test_no_windows_archive_is_said_plainly(app, client, tmp_path, monkeypatch):
    monkeypatch.setattr(app_module, '_APK_DIR', str(tmp_path))
    _put(tmp_path, 'se-mobile-1.26.0+66.apk')
    windows = client.get('/api/app/latest').get_json()['windows']
    assert windows['available'] is False and 'SemEng-windows' in windows['reason']
