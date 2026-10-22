"""Ознакомление с приказами: рассылка отделам, отметка, отчёт, напоминание."""

from datetime import datetime, timedelta

import pytest

import app as app_module
import orders_ack
from orders_ack import OrderAck, OrderDoc
from models import db, Employee, Notification

_CLERK = '0000002002'     # делопроизводитель — издаёт
_AO_HEAD = '0000002162'   # начальник АО — тоже издаёт
_HEAD = '0000000016'      # начальник ПЭО
_PEO = '0000001445'       # менеджер ПЭО
_OTHER = '0000002107'     # менеджер по учёту ТМЦ — другой отдел
_PEO_DEPT = 'Планово-экономический отдел (ПЭО)'


@pytest.fixture(autouse=True)
def clean(app):
    yield
    with app.app_context():
        OrderAck.query.delete()
        OrderDoc.query.delete()
        Notification.query.filter_by(kind='order').delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        assert kind == 'order'
        sent.append((sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _publish(client, headers, **fields):
    body = {'kind': 'order', 'number': '45-П', 'doc_date': '2026-10-20',
            'title': 'О режиме работы в праздничные дни',
            'text': 'Приказываю: 1. Установить режим…',
            'departments': [_PEO_DEPT], 'due_date': '2030-01-01'}
    body.update(fields)
    return client.post('/api/orders', json=body, headers=headers)


def _act(client, headers, order_id, action):
    return client.post(f'/api/orders/{order_id}', json={'action': action},
                       headers=headers)


def _peo_ids(app):
    with app.app_context():
        return sorted(e.employee_id for e in
                      Employee.query.filter_by(department=_PEO_DEPT)
                      if e.full_name)


def test_who_publishes(app):
    with app.app_context():
        get = lambda i: db.session.get(Employee, i)
        assert orders_ack.is_publisher(get(_CLERK))
        assert orders_ack.is_publisher(get(_AO_HEAD))
        assert not orders_ack.is_publisher(get(_HEAD))
        assert not orders_ack.is_publisher(get(_OTHER))


@pytest.mark.parametrize('fields, error', [
    ({'title': '  '}, 'title_required'),
    ({'text': ''}, 'text_required'),
    ({'kind': 'memo'}, 'bad_kind'),
    ({'link': 'ftp://x'}, 'bad_link'),
    ({'due_date': '2020-01-01'}, 'bad_date'),
    ({'doc_date': 'вчера'}, 'bad_date'),
    ({'departments': ['Нет такого отдела']}, 'bad_departments'),
    ({'departments': 'ПЭО'}, 'bad_departments'),
])
def test_bad_requests(app, client, pushes, fields, error):
    r = _publish(client, _auth(app, _CLERK), **fields)
    assert r.status_code == 400
    assert r.get_json()['error'] == error
    assert pushes == []


def test_only_publishers_publish(app, client, pushes):
    headers = _auth(app, _HEAD)
    assert _publish(client, headers).status_code == 403
    assert client.get('/api/orders?scope=published',
                      headers=headers).status_code == 403
    assert client.get('/api/orders/departments',
                      headers=headers).status_code == 403


def test_publish_ack_report(app, client, pushes):
    clerk = _auth(app, _CLERK)
    departments = client.get('/api/orders/departments', headers=clerk).get_json()
    assert _PEO_DEPT in [d['name'] for d in departments['departments']]

    r = _publish(client, clerk)
    assert r.status_code == 201, r.get_json()
    item = r.get_json()['item']
    peo = _peo_ids(app)
    assert item['total'] == len(peo) and item['acked'] == 0
    assert pushes == [(peo, 'Ознакомьтесь до 01.01',
                       'Приказ №45-П: О режиме работы в праздничные дни')]

    # Чужой отдел приказа не видит вовсе.
    other = _auth(app, _OTHER)
    assert client.get('/api/orders', headers=other).get_json()['items'] == []
    assert client.get(f'/api/orders/{item["id"]}',
                      headers=other).status_code == 404
    assert _act(client, other, item['id'], 'ack').status_code == 404

    peo_headers = _auth(app, _PEO)
    mine = client.get('/api/orders', headers=peo_headers).get_json()
    assert mine['pending'] == 1
    detail = client.get(f'/api/orders/{item["id"]}', headers=peo_headers).get_json()['item']
    assert detail['text'].startswith('Приказываю')
    assert detail['can_report'] is False and detail['can_remind'] is False

    r = _act(client, peo_headers, item['id'], 'ack')
    assert r.status_code == 200
    assert r.get_json()['item']['acked_at']
    assert _act(client, peo_headers, item['id'], 'ack').status_code == 409
    assert client.get('/api/orders', headers=peo_headers).get_json()['pending'] == 0

    report = client.get(f'/api/orders/{item["id"]}/report', headers=clerk).get_json()
    assert report['total'] == len(peo) and report['acked'] == 1
    # Неознакомленные — сверху.
    assert report['people'][-1]['id'] == _PEO
    assert all(p['acked_at'] is None for p in report['people'][:-1])

    published = client.get('/api/orders?scope=published', headers=clerk).get_json()
    assert published['items'][0]['acked'] == 1

    # Сотруднику без руководящей должности отчёт закрыт.
    assert client.get(f'/api/orders/{item["id"]}/report',
                      headers=peo_headers).status_code == 404


def test_manager_report_shows_own_people(app, client, pushes):
    item_id = _publish(client, _auth(app, _CLERK),
                       departments=[]).get_json()['item']['id']
    report = client.get(f'/api/orders/{item_id}/report',
                        headers=_auth(app, _HEAD)).get_json()
    ids = {p['id'] for p in report['people']}
    assert _PEO in ids and _OTHER not in ids


def test_remind_once_a_day_and_withdraw(app, client, pushes):
    clerk = _auth(app, _CLERK)
    item_id = _publish(client, clerk).get_json()['item']['id']
    _act(client, _auth(app, _PEO), item_id, 'ack')
    pushes.clear()

    assert _act(client, _auth(app, _HEAD), item_id, 'remind').status_code == 403
    r = _act(client, clerk, item_id, 'remind')
    left = [i for i in _peo_ids(app) if i != _PEO]
    assert r.get_json()['reminded'] == len(left)
    assert pushes == [(left, 'Напоминание: ознакомьтесь до 01.01',
                       'Приказ №45-П: О режиме работы в праздничные дни')]
    assert _act(client, clerk, item_id, 'remind').status_code == 429
    detail = client.get(f'/api/orders/{item_id}', headers=clerk).get_json()['item']
    assert detail['can_remind'] is False
    assert detail['can_withdraw'] is True
    assert detail['total'] == len(_peo_ids(app)) and detail['acked'] == 1

    with app.app_context():
        order = db.session.get(OrderDoc, item_id)
        order.reminded_at = datetime.utcnow() - timedelta(hours=21)
        db.session.commit()
    assert _act(client, clerk, item_id, 'remind').status_code == 200

    r = _act(client, clerk, item_id, 'withdraw')
    assert r.get_json()['item']['withdrawn'] is True
    peo_headers = _auth(app, _HEAD)
    assert client.get('/api/orders', headers=peo_headers).get_json()['items'] == []
    assert client.get(f'/api/orders/{item_id}', headers=peo_headers).status_code == 404
    assert _act(client, clerk, item_id, 'remind').status_code == 409
