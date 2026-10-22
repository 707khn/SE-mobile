"""Наряд-допуск: выписать, согласовать в БиОТ, допустить, закрыть."""

from datetime import datetime, timedelta

import pytest

import app as app_module
from hazards import is_safety
from models import db, Employee, Notification
from work_permits import WorkPermit, WorkPermitEvent

_ISSUER = '0000000082'      # мастер ОП
_PERFORMER = '0000000150'   # другой мастер ОП
_ADMITTER = '0000000631'    # главный энергетик
_SAFETY = '0000001972'      # инженер по БиОТ
_SECURITY = '0000001490'    # начальник СБ
_DRIVER = '0000000155'      # водитель — наряды не выписывает
_NOW = datetime(2030, 1, 15, 8, 0)


@pytest.fixture(autouse=True)
def clean(app, monkeypatch):
    monkeypatch.setattr(app_module, '_plant_now', lambda: _NOW)
    yield
    with app.app_context():
        WorkPermitEvent.query.delete()
        WorkPermit.query.delete()
        Notification.query.filter_by(kind='permit').delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        assert kind == 'permit'
        sent.append((sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _issue(client, headers, **fields):
    body = {'kind': 'fire', 'place': 'Цех 1, участок сварки',
            'work': 'Сварка рамы стенда', 'starts_at': '2030-01-15T09:00',
            'ends_at': '2030-01-15T17:00', 'performer_id': _PERFORMER,
            'admitter_id': _ADMITTER, 'members': ['Иванов И.', ' ', 'Петров П.'],
            'measures': ['Убрать горючие материалы', 'Огнетушитель на месте']}
    body.update(fields)
    return client.post('/api/permits', json=body, headers=headers)


def _act(client, headers, item_id, action, **body):
    return client.post(f'/api/permits/{item_id}', json={'action': action, **body},
                       headers=headers)


def _safety_ids(app):
    with app.app_context():
        return sorted(e.employee_id for e in Employee.query.all() if is_safety(e))


def test_issue_goes_to_safety(app, client, pushes):
    answer = _issue(client, _auth(app, _ISSUER))
    assert answer.status_code == 201, answer.get_json()
    item = answer.get_json()['item']
    assert item['status'] == 'pending' and item['members'] == ['Иванов И.', 'Петров П.']
    assert item['responsible']['id'] == _ISSUER
    assert item['starts_at'] == '2030-01-15T09:00'
    [(ids, title, body)] = pushes
    assert ids == _safety_ids(app) and _SAFETY in ids
    assert title == f'Наряд №{item["id"]} на согласование: огневые работы'
    assert 'с 15.01 09:00' in body


def test_validation(app, client):
    headers = _auth(app, _ISSUER)
    assert _issue(client, _auth(app, _DRIVER)).status_code == 403
    assert _issue(client, headers, kind='party').status_code == 400
    assert _issue(client, headers, place=' ').get_json()['error'] == 'place_required'
    assert _issue(client, headers, ends_at='2030-01-15T08:30',
                  starts_at='2030-01-15T09:00').get_json()['error'] == 'bad_time'
    assert _issue(client, headers, starts_at='2030-01-14T06:00',
                  ends_at='2030-01-14T07:00').get_json()['error'] == 'in_past'
    assert _issue(client, headers, ends_at='2030-02-15T09:00').get_json()['error'] \
        == 'too_long'
    assert _issue(client, headers, performer_id='').get_json()['error'] \
        == 'performer_required'
    assert _issue(client, headers, admitter_id='9999').get_json()['error'] \
        == 'unknown_person'
    assert _issue(client, headers, measures=[]).get_json()['error'] \
        == 'measures_required'
    assert _issue(client, headers, kind='other', measures=[]).status_code == 201


def test_full_path(app, client, pushes):
    item_id = _issue(client, _auth(app, _ISSUER)).get_json()['item']['id']
    performer, admitter = _auth(app, _PERFORMER), _auth(app, _ADMITTER)
    safety = _auth(app, _SAFETY)

    # До согласования допустить нельзя, и не БиОТ согласовать не может.
    assert _act(client, admitter, item_id, 'admit').status_code == 403
    assert _act(client, performer, item_id, 'approve').status_code == 403
    queue = client.get('/api/permits?scope=queue', headers=safety).get_json()
    assert [i['id'] for i in queue['items']] == [item_id] and queue['waiting'] == 1

    assert _act(client, safety, item_id, 'approve').get_json()['item']['status'] \
        == 'approved'
    assert pushes[-1][0] == sorted({_ISSUER, _PERFORMER, _ADMITTER})
    # Допускает допускающий, а не выдавший.
    assert _act(client, _auth(app, _ISSUER), item_id, 'admit').status_code == 403
    opened = _act(client, admitter, item_id, 'admit').get_json()['item']
    assert opened['status'] == 'open' and opened['can_close'] is False
    assert _SAFETY in pushes[-1][0]

    board = client.get('/api/permits?scope=board',
                       headers=_auth(app, _SECURITY)).get_json()
    assert [i['id'] for i in board['items']] == [item_id]
    assert client.get('/api/permits?scope=board',
                      headers=performer).status_code == 403

    closed = _act(client, performer, item_id, 'close', text='Место убрано')
    item = closed.get_json()['item']
    assert item['status'] == 'closed'
    assert [e['action'] for e in item['events']] == ['created', 'approve', 'admit',
                                                    'close']
    assert _act(client, performer, item_id, 'comment', text='ещё').status_code == 409


def test_reject_stop_cancel(app, client, pushes):
    issuer, safety = _auth(app, _ISSUER), _auth(app, _SAFETY)
    first = _issue(client, issuer).get_json()['item']['id']
    assert _act(client, safety, first, 'reject').status_code == 400
    rejected = _act(client, safety, first, 'reject', text='Нет наблюдающего')
    assert rejected.get_json()['item']['reason'] == 'Нет наблюдающего'
    assert pushes[-1][0] == [_ISSUER]

    second = _issue(client, issuer, admitter_id='').get_json()['item']['id']
    _act(client, safety, second, 'approve')
    # Без допускающего допускает ответственный — здесь выдавший.
    assert _act(client, issuer, second, 'admit').get_json()['item']['status'] == 'open'
    stopped = _act(client, safety, second, 'stop', text='Нет огнетушителя')
    assert stopped.get_json()['item']['status'] == 'stopped'

    third = _issue(client, issuer).get_json()['item']['id']
    assert _act(client, _auth(app, _PERFORMER), third, 'cancel').status_code == 403
    assert _act(client, issuer, third, 'cancel').get_json()['item']['status'] \
        == 'cancelled'


def test_visibility_and_overdue(app, client, monkeypatch):
    item_id = _issue(client, _auth(app, _ISSUER)).get_json()['item']['id']
    assert client.get(f'/api/permits/{item_id}',
                      headers=_auth(app, _DRIVER)).status_code == 404
    mine = client.get('/api/permits', headers=_auth(app, _ADMITTER)).get_json()
    assert [i['id'] for i in mine['items']] == [item_id]
    assert mine['measures']['electrical'][0].startswith('Отключить')

    _act(client, _auth(app, _SAFETY), item_id, 'approve')
    _act(client, _auth(app, _ADMITTER), item_id, 'admit')
    monkeypatch.setattr(app_module, '_plant_now', lambda: _NOW + timedelta(hours=10))
    item = client.get(f'/api/permits/{item_id}',
                      headers=_auth(app, _ISSUER)).get_json()['item']
    assert item['overdue'] is True


def test_expired_permit_cannot_be_admitted(app, client, monkeypatch):
    item_id = _issue(client, _auth(app, _ISSUER)).get_json()['item']['id']
    _act(client, _auth(app, _SAFETY), item_id, 'approve')
    monkeypatch.setattr(app_module, '_plant_now', lambda: _NOW + timedelta(hours=10))
    answer = _act(client, _auth(app, _ADMITTER), item_id, 'admit')
    assert answer.status_code == 409 and answer.get_json()['error'] == 'expired'
