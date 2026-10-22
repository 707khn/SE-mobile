"""Итоги месяца по своим проходам: /report/month.

Раньше у человека был только список проходов, а сколько дней он был на
работе, во сколько приходил и были ли опоздания, считать приходилось самому.
"""
import json
from datetime import date, datetime

import pytest

import app as app_module
from models import db, AccessRecord, Employee, TurnstileEvent

_WORKER = 'MON00001'


def _post(client, body):
    return client.post('/report/month', data=json.dumps(body),
                       content_type='application/json')


@pytest.fixture
def worker(app, remove_employee):
    with app.app_context():
        remove_employee(_WORKER)
        db.session.add(Employee(employee_id=_WORKER,
                                full_name='Итогов Тест Тестович',
                                job_title='Инженер'))
        db.session.flush()
        # Март 2025: 3-е — понедельник.
        for day, time, event in (
                (3, '07:50', 'Вход'), (3, '12:00', 'Выход'),
                (3, '12:40', 'Вход'), (3, '17:10', 'Выход'),
                (4, '08:20', 'Проход'), (4, '17:00', 'Выход'),   # опоздал
                (5, '08:00', 'Вход'),                            # ровно — не опоздание
                (8, '10:30', 'Вход'), (8, '13:00', 'Выход'),     # суббота
                (6, '17:30', 'Выход')):                          # один уход
            db.session.add(AccessRecord(
                employee_id=_WORKER, access_date=date(2025, 3, day),
                access_time=time, event_type=event,
                door_location='Проходная'))
        # Апрель ещё не выгружен — день есть только в событиях турникета.
        db.session.add(TurnstileEvent(employee_id=_WORKER, direction='in',
                                      timestamp=datetime(2025, 4, 1, 8, 15)))
        db.session.add(TurnstileEvent(employee_id=_WORKER, direction='out',
                                      timestamp=datetime(2025, 4, 1, 17, 0)))
        # День из выгрузки главнее турникета: этот приход не считается.
        db.session.add(TurnstileEvent(employee_id=_WORKER, direction='in',
                                      timestamp=datetime(2025, 3, 3, 9, 30)))
        db.session.commit()
    yield _WORKER
    with app.app_context():
        app_module._access_loaded_until['checked_at'] = None


def test_month_totals(client, worker):
    body = _post(client, {'key_suffix': worker, 'month': '2025-03'}).get_json()
    assert body['message'] == 'Success'
    assert body['month'] == '2025-03'
    assert body['work_start'] == '08:00'
    assert body['days_present'] == 5
    assert body['weekend_days'] == 1
    assert body['late_count'] == 1
    # (07:50 + 08:20 + 08:00 + 10:30) / 4 = 08:40
    assert body['avg_arrival'] == '08:40'
    # (17:10 + 17:00 + 13:00 + 17:30) / 4 = 16:10
    assert body['avg_departure'] == '16:10'
    late = [d['date'] for d in body['days'] if d['late']]
    assert late == ['2025-03-04']
    first = body['days'][0]
    assert first == {'date': '2025-03-03', 'first_in': '07:50',
                     'last_out': '17:10', 'late': False, 'weekend': False}
    assert body['first_month'] == '2025-03'
    assert body['coverage']['employee_has_any'] is True


def test_live_events_fill_the_month_before_upload(client, worker):
    body = _post(client, {'key_suffix': worker, 'month': '2025-04'}).get_json()
    assert body['days_present'] == 1
    assert body['late_count'] == 1
    assert body['days'][0]['first_in'] == '08:15'


def test_empty_month_is_not_an_error(client, worker):
    body = _post(client, {'key_suffix': worker, 'month': '2025-07'}).get_json()
    assert body['message'] == 'Success'
    assert body['days_present'] == 0
    assert body['avg_arrival'] is None
    assert body['days'] == []


def test_work_start_comes_from_settings(client, worker, monkeypatch):
    monkeypatch.setenv('WORK_DAY_START', '08:30')
    body = _post(client, {'key_suffix': worker, 'month': '2025-03'}).get_json()
    assert body['work_start'] == '08:30'
    assert body['late_count'] == 0


def test_bad_work_start_falls_back(client, worker, monkeypatch):
    monkeypatch.setenv('WORK_DAY_START', 'утро')
    body = _post(client, {'key_suffix': worker, 'month': '2025-03'}).get_json()
    assert body['work_start'] == '08:00'


@pytest.mark.parametrize('month', ['2025-13', '2025-00', '2025-3', 'март', 123])
def test_bad_month(client, worker, month):
    answer = _post(client, {'key_suffix': worker, 'month': month})
    assert answer.status_code == 400
    assert answer.get_json()['error'] == 'bad_period'


def test_month_defaults_to_current(client, worker):
    body = _post(client, {'key_suffix': worker}).get_json()
    assert body['month'] == app_module._plant_today().strftime('%Y-%m')


def test_someone_elses_month_is_denied(app, client, worker):
    """Рядовой сотрудник видит итоги только свои — как и сами проходы."""
    with app.app_context():
        token = app_module._issue_token('0000002114')   # техник-программист
    answer = client.post('/report/month',
                         data=json.dumps({'key_suffix': worker,
                                          'month': '2025-03'}),
                         content_type='application/json',
                         headers={'Authorization': f'Bearer {token}'})
    assert answer.status_code == 403
