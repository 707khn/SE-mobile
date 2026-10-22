"""Плановые отключения: кто объявляет, кому приходит, «скоро» и отмена."""

from datetime import datetime

import pytest

import app as app_module
import planned_outages
from models import db, Notification
from planned_outages import Outage, remind_soon

_IT = '0000001965'          # инженер-программист ОИТиС
_POWER = '0000000631'       # главный энергетик
_MASTER = '0000000082'      # мастер ОП
_ACCOUNTANT = '0000000137'  # бухгалтер ОБиНУ
_OP = 'Основное производство (ОП)'
_NOW = datetime(2030, 3, 4, 10, 0)


@pytest.fixture(autouse=True)
def clean(app, monkeypatch):
    clock = {'now': _NOW}
    monkeypatch.setattr(app_module, '_plant_now', lambda: clock['now'])
    # Напоминания из before_request не должны вмешиваться в проверку.
    monkeypatch.setattr(planned_outages, '_reminded_at', datetime.utcnow())
    yield clock
    with app.app_context():
        Outage.query.delete()
        Notification.query.filter_by(kind='outage').delete()
        db.session.commit()


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _announce(app, client, who=_POWER, **extra):
    body = {'kind': 'power', 'starts_at': '2030-03-09 09:00',
            'ends_at': '2030-03-09 13:00', 'note': 'Замена трансформатора',
            'departments': ['основное производство (оп)'], **extra}
    return client.post('/api/outages', headers=_auth(app, who), json=body)


def _notices(app, employee_id):
    with app.app_context():
        return [n.title for n in Notification.query.filter_by(
            kind='outage', employee_id=employee_id).order_by(Notification.id)]


def test_who_announces(app, client):
    assert _announce(app, client, who=_MASTER).status_code == 403
    assert _announce(app, client, who=_IT, kind='network').status_code == 201
    assert _announce(app, client).status_code == 201


def test_validation(app, client):
    def error(**extra):
        return _announce(app, client, **extra).get_json()['error']
    assert error(kind='gas') == 'bad_kind'
    assert error(starts_at='завтра') == 'bad_time'
    assert error(ends_at='2030-03-09 08:00') == 'ends_before'
    assert error(starts_at='2030-03-01 09:00',
                 ends_at='2030-03-01 13:00') == 'past'
    assert error(ends_at='2030-04-09 13:00') == 'too_long'
    assert error(kind='other', note='') == 'note_required'
    assert error(departments=['Цех №9']) == 'bad_departments'
    assert error(departments='ОП') == 'bad_departments'


def test_notice_reaches_only_departments(app, client):
    answer = _announce(app, client)
    assert answer.status_code == 201, answer.get_json()
    outage = answer.get_json()['outage']
    assert outage['departments'] == [_OP] and outage['state'] == 'planned'
    assert answer.get_json()['notified'] > 0
    assert _notices(app, _MASTER) == [
        'Отключение электроэнергии 09.03 с 09:00 до 13:00']
    assert _notices(app, _ACCOUNTANT) == []

    mine = client.get('/api/outages', headers=_auth(app, _MASTER)).get_json()
    assert mine['staff'] is False and mine['items'][0]['mine'] is True
    theirs = client.get('/api/outages', headers=_auth(app, _ACCOUNTANT)).get_json()
    assert theirs['items'][0]['mine'] is False

    # Всему предприятию — когда подразделений не указали.
    _announce(app, client, who=_IT, kind='service', note='Обновление 1С',
              departments=[], starts_at='2030-03-10 18:00',
              ends_at='2030-03-11 08:00')
    assert _notices(app, _ACCOUNTANT) == [
        'Отключение сервиса с 10.03 18:00 до 11.03 08:00']


def test_remind_soon_and_cancel(app, client, clean):
    outage_id = _announce(app, client).get_json()['outage']['id']
    with app.app_context():
        assert remind_soon(app_module) == 0
    clean['now'] = datetime(2030, 3, 9, 7, 30)
    with app.app_context():
        assert remind_soon(app_module) == 1
        assert remind_soon(app_module) == 0
    assert _notices(app, _MASTER)[-1] == \
        'Скоро отключение электроэнергии 09.03 с 09:00 до 13:00'

    assert client.post(f'/api/outages/{outage_id}', headers=_auth(app, _MASTER),
                       json={'action': 'cancel'}).status_code == 403
    cancelled = client.post(f'/api/outages/{outage_id}', headers=_auth(app, _IT),
                            json={'action': 'cancel'})
    assert cancelled.get_json()['outage']['state'] == 'cancelled'
    assert _notices(app, _MASTER)[-1].startswith('Отменено отключение')
    assert client.post(f'/api/outages/{outage_id}', headers=_auth(app, _IT),
                       json={'action': 'cancel'}).status_code == 409


def test_departments_list(app, client):
    assert client.get('/api/outages/departments',
                      headers=_auth(app, _MASTER)).status_code == 403
    names = client.get('/api/outages/departments',
                       headers=_auth(app, _POWER)).get_json()['departments']
    assert _OP in names and names == sorted(names)
