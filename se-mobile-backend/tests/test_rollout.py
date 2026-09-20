"""Готовность к включению обязательной проверки пропуска.

Пока приложение не дошло до всех, включать её нельзя: у необновившихся всё
перестанет работать. Эти проверки — про то, что сервер честно считает, кто
на какой сборке и сколько ещё приходит запросов без пропуска.
"""

import os

import app as app_module
from models import db, UserAccount, AuthMiss

_ADMIN = {'X-Admin-Token': os.environ['ADMIN_TOKEN']}


def _token(app, employee_id):
    with app.app_context():
        return app_module._issue_token(employee_id)


def test_version_is_remembered(app, client):
    token = _token(app, '0000001465')          # Даурембекова
    client.get('/api/menu', headers={'Authorization': f'Bearer {token}',
                                     'X-App-Version': '1.6.0 (8)'})
    with app.app_context():
        account = UserAccount.query.filter_by(employee_id='0000001465').first()
        assert account.app_version == '1.6.0 (8)'
        assert account.last_seen_at is not None


def test_requests_without_a_pass_are_counted(app, client):
    with app.app_context():
        before = sum(m.count for m in AuthMiss.query.all())
    client.get('/api/menu')                     # без пропуска, как старая сборка
    with app.app_context():
        after = sum(m.count for m in AuthMiss.query.all())
    assert after == before + 1


def test_rollout_report_is_for_admins_only(app, client):
    token = _token(app, '0000001465')           # начальник отдела, не админ
    denied = client.get('/api/admin/rollout',
                        headers={'Authorization': f'Bearer {token}'})
    assert denied.status_code == 403

    with app.app_context():
        admin = app_module._authenticate('admin', 'admin')
        admin_token = app_module._issue_token(admin)
    allowed = client.get('/api/admin/rollout',
                         headers={'Authorization': f'Bearer {admin_token}'})
    assert allowed.status_code == 200
    body = allowed.get_json()
    assert body['require_auth'] is False        # в проверках она выключена
    assert body['accounts'] > 100
    assert isinstance(body['by_version'], dict)
    assert body['without_pass'], 'счётчик запросов без пропуска пуст'
