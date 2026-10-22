"""Предъявление продукции: ОТК → ВП → принято, возврат и повтор."""

import pytest

import app as app_module
import inspections
from inspections import Inspection, InspectionEvent
from models import db, Employee, Notification

_MASTER = '0000000082'      # мастер ОП
_OTHER_MASTER = '0000000150'  # другой мастер ОП
_OTK = '0000000176'         # контрольный мастер
_OTK_CHIEF = '0000000910'   # начальник ОТК
_OP_CHIEF = '0000001781'    # начальник ОП
_VP = '0000002183'          # на время проверки — военпред (через VP_STAFF)


@pytest.fixture(autouse=True)
def clean(app, monkeypatch):
    monkeypatch.setenv('VP_STAFF', _VP)
    yield
    with app.app_context():
        InspectionEvent.query.delete()
        Inspection.query.delete()
        Notification.query.filter_by(kind='inspection').delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        assert kind == 'inspection'
        sent.append((sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _create(client, headers, **fields):
    body = {'product': 'Корпус 12-04', 'quantity': '20', 'order_no': '112',
            'place': 'Участок 3', 'needs_vp': True}
    body.update(fields)
    return client.post('/api/inspections', json=body, headers=headers)


def _act(client, headers, item_id, action, comment=None):
    body = {'action': action}
    if comment:
        body['comment'] = comment
    return client.post(f'/api/inspections/{item_id}', json=body, headers=headers)


def _queue(client, headers):
    return client.get('/api/inspections?scope=queue', headers=headers)


def test_roles(app):
    with app.app_context():
        get = lambda i: db.session.get(Employee, i)
        assert inspections.is_otk(get(_OTK)) and inspections.is_otk(get(_OTK_CHIEF))
        assert not inspections.is_otk(get(_MASTER))
        assert inspections.is_vp(get(_VP))
        assert inspections.is_production_head(get(_OP_CHIEF))
        assert not inspections.is_production_head(get(_MASTER))


def test_whole_way_through_otk_and_vp(app, client, pushes):
    master, otk, vp = _auth(app, _MASTER), _auth(app, _OTK), _auth(app, _VP)
    r = _create(client, master)
    assert r.status_code == 201, r.get_json()
    item = r.get_json()['item']
    assert item['status'] == 'waiting_otk' and item['quantity'] == 20
    assert _OTK in pushes[0][0] and _OTK_CHIEF in pushes[0][0]
    assert pushes[0][1] == f'Предъявление №{item["id"]}: Корпус 12-04, 20 шт, заказ 112'

    # ВП до ОТК партию не видит.
    assert client.get(f'/api/inspections/{item["id"]}', headers=vp).status_code == 404
    assert _queue(client, vp).get_json()['items'] == []
    # Мастер сам у себя не принимает.
    assert _act(client, master, item['id'], 'accept').status_code == 403

    r = _act(client, otk, item['id'], 'take')
    assert r.get_json()['item']['status'] == 'checking_otk'
    assert r.get_json()['item']['can_act'] is True
    assert _act(client, otk, item['id'], 'take').get_json()['error'] == 'already_taken'

    r = _act(client, otk, item['id'], 'accept')
    assert r.get_json()['item']['status'] == 'waiting_vp'
    assert r.get_json()['item']['can_act'] is False
    told_vp = [p for p in pushes if _VP in p[0]]
    assert told_vp and 'Принято ОТК' in told_vp[-1][2]

    assert [i['id'] for i in _queue(client, vp).get_json()['items']] == [item['id']]
    assert _act(client, otk, item['id'], 'accept').status_code == 403
    r = _act(client, vp, item['id'], 'accept')
    got = r.get_json()['item']
    assert got['status'] == 'accepted' and got['closed_at']
    assert [(e['action'], e['stage']) for e in got['events']] == [
        ('created', 'otk'), ('take', 'otk'), ('accept', 'otk'), ('accept', 'vp')]


def test_without_vp_otk_closes_it(app, client, pushes):
    item_id = _create(client, _auth(app, _MASTER), needs_vp=False).get_json()['item']['id']
    r = _act(client, _auth(app, _OTK_CHIEF), item_id, 'accept')
    assert r.get_json()['item']['status'] == 'accepted'
    assert not [p for p in pushes if _VP in p[0]]


def test_return_and_resubmit_goes_back_to_otk(app, client, pushes):
    master, otk, vp = _auth(app, _MASTER), _auth(app, _OTK), _auth(app, _VP)
    item_id = _create(client, master).get_json()['item']['id']
    _act(client, otk, item_id, 'accept')
    assert _act(client, vp, item_id, 'return').get_json()['error'] == 'comment_required'
    r = _act(client, vp, item_id, 'return', 'Нет маркировки')
    got = r.get_json()['item']
    assert got['status'] == 'returned'
    assert got['return_reason'] == 'Нет маркировки' and got['returns'] == 1
    # И мастеру, и контрольному мастеру, который принял.
    assert any(p[0] == [_MASTER] for p in pushes[-2:])
    assert any(p[0] == [_OTK] for p in pushes[-2:])

    assert _act(client, otk, item_id, 'resubmit').status_code == 403
    r = _act(client, master, item_id, 'resubmit', 'Нанесли маркировку')
    assert r.get_json()['item']['status'] == 'waiting_otk'
    assert pushes[-1][0] == [_OTK]
    assert _act(client, master, item_id, 'resubmit').get_json()['error'] == 'not_returned'


def test_who_sees_what(app, client, pushes):
    item_id = _create(client, _auth(app, _MASTER)).get_json()['item']['id']
    other = _auth(app, _OTHER_MASTER)
    assert client.get(f'/api/inspections/{item_id}', headers=other).status_code == 404
    assert _queue(client, other).status_code == 403

    chief = _queue(client, _auth(app, _OP_CHIEF)).get_json()
    assert chief['roles']['watch'] is True and chief['roles']['otk'] is False
    assert chief['open']['waiting_otk'] == 1
    assert _act(client, _auth(app, _OP_CHIEF), item_id, 'accept').status_code == 403


@pytest.mark.parametrize('fields, error', [
    ({'product': ''}, 'product_required'),
    ({'quantity': '0'}, 'bad_quantity'),
    ({'quantity': 'много'}, 'bad_quantity'),
    ({'place': ''}, 'place_required'),
])
def test_bad_fields(app, client, pushes, fields, error):
    r = _create(client, _auth(app, _MASTER), **fields)
    assert r.status_code == 400 and r.get_json()['error'] == error


def test_cancel_by_author_only(app, client, pushes):
    master = _auth(app, _MASTER)
    item_id = _create(client, master).get_json()['item']['id']
    assert _act(client, _auth(app, _OTK), item_id, 'cancel').status_code == 403
    assert _act(client, master, item_id, 'cancel').get_json()['item']['status'] == 'cancelled'
    assert _act(client, _auth(app, _OTK), item_id, 'take').get_json()['error'] == 'closed'
