"""Загрузки и объявления говорят «замок», а не «неверный пароль».

Технолог, которому после пяти ошибок пишут «неверный логин или пароль»,
вводит верный снова и снова — и только продлевает себе замок.
"""

import io
from datetime import datetime, timedelta

import pytest
from werkzeug.security import generate_password_hash

from models import db, Employee, UserAccount

_ID = 'UPL00001'
_LOGIN = 'zagruzkin'
_PASSWORD = 'длинная-фраза-технолога'


@pytest.fixture
def account(app, remove_employee):
    with app.app_context():
        remove_employee(_ID)
        UserAccount.query.filter_by(login=_LOGIN).delete()
        db.session.add(Employee(employee_id=_ID, full_name='Загрузкин Тест',
                                job_title='Технолог столовой'))
        db.session.add(UserAccount(login=_LOGIN, employee_id=_ID,
                                   password_hash=generate_password_hash(_PASSWORD),
                                   must_change_password=False))
        db.session.commit()
    yield
    with app.app_context():
        UserAccount.query.filter_by(login=_LOGIN).delete()
        db.session.commit()


def _lock(app):
    with app.app_context():
        acc = UserAccount.query.filter_by(login=_LOGIN).first()
        acc.locked_until = datetime.utcnow() + timedelta(minutes=4)
        db.session.commit()


def _menu(client, password):
    return client.post('/api/menu/import-excel', data={
        'login': _LOGIN, 'password': password,
        'file': (io.BytesIO(b'not an xlsx'), 'menu.xlsx')},
        content_type='multipart/form-data')


def _announce(client, password):
    return client.post('/api/news/announcements', json={
        'login': _LOGIN, 'password': password, 'title': 'Проверка'})


def test_wrong_password_is_still_wrong_password(client, account):
    for answer in (_menu(client, 'не-тот'), _announce(client, 'не-тот')):
        assert answer.status_code == 401
        assert 'Неверный логин или пароль' in answer.get_json()['message']


def test_locked_account_says_it_is_locked(app, client, account):
    _lock(app)
    for answer in (_menu(client, _PASSWORD), _announce(client, _PASSWORD)):
        assert answer.status_code == 429
        body = answer.get_json()
        assert body['error'] == 'locked'
        assert body['retry_after'] > 0
        assert 'Попробуйте через 4 мин' in body['message']
