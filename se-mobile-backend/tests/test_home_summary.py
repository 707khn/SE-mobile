"""Сводка для главного экрана: по строке на раздел, одним запросом.

Данные вымышленные. День подменяется на далёкий, чтобы меню и события
турникета из сидеров не попадали в проверку.
"""

from datetime import date, datetime

import pytest

import app as app_module
from models import (db, AccessRecord, Employee, LeaveBalance, MenuDate,
                    MenuItem, Payslip, TurnstileEvent)

_WORKER = 'HOME0001'
_NEIGHBOUR = 'HOME0002'
_DAY = date(2031, 3, 4)


@pytest.fixture
def plant_day(monkeypatch):
    monkeypatch.setattr(app_module, '_plant_today', lambda: _DAY)
    return _DAY


@pytest.fixture
def worker(app, remove_employee):
    with app.app_context():
        for employee_id in (_WORKER, _NEIGHBOUR):
            remove_employee(employee_id)
            db.session.add(Employee(employee_id=employee_id,
                                    full_name='Сводкин Тест Тестович',
                                    job_title='Слесарь'))
        db.session.flush()
        for y, m in ((2031, 1), (2031, 2), (2030, 12)):
            db.session.add(Payslip(employee_id=_WORKER, period_month=m,
                                   period_year=y, period_display='x',
                                   total_accruals=1.0, total_deductions=0.0,
                                   net_pay=1.0))
        db.session.add_all([
            LeaveBalance(employee_id=_WORKER, leave_type='Ежегодный трудовой отпуск',
                         total_days=24, used_days=10, remaining_days=14),
            LeaveBalance(employee_id=_WORKER, leave_type='Экологический отпуск',
                         total_days=12, used_days=0, remaining_days=12),
            AccessRecord(employee_id=_WORKER, access_date=date(2031, 2, 27),
                         access_time='07:51', event_type='Вход',
                         door_location='Проходная'),
            AccessRecord(employee_id=_WORKER, access_date=date(2031, 2, 27),
                         access_time='12:30', event_type='Выход',
                         door_location='Проходная'),
            AccessRecord(employee_id=_WORKER, access_date=date(2031, 2, 27),
                         access_time='17:05', event_type='Выход',
                         door_location='Проходная'),
            AccessRecord(employee_id=_WORKER, access_date=date(2031, 2, 26),
                         access_time='07:40', event_type='Вход',
                         door_location='Проходная'),
        ])
        db.session.commit()
    yield
    with app.app_context():
        menu = MenuDate.query.filter_by(date=_DAY).first()
        if menu is not None:
            db.session.delete(menu)
            db.session.commit()


def _home(client, body=None, token=None):
    headers = {'Authorization': f'Bearer {token}'} if token else {}
    return client.post('/api/home', json=body or {}, headers=headers)


def test_summary_without_events_today_uses_last_loaded_day(client, worker,
                                                            plant_day):
    body = _home(client, {'key_suffix': _WORKER}).get_json()
    assert body['message'] == 'Success'
    assert body['today'] == '2031-03-04'
    assert body['access'] == {'date': '2031-02-27', 'first_in': '07:51',
                              'last_out': '17:05'}
    assert body['payslip'] == {'year': 2031, 'month': 2}
    assert body['leave'] == {'remaining_days': 26}
    assert body['menu'] == {'count': 0, 'dishes': []}


def test_turnstile_today_wins_and_menu_is_today(app, client, worker,
                                                plant_day):
    with app.app_context():
        db.session.add_all([
            TurnstileEvent(employee_id=_WORKER, direction='in',
                           timestamp=datetime(2031, 3, 4, 7, 48)),
            TurnstileEvent(employee_id=_WORKER, direction='in',
                           timestamp=datetime(2031, 3, 4, 13, 2)),
            # Вчерашний поздний проход в сегодняшний день не попадает.
            TurnstileEvent(employee_id=_WORKER, direction='out',
                           timestamp=datetime(2031, 3, 3, 23, 59)),
        ])
        menu = MenuDate(date=_DAY)
        db.session.add(menu)
        db.session.flush()
        for name in ('Борщ', 'Плов', 'Компот', 'Салат'):
            db.session.add(MenuItem(menu_date_id=menu.id, category='Блюда',
                                    name=name))
        db.session.commit()

    body = _home(client, {'key_suffix': _WORKER}).get_json()
    assert body['access'] == {'date': '2031-03-04', 'first_in': '07:48',
                              'last_out': None}
    assert body['menu'] == {'count': 4, 'dishes': ['Борщ', 'Плов', 'Компот']}


def test_nothing_known_is_nulls_not_failure(client, worker, plant_day):
    body = _home(client, {'key_suffix': _NEIGHBOUR}).get_json()
    assert body['message'] == 'Success'
    assert body['access'] is None
    assert body['payslip'] is None
    assert body['leave'] is None


def test_summary_is_for_yourself(app, client, worker, plant_day):
    with app.app_context():
        token = app_module._issue_token(_NEIGHBOUR)
    assert _home(client, {'key_suffix': _WORKER}, token).status_code == 403
    # Без номера — свой.
    mine = _home(client, {}, token).get_json()
    assert mine['message'] == 'Success' and mine['payslip'] is None
