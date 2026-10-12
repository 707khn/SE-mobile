"""Старый пароль при смене нельзя перебирать без конца.

Вход закрывается после пяти неудач подряд, а смена пароля — нет: с чужого
телефона, оставленного открытым, старый пароль можно было подбирать сколько
угодно, а подобрав — сменить и забрать учётную запись насовсем. Теперь у
смены тот же замок и тот же счётчик, что у входа.
"""

import pytest
from werkzeug.security import generate_password_hash

import app as app_module
from models import db, Employee, UserAccount

_ID = 'LCK00001'
_LOGIN = 'zamkov'
_PASSWORD = 'старая-длинная-фраза'


@pytest.fixture
def owner(app, remove_employee):
    with app.app_context():
        remove_employee(_ID)
        UserAccount.query.filter_by(login=_LOGIN).delete()
        db.session.add(Employee(employee_id=_ID, full_name='Замков Тест Тестович',
                                job_title='Слесарь'))
        db.session.add(UserAccount(login=_LOGIN, employee_id=_ID,
                                   password_hash=generate_password_hash(_PASSWORD),
                                   must_change_password=False))
        db.session.commit()
        token = app_module._issue_token(_ID)
    yield {'Authorization': f'Bearer {token}'}
    with app.app_context():
        UserAccount.query.filter_by(login=_LOGIN).delete()
        db.session.commit()


def _change(client, headers, old):
    return client.post('/change-password', headers=headers, json={
        'old_password': old, 'new_password': 'новая-длинная-фраза-2026'})


def test_wrong_old_password_locks_after_five(client, owner):
    for _ in range(app_module._LOCK_AFTER):
        answer = _change(client, owner, 'не-тот')
        assert answer.status_code == 403
        assert answer.get_json()['error'] == 'wrong_password'

    # Замок закрыт: даже верный старый пароль не проходит, а человеку
    # сказано, сколько ждать.
    answer = _change(client, owner, _PASSWORD)
    assert answer.status_code == 429
    body = answer.get_json()
    assert body['error'] == 'locked'
    assert body['retry_after'] > 0


def test_lock_is_shared_with_login(client, owner):
    for _ in range(app_module._LOCK_AFTER):
        _change(client, owner, 'не-тот')
    answer = client.post('/login', json={'login': _LOGIN, 'password': _PASSWORD})
    assert answer.status_code == 429
    assert answer.get_json()['error'] == 'locked'


def test_a_mistake_or_two_still_lets_you_change(client, owner):
    for _ in range(app_module._LOCK_AFTER - 1):
        assert _change(client, owner, 'не-тот').status_code == 403
    answer = _change(client, owner, _PASSWORD)
    assert answer.status_code == 200, answer.get_json()
    assert answer.get_json()['message'] == 'Success'
