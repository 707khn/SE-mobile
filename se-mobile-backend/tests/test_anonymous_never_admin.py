"""Без пропуска — никогда не админ, не начальник и не технолог.

Пока REQUIRE_AUTH выключен, запрос без пропуска проходит: старые сборки
рядовых сотрудников его не присылают, и им нужно видеть своё. Но проверки
прав отвечали такому запросу «можно» на всё — `not _AUTH_REQUIRED`, — и любой
из интернета, зная только адрес сервера, мог сбросить пароль «admin» (новый
сервер присылал прямо в ответе), включить себе расчётную группу, отключать
учётки и смотреть табель всего предприятия.

Админ-панелью, табелем и меню пользуются единицы, и у всех у них новая
сборка, которая пропуск присылает. Поэтому эти права без пропуска закрыты
и в переходном режиме.
"""

import json

import pytest

import app as app_module
from models import db, UserAccount, PayrollGrant

_ORDINARY = '0000002114'     # Сарсекенов, техник-программист


@pytest.fixture(autouse=True)
def transition_mode(monkeypatch):
    """Ровно то, что сейчас на боевом сервере: REQUIRE_AUTH=0."""
    monkeypatch.setattr(app_module, '_AUTH_REQUIRED', False)


def _back_to_number(login):
    """База общая на весь прогон, и другие проверки входят по табельному
    номеру — возвращаем учётке прежний пароль после сброса."""
    from werkzeug.security import generate_password_hash as _hash
    account = db.session.get(UserAccount, login)
    account.password_hash = _hash(login)
    db.session.commit()


def _anon_post(client, path, body=None):
    return client.post(path, data=json.dumps(body or {}),
                       content_type='application/json')


def test_anonymous_cannot_reset_the_admin_password(app, client):
    with app.app_context():
        before = db.session.get(UserAccount, 'admin').password_hash

    answer = _anon_post(client, '/api/admin/accounts/admin/reset')

    assert answer.status_code == 403
    assert 'temporary_password' not in (answer.get_json() or {})
    with app.app_context():
        assert db.session.get(UserAccount, 'admin').password_hash == before


def test_anonymous_cannot_list_accounts(client):
    assert client.get('/api/admin/accounts').status_code == 403


def test_anonymous_cannot_disable_an_account(app, client):
    answer = _anon_post(client, '/api/admin/accounts/2114/active',
                        {'active': False})
    assert answer.status_code == 403
    with app.app_context():
        assert db.session.get(UserAccount, '2114').is_active


def test_anonymous_cannot_grant_payroll(app, client):
    answer = _anon_post(client, f'/api/admin/employees/{_ORDINARY}/payroll',
                        {'payroll': True})
    assert answer.status_code == 403
    with app.app_context():
        assert db.session.get(PayrollGrant, _ORDINARY) is None


def test_anonymous_cannot_open_the_rollout_report(client):
    assert client.get('/api/admin/rollout').status_code == 403


def test_anonymous_is_not_a_manager(client):
    assert _anon_post(client, '/get_sname',
                      {'key_suffix': _ORDINARY}).status_code == 403
    assert client.get('/api/attendance?date=2024-01-15').status_code == 403


def test_anonymous_cannot_look_people_up_by_name(client):
    answer = _anon_post(client, '/director_report', {
        'emp_sname': 'Сарсекенов',
        'start_date': '2024-01-01',
        'end_date': '2024-01-31',
    })
    assert answer.status_code == 403


def test_anonymous_cannot_edit_the_menu(client):
    answer = _anon_post(client, '/api/menu', {
        'date': '2031-02-01',
        'items': [{'category': 'Первое блюдо', 'name': 'Суп', 'price': 1.0}],
    })
    assert answer.status_code == 403
    assert client.delete('/api/menu/2031-02-01').status_code == 403


def test_admin_with_a_pass_still_resets(app, client):
    """Закрыли анонима, а не администратора."""
    with app.app_context():
        token = app_module._issue_token('ADMIN')
    answer = client.post('/api/admin/accounts/2114/reset',
                         headers={'Authorization': f'Bearer {token}'})
    assert answer.status_code == 200
    code = answer.get_json()['temporary_password']
    assert code != '2114' and len(code) == 4 and code.isdigit()
    with app.app_context():
        assert app_module._authenticate('2114', '2114') is None
        assert app_module._authenticate('2114', code) is not None
        # База общая на прогон: возвращаем, как было.
        _back_to_number('2114')
