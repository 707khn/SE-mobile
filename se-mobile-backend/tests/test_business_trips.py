"""Командировка: согласование, аванс, отчёт, остаток."""

from datetime import date

import pytest

import app as app_module
from business_trips import (BusinessTrip, BusinessTripEvent, TripExpense,
                            may_approve)
from models import db, Employee, Notification

_ENGINEER = '0000001674'    # инженер-технолог ТО
_TO_HEAD = '0000001520'     # начальник ТО
_TO_DEPUTY = '0000001856'   # заместитель начальника ТО
_OP_HEAD = '0000001781'     # начальник ОП — чужой отдел
_GD = '0000002183'          # генеральный директор
_ACCOUNTANT = '0000000137'  # бухгалтер
_DMTO_MANAGER = '0000001582'  # главный менеджер ДМТО — не руководитель
_TODAY = date(2030, 1, 15)


@pytest.fixture(autouse=True)
def clean(app, monkeypatch):
    monkeypatch.setattr(app_module, '_plant_today', lambda: _TODAY)
    yield
    with app.app_context():
        TripExpense.query.delete()
        BusinessTripEvent.query.delete()
        BusinessTrip.query.delete()
        Notification.query.filter_by(kind='trip').delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        assert kind == 'trip'
        sent.append((sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _ask(client, headers, **fields):
    body = {'destination': 'Астана', 'organization': 'Заказчик',
            'purpose': 'Сдача документации', 'date_from': '2030-01-20',
            'date_to': '2030-01-22', 'transport': 'train', 'advance': '150 000'}
    body.update(fields)
    return client.post('/api/trips', json=body, headers=headers)


def _act(client, headers, item_id, action, **body):
    return client.post(f'/api/trips/{item_id}', json={'action': action, **body},
                       headers=headers)


def test_who_approves(app):
    with app.app_context():
        get = lambda i: db.session.get(Employee, i)
        assert may_approve(get(_TO_HEAD), get(_ENGINEER))
        assert may_approve(get(_TO_DEPUTY), get(_ENGINEER))
        assert not may_approve(get(_OP_HEAD), get(_ENGINEER))
        assert not may_approve(get(_ENGINEER), get(_ENGINEER))
        # Руководителю отдела — руководство, а не свой заместитель.
        assert not may_approve(get(_TO_DEPUTY), get(_TO_HEAD))
        assert may_approve(get(_GD), get(_TO_HEAD))


def test_request_goes_to_department_head(app, client, pushes):
    answer = _ask(client, _auth(app, _ENGINEER))
    assert answer.status_code == 201, answer.get_json()
    item = answer.get_json()['item']
    assert item['days'] == 3 and item['advance_requested'] == 150000
    [(ids, title, body)] = pushes
    assert _TO_HEAD in ids and _TO_DEPUTY in ids and _OP_HEAD not in ids
    assert _GD not in ids
    assert title == 'Командировка на согласование: Астана'
    assert '150' not in body

    pushes.clear()
    _ask(client, _auth(app, _TO_HEAD))
    assert _GD in pushes[0][0] and _TO_DEPUTY not in pushes[0][0]


def test_validation(app, client):
    headers = _auth(app, _ENGINEER)
    assert _ask(client, headers, destination='').get_json()['error'] \
        == 'destination_required'
    assert _ask(client, headers, date_to='2030-01-19').get_json()['error'] \
        == 'bad_dates'
    assert _ask(client, headers, date_from='2029-11-01',
                date_to='2029-11-03').get_json()['error'] == 'too_old'
    assert _ask(client, headers, transport='ufo').get_json()['error'] \
        == 'bad_transport'
    assert _ask(client, headers, advance='много').get_json()['error'] == 'bad_amount'


def test_full_path_with_balance(app, client, pushes, monkeypatch):
    engineer, head = _auth(app, _ENGINEER), _auth(app, _TO_HEAD)
    accountant = _auth(app, _ACCOUNTANT)
    item_id = _ask(client, engineer).get_json()['item']['id']

    assert _act(client, _auth(app, _OP_HEAD), item_id, 'approve').status_code == 404
    approve = client.get('/api/trips?scope=approve', headers=head).get_json()
    assert [i['id'] for i in approve['items']] == [item_id]
    assert _act(client, head, item_id, 'approve').get_json()['item']['status'] \
        == 'approved'
    assert _ACCOUNTANT in pushes[-1][0]

    queue = client.get('/api/trips?scope=accounting', headers=accountant).get_json()
    assert [i['id'] for i in queue['items']] == [item_id]
    assert _act(client, accountant, item_id, 'advance').get_json()['error'] \
        == 'bad_amount'
    advanced = _act(client, accountant, item_id, 'advance', amount=150000)
    assert advanced.get_json()['item']['status'] == 'advanced'
    assert 'Сумма' in pushes[-1][2]

    assert _act(client, engineer, item_id, 'report').get_json()['error'] \
        == 'not_started'
    monkeypatch.setattr(app_module, '_plant_today', lambda: date(2030, 1, 23))
    assert _act(client, engineer, item_id, 'report').get_json()['error'] \
        == 'no_expenses'
    assert _act(client, engineer, item_id, 'expense_add', category='bar',
                amount=1).get_json()['error'] == 'bad_category'
    _act(client, engineer, item_id, 'expense_add', category='travel',
         amount='24 500', document='Билет 0012')
    _act(client, engineer, item_id, 'expense_add', category='lodging', amount=60000)
    item = _act(client, engineer, item_id, 'expense_add', category='other',
                amount=999).get_json()['item']
    item = _act(client, engineer, item_id, 'expense_remove',
                expense_id=item['expenses'][-1]['id']).get_json()['item']
    assert item['spent'] == 84500 and item['balance'] == 65500

    assert _act(client, engineer, item_id, 'report').get_json()['item']['status'] \
        == 'reported'
    assert _act(client, engineer, item_id, 'expense_add', category='other',
                amount=5).status_code == 409
    assert _act(client, accountant, item_id, 'send_back').status_code == 400
    back = _act(client, accountant, item_id, 'send_back',
                text='Нет счёта гостиницы').get_json()['item']
    assert back['status'] == 'advanced' and back['note'] == 'Нет счёта гостиницы'
    _act(client, engineer, item_id, 'report')
    closed = _act(client, accountant, item_id, 'accept').get_json()['item']
    assert closed['status'] == 'closed'
    assert [e['action'] for e in closed['events']] == [
        'created', 'approve', 'advance', 'report', 'send_back', 'report', 'accept']


def test_reject_and_cancel(app, client):
    engineer, head = _auth(app, _ENGINEER), _auth(app, _TO_HEAD)
    first = _ask(client, engineer).get_json()['item']['id']
    assert _act(client, head, first, 'reject').status_code == 400
    assert _act(client, head, first, 'reject', text='Не сейчас').get_json()[
        'item']['status'] == 'rejected'
    second = _ask(client, engineer).get_json()['item']['id']
    assert _act(client, head, second, 'cancel').status_code == 403
    assert _act(client, engineer, second, 'cancel').get_json()['item']['status'] \
        == 'cancelled'
    assert client.get(f'/api/trips/{second}',
                      headers=_auth(app, _DMTO_MANAGER)).status_code == 404


def test_accountant_does_not_handle_own_trip(app, client, pushes):
    # Аванс себе и приём своего отчёта — как согласовать себе поездку.
    own = _auth(app, _ACCOUNTANT)
    r = _ask(client, own)
    assert r.status_code == 201, r.get_json()
    item_id = r.get_json()['item']['id']
    assert _act(client, _auth(app, _GD), item_id, 'approve').status_code == 200
    item = client.get(f'/api/trips/{item_id}', headers=own).get_json()['item']
    assert item['can_advance'] is False
    assert _act(client, own, item_id, 'advance', amount=150000).status_code == 403
