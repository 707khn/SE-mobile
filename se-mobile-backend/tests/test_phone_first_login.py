"""Первый вход по коду из ОИТиС: везде — свой пароль от восьми символов.

Было: телефон и браузер гасили выданный код (/api/account/code-used), и
своего пароля у учётки не оставалось. Выйдя или сменив телефон, человек
возвращался только по новому коду, а значок на iPhone просил пароль,
которого нет. Теперь код гаснет, только когда придуман свой пароль
(/change-password); /api/account/code-used больше ничего не гасит.
"""

from werkzeug.security import generate_password_hash

import app as app_module
from models import db, AuthToken, Employee, UserAccount


def _make(login, password, must_change=True):
    db.session.add(Employee(employee_id=login.zfill(10),
                            full_name=f'Телефон Тестович {login}',
                            job_title='Слесарь'))
    db.session.add(UserAccount(login=login, employee_id=login.zfill(10),
                               password_hash=generate_password_hash(password),
                               must_change_password=must_change))
    db.session.commit()


def _drop(login):
    AuthToken.query.filter_by(employee_id=login.zfill(10)).delete()
    db.session.delete(db.session.get(UserAccount, login))
    db.session.delete(db.session.get(Employee, login.zfill(10)))
    db.session.commit()


def _login(client, login, password):
    answer = client.post('/login', json={'login': login, 'password': password})
    return answer.get_json()


def _auth(token):
    return {'Authorization': f'Bearer {token}'}


def test_code_is_not_spent_without_own_password(app, client):
    """Приложение прежней версии просит погасить код — сервер отказывает,
    и оно, как при любом отказе, открывает «придумайте пароль»."""
    with app.app_context():
        _make('9401', '48213')
    try:
        body = _login(client, '9401', '48213')
        assert body['message'] == 'Success'
        assert body['must_change_password'] is True
        token = body['token']

        answer = client.post('/api/account/code-used', headers=_auth(token))
        assert answer.status_code == 403
        assert answer.get_json()['error'] == 'password_required'

        me = client.get('/api/me', headers=_auth(token)).get_json()
        assert me['must_change_password'] is True
        assert me['has_password'] is True
        # Код ещё действует: свой пароль не задан.
        assert _login(client, '9401', '48213')['message'] == 'Success'
    finally:
        with app.app_context():
            _drop('9401')


def test_own_password_replaces_the_code(app, client):
    with app.app_context():
        _make('9402', '59331')
    try:
        token = _login(client, '9402', '59331')['token']
        answer = client.post('/change-password', headers=_auth(token),
                             json={'old_password': '59331',
                                   'new_password': 'Цех-2026-ok'})
        assert answer.status_code == 200
        new_token = answer.get_json()['token']

        me = client.get('/api/me', headers=_auth(new_token)).get_json()
        assert me['must_change_password'] is False
        assert me['has_password'] is True
        assert _login(client, '9402', 'Цех-2026-ok')['message'] == 'Success'
        # Код из ОИТиС больше не пускает.
        assert _login(client, '9402', '59331')['message'] == 'Failure'
    finally:
        with app.app_context():
            _drop('9402')


def test_password_rules():
    problem = app_module._password_problem
    assert problem('Abc-123', '9405') == 'too_short'       # семь символов
    assert problem('Abc-1234', '9405') is None             # восемь — можно
    assert problem('48213907', '9405') is None             # и одни цифры
    assert problem('11111111', '9405') == 'too_simple'
    assert problem('12121212', '9405') == 'too_simple'
    assert problem('aaaaaaaa', '9405') == 'too_simple'
    assert problem('12345678', '9405') == 'too_simple'
    assert problem('87654321', '9405') == 'too_simple'
    assert problem('0000009405', '9405') == 'same_as_login'


def test_short_password_is_refused(app, client):
    with app.app_context():
        _make('9406', '70412')
    try:
        token = _login(client, '9406', '70412')['token']
        answer = client.post('/change-password', headers=_auth(token),
                             json={'old_password': '70412',
                                   'new_password': 'Цех-202'})
        assert answer.status_code == 400
        assert answer.get_json()['error'] == 'too_short'
        assert _login(client, '9406', '70412')['message'] == 'Success'
    finally:
        with app.app_context():
            _drop('9406')


def test_who_had_no_password_sets_it_without_old_one(app, client):
    """Кто входил по коду, пока пароль не спрашивали, остался без пароля
    (метка «!»). Задать его в «Настройках» можно без старого."""
    with app.app_context():
        _make('9407', 'не-важно-1', must_change=False)
        token = app_module._issue_token('0000009407')
        db.session.get(UserAccount, '9407').password_hash = '!'
        db.session.commit()
    try:
        answer = client.post('/change-password', headers=_auth(token),
                             json={'old_password': '',
                                   'new_password': 'Цех-2026-ok'})
        assert answer.status_code == 200
        new_token = answer.get_json()['token']
        me = client.get('/api/me', headers=_auth(new_token)).get_json()
        assert me['has_password'] is True
        assert _login(client, '9407', 'Цех-2026-ok')['message'] == 'Success'

        # Пароль появился — дальше без старого его не сменить.
        again = client.post('/change-password', headers=_auth(new_token),
                            json={'old_password': '',
                                  'new_password': 'Другой-2026-ok'})
        assert again.status_code == 403
        assert again.get_json()['error'] == 'wrong_password'
    finally:
        with app.app_context():
            _drop('9407')


def test_own_password_is_never_dropped(app, client):
    """Кто уже придумал пароль, тот его и сохраняет."""
    with app.app_context():
        _make('9403', 'Свой-пароль-1', must_change=False)
    try:
        token = _login(client, '9403', 'Свой-пароль-1')['token']
        answer = client.post('/api/account/code-used', headers=_auth(token))
        assert answer.status_code == 200
        assert answer.get_json()['has_password'] is True
        assert _login(client, '9403', 'Свой-пароль-1')['message'] == 'Success'
    finally:
        with app.app_context():
            _drop('9403')


def test_admin_keeps_password(app, client):
    body = _login(client, 'admin', 'test-admin-password')
    assert body['message'] == 'Success'
    answer = client.post('/api/account/code-used',
                         headers=_auth(body['token']))
    assert answer.status_code == 403
    assert answer.get_json()['error'] == 'password_required'


def test_needs_a_token(client):
    assert client.post('/api/account/code-used').status_code == 401


def test_reset_gives_a_code_again(app, client):
    """Забыл пароль или потерял телефон — администратор выдаёт новый код."""
    with app.app_context():
        _make('9404', 'Свой-пароль-1', must_change=False)
    try:
        admin = _login(client, 'admin', 'test-admin-password')['token']
        reset = client.post('/api/admin/accounts/9404/reset',
                            headers=_auth(admin)).get_json()
        code = reset['temporary_password']
        assert _login(client, '9404', 'Свой-пароль-1')['message'] == 'Failure'
        body = _login(client, '9404', code)
        assert body['message'] == 'Success'
        assert body['must_change_password'] is True
    finally:
        with app.app_context():
            _drop('9404')
