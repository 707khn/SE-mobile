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
        raise RuntimeError('база не отвечает')

    monkeypatch.setattr(db.session, 'execute', _refuse)
    answer = client.get('/health')
    assert answer.status_code == 503
    body = answer.get_json()
    assert body['status'] == 'fail' and 'не отвечает' in body['database']


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
