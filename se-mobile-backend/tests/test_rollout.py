"""Готовность к включению обязательной проверки пропуска.

Пока приложение не дошло до всех, включать её нельзя: у необновившихся всё
перестанет работать. Эти проверки — про то, что сервер честно считает, кто
на какой сборке и сколько ещё приходит запросов без пропуска.
"""

import os

import app as app_module
from models import db, UserAccount, AuthMiss

# Тот же пароль, что conftest кладёт в окружение до создания приложения.
ADMIN_PASSWORD = os.environ['ADMIN_PASSWORD']

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
        admin = app_module._authenticate('admin', ADMIN_PASSWORD)
        admin_token = app_module._issue_token(admin)
    allowed = client.get('/api/admin/rollout',
                         headers={'Authorization': f'Bearer {admin_token}'})
    assert allowed.status_code == 200
    body = allowed.get_json()
    assert body['require_auth'] is False        # в проверках она выключена
    assert body['accounts'] > 100
    assert isinstance(body['by_version'], dict)
    assert body['without_pass'], 'счётчик запросов без пропуска пуст'


def test_api_me_answers_by_the_pass(app, client):
    """Приложение узнаёт, кто оно, по пропуску — без пароля на телефоне."""
    token = _token(app, '0000001465')
    r = client.get('/api/me', headers={'Authorization': f'Bearer {token}'})
    assert r.status_code == 200
    body = r.get_json()
    assert body['employee_id'] == '0000001465'
    assert 'Даурембекова' in body['full_name']
    assert body['job']
    assert 'must_change_password' in body


def test_api_me_refuses_without_a_pass(app, client):
    """Без пропуска — отказ, даже пока обязательная проверка выключена.

    Иначе этот путь отдавал бы имя и должность любому, кто знает адрес.
    """
    r = client.get('/api/me')
    assert r.status_code == 401


def test_in_code_passwords_are_counted(app, client):
    """Счётчик пропавших учётных записей.

    Раньше логин, которого нет в user_accounts, проверялся по словарю
    паролей в коде, и счётчик показывал, сколько раз этим воспользовались.
    Паролей в словаре больше нет, и такой вход просто не проходит — а
    считать всё равно надо: не ноль значит, что у кого-то пропала строка в
    базе и человек не войдёт, пока сидер её не восстановит.
    """
    with app.app_context():
        for login in app_module._CREDENTIALS:
            assert UserAccount.query.filter_by(login=login).first() is not None, \
                f'{login} не заведён в user_accounts — под ним не войти'

        before = sum(m.fallback_logins or 0 for m in AuthMiss.query.all())
        app_module._count_today('fallback_logins')
        after = sum(m.fallback_logins or 0 for m in AuthMiss.query.all())
        assert after == before + 1

        admin = app_module._issue_token(app_module._authenticate('admin', ADMIN_PASSWORD))
    report = client.get('/api/admin/rollout',
                        headers={'Authorization': f'Bearer {admin}'}).get_json()
    assert sum(d['count'] for d in report['in_code_passwords']) >= 1


def test_backup_state_is_reported(app, client, tmp_path, monkeypatch):
    """Три недели подряд копии не делались, и узнали об этом случайно.

    Поэтому дата последней копии теперь стоит рядом с остальным, что
    администратор и так открывает.
    """
    monkeypatch.setenv('BACKUP_DIR', str(tmp_path))
    (tmp_path / 'se_mobile_2026-09-21.sql.gz.enc').write_bytes(b'x')
    with app.app_context():
        state = app_module._backup_state()
    assert state['available'] and state['count'] == 1
    assert state['days_ago'] == 0 and state['encrypted']

    # Нет папки — не молчим, а говорим, почему.
    monkeypatch.setenv('BACKUP_DIR', str(tmp_path / 'нет-такой'))
    with app.app_context():
        missing = app_module._backup_state()
    assert not missing['available'] and missing['reason']


def _fetch_status(tmp_path, monkeypatch, **fields):
    path = tmp_path / 'status'
    path.write_text(''.join(f'{k}={v}\n' for k, v in fields.items()),
                    encoding='utf-8')
    monkeypatch.setattr(app_module, '_FETCH_APK_STATUS', str(path))
    return app_module._fetch_apk_state()


def _now():
    from datetime import datetime, timezone
    return datetime.now(timezone.utc)


def test_fetch_apk_all_good(tmp_path, monkeypatch):
    from datetime import timedelta
    state = _fetch_status(
        tmp_path, monkeypatch,
        checked_at=_now().strftime('%Y-%m-%dT%H:%M:%SZ'), result='ok',
        message='', token_expires=(_now() + timedelta(days=200))
        .strftime('%Y-%m-%d %H:%M:%S UTC'))
    assert state['problem'] == ''
    assert state['token_days_left'] in (199, 200)


def test_fetch_apk_expired_token_is_shown(tmp_path, monkeypatch):
    """Истёкший токен иначе виден только в журнале, который читает root."""
    state = _fetch_status(
        tmp_path, monkeypatch,
        checked_at=_now().strftime('%Y-%m-%dT%H:%M:%SZ'), result='fail',
        message='GitHub не принял токен: истёк срок или его отозвали.',
        token_expires='')
    assert 'не принял токен' in state['problem']


def test_fetch_apk_token_running_out_is_warned(tmp_path, monkeypatch):
    from datetime import timedelta
    state = _fetch_status(
        tmp_path, monkeypatch,
        checked_at=_now().strftime('%Y-%m-%dT%H:%M:%SZ'), result='ok',
        message='', token_expires=(_now() + timedelta(days=5, hours=1))
        .strftime('%Y-%m-%d %H:%M:%S UTC'))
    assert 'истекает через 5 дн.' in state['problem']


def test_fetch_apk_silent_timer_is_shown(tmp_path, monkeypatch):
    from datetime import timedelta
    state = _fetch_status(
        tmp_path, monkeypatch,
        checked_at=(_now() - timedelta(hours=3)).strftime('%Y-%m-%dT%H:%M:%SZ'),
        result='ok', message='', token_expires='')
    assert 'Таймер не запускался' in state['problem']


def test_fetch_apk_never_ran_is_shown(app, client, tmp_path, monkeypatch):
    monkeypatch.setattr(app_module, '_FETCH_APK_STATUS',
                        str(tmp_path / 'нет-такого'))
    answer = client.get('/api/admin/rollout', headers=_ADMIN)
    assert answer.status_code == 200
    state = answer.get_json()['fetch_apk']
    assert not state['available'] and 'ни разу' in state['problem']
