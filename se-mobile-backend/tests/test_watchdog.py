"""Сторож и проверка здоровья.

Двенадцатого сентября приложение отвечало, а база лежала: процесс был на
месте, systemd считал службу исправной, и сбой прожил восемь дней — ровно до
первой жалобы сотрудника. Пятьсот человек всё это время не могли войти.

Отсюда два вывода, оба проверяются здесь: «работает» надо спрашивать запросом
в базу, а не тем, что порт открыт; и увиденное надо где-то записывать, иначе
о перебоях снова будут узнавать со слов.
"""

import os

import app as app_module
from models import db


def test_health_asks_the_database(app, client):
    answer = client.get('/health')
    assert answer.status_code == 200
    assert answer.get_json() == {'status': 'ok', 'database': 'ok'}


def test_health_fails_when_the_database_does(app, client, monkeypatch):
    """Ровно тот случай, который прожил восемь дней.

    Порт открыт, процесс жив, а база не отвечает. Ответ должен быть 503 —
    по нему за дело берётся сторож.
    """
    def _refuse(*args, **kwargs):
        raise RuntimeError('password authentication failed for user "semobile"')

    monkeypatch.setattr(db.session, 'execute', _refuse)
    answer = client.get('/health')
    assert answer.status_code == 503
    body = answer.get_json()
    assert body == {'status': 'fail', 'database': 'unavailable'}
    # Адрес открыт всем: имя пользователя базы наружу не уходит.
    assert 'semobile' not in answer.get_data(as_text=True)


def test_health_needs_no_pass(app, client):
    """Сторож ходит без пропуска — и любой сторонний присмотр тоже."""
    assert client.get('/health').status_code == 200


def test_outages_are_read_newest_first(app, tmp_path, monkeypatch):
    log = tmp_path / 'outages.log'
    log.write_text(
        '2026-09-12T03:10:00+05:00 не отвечает (1 подряд): connection refused\n'
        '2026-09-12T03:12:00+05:00 перезапускаю se-mobile\n'
        '2026-09-20T09:00:00+05:00 восстановился после 5760 неудач подряд\n',
        encoding='utf-8')
    monkeypatch.setattr(app_module, '_WATCHDOG_LOG', str(log))

    state = app_module._outage_state()
    assert state['available'] and state['total'] == 3
    assert state['entries'][0]['at'].startswith('2026-09-20')
    assert 'восстановился' in state['entries'][0]['what']


def test_no_log_means_no_outages_not_an_error(app, tmp_path, monkeypatch):
    """Журнала нет — сервер просто не падал с тех пор, как его завели.

    Отличать это от «не смог прочитать» важно: второе значит, что сторож не
    работает, и молчать об этом нельзя.
    """
    monkeypatch.setattr(app_module, '_WATCHDOG_LOG', str(tmp_path / 'нет-такого'))
    empty = app_module._outage_state()
    assert empty['available'] is True and empty['entries'] == []

    # А вот папка вместо файла — это уже неисправность, и она называется.
    monkeypatch.setattr(app_module, '_WATCHDOG_LOG', str(tmp_path))
    broken = app_module._outage_state()
    assert broken['available'] is False and broken['reason']


def _run_watchdog(tmp_path, https_ok):
    """Сторож с подменённым curl: приложение живо, HTTPS — как скажем."""
    import subprocess
    import stat

    fake = tmp_path / 'bin'
    fake.mkdir(exist_ok=True)
    curl = fake / 'curl'
    curl.write_text(
        '#!/bin/bash\n'
        'case "$*" in\n'
        f'  *--resolve*) {"echo ok" if https_ok else "echo refused >&2; exit 7"} ;;\n'
        '  *) echo \'{"status":"ok"}\' ;;\n'
        'esac\n', encoding='utf-8')
    curl.chmod(curl.stat().st_mode | stat.S_IEXEC)
    script = os.path.join(os.path.dirname(__file__), '..', '..', 'deploy',
                          'watchdog.sh')
    env = dict(os.environ, PATH=f'{fake}:{os.environ["PATH"]}',
               WATCHDOG_STATE_DIR=str(tmp_path / 'state'))
    return subprocess.run(['bash', script], env=env, capture_output=True,
                          text=True, timeout=30)


def test_watchdog_notices_https_gone_while_the_app_is_alive(tmp_path):
    """26 сентября: приложение отвечало, а секция 443 пропала из nginx.

    Сторож спрашивал только 127.0.0.1:8000 и был доволен, а все телефоны
    видели «Ошибка подключения к серверу». Теперь это попадает в журнал —
    один раз при поломке и один раз при починке, а не каждые две минуты.
    """
    log = tmp_path / 'state' / 'outages.log'

    assert _run_watchdog(tmp_path, https_ok=False).returncode == 0
    assert _run_watchdog(tmp_path, https_ok=False).returncode == 0
    lines = log.read_text(encoding='utf-8').splitlines()
    assert len(lines) == 1 and 'не отвечает' in lines[0] and 'refused' in lines[0]

    _run_watchdog(tmp_path, https_ok=True)
    _run_watchdog(tmp_path, https_ok=True)
    lines = log.read_text(encoding='utf-8').splitlines()
    assert len(lines) == 2 and 'снова отвечает' in lines[1]
