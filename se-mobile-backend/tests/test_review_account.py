"""Учётная запись для проверяющих Google Play (review_account.py).

Проверяющему нужен вход, но не чужая зарплата. Здесь проверяется, что
вымышленный сотрудник заводится и под ним действительно можно войти и
увидеть листки, что повторный запуск не плодит дублей, что --remove
убирает всё — и что экран «Свежесть данных» от этого не врёт.
"""

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


def test_reviewer_can_log_in_and_see_a_payslip(app, client, capsys):
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
