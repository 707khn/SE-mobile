"""«Где моя закупка»: этапы вперёд, ответственный, оповещения инициатору."""

from datetime import datetime, timedelta

import pytest

import app as app_module
import purchases
from purchases import Purchase, PurchaseEvent, PurchaseLine
from models import db, Employee, Notification

_AUTHOR = '0000001295'      # главный менеджер ПЭО — инициатор
_HEAD = '0000002198'        # руководитель ДМТО
_DEPUTY = '0000001777'      # заместитель руководителя ДМТО
_MANAGER = '0000000110'     # менеджер ДМТО
_MANAGER2 = '0000001982'    # менеджер ДМТО
_STRANGER = '0000002063'    # офис-менеджер приёмной


@pytest.fixture(autouse=True)
def clean(app):
    yield
    with app.app_context():
        PurchaseEvent.query.delete()
        PurchaseLine.query.delete()
        Purchase.query.delete()
        Notification.query.filter_by(kind='purchase').delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        assert kind == 'purchase'
        sent.append((sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _create(client, headers, **fields):
    body = {'purpose': 'Ремонт пресса К-2130',
            'lines': [{'name': 'Подшипник 6205', 'quantity': 4, 'unit': 'шт'}]}
    body.update(fields)
    return client.post('/api/purchases', json=body, headers=headers)


def _act(client, headers, item_id, action, **body):
    return client.post(f'/api/purchases/{item_id}',
                       json={'action': action, **body}, headers=headers)


def test_who_is_staff(app):
    with app.app_context():
        assert purchases.is_purchase_staff(db.session.get(Employee, _MANAGER))
        assert not purchases.is_purchase_staff(db.session.get(Employee, _AUTHOR))


@pytest.mark.parametrize('fields, error', [
    ({'purpose': ''}, 'purpose_required'),
    ({'lines': []}, 'lines_required'),
    ({'needed_by': '2020-01-01'}, 'bad_date'),
    ({'lines': [{'name': 'Болт', 'quantity': 'много'}]}, 'bad_quantity'),
])
def test_bad_requests(app, client, pushes, fields, error):
    r = _create(client, _auth(app, _AUTHOR), **fields)
    assert r.status_code == 400
    assert r.get_json()['error'] == error


def test_new_goes_to_heads_urgent_to_all(app, client, pushes):
    _create(client, _auth(app, _AUTHOR))
    assert pushes[-1][0] == sorted([_HEAD, _DEPUTY])
    _create(client, _auth(app, _AUTHOR), urgent=True)
    assert _MANAGER in pushes[-1][0] and _MANAGER2 in pushes[-1][0]
    assert pushes[-1][1].startswith('Срочная закупка №')


def test_stages_forward_and_author_sees_each(app, client, pushes):
    author = _auth(app, _AUTHOR)
    manager = _auth(app, _MANAGER)
    item_id = _create(client, author).get_json()['item']['id']

    assert _act(client, author, item_id, 'take').status_code == 403
    pushes.clear()
    r = _act(client, manager, item_id, 'take')
    got = r.get_json()['item']
    assert got['status'] == 'accepted'
    assert got['assignee']['id'] == _MANAGER
    assert pushes == [([_AUTHOR], f'Закупка №{item_id}: принята',
                       got['assignee']['name'])]

    r = _act(client, manager, item_id, 'stage', stage='contract',
             supplier='ТОО «Подшипник»')
    assert r.get_json()['item']['supplier'] == 'ТОО «Подшипник»'
    assert _act(client, manager, item_id, 'stage',
                stage='sourcing').get_json()['error'] == 'stage_back'

    pushes.clear()
    r = _act(client, manager, item_id, 'stage', stage='in_transit',
             eta='2030-01-20', comment='Отгрузили транспортной')
    assert r.get_json()['item']['eta'] == '2030-01-20'
    assert pushes == [([_AUTHOR], f'Закупка №{item_id}: в пути',
                       'ожидается 20.01; ТОО «Подшипник»; Отгрузили транспортной')]

    r = _act(client, manager, item_id, 'stage', stage='delivered')
    got = r.get_json()['item']
    assert got['status'] == 'delivered'
    assert got['can_act'] is False
    assert [e['stage'] for e in got['events']] == [
        'new', 'accepted', 'contract', 'in_transit', 'delivered']
    assert _act(client, manager, item_id, 'comment', comment='?').status_code == 200
    assert _act(client, manager, item_id, 'reject',
                comment='x').get_json()['error'] == 'closed'


def test_head_assigns(app, client, pushes):
    item_id = _create(client, _auth(app, _AUTHOR)).get_json()['item']['id']
    assert _act(client, _auth(app, _MANAGER), item_id, 'assign',
                assignee_id=_MANAGER2).status_code == 403
    head = _auth(app, _HEAD)
    assert _act(client, head, item_id, 'assign',
                assignee_id=_AUTHOR).get_json()['error'] == 'bad_assignee'
    pushes.clear()
    r = _act(client, head, item_id, 'assign', assignee_id=_MANAGER2)
    assert r.get_json()['item']['assignee']['id'] == _MANAGER2
    assert [p[0] for p in pushes] == [[_AUTHOR], [_MANAGER2]]
    staff = client.get('/api/purchases/staff', headers=head).get_json()['people']
    assert _MANAGER in [p['id'] for p in staff]


def test_reject_cancel_and_stale(app, client, pushes):
    author = _auth(app, _AUTHOR)
    manager = _auth(app, _MANAGER)
    first = _create(client, author).get_json()['item']['id']
    assert _act(client, manager, first, 'reject').get_json()['error'] == 'comment_required'
    assert _act(client, manager, first, 'reject',
                comment='Есть на складе №2').get_json()['item']['reason'] == 'Есть на складе №2'

    second = _create(client, author).get_json()['item']['id']
    with app.app_context():
        db.session.get(Purchase, second).stage_since = datetime.utcnow() - timedelta(days=8)
        db.session.commit()
    queue = client.get('/api/purchases?scope=queue', headers=manager).get_json()
    by_id = {i['id']: i for i in queue['items']}
    assert by_id[second]['stale'] is True
    assert queue['open']['new'] == 1

    assert _act(client, manager, second, 'cancel').status_code == 403
    assert _act(client, author, second, 'cancel').get_json()['item']['status'] == 'cancelled'


def test_privacy(app, client, pushes):
    item_id = _create(client, _auth(app, _AUTHOR)).get_json()['item']['id']
    stranger = _auth(app, _STRANGER)
    assert client.get(f'/api/purchases/{item_id}', headers=stranger).status_code == 404
    assert client.get('/api/purchases?scope=queue', headers=stranger).status_code == 403
    # Никто ещё не взял — вопрос инициатора видят те, кто распределяет.
    pushes.clear()
    _act(client, _auth(app, _AUTHOR), item_id, 'comment', comment='Когда?')
    assert pushes[0][0] == sorted([_HEAD, _DEPUTY])
