"""Запись на приём к руководству: окна, запись, подтверждение, отказ."""

from datetime import date, datetime

import pytest

import app as app_module
from models import db, Notification
from reception import ReceptionSlot

_OFFICE = '0000002063'      # офис-менеджер приёмной
_DIRECTOR = '0000002183'    # генеральный директор
_DEPUTY = '0000002184'      # заместитель по экономике и финансам
_MASTER = '0000000082'
_ACCOUNTANT = '0000000137'
_NOW = datetime(2030, 3, 4, 10, 0)


@pytest.fixture(autouse=True)
def clean(app, monkeypatch):
    monkeypatch.setattr(app_module, '_plant_now', lambda: _NOW)
    monkeypatch.setattr(app_module, '_plant_today', lambda: _NOW.date())
    yield
    with app.app_context():
        ReceptionSlot.query.delete()
        Notification.query.filter_by(kind='reception').delete()
        db.session.commit()


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _open(app, client, who=_OFFICE, **extra):
    body = {'host_id': _DIRECTOR, 'date': '2030-03-06', 'from': '14:00',
            'to': '15:00', 'step': 20, **extra}
    return client.post('/api/reception/slots', headers=_auth(app, who), json=body)


def _mine(app, client, who):
    return client.get('/api/reception', headers=_auth(app, who)).get_json()


def _book(app, client, slot_id, who=_MASTER, topic='Перевод на другой участок'):
    return client.post(f'/api/reception/slots/{slot_id}/book',
                       headers=_auth(app, who), json={'topic': topic})


def _notices(app, employee_id):
    with app.app_context():
        return [(n.title, n.body) for n in Notification.query.filter_by(
            kind='reception', employee_id=employee_id).order_by(Notification.id)]


def test_open_windows(app, client):
    assert _open(app, client, who=_MASTER).status_code == 403
    assert _open(app, client, host_id=_MASTER).get_json()['error'] == 'bad_host'
    assert _open(app, client, date='2030-03-01').get_json()['error'] == 'bad_date'
    assert _open(app, client, to='13:00').get_json()['error'] == 'bad_time'
    assert _open(app, client).get_json()['added'] == 3
    assert _open(app, client).get_json()['added'] == 0
    assert _open(app, client, host_id=_DEPUTY).get_json()['added'] == 3

    mine = _mine(app, client, _MASTER)
    assert mine['manager'] is False and mine['host'] is False
    assert mine['hosts'][0]['id'] == _DIRECTOR
    assert [(s['host']['id'], s['starts_at']) for s in mine['free']][:3] == [
        (_DIRECTOR, '2030-03-06T14:00'), (_DEPUTY, '2030-03-06T14:00'),
        (_DIRECTOR, '2030-03-06T14:20')]
    assert 'topic' not in mine['free'][0]
    assert _mine(app, client, _OFFICE)['manager'] is True
    assert _mine(app, client, _DIRECTOR)['host'] is True


def test_book_confirm_and_privacy(app, client):
    _open(app, client)
    slots = [s['id'] for s in _mine(app, client, _MASTER)['free']]
    assert _book(app, client, slots[0], topic='да').get_json()['error'] == \
        'topic_required'
    answer = _book(app, client, slots[0])
    assert answer.status_code == 200, answer.get_json()
    assert answer.get_json()['slot']['status'] == 'requested'
    assert _book(app, client, slots[1]).get_json()['error'] == 'too_many'
    assert _book(app, client, slots[0], who=_ACCOUNTANT).get_json()['error'] == \
        'taken'
    assert _book(app, client, slots[1], who=_DIRECTOR).get_json()['error'] == 'own'
    assert _notices(app, _OFFICE)[-1][0] == 'Запись на приём: нужно подтвердить'

    # Чужой вопрос не виден ни в свободных окнах, ни в чужих записях.
    other = _mine(app, client, _ACCOUNTANT)
    assert all('topic' not in s for s in other['free'])
    assert client.get('/api/reception/desk', headers=_auth(app, _ACCOUNTANT)
                      ).status_code == 403
    desk = client.get('/api/reception/desk', headers=_auth(app, _DIRECTOR),
                      query_string={'date': '2030-03-06', 'host': _DEPUTY}).get_json()
    assert [s['host']['id'] for s in desk['slots']] == [_DIRECTOR] * 3
    assert desk['slots'][0]['topic'] == 'Перевод на другой участок'
    assert desk['slots'][0]['employee']['id'] == _MASTER

    confirmed = client.post(f'/api/reception/slots/{slots[0]}',
                            headers=_auth(app, _OFFICE), json={'action': 'confirm'})
    assert confirmed.get_json()['slot']['status'] == 'confirmed'
    assert _notices(app, _MASTER)[-1][0] == 'Приём подтверждён'
    assert _mine(app, client, _MASTER)['bookings'][0]['status'] == 'confirmed'


def test_decline_cancel_delete(app, client):
    _open(app, client)
    slots = [s['id'] for s in _mine(app, client, _MASTER)['free']]
    _book(app, client, slots[0])
    headers = _auth(app, _OFFICE)
    assert client.post(f'/api/reception/slots/{slots[0]}', headers=headers,
                       json={'action': 'decline'}).get_json()['error'] == \
        'reason_required'
    assert client.post(f'/api/reception/slots/{slots[0]}', headers=headers,
                       json={'action': 'decline', 'reason': 'Вопрос решит ПЭО'}
                       ).status_code == 200
    assert _notices(app, _MASTER)[-1] == (
        'Приём не состоится', '06.03.2030 14:00, ' +
        _mine(app, client, _MASTER)['hosts'][0]['name'] + '. Вопрос решит ПЭО')
    assert _mine(app, client, _MASTER)['bookings'] == []

    _book(app, client, slots[1])
    assert client.post(f'/api/reception/slots/{slots[1]}/cancel',
                       headers=_auth(app, _ACCOUNTANT)).status_code == 403
    assert client.post(f'/api/reception/slots/{slots[1]}/cancel',
                       headers=_auth(app, _MASTER)).status_code == 200
    assert len(_mine(app, client, _MASTER)['free']) == 3

    _book(app, client, slots[2])
    assert client.delete(f'/api/reception/slots/{slots[2]}',
                         headers=headers).status_code == 200
    assert _notices(app, _MASTER)[-1][0] == 'Приём не состоится'
    with app.app_context():
        assert ReceptionSlot.query.count() == 2
