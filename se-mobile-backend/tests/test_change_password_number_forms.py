"""Временный пароль при смене принимается в тех же формах, что и на входе.

Вход пускал с «450», когда в хеше «0000000450», а смена пароля сверяла только
набранное как есть. Приложение при обязательной смене подставляет старый
пароль само и поле не показывает — человек видел «Текущий пароль неверен» и
ничего не мог поправить.
"""

import pytest
from werkzeug.security import generate_password_hash

import app as app_module
from models import db, Employee, UserAccount

_ID = '0000009450'
_NEW = 'новая-длинная-фраза-2026'


@pytest.fixture
def account(app, remove_employee):
    def make(must_change, password=_ID):
        with app.app_context():
            remove_employee(_ID)
            UserAccount.query.filter_by(login=_ID).delete()
            db.session.add(Employee(employee_id=_ID,
                                    full_name='Номеров Тест Тестович',
                                    job_title='Слесарь'))
            db.session.add(UserAccount(
                login=_ID, employee_id=_ID,
                password_hash=generate_password_hash(password),
                must_change_password=must_change))
            db.session.commit()
            return {'Authorization': f'Bearer {app_module._issue_token(_ID)}'}
    yield make
    with app.app_context():
        UserAccount.query.filter_by(login=_ID).delete()
        db.session.commit()


def test_short_number_logs_in_and_changes_password(client, account):
    account(must_change=True)
    login = client.post('/login', json={'login': '9450', 'password': '9450'})
    body = login.get_json()
    assert body['message'] == 'Success' and body['must_change_password']

    headers = {'Authorization': f'Bearer {body["token"]}'}
    answer = client.post('/change-password', headers=headers, json={
        'old_password': '9450', 'new_password': _NEW})
    assert answer.status_code == 200, answer.get_json()


def test_number_forms_are_not_accepted_for_a_real_password(client, account):
    # Придуманный человеком пароль сверяется только как есть.
    headers = account(must_change=False, password='12345678')
    answer = client.post('/change-password', headers=headers, json={
        'old_password': '0012345678', 'new_password': _NEW})
    assert answer.status_code == 403
