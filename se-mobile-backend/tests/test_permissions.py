"""Кто чьи проходы видит.

Заместитель Генерального директора по экономике и финансам смотрит всё
предприятие, кроме Генерального директора и заместителя по производству.
Общее правило (начальник видит своё подразделение) ему не подходит: его
подразделение — «Руководство», то есть ровно те, кого смотреть не нужно.
"""

from datetime import datetime

import pytest
from flask import g

import app as app_module
from models import db, Employee, TurnstileEvent

_FINANCE = 'D003'      # Шаяхметов, зам. по экономике и финансам
_CEO = 'D001'          # Асқаров, Генеральный директор
_PRODUCTION = 'D002'   # Мусипов, зам. по производству
_ORDINARY = '001'      # Сарсекенов, техник-программист


@pytest.fixture
def as_finance(app):
    """Запрос от имени заместителя по экономике и финансам."""
    with app.test_request_context():
        g.employee = db.session.get(Employee, _FINANCE)
        assert g.employee is not None, 'сидер справочника не отработал'
        yield g.employee


def test_titles_are_compared_whole(app):
    """«Генеральный директор» — подстрока должности его заместителя."""
    norm = app_module._norm_title
    assert norm('Генеральный директор') != norm(
        'Заместитель Генерального директора по экономике и финансам')
    assert norm(' генеральный  ДИРЕКТОР ') == 'генеральный директор'


def test_finance_sees_an_ordinary_employee(as_finance):
    assert app_module._may_view(_ORDINARY)


def test_finance_does_not_see_the_two_directors(as_finance):
    assert not app_module._may_view(_CEO)
    assert not app_module._may_view(_PRODUCTION)


def test_finance_sees_himself(as_finance):
    assert app_module._may_view(_FINANCE)


def test_department_rule_is_untouched(app):
    """Начальник отдела как видел своё подразделение, так и видит."""
    with app.test_request_context():
        g.employee = db.session.get(Employee, '0000001465')   # начальник ОИТиС
        assert g.employee.department != 'Руководство'
        assert app_module._may_view('001')        # её отдел
        assert not app_module._may_view(_CEO)     # чужой


def _token_for(login, password):
    employee_id = app_module._authenticate(login, password)
    assert employee_id, f'учётная запись {login} не заводилась'
    return app_module._issue_token(employee_id)


def test_attendance_hides_the_two_directors(app, client):
    """Спрятать в отчёте, но показать в табеле — значит не спрятать."""
    day = datetime(2031, 3, 4, 8, 0)
    with app.app_context():
        for employee_id in (_CEO, _PRODUCTION, _ORDINARY):
            db.session.add(TurnstileEvent(employee_id=employee_id,
                                          direction='in', timestamp=day))
        db.session.commit()
        token = _token_for('2222', '2222')

    response = client.get('/api/attendance?date=2031-03-04',
                          headers={'Authorization': f'Bearer {token}'})
    assert response.status_code == 200
    seen = {e['employee_id'] for e in response.get_json()['events']}
    assert seen == {_ORDINARY}

    summary = client.get('/api/attendance/summary?month=2031-03',
                         headers={'Authorization': f'Bearer {token}'})
    listed = {emp['full_name']
              for day_row in summary.get_json()['days']
              for emp in day_row['employees']}
    with app.app_context():
        assert db.session.get(Employee, _CEO).full_name not in listed


def test_admin_still_sees_everyone(app, client):
    with app.app_context():
        token = _token_for('admin', 'admin')
    response = client.get('/api/attendance?date=2031-03-04',
                          headers={'Authorization': f'Bearer {token}'})
    seen = {e['employee_id'] for e in response.get_json()['events']}
    assert {_CEO, _PRODUCTION, _ORDINARY} <= seen
