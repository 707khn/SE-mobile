"""Заявки на ТМЦ со склада: позиции, «собрано», чего нет — снабжению."""

import pytest

import app as app_module
import stock_requests
from stock_requests import StockRequest, StockRequestEvent, StockRequestLine
from models import db, Notification

_AUTHOR = '0000002107'      # менеджер по учёту ТМЦ основного производства
_STRANGER = '0000002183'    # генеральный директор
_STORE1 = '0000000009'      # зав. складом №1
_STORE1_CLERK = '0000002152'  # кладовщик склада №1
_STORE2 = '0000000674'      # зав. складом №2
_SUPPLY_HEAD = '0000002198'  # руководитель ДМТО
_SUPPLY_DEPUTY = '0000001777'  # заместитель руководителя ДМТО
_SUPPLY = '0000000110'      # менеджер ДМТО


@pytest.fixture(autouse=True)
def clean(app):
    yield
    with app.app_context():
        StockRequestEvent.query.delete()
        StockRequestLine.query.delete()
        StockRequest.query.delete()
        Notification.query.filter_by(kind='stock').delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        assert kind == 'stock'
        sent.append((sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


_LINES = [{'name': 'Электроды МР-3 ф3', 'quantity': '5', 'unit': 'кг'},
          {'name': 'Перчатки х/б', 'quantity': 10, 'unit': 'пар'},
          {'name': 'Круг отрезной 230', 'quantity': '2,5', 'unit': 'шт'}]


def _create(client, headers, **fields):
    body = {'warehouse': 1, 'purpose': 'Участок 3, заказ 112', 'lines': _LINES}
    body.update(fields)
    return client.post('/api/stock-requests', json=body, headers=headers)


def _act(client, headers, item_id, action, **body):
    return client.post(f'/api/stock-requests/{item_id}',
                       json={'action': action, **body}, headers=headers)


def test_who_is_who(app):
    from models import Employee
    with app.app_context():
        get = lambda i: db.session.get(Employee, i)
        assert stock_requests.is_stock_staff(get(_STORE1))
        assert stock_requests.is_stock_staff(get(_STORE2))
        assert not stock_requests.is_stock_staff(get(_AUTHOR))
        assert stock_requests.warehouse_of(get(_STORE1).job_title) == 1
        assert stock_requests.warehouse_of(get(_STORE1_CLERK).job_title) == 1
        assert stock_requests.warehouse_of('Менеджер') is None
        assert stock_requests.is_supply_head(get(_SUPPLY_HEAD))
        assert stock_requests.is_supply_head(get(_SUPPLY_DEPUTY))
        assert not stock_requests.is_supply_head(get(_SUPPLY))


def test_create_goes_to_that_warehouse_only(app, client, pushes):
    r = _create(client, _auth(app, _AUTHOR))
    assert r.status_code == 201, r.get_json()
    item = r.get_json()['item']
    assert [l['quantity'] for l in item['lines']] == [5, 10, 2.5]
    ids, title, body = pushes[0]
    assert ids == sorted([_STORE1, _STORE1_CLERK])
    assert title == f'ТМЦ №{item["id"]}: Участок 3, заказ 112 (склад №1)'
    assert body.endswith('Электроды МР-3 ф3 — 5 кг; Перчатки х/б — 10 пар; '
                         'Круг отрезной 230 — 2,5 шт')


def test_unknown_warehouse_tells_everyone(app, client, pushes):
    _create(client, _auth(app, _AUTHOR), warehouse=None)
    ids = pushes[0][0]
    assert _STORE1 in ids and _STORE2 in ids


@pytest.mark.parametrize('fields, error', [
    ({'purpose': ''}, 'purpose_required'),
    ({'lines': []}, 'lines_required'),
    ({'warehouse': 7}, 'bad_warehouse'),
    ({'lines': [{'name': '', 'quantity': 1}]}, 'line_name_required'),
    ({'lines': [{'name': 'Болт', 'quantity': 0}]}, 'bad_quantity'),
    ({'lines': [{'name': 'Болт', 'quantity': 'много'}]}, 'bad_quantity'),
    ({'lines': [{'name': 'Болт', 'quantity': 1, 'unit': 'ведро'}]}, 'bad_unit'),
    ({'lines': [{'name': 'Болт', 'quantity': 1}] * 31}, 'too_many_lines'),
])
def test_bad_requests(app, client, pushes, fields, error):
    r = _create(client, _auth(app, _AUTHOR), **fields)
    assert r.status_code == 400
    assert r.get_json()['error'] == error
    assert not pushes


def test_ready_with_missing_goes_to_supply(app, client, pushes):
    author = _auth(app, _AUTHOR)
    store = _auth(app, _STORE1_CLERK)
    item = _create(client, author).get_json()['item']
    line_ids = [l['id'] for l in item['lines']]

    assert _act(client, author, item['id'], 'take').status_code == 403
    r = _act(client, store, item['id'], 'take')
    assert r.get_json()['item']['status'] == 'in_progress'
    assert pushes[-1][0] == [_AUTHOR]

    # Нет ничего — это не «собрано».
    assert _act(client, store, item['id'], 'ready',
                missing=line_ids).status_code == 409
    assert _act(client, store, item['id'], 'ready',
                missing=[999999]).get_json()['error'] == 'bad_missing'

    pushes.clear()
    r = _act(client, store, item['id'], 'ready', missing=[line_ids[2]])
    got = r.get_json()['item']
    assert got['status'] == 'ready'
    assert [l['missing'] for l in got['lines']] == [False, False, True]
    to_author = [p for p in pushes if p[0] == [_AUTHOR]][0]
    assert to_author[1] == f'ТМЦ №{item["id"]} собрана'
    assert 'склад №1' in to_author[2] and 'Нет: Круг отрезной 230' in to_author[2]
    to_supply = [p for p in pushes if p[0] != [_AUTHOR]][0]
    assert to_supply[0] == sorted([_SUPPLY_HEAD, _SUPPLY_DEPUTY])
    assert to_supply[1] == f'Нет на складе: ТМЦ №{item["id"]}'

    # Снабжение открывает заявку по ссылке, но ничего в ней не делает.
    supply = _auth(app, _SUPPLY_HEAD)
    assert client.get(f'/api/stock-requests/{item["id"]}',
                      headers=supply).get_json()['item']['can_act'] is False
    assert _act(client, supply, item['id'], 'issued').status_code == 403

    r = _act(client, store, item['id'], 'issued')
    assert r.get_json()['item']['status'] == 'issued'
    assert _act(client, store, item['id'], 'issued').status_code == 409
    events = [e['action'] for e in r.get_json()['item']['events']]
    assert events == ['created', 'take', 'ready', 'issued']


def test_reject_needs_reason_and_cancel_is_authors(app, client, pushes):
    author = _auth(app, _AUTHOR)
    store = _auth(app, _STORE2)
    item_id = _create(client, author).get_json()['item']['id']
    assert _act(client, store, item_id, 'reject').get_json()['error'] == 'comment_required'
    assert _act(client, store, item_id, 'cancel').status_code == 403
    assert _act(client, author, item_id, 'cancel').get_json()['item']['status'] == 'cancelled'


def test_queue_and_privacy(app, client, pushes):
    item_id = _create(client, _auth(app, _AUTHOR)).get_json()['item']['id']
    queue = client.get('/api/stock-requests?scope=queue',
                       headers=_auth(app, _STORE2)).get_json()
    assert queue['staff'] is True
    assert queue['my_warehouse'] == 2
    assert queue['open']['new'] == 1
    assert [i['id'] for i in queue['items']] == [item_id]

    stranger = _auth(app, _STRANGER)
    assert client.get('/api/stock-requests?scope=queue',
                      headers=stranger).status_code == 403
    assert client.get(f'/api/stock-requests/{item_id}',
                      headers=stranger).status_code == 404
    assert _act(client, stranger, item_id, 'comment', comment='?').status_code == 404


def test_feed_has_the_link(app, client):
    author = _auth(app, _AUTHOR)
    item_id = _create(client, author).get_json()['item']['id']
    _act(client, _auth(app, _STORE1), item_id, 'take')
    feed = client.get('/api/notifications', headers=author).get_json()
    mine = [n for n in feed['items'] if n['kind'] == 'stock']
    assert mine[0]['title'] == f'ТМЦ №{item_id} собирают'
    assert mine[0]['ref'] == str(item_id)
