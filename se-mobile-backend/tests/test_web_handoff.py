"""Вход из Safari — значку на экране «Домой» (web_handoff.py)."""

from werkzeug.security import generate_password_hash

import web_handoff
from models import db, AuthToken, Employee, UserAccount, WebHandoff

# Кука Secure: тестовый клиент шлёт её только по https.
HTTPS = 'https://api.se-btrz.com'


def _make(login, must_change=False):
    db.session.add(Employee(employee_id=login.zfill(10),
                            full_name=f'Значок Тестович {login}',
                            job_title='Слесарь'))
    db.session.add(UserAccount(login=login, employee_id=login.zfill(10),
                               password_hash=generate_password_hash('Цех-2026-ok'),
                               must_change_password=must_change))
    db.session.commit()


def _drop(*logins):
    for login in logins:
        employee_id = login.zfill(10)
        keys = [row.token for row in
                AuthToken.query.filter_by(employee_id=employee_id)]
        if keys:
            WebHandoff.query.filter(WebHandoff.source_token.in_(keys)).delete(
                synchronize_session=False)
        AuthToken.query.filter_by(employee_id=employee_id).delete()
        db.session.delete(db.session.get(UserAccount, login))
        db.session.delete(db.session.get(Employee, employee_id))
    db.session.commit()


def _client(app):
    """Своя банка куки на каждую проверку: и вкладка, и значок."""
    return app.test_client()


def _token(client, login):
    body = client.post(f'{HTTPS}/login', json={
        'login': login, 'password': 'Цех-2026-ok'}).get_json()
    assert body['message'] == 'Success'
    return body['token']


def _auth(token):
    return {'Authorization': f'Bearer {token}'}


def _offer(client, token):
    answer = client.post(f'{HTTPS}/api/web-handoff', headers=_auth(token))
    assert answer.status_code == 200
    cookie = client.get_cookie(web_handoff.COOKIE, domain='api.se-btrz.com',
                               path=web_handoff.COOKIE_PATH)
    assert cookie is not None
    assert cookie.http_only and cookie.secure
    return cookie.value


def _icon(app, secret):
    """Значок: свой клиент, в котором только скопированная кука."""
    icon = _client(app)
    icon.set_cookie(web_handoff.COOKIE, secret, domain='api.se-btrz.com',
                    path=web_handoff.COOKIE_PATH)
    return icon


def _claim(client):
    return client.post(f'{HTTPS}/api/web-handoff/claim').get_json()


def test_icon_gets_own_working_token_once(app):
    with app.app_context():
        _make('9601')
    try:
        tab = _client(app)
        safari = _token(tab, '9601')
        secret = _offer(tab, safari)

        icon = _icon(app, secret)
        body = _claim(icon)
        assert body['status'] == 'approved'
        assert body['login'] == '9601'
        assert body['employee_id'] == '0000009601'
        assert body['full_name'] == 'Значок Тестович 9601'
        assert body['must_change_password'] is False
        own = body['token']
        assert own and own != safari
        me = icon.get(f'{HTTPS}/api/me', headers=_auth(own)).get_json()
        assert me['employee_id'] == '0000009601'

        # Второй раз по той же куке — ничего.
        assert _claim(_icon(app, secret))['status'] == 'none'
        # И вкладка продолжает работать как работала.
        me = tab.get(f'{HTTPS}/api/me', headers=_auth(safari)).get_json()
        assert me['employee_id'] == '0000009601'
    finally:
        with app.app_context():
            _drop('9601')


def test_offer_again_keeps_the_same_cookie(app):
    """Значок мог унести куку минуту назад — новая её не отменяет."""
    with app.app_context():
        _make('9602')
    try:
        tab = _client(app)
        safari = _token(tab, '9602')
        first = _offer(tab, safari)
        assert _offer(tab, safari) == first
        with app.app_context():
            assert WebHandoff.query.count() >= 1
            assert WebHandoff.query.filter_by(
                id=web_handoff._hash(first)).count() == 1
        assert _claim(_icon(app, first))['status'] == 'approved'
    finally:
        with app.app_context():
            _drop('9602')


def test_logout_in_safari_cancels_handoff(app):
    with app.app_context():
        _make('9603')
    try:
        tab = _client(app)
        safari = _token(tab, '9603')
        secret = _offer(tab, safari)
        tab.post(f'{HTTPS}/logout', headers=_auth(safari))
        assert _claim(_icon(app, secret))['status'] == 'none'
    finally:
        with app.app_context():
            _drop('9603')


def test_disabled_account_gets_nothing(app):
    with app.app_context():
        _make('9604')
    try:
        tab = _client(app)
        secret = _offer(tab, _token(tab, '9604'))
        with app.app_context():
            db.session.get(UserAccount, '9604').is_active = False
            db.session.commit()
        assert _claim(_icon(app, secret))['status'] == 'none'
    finally:
        with app.app_context():
            _drop('9604')


def test_issued_code_is_reported_to_icon(app):
    """Вошёл в Safari выданным кодом — значок узнаёт, что его пора гасить."""
    with app.app_context():
        _make('9605', must_change=True)
    try:
        tab = _client(app)
        secret = _offer(tab, _token(tab, '9605'))
        body = _claim(_icon(app, secret))
        assert body['status'] == 'approved'
        assert body['must_change_password'] is True
    finally:
        with app.app_context():
            _drop('9605')


def test_without_cookie_or_token(app):
    icon = _client(app)
    assert _claim(icon)['status'] == 'none'
    assert _claim(_icon(app, 'нет-такой'))['status'] == 'none'
    answer = icon.post(f'{HTTPS}/api/web-handoff')
    assert answer.status_code == 401
