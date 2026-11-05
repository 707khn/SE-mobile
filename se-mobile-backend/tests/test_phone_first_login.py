"""Первый вход с телефона: код с бумажки и сразу код из четырёх цифр.

Свой пароль на телефоне человек придумывал и тут же забывал: дальше он
входит кодом или пальцем. Теперь телефон гасит выданный код сам
(/api/account/code-used), пароля у учётки нет, а задать его можно позже в
«Настройках» — тем, кому нужен вход с компьютера.
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


def test_code_is_spent_and_password_is_not_asked(app, client):
    with app.app_context():
        _make('9401', '4821')
    try:
        body = _login(client, '9401', '4821')
        assert body['message'] == 'Success'
        assert body['must_change_password'] is True
        token = body['token']

        answer = client.post('/api/account/code-used', headers=_auth(token))
        assert answer.status_code == 200
        assert answer.get_json() == {'message': 'Success',
                                     'has_password': False}

        # Пропуск телефона остался годным: человек уже внутри.
        me = client.get('/api/me', headers=_auth(token)).get_json()
        assert me['must_change_password'] is False
        assert me['has_password'] is False

        # А код с бумажки больше не пускает — ни в какой форме.
        assert _login(client, '9401', '4821')['message'] == 'Failure'
        assert _login(client, '9401', '!')['message'] == 'Failure'
        assert _login(client, '9401', '')['message'] == 'Failure'
    finally:
        with app.app_context():
            _drop('9401')


def test_password_is_set_later_without_old_one(app, client):
    with app.app_context():
        _make('9402', '5933')
    try:
        token = _login(client, '9402', '5933')['token']
        client.post('/api/account/code-used', headers=_auth(token))

        answer = client.post('/change-password', headers=_auth(token),
                             json={'old_password': '',
                                   'new_password': 'Цех-2026-ok'})
        assert answer.status_code == 200
        new_token = answer.get_json()['token']

        me = client.get('/api/me', headers=_auth(new_token)).get_json()
        assert me['has_password'] is True
        assert _login(client, '9402', 'Цех-2026-ok')['message'] == 'Success'

        # Пароль появился — дальше без старого его не сменить.
        again = client.post('/change-password', headers=_auth(new_token),
                            json={'old_password': '',
                                  'new_password': 'Другой-2026-ok'})
        assert again.status_code == 403
        assert again.get_json()['error'] == 'wrong_password'
    finally:
        with app.app_context():
            _drop('9402')


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
    """Потерял телефон — администратор выдаёт новый код, как и раньше."""
    with app.app_context():
        _make('9404', '6044')
    try:
        token = _login(client, '9404', '6044')['token']
        client.post('/api/account/code-used', headers=_auth(token))

        admin = _login(client, 'admin', 'test-admin-password')['token']
        reset = client.post('/api/admin/accounts/9404/reset',
                            headers=_auth(admin)).get_json()
        code = reset['temporary_password']
        body = _login(client, '9404', code)
        assert body['message'] == 'Success'
        assert body['must_change_password'] is True

        rows = client.get('/api/admin/accounts', headers=_auth(admin)).get_json()
        row = next(r for r in rows['accounts'] if r['login'] == '9404')
        assert row['has_password'] is True
    finally:
        with app.app_context():
            _drop('9404')
