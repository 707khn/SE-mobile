"""Вход на компьютере по QR-коду с телефона (qr_login.py)."""

from datetime import datetime, timedelta

from werkzeug.security import generate_password_hash

import qr_login
from models import db, AuthToken, Employee, Notification, QrLogin, UserAccount


def _make(login):
    db.session.add(Employee(employee_id=login.zfill(10),
                            full_name=f'Компьютер Тестович {login}',
                            job_title='Бухгалтер'))
    db.session.add(UserAccount(login=login, employee_id=login.zfill(10),
                               password_hash=generate_password_hash('Цех-2026-ok'),
                               must_change_password=False))
    db.session.commit()


def _drop(*logins):
    for login in logins:
        employee_id = login.zfill(10)
        QrLogin.query.filter_by(employee_id=employee_id).delete()
        Notification.query.filter_by(employee_id=employee_id).delete()
        AuthToken.query.filter_by(employee_id=employee_id).delete()
        db.session.delete(db.session.get(UserAccount, login))
        db.session.delete(db.session.get(Employee, employee_id))
    db.session.commit()


def _token(client, login):
    body = client.post('/login', json={'login': login,
                                       'password': 'Цех-2026-ok'}).get_json()
    assert body['message'] == 'Success'
    return body['token']


def _auth(token):
    return {'Authorization': f'Bearer {token}'}


def _start(client, device='BUH-PC-07'):
    answer = client.post('/api/qr-login/start', json={'device': device})
    assert answer.status_code == 200
    body = answer.get_json()
    assert len(body['code']) == 8
    return body['secret'], body['code']


def _poll(client, secret):
    return client.post('/api/qr-login/poll', json={'secret': secret}).get_json()


def test_whole_flow_gives_pc_a_working_token_once(app, client):
    with app.app_context():
        _make('9501')
    try:
        phone = _token(client, '9501')
        secret, code = _start(client)
        assert _poll(client, secret)['status'] == 'waiting'

        # Телефон считывает ссылку из QR — код внутри неё.
        scanned = client.post('/api/qr-login/scan', headers=_auth(phone),
                              json={'code': f'https://api.se-btrz.com/web/?pc={code}'})
        assert scanned.status_code == 200
        assert scanned.get_json()['device'] == 'BUH-PC-07'
        assert _poll(client, secret)['status'] == 'scanned'

        confirmed = client.post('/api/qr-login/confirm', headers=_auth(phone),
                                json={'code': code})
        assert confirmed.status_code == 200

        body = _poll(client, secret)
        assert body['status'] == 'approved'
        assert body['login'] == '9501'
        assert body['employee_id'] == '0000009501'
        pc = body['token']
        assert pc and pc != phone
        me = client.get('/api/me', headers=_auth(pc)).get_json()
        assert me['employee_id'] == '0000009501'

        # Второй раз пропуск не выдаётся, и код больше не годится.
        assert _poll(client, secret)['status'] == 'expired'
        again = client.post('/api/qr-login/scan', headers=_auth(phone),
                            json={'code': code})
        assert again.status_code == 404

        # Человеку — оповещение о входе.
        with app.app_context():
            assert Notification.query.filter_by(
                employee_id='0000009501', kind='signin').count() == 1
    finally:
        with app.app_context():
            _drop('9501')


def test_scan_needs_a_signed_in_phone(app, client):
    secret, code = _start(client)
    answer = client.post('/api/qr-login/scan', json={'code': code})
    assert answer.status_code == 401
    answer = client.post('/api/qr-login/confirm', json={'code': code})
    assert answer.status_code == 401
    assert _poll(client, secret)['status'] == 'waiting'


def test_only_the_phone_that_scanned_can_confirm(app, client):
    with app.app_context():
        _make('9502')
        _make('9503')
    try:
        first = _token(client, '9502')
        second = _token(client, '9503')
        secret, code = _start(client)

        assert client.post('/api/qr-login/scan', headers=_auth(first),
                           json={'code': code}).status_code == 200
        # Второй телефон тот же код уже не займёт и не подтвердит.
        assert client.post('/api/qr-login/scan', headers=_auth(second),
                           json={'code': code}).status_code == 409
        assert client.post('/api/qr-login/confirm', headers=_auth(second),
                           json={'code': code}).status_code == 409
        assert _poll(client, secret)['status'] == 'scanned'
    finally:
        with app.app_context():
            _drop('9502', '9503')


def test_confirm_without_scan_is_refused(app, client):
    with app.app_context():
        _make('9504')
    try:
        phone = _token(client, '9504')
        secret, code = _start(client)
        answer = client.post('/api/qr-login/confirm', headers=_auth(phone),
                             json={'code': code})
        assert answer.status_code == 409
        assert _poll(client, secret)['status'] == 'waiting'
    finally:
        with app.app_context():
            _drop('9504')


def test_reject_tells_the_pc(app, client):
    with app.app_context():
        _make('9505')
    try:
        phone = _token(client, '9505')
        secret, code = _start(client)
        client.post('/api/qr-login/scan', headers=_auth(phone),
                    json={'code': code})
        assert client.post('/api/qr-login/reject', headers=_auth(phone),
                           json={'code': code}).status_code == 200
        body = _poll(client, secret)
        assert body == {'message': 'Success', 'status': 'rejected'}
        assert 'token' not in body
        # После отказа подтвердить уже нечего.
        assert client.post('/api/qr-login/confirm', headers=_auth(phone),
                           json={'code': code}).status_code == 404
    finally:
        with app.app_context():
            _drop('9505')


def test_code_expires(app, client):
    with app.app_context():
        _make('9506')
    try:
        phone = _token(client, '9506')
        secret, code = _start(client)
        with app.app_context():
            row = QrLogin.query.filter_by(code_hash=qr_login._hash(code)).one()
            row.expires_at = datetime.utcnow() - timedelta(seconds=1)
            db.session.commit()
        assert client.post('/api/qr-login/scan', headers=_auth(phone),
                           json={'code': code}).status_code == 404
        assert _poll(client, secret)['status'] == 'expired'
    finally:
        with app.app_context():
            _drop('9506')


def test_disabled_account_gets_no_token(app, client):
    with app.app_context():
        _make('9507')
    try:
        phone = _token(client, '9507')
        secret, code = _start(client)
        client.post('/api/qr-login/scan', headers=_auth(phone),
                    json={'code': code})
        client.post('/api/qr-login/confirm', headers=_auth(phone),
                    json={'code': code})
        with app.app_context():
            db.session.get(UserAccount, '9507').is_active = False
            db.session.commit()
        body = _poll(client, secret)
        assert body['status'] == 'rejected'
        assert 'token' not in body
    finally:
        with app.app_context():
            _drop('9507')


def test_nothing_secret_is_stored(app, client):
    secret, code = _start(client)
    with app.app_context():
        row = QrLogin.query.filter_by(code_hash=qr_login._hash(code)).one()
        assert row.id == qr_login._hash(secret)
        assert secret not in (row.id, row.code_hash)
        assert code not in (row.id, row.code_hash)


def test_codes_typed_by_hand_are_understood():
    assert qr_login.normalize_code('abcd-2345') == 'ABCD2345'
    assert qr_login.normalize_code(' ABCD 2345 ') == 'ABCD2345'
    assert qr_login.normalize_code('https://x/web/?pc=ABCD2345') == 'ABCD2345'
    assert qr_login.normalize_code('https://x/web/#/?pc=ABCD2345') == 'ABCD2345'
    # 0, O, 1 и I в коде не бывает — это опечатка, а не код.
    assert qr_login.normalize_code('ABCD0O1I') == ''
    assert qr_login.normalize_code('ABC') == ''
    assert qr_login.normalize_code('') == ''


def test_poll_with_garbage(client):
    assert client.post('/api/qr-login/poll', json={}).status_code == 400
    assert client.post('/api/qr-login/poll',
                       json={'secret': 'x' * 500}).status_code == 400
    assert _poll(client, 'no-such-secret')['status'] == 'expired'
