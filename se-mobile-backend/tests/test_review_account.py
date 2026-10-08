"""Учётная запись для проверяющих Google Play (review_account.py).

Проверяющему нужен вход, но не чужая зарплата. Здесь проверяется, что
вымышленный сотрудник заводится и под ним действительно можно войти и
увидеть листки, что повторный запуск не плодит дублей, что --remove
убирает всё — и что экран «Свежесть данных» от этого не врёт.
"""

import pytest

import app as app_module
import review_account
from models import AccessRecord, Payslip, UserAccount, db


def _password(output):
    for line in output.splitlines():
        if 'пароль:' in line:
            return line.split('пароль:')[1].strip()
    raise AssertionError(output)


def _freshness(app):
    with app.app_context():
        return {s['key']: (s.get('last'), s.get('rows'))
                for s in app_module._data_freshness()}


_STAFF = 'REV00001'


@pytest.fixture
def plant_data(app, remove_employee):
    """Чьи-то листки и проходы, как на живой базе.

    Проверяющий подстраивается под них: его листки — в последних трёх
    месяцах, за которые листки есть, проходы — кончая последним днём
    выгрузки. В исходниках своих листков больше нет, и без этой записи
    база пуста, а «свежесть» сдвигать было бы не с чего.
    """
    from datetime import date
    from models import Employee
    with app.app_context():
        remove_employee(_STAFF)
        db.session.add(Employee(employee_id=_STAFF,
                                full_name='Живой Тест Тестович',
                                job_title='Слесарь'))
        db.session.add(Payslip(employee_id=_STAFF, period_month=7,
                               period_year=2026, period_display='Июль 2026',
                               total_accruals=1.0, total_deductions=0.0,
                               net_pay=1.0))
        db.session.add(AccessRecord(employee_id=_STAFF,
                                    access_date=date(2026, 8, 20),
                                    access_time='08:00', event_type='Вход',
                                    door_location='Проходная'))
        db.session.commit()
    yield


def test_reviewer_can_log_in_and_see_a_payslip(app, client, capsys,
                                               plant_data):
    before = _freshness(app)
    try:
        assert review_account.main([], application=app) == 0
        password = _password(capsys.readouterr().out)

        answer = client.post('/login', json={'login': 'review',
                                             'password': password}).get_json()
        assert answer['message'] == 'Success'
        assert answer['full_name'] == review_account.FULL_NAME
        # Без обязательной смены пароля: проверяющий её не пройдёт.
        assert answer['must_change_password'] is False

        headers = {'Authorization': f"Bearer {answer['token']}"}
        periods = client.post('/payslip/periods', json={},
                              headers=headers).get_json()
        assert periods['message'] == 'Success' and len(periods['periods']) == 3

        # Последний загруженный день и последний месяц листков не сдвинулись.
        after = _freshness(app)
        for key in ('payslips', 'access'):
            assert after[key][0] == before[key][0], key

        # Повторный запуск — новый пароль, но не вторая порция данных.
        assert review_account.main([], application=app) == 0
        assert _password(capsys.readouterr().out) != password
        with app.app_context():
            assert Payslip.query.filter_by(
                employee_id=review_account.EMPLOYEE_ID).count() == 3
            assert AccessRecord.query.filter_by(
                employee_id=review_account.EMPLOYEE_ID).count() == 30
    finally:
        assert review_account.main(['--remove'], application=app) == 0

    with app.app_context():
        assert db.session.get(UserAccount, 'review') is None
        assert Payslip.query.filter_by(
            employee_id=review_account.EMPLOYEE_ID).count() == 0
    assert _freshness(app) == before


def test_does_not_take_over_a_real_login(app, capsys):
    """Логин «review» у настоящего сотрудника — не трогаем ничего."""
    from models import Employee
    from werkzeug.security import generate_password_hash
    with app.app_context():
        someone = Employee.query.filter(
            Employee.employee_id != review_account.EMPLOYEE_ID).first()
        db.session.add(UserAccount(login='review',
                                   employee_id=someone.employee_id,
                                   password_hash=generate_password_hash('x')))
        db.session.commit()
    try:
        assert review_account.main([], application=app) == 1
        assert 'уже занят' in capsys.readouterr().err
    finally:
        with app.app_context():
            db.session.delete(db.session.get(UserAccount, 'review'))
            db.session.commit()
