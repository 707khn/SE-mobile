"""Отключение уволенного доходит и до конфиденциального чата.

Чат — отдельный сервер; этот говорит ему только «сотрудник уволен», и
только по служебному токену. Здесь проверяется, что отключение работает и
без чата, а чату уходит ровно логин — без пароля и прочего.
"""
import io
import json
import os

import pytest
from werkzeug.security import generate_password_hash

import app as app_module
import chat_link
from models import db, AuthToken, Employee, UserAccount

ADMIN_PASSWORD = os.environ['ADMIN_PASSWORD']
LOGIN = '0000009301'


@pytest.fixture
def admin_headers(app):
    with app.app_context():
        token = app_module._issue_token(app_module._authenticate('admin', ADMIN_PASSWORD))
    return {'Authorization': f'Bearer {token}'}


@pytest.fixture
def leaver(app, remove_employee):
    with app.app_context():
        db.session.add(Employee(employee_id=LOGIN, full_name='Уходящий Тест Тестович',
                                job_title='Слесарь'))
        db.session.add(UserAccount(login=LOGIN, employee_id=LOGIN,
                                   password_hash=generate_password_hash('Длинный-пароль-1'),
                                   must_change_password=False))
        db.session.commit()
        app_module._issue_token(LOGIN)
    remove_employee(LOGIN)
    return LOGIN


class _Answer(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_disable_without_chat_configured(client, admin_headers, leaver, monkeypatch):
    monkeypatch.delenv('CHAT_SERVICE_URL', raising=False)
    monkeypatch.delenv('CHAT_SERVICE_TOKEN', raising=False)

    answer = client.post(f'/api/admin/accounts/{leaver}/active', json={'active': False},
                         headers=admin_headers)
    body = answer.get_json()
    assert answer.status_code == 200
    assert body['is_active'] is False and body['chat'] == 'not_configured'

    with client.application.app_context():
        assert db.session.get(UserAccount, leaver).is_active is False
        assert AuthToken.query.filter_by(employee_id=leaver).count() == 0
        assert app_module._authenticate(leaver, 'Длинный-пароль-1') is None

    back = client.post(f'/api/admin/accounts/{leaver}/active', json={'active': True},
                       headers=admin_headers)
    assert back.get_json()['is_active'] is True and back.get_json()['chat'] is None
    with client.application.app_context():
        assert app_module._authenticate(leaver, 'Длинный-пароль-1') == leaver


def test_disable_tells_the_chat(client, admin_headers, leaver, monkeypatch):
    monkeypatch.setenv('CHAT_SERVICE_URL', 'https://chat.example/')
    monkeypatch.setenv('CHAT_SERVICE_TOKEN', 'service-token')
    sent = []

    def fake_urlopen(request, timeout):
        sent.append(request)
        return _Answer(b'{"status": "disabled"}')

    monkeypatch.setattr(chat_link.urllib.request, 'urlopen', fake_urlopen)

    answer = client.post(f'/api/admin/accounts/{leaver}/active', json={'active': False},
                         headers=admin_headers)
    assert answer.get_json()['chat'] == 'disabled'

    (request,) = sent
    assert request.full_url == 'https://chat.example/api/service/offboard'
    assert request.get_header('Authorization') == 'Bearer service-token'
    payload = json.loads(request.data)
    assert payload['username'] == leaver
    assert set(payload) == {'username', 'initiated_by'}


def test_chat_down_does_not_block_disabling(client, admin_headers, leaver, monkeypatch):
    monkeypatch.setenv('CHAT_SERVICE_URL', 'https://chat.example')
    monkeypatch.setenv('CHAT_SERVICE_TOKEN', 'service-token')

    def down(request, timeout):
        raise OSError('нет связи')

    monkeypatch.setattr(chat_link.urllib.request, 'urlopen', down)
    answer = client.post(f'/api/admin/accounts/{leaver}/active', json={'active': False},
                         headers=admin_headers)
    assert answer.get_json()['chat'] == 'failed'
    with client.application.app_context():
        assert db.session.get(UserAccount, leaver).is_active is False


def test_chat_admin_is_reported_not_failed(monkeypatch):
    """Администратора чата служебный токен не отключает — и это не сбой связи."""
    monkeypatch.setenv('CHAT_SERVICE_URL', 'https://chat.example')
    monkeypatch.setenv('CHAT_SERVICE_TOKEN', 'service-token')

    def conflict(request, timeout):
        raise chat_link.urllib.error.HTTPError(
            request.full_url, 409, 'Conflict', {}, io.BytesIO(b'{}'))

    monkeypatch.setattr(chat_link.urllib.request, 'urlopen', conflict)
    assert chat_link.offboard('1874') == 'privileged'


def test_plain_http_chat_is_refused(monkeypatch):
    """Токен не уходит открытым текстом даже при ошибке в настройке."""
    monkeypatch.setenv('CHAT_SERVICE_URL', 'http://chat.example')
    monkeypatch.setenv('CHAT_SERVICE_TOKEN', 'service-token')
    monkeypatch.setattr(chat_link.urllib.request, 'urlopen',
                        lambda *a, **k: pytest.fail('запрос ушёл по http'))
    assert chat_link.offboard('1874') == 'failed'


def test_admin_cannot_disable_themselves(client, admin_headers):
    answer = client.post('/api/admin/accounts/admin/active', json={'active': False},
                         headers=admin_headers)
    assert answer.status_code == 400


def test_only_admin_may_disable(client, leaver):
    with client.application.app_context():
        token = app_module._issue_token(leaver)
    answer = client.post(f'/api/admin/accounts/{leaver}/active', json={'active': False},
                         headers={'Authorization': f'Bearer {token}'})
    assert answer.status_code == 403
