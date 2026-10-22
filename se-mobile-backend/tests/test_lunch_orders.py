"""Предзаказ обеда: заказ до отсечки, снимок меню, итог для столовой."""

from datetime import date, datetime
from decimal import Decimal

import pytest

import app as app_module
from lunch_orders import LunchOrder, LunchOrderLine
from models import db, MenuDate, MenuItem

_WORKER = '0000000082'     # мастер ОП
_WORKER2 = '0000000150'
_TECHNOLOGIST = '0000000044'  # технолог столовой
_COOK = '0000002025'       # старший повар
_DAY = date(2030, 1, 15)


@pytest.fixture(autouse=True)
def menu(app, monkeypatch):
    monkeypatch.setattr(app_module, '_plant_now', lambda: datetime(2030, 1, 15, 9, 0))
    monkeypatch.setattr(app_module, '_plant_today', lambda: _DAY)
    with app.app_context():
        day = MenuDate(date=_DAY)
        db.session.add(day)
        db.session.flush()
        items = [MenuItem(menu_date_id=day.id, category='Первые блюда',
                          name='Борщ', price=Decimal('450'), portion='250'),
                 MenuItem(menu_date_id=day.id, category='Вторые блюда',
                          name='Плов', price=Decimal('900.50'), portion='300'),
                 MenuItem(menu_date_id=day.id, category='Напитки',
                          name='Компот', price=None, portion='200')]
        db.session.add_all(items)
        db.session.commit()
        ids = [i.id for i in items]
    yield ids
    with app.app_context():
        LunchOrderLine.query.delete()
        LunchOrder.query.delete()
        day = MenuDate.query.filter_by(date=_DAY).first()
        if day:
            db.session.delete(day)
        db.session.commit()


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _order(client, headers, items, day='2030-01-15', note=''):
    return client.put('/api/lunch-orders', headers=headers, json={
        'date': day, 'note': note,
        'items': [{'menu_item_id': i, 'quantity': q} for i, q in items]})


def test_order_and_change(app, client, menu):
    borsch, plov, compote = menu
    headers = _auth(app, _WORKER)
    day = client.get('/api/lunch-orders?date=2030-01-15', headers=headers).get_json()
    assert day['open'] is True and day['cutoff'] == '10:30'
    assert [m['name'] for m in day['menu']] == ['Борщ', 'Плов', 'Компот']
    assert day['order'] is None and day['canteen'] is False

    answer = _order(client, headers, [(borsch, 1), (plov, 2), (borsch, 1)],
                    note='Без лука')
    assert answer.status_code == 201, answer.get_json()
    order = answer.get_json()['order']
    assert [(l['name'], l['quantity']) for l in order['lines']] == [
        ('Борщ', 2), ('Плов', 2)]
    assert order['total'] == 2701.0 and order['note'] == 'Без лука'

    changed = _order(client, headers, [(compote, 1)])
    assert changed.status_code == 200
    assert changed.get_json()['order']['lines'][0]['price'] is None
    with app.app_context():
        assert LunchOrder.query.count() == 1


def test_menu_edit_keeps_ordered_dishes(app, client, menu):
    borsch, _, _ = menu
    _order(client, _auth(app, _WORKER), [(borsch, 1)])
    with app.app_context():
        MenuItem.query.filter_by(id=borsch).delete()
        db.session.commit()
    day = client.get('/api/lunch-orders?date=2030-01-15',
                     headers=_auth(app, _WORKER)).get_json()
    assert day['order']['lines'][0]['name'] == 'Борщ'


def test_cutoff_and_validation(app, client, menu, monkeypatch):
    borsch, _, _ = menu
    headers = _auth(app, _WORKER)
    assert _order(client, headers, []).get_json()['error'] == 'empty'
    assert _order(client, headers, [(999999, 1)]).get_json()['error'] == 'bad_items'
    assert _order(client, headers, [(borsch, 9)]).get_json()['error'] == 'bad_items'
    assert _order(client, headers, [(borsch, 1)],
                  day='2030-01-16').get_json()['error'] == 'no_menu'
    assert _order(client, headers, [(borsch, 1)],
                  day='2030-01-30').get_json()['error'] == 'closed'
    _order(client, headers, [(borsch, 1)])
    monkeypatch.setattr(app_module, '_plant_now', lambda: datetime(2030, 1, 15, 11, 0))
    assert _order(client, headers, [(borsch, 2)]).get_json()['error'] == 'closed'
    assert client.delete('/api/lunch-orders?date=2030-01-15',
                         headers=headers).status_code == 409


def test_cancel_before_cutoff(app, client, menu):
    borsch, _, _ = menu
    headers = _auth(app, _WORKER)
    _order(client, headers, [(borsch, 1)])
    assert client.delete('/api/lunch-orders?date=2030-01-15',
                         headers=headers).status_code == 200
    assert client.delete('/api/lunch-orders?date=2030-01-15',
                         headers=headers).status_code == 404


def test_canteen_summary_and_served(app, client, menu):
    borsch, plov, _ = menu
    _order(client, _auth(app, _WORKER), [(borsch, 1), (plov, 1)])
    _order(client, _auth(app, _WORKER2), [(plov, 2)])
    assert client.get('/api/lunch-orders/summary?date=2030-01-15',
                      headers=_auth(app, _WORKER)).status_code == 403
    cook = _auth(app, _COOK)
    summary = client.get('/api/lunch-orders/summary?date=2030-01-15',
                         headers=cook).get_json()
    assert summary['count'] == 2 and summary['served'] == 0
    assert {(d['name'], d['quantity']) for d in summary['dishes']} == {
        ('Борщ', 1), ('Плов', 3)}
    order_id = summary['orders'][0]['id']
    served = client.post(f'/api/lunch-orders/{order_id}/served', json={},
                         headers=_auth(app, _TECHNOLOGIST)).get_json()['order']
    assert served['served'] is True and served['employee']['name']
    again = client.get('/api/lunch-orders/summary?date=2030-01-15',
                       headers=cook).get_json()
    assert again['served'] == 1 and again['orders'][-1]['served'] is True
    # Выданный заказ не меняют.
    owner = summary['orders'][0]['employee']['id']
    assert _order(client, _auth(app, owner), [(borsch, 1)]).get_json()['error'] \
        == 'served'
