"""Инвентаризация: пересчёт по выгрузке 1С, штрихкоды, расхождения."""

from datetime import datetime

import pytest

import app as app_module
from inventory import InventoryBarcode, InventoryCount, InventoryLine
from models import db
from stock_balances import StockBalance

_KEEPER = '0000000009'      # зав. складом №1
_CLERK = '0000002152'       # кладовщик склада №1
_MASTER = '0000000082'      # мастер ОП — склад не считает
_UPLOADED = datetime(2030, 1, 14, 6, 0)


@pytest.fixture(autouse=True)
def clean(app):
    with app.app_context():
        rows = [('00-123', 'Электроды МР-3 ф3', 'кг', 55, 'Склад №1'),
                ('00-200', 'Перчатки х/б', 'пар', 85, 'Склад №1'),
                # Две партии одной позиции — одна строка пересчёта.
                ('00-300', 'Ветошь', 'кг', 4, 'Склад №1'),
                ('00-300', 'Ветошь', 'кг', 6, 'Склад №1'),
                ('00-123', 'Электроды МР-3 ф3', 'кг', 20, 'Склад №2')]
        for code, name, unit, quantity, warehouse in rows:
            db.session.add(StockBalance(
                code=code, name=name, name_key=name.lower(), unit=unit,
                quantity=quantity, warehouse=warehouse, uploaded_at=_UPLOADED))
        db.session.commit()
    yield
    with app.app_context():
        InventoryLine.query.delete()
        InventoryCount.query.delete()
        InventoryBarcode.query.delete()
        StockBalance.query.delete()
        db.session.commit()


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _start(app, client, warehouse='Склад №1', who=_KEEPER):
    return client.post('/api/inventory', headers=_auth(app, who),
                       json={'warehouse': warehouse})


def _scan(app, client, count_id, who=_KEEPER, **body):
    return client.post(f'/api/inventory/{count_id}/scan',
                       headers=_auth(app, who), json=body)


def _lines(app, client, count_id):
    answer = client.get(f'/api/inventory/{count_id}', headers=_auth(app, _KEEPER))
    return {line['code'] or line['name']: line
            for line in answer.get_json()['lines']}


def test_only_stock_staff(app, client):
    assert client.get('/api/inventory',
                      headers=_auth(app, _MASTER)).status_code == 403
    assert _start(app, client, who=_MASTER).status_code == 403
    answer = client.get('/api/inventory', headers=_auth(app, _CLERK)).get_json()
    assert [(w['name'], w['items']) for w in answer['warehouses']] == [
        ('Склад №1', 4), ('Склад №2', 1)]
    assert answer['counts'] == []


def test_start_takes_1c_balances(app, client):
    assert _start(app, client, warehouse='Склад №9').get_json()['error'] == \
        'no_warehouse'
    answer = _start(app, client)
    assert answer.status_code == 201, answer.get_json()
    count = answer.get_json()['count']
    assert (count['lines'], count['counted'], count['differences']) == (3, 0, 0)
    assert count['started_by']['id'] == _KEEPER

    again = _start(app, client, who=_CLERK)
    assert again.status_code == 409 and again.get_json()['id'] == count['id']
    assert _start(app, client, warehouse='Склад №2').status_code == 201

    lines = _lines(app, client, count['id'])
    assert [(k, v['expected']) for k, v in lines.items()] == [
        ('00-300', 10), ('00-200', 85), ('00-123', 55)]


def test_scan_adds_and_sets(app, client):
    count_id = _start(app, client).get_json()['count']['id']
    # Код без количества — только найти позицию.
    found = _scan(app, client, count_id, barcode='00-123').get_json()['line']
    assert found['name'] == 'Электроды МР-3 ф3' and found['counted'] is None

    assert _scan(app, client, count_id, barcode='00-123',
                 quantity=30).get_json()['line']['counted'] == 30
    # Второй кладовщик досчитал на соседнем стеллаже.
    line = _scan(app, client, count_id, who=_CLERK, barcode='00-123',
                 quantity='25,5').get_json()['line']
    assert line['counted'] == 55.5 and line['diff'] == 0.5
    assert _scan(app, client, count_id, barcode='00-123', quantity=55,
                 mode='set').get_json()['line']['diff'] == 0

    assert _scan(app, client, count_id, barcode='00-123',
                 quantity=-1).get_json()['error'] == 'bad_quantity'
    assert _scan(app, client, count_id).get_json()['error'] == 'code_required'
    assert _scan(app, client, count_id, who=_MASTER,
                 barcode='00-123', quantity=1).status_code == 403


def test_unknown_barcode_is_bound_once(app, client):
    count_id = _start(app, client).get_json()['count']['id']
    unknown = _scan(app, client, count_id, barcode='4601234567893')
    assert unknown.status_code == 404
    assert unknown.get_json() == {'message': 'Failure', 'error': 'unknown_code',
                                  'barcode': '4601234567893'}

    gloves = _lines(app, client, count_id)['00-200']['id']
    bound = _scan(app, client, count_id, barcode='4601234567893',
                  line_id=gloves, quantity=40).get_json()['line']
    assert bound['code'] == '00-200' and bound['counted'] == 40
    assert _scan(app, client, count_id, barcode='4601234567893',
                 quantity=5).get_json()['line']['counted'] == 45

    # Чужая строка — не в этом пересчёте.
    other = _start(app, client, warehouse='Склад №2').get_json()['count']['id']
    other_line = _lines(app, client, other)['00-123']['id']
    assert _scan(app, client, count_id, line_id=other_line,
                 quantity=1).status_code == 404


def test_extra_close_and_differences(app, client):
    count_id = _start(app, client).get_json()['count']['id']
    _scan(app, client, count_id, barcode='00-123', quantity=50)
    _scan(app, client, count_id, barcode='00-300', quantity=10)
    extra = client.post(f'/api/inventory/{count_id}/extra',
                        headers=_auth(app, _CLERK),
                        json={'name': ' Болт  М12 ', 'unit': 'шт',
                              'quantity': 7, 'barcode': '2000000000015'})
    assert extra.status_code == 201, extra.get_json()
    assert extra.get_json()['line']['diff'] == 7
    assert client.post(f'/api/inventory/{count_id}/extra',
                       headers=_auth(app, _CLERK),
                       json={'name': 'болт м12', 'unit': 'шт',
                             'quantity': 1}).status_code == 409
    assert _scan(app, client, count_id, barcode='2000000000015',
                 quantity=1).get_json()['line']['counted'] == 8

    removed = client.post(f'/api/inventory/{count_id}', headers=_auth(app, _KEEPER),
                          json={'action': 'remove'})
    assert removed.get_json()['error'] == 'has_counts'

    closed = client.post(f'/api/inventory/{count_id}', headers=_auth(app, _KEEPER),
                         json={'action': 'close'}).get_json()['count']
    assert closed['status'] == 'closed' and closed['closed_by']['id'] == _KEEPER
    # Электроды −5, болт +8, неподсчитанные перчатки — все 85 не нашлись.
    assert (closed['counted'], closed['differences']) == (3, 3)
    lines = _lines(app, client, count_id)
    assert {k: v['diff'] for k, v in lines.items()} == {
        'Болт М12': 8, '00-300': 0, '00-200': -85, '00-123': -5}
    assert lines['Болт М12']['extra'] is True

    assert _scan(app, client, count_id, barcode='00-123',
                 quantity=1).status_code == 409
    listed = client.get('/api/inventory', headers=_auth(app, _KEEPER)).get_json()
    assert [c['status'] for c in listed['counts']] == ['closed']


def test_remove_empty_count(app, client):
    count_id = _start(app, client).get_json()['count']['id']
    assert client.post(f'/api/inventory/{count_id}', headers=_auth(app, _CLERK),
                       json={'action': 'remove'}).status_code == 200
    with app.app_context():
        assert InventoryLine.query.count() == 0
    assert _start(app, client).status_code == 201
