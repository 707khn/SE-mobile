"""Проходы из отчёта программы турникета.

Отчёт — «Таблица XML 2003» из FastReport с расширением .xls: шапка на
каждой странице, по две строки на проход («Доступ предоставлен» и «Проход»),
ФИО без табельного и без направления. Люди здесь выдуманные.
"""

import gzip
import io
from datetime import date, datetime

import pytest

import app as app_module
from models import db, Employee, AccessRecord, TurnstileEvent
from parser_access_report import parse_access_report

_ADMIN = 'T-ACC-ADM'
_A = 'T-ACC-1'
_B = 'T-ACC-2'
_TWIN1, _TWIN2 = 'T-ACC-3', 'T-ACC-4'

_HEAD = ['ФИО сотрудника', 'Компания', 'Подразделение', 'Дата и время',
         'Событие', 'Зона доступа', 'Дверь', 'Код ключа', '']


def _xml(rows):
    def row(cells):
        return '<Row>' + ''.join(
            f'<Cell><Data ss:Type="String">{c}</Data></Cell>' for c in cells
        ) + '</Row>'
    body = []
    for i, r in enumerate(rows):
        if i % 3 == 0:   # шапка страницы, как в настоящем отчёте
            body += [row(['', 'Проходы ХО/Посетителей']), row(_HEAD)]
        body.append(row(r))
    body.append(row(['', 'Страница 1 из 1']))
    return ('<?xml version="1.0"?>\n<?mso-application progid="Excel.Sheet"?>\n'
            '<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" '
            'xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">'
            '<Worksheet ss:Name="1"><Table>' + ''.join(body) +
            '</Table></Worksheet></Workbook>').encode('utf-8')


def _pass(name, at, door='Турникет 2', event='Проход'):
    return [name, 'АО Тест', 'Отдел испытаний', at, event, '', door, 'C1', '']


def _both(name, at, door='Турникет 2'):
    return [_pass(name, at, door, 'Доступ предоставлен'), _pass(name, at, door)]


@pytest.fixture(autouse=True)
def people(app, monkeypatch, remove_employee):
    monkeypatch.setattr(app_module, '_authenticate',
                        lambda login, password: {'admin': _ADMIN, 'a': _A}.get(login))
    with app.app_context():
        for emp_id, name, job in [
                (_ADMIN, 'Админов Админ Админович', 'Администратор системы'),
                (_A, 'Тестов Тест Тестович', 'Инженер'),
                (_B, 'Пробная Проба Пробовна', 'Инженер'),
                (_TWIN1, 'Двойнов Иван Иванович', 'Инженер'),
                (_TWIN2, 'Двойнов Иван Иванович', 'Слесарь')]:
            db.session.add(Employee(employee_id=remove_employee(emp_id),
                                    full_name=name, job_title=job))
        db.session.commit()
    yield


def _post(client, data, login='admin', dry_run=False, name='Отчет.xls'):
    form = {'login': login, 'password': 'x', 'file': (io.BytesIO(data), name)}
    if dry_run:
        form['dry_run'] = '1'
    return client.post('/api/access/import-report', data=form,
                       content_type='multipart/form-data')


def _records(app, emp_id):
    with app.app_context():
        return [(r.access_date.isoformat(), r.access_time, r.event_type,
                 r.door_location)
                for r in AccessRecord.query.filter_by(employee_id=emp_id)
                .order_by(AccessRecord.access_date, AccessRecord.access_time)]


_REPORT = (
    _both('Тестов Тест Тестович', '01.10.2026 7:47:41')
    + [_pass('Тестов Тест Тестович', '01.10.2026 10:15:00',
             'Техническая библиотека')]
    + _both('Тестов Тест Тестович', '01.10.2026 17:08:18')
    + _both('Пробная Проба Пробовна', '02.10.2026 8:01:00', 'Турникет 1')
    + [_pass('Пробная Проба Пробовна', '02.10.2026 9:00:00', 'Парадный вход',
             'Доступ предоставлен'),
       _pass('Тестов Тест Тестович', '01.10.2026 18:00:00', 'Турникет 2',
             'Запрет доступа')]
    + _both('Двойнов Иван Иванович', '02.10.2026 8:00:00')
    + _both('Незнакомов Некто', '02.10.2026 8:00:00')
)


def test_parser_takes_passes_not_grants_or_refusals():
    passes = parse_access_report(_xml(_REPORT))
    doors = [(p['name'].split()[0], p['at'].strftime('%H:%M'), p['door'])
             for p in passes]
    # «Доступ предоставлен» у турникета — та же минута, что «Проход»: не
    # второй проход. У парадного «Прохода» не бывает — там берём отметку.
    assert ('Тестов', '07:47', 'Турникет 2') in doors
    assert doors.count(('Тестов', '07:47', 'Турникет 2')) == 1
    assert ('Пробная', '09:00', 'Парадный вход') in doors
    assert ('Тестов', '18:00', 'Турникет 2') not in doors
    assert len(passes) == 7


def test_upload_adds_passes_with_directions(app, client):
    r = _post(client, gzip.compress(_xml(_REPORT)), name='Отчет.xls.gz')
    assert r.status_code == 200, r.get_json()
    body = r.get_json()
    # Только турникеты: библиотека и парадный вход не грузятся.
    assert body['added'] == 3
    assert body['skipped_doors'] == ['Парадный вход', 'Техническая библиотека']
    assert body['unmatched_people'] == 2   # тёзки и человек не из приложения
    assert {u['reason'] for u in body['unmatched']} == {'тёзки', 'нет в приложении'}

    assert _records(app, _A) == [
        ('2026-10-01', '07:47', 'Вход', 'Турникет 2'),
        ('2026-10-01', '17:08', 'Выход', 'Турникет 2'),
    ]
    with app.app_context():
        events = [(e.direction, e.timestamp) for e in TurnstileEvent.query
                  .filter_by(employee_id=_A).order_by(TurnstileEvent.timestamp)]
    assert events == [('in', datetime(2026, 10, 1, 7, 47)),
                      ('out', datetime(2026, 10, 1, 17, 8))]
    assert _records(app, _B) == [('2026-10-02', '08:01', 'Вход', 'Турникет 1')]
    assert _records(app, _TWIN1) == [] and _records(app, _TWIN2) == []


def test_repeat_and_continuation_do_not_double_or_restart(app, client):
    morning = _both('Тестов Тест Тестович', '01.10.2026 7:47:41')
    assert _post(client, _xml(morning)).get_json()['added'] == 1
    # Следующая часть отчёта перекрывает первую и продолжает день.
    rest = morning + _both('Тестов Тест Тестович', '01.10.2026 17:08:18')
    body = _post(client, _xml(rest)).get_json()
    assert body['added'] == 1 and body['already_loaded'] == 1
    assert [r[2] for r in _records(app, _A)] == ['Вход', 'Выход']
    with app.app_context():
        assert TurnstileEvent.query.filter_by(employee_id=_A).count() == 2


def test_dry_run_writes_nothing(app, client):
    body = _post(client, _xml(_REPORT), dry_run=True).get_json()
    assert body['added'] == 3
    assert 'Будет добавлено' in body['message']
    assert _records(app, _A) == []


def test_only_admin_uploads(client):
    assert _post(client, _xml(_REPORT), login='a').status_code == 403
    assert _post(client, _xml(_REPORT), login='nobody').status_code == 401


def test_not_a_report(client):
    assert _post(client, b'<?xml version="1.0"?><a/>').status_code == 422
    assert _post(client, b'hello').status_code == 422


def test_other_doors_loaded_earlier_are_removed(app, client):
    """Первая выкладка грузила все двери; следующая загрузка убирает лишнее
    за период отчёта и пересчитывает направления дня."""
    with app.app_context():
        for at, door, event in [('07:47', 'Турникет 2', 'Вход'),
                                ('09:00', 'Парадный вход', 'Выход'),
                                ('10:15', 'считыватель ИТиС', 'Проход'),
                                ('17:08', 'Турникет 2', 'Вход')]:
            db.session.add(AccessRecord(employee_id=_A,
                                        access_date=date(2026, 10, 1),
                                        access_time=at, event_type=event,
                                        door_location=door))
        db.session.add(TurnstileEvent(employee_id=_A, direction='out',
                                      timestamp=datetime(2026, 10, 1, 9, 0)))
        db.session.commit()

    report = (_both('Тестов Тест Тестович', '01.10.2026 7:47:41')
              + [_pass('Тестов Тест Тестович', '01.10.2026 9:00:00',
                       'Парадный вход', 'Доступ предоставлен'),
                 _pass('Тестов Тест Тестович', '01.10.2026 10:15:00',
                       'считыватель ИТиС')]
              + _both('Тестов Тест Тестович', '01.10.2026 17:08:18'))
    body = _post(client, _xml(report)).get_json()
    assert body['removed'] == 2 and body['added'] == 0
    assert _records(app, _A) == [
        ('2026-10-01', '07:47', 'Вход', 'Турникет 2'),
        ('2026-10-01', '17:08', 'Выход', 'Турникет 2'),
    ]
    with app.app_context():
        events = [(e.direction, e.timestamp.strftime('%H:%M')) for e in
                  TurnstileEvent.query.filter_by(employee_id=_A)
                  .order_by(TurnstileEvent.timestamp)]
    assert events == [('in', '07:47'), ('out', '17:08')]
