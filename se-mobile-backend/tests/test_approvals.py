"""Лист согласования: маршрут, согласование с замечаниями, возврат,
повтор с того, кто вернул, напоминание."""

from datetime import datetime, timedelta

import pytest

import app as app_module
import approvals
from approvals import Approval, ApprovalEvent, ApprovalStep
from models import db, Notification

_AUTHOR = '0000001582'      # главный менеджер ДМТО
_DMTO = '0000002198'        # руководитель ДМТО
_LEGAL = '0000000450'       # начальник юридического отдела
_PEO = '0000000016'         # начальник ПЭО
_CHIEF_ACC = '0000001298'   # главный бухгалтер
_FIN = '0000002184'         # заместитель ГД по экономике и финансам
_GD = '0000002183'          # генеральный директор
_PEO_CLERK = '0000001445'   # менеджер ПЭО
_STRANGER = '0000002063'    # офис-менеджер приёмной


@pytest.fixture(autouse=True)
def clean(app):
    yield
    with app.app_context():
        ApprovalEvent.query.delete()
        ApprovalStep.query.delete()
        Approval.query.delete()
        Notification.query.filter_by(kind='approval').delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        assert kind == 'approval'
        sent.append((sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _create(client, headers, **fields):
    body = {'kind': 'contract', 'title': 'Договор поставки металлопроката',
            'doc_number': 'Д-245/26', 'counterparty': 'ТОО «Металл»',
            'amount': '12 500 000 тг', 'summary': 'Поставка листа 3 мм, 20 т',
            'route': [_DMTO, _LEGAL, _PEO]}
    body.update(fields)
    return client.post('/api/approvals', json=body, headers=headers)


def _act(client, headers, item_id, action, **body):
    return client.post(f'/api/approvals/{item_id}',
                       json={'action': action, **body}, headers=headers)


def test_suggested_routes(app, client):
    r = client.get('/api/approvals/route?kind=contract',
                   headers=_auth(app, _AUTHOR))
    assert [p['id'] for p in r.get_json()['steps']] == [
        _DMTO, _LEGAL, _PEO, _CHIEF_ACC, _FIN]
    # Себя в маршрут не ставим: руководителю ДМТО его же не предлагают.
    r = client.get('/api/approvals/route?kind=contract',
                   headers=_auth(app, _DMTO))
    assert _DMTO not in [p['id'] for p in r.get_json()['steps']]
    r = client.get('/api/approvals/route?kind=memo',
                   headers=_auth(app, _PEO_CLERK))
    assert [p['id'] for p in r.get_json()['steps']] == [_PEO, _GD]
    assert client.get('/api/approvals/route?kind=x',
                      headers=_auth(app, _AUTHOR)).status_code == 400


def test_people_search(app, client):
    r = client.get('/api/approvals/people?q=главный бухгалтер',
                   headers=_auth(app, _AUTHOR))
    assert _CHIEF_ACC in [p['id'] for p in r.get_json()['people']]
    r = client.get('/api/approvals/people?q=а', headers=_auth(app, _AUTHOR))
    assert r.get_json()['people'] == []


@pytest.mark.parametrize('fields, error', [
    ({'title': ''}, 'title_required'),
    ({'summary': ''}, 'summary_required'),
    ({'kind': 'order'}, 'bad_kind'),
    ({'route': []}, 'route_required'),
    ({'route': [_DMTO, _DMTO]}, 'route_repeats'),
    ({'route': [_AUTHOR]}, 'route_self'),
    ({'route': ['9999999999']}, 'route_unknown'),
    ({'route': [_DMTO, _LEGAL, _PEO, _CHIEF_ACC, _FIN, _GD, _PEO_CLERK,
                _STRANGER, '0000001777']}, 'route_too_long'),
])
def test_bad_requests(app, client, pushes, fields, error):
    r = _create(client, _auth(app, _AUTHOR), **fields)
    assert r.status_code == 400
    assert r.get_json()['error'] == error
    assert not pushes


def test_route_goes_step_by_step(app, client, pushes):
    author = _auth(app, _AUTHOR)
    r = _create(client, author)
    assert r.status_code == 201, r.get_json()
    item = r.get_json()['item']
    assert item['current']['id'] == _DMTO
    assert pushes[-1][0] == [_DMTO]
    assert pushes[-1][1] == 'На согласование: Договор поставки металлопроката (Д-245/26)'

    # Не его очередь — юрист пока не согласует.
    assert _act(client, _auth(app, _LEGAL), item['id'], 'approve').status_code == 403
    todo = client.get('/api/approvals', headers=_auth(app, _DMTO)).get_json()
    assert todo['todo'] == 1 and todo['items'][0]['my_turn'] is True
    assert client.get('/api/approvals', headers=_auth(app, _LEGAL)).get_json()['todo'] == 0

    pushes.clear()
    r = _act(client, _auth(app, _DMTO), item['id'], 'approve')
    assert r.get_json()['item']['current']['id'] == _LEGAL
    assert pushes == [([_LEGAL], 'На согласование: Договор поставки '
                       'металлопроката (Д-245/26)',
                       f'Лист №{item["id"]}, согласовал '
                       + r.get_json()['item']['steps'][0]['person']['name'])]

    # Замечания при согласовании — автору сразу, документ идёт дальше.
    pushes.clear()
    r = _act(client, _auth(app, _LEGAL), item['id'], 'approve',
             comment='Пункт 5.2 — пеня 0,1%')
    got = r.get_json()['item']
    assert got['current']['id'] == _PEO
    assert got['steps'][1]['comment'] == 'Пункт 5.2 — пеня 0,1%'
    assert [p[0] for p in pushes] == [[_PEO], [_AUTHOR]]

    pushes.clear()
    r = _act(client, _auth(app, _PEO), item['id'], 'approve')
    got = r.get_json()['item']
    assert got['status'] == 'approved'
    assert got['current'] is None
    assert pushes == [([_AUTHOR], f'Лист №{item["id"]} согласован',
                       'Договор поставки металлопроката (Д-245/26)')]
    assert _act(client, _auth(app, _PEO), item['id'], 'approve').status_code == 409


def test_return_and_resubmit_from_the_one_who_returned(app, client, pushes):
    author = _auth(app, _AUTHOR)
    item_id = _create(client, author).get_json()['item']['id']
    _act(client, _auth(app, _DMTO), item_id, 'approve')
    legal = _auth(app, _LEGAL)
    assert _act(client, legal, item_id, 'return').get_json()['error'] == 'comment_required'
    r = _act(client, legal, item_id, 'return', comment='Нет протокола разногласий')
    assert r.get_json()['item']['status'] == 'returned'
    assert pushes[-1][0] == [_AUTHOR]
    assert _act(client, author, item_id, 'remind').status_code == 409

    assert _act(client, legal, item_id, 'resubmit').status_code == 403
    r = _act(client, author, item_id, 'resubmit', comment='Приложил протокол')
    got = r.get_json()['item']
    assert got['status'] == 'on_route'
    assert got['current']['id'] == _LEGAL
    assert [s['decision'] for s in got['steps']] == ['approved', 'pending', 'pending']
    assert pushes[-1] == ([_LEGAL], 'Снова на согласовании: Договор поставки '
                          'металлопроката (Д-245/26)', 'Приложил протокол')
    actions = [e['action'] for e in got['events']]
    assert actions == ['created', 'approve', 'return', 'resubmit']


def test_remind_once_in_a_while(app, client, pushes):
    author = _auth(app, _AUTHOR)
    item_id = _create(client, author).get_json()['item']['id']
    with app.app_context():
        item = db.session.get(Approval, item_id)
        item.step_since = datetime.utcnow() - timedelta(days=3)
        db.session.commit()
    pushes.clear()
    r = _act(client, author, item_id, 'remind')
    assert r.get_json()['item']['can_remind'] is False
    assert pushes == [([_DMTO], 'Напоминание: Договор поставки '
                       'металлопроката (Д-245/26)',
                       f'Лист №{item_id} ждёт вашего согласования. Лежит 3 дн.')]
    assert _act(client, author, item_id, 'remind').get_json()['error'] == 'too_soon'
    assert _act(client, _auth(app, _DMTO), item_id, 'remind').status_code == 403


def test_privacy_and_cancel(app, client, pushes):
    author = _auth(app, _AUTHOR)
    item_id = _create(client, author).get_json()['item']['id']
    stranger = _auth(app, _STRANGER)
    assert client.get(f'/api/approvals/{item_id}', headers=stranger).status_code == 404
    assert _act(client, stranger, item_id, 'comment', comment='?').status_code == 404
    assert client.get('/api/approvals', headers=stranger).get_json()['items'] == []
    # Согласующий дальше по маршруту видит лист заранее.
    assert client.get(f'/api/approvals/{item_id}',
                      headers=_auth(app, _PEO)).status_code == 200
    assert _act(client, _auth(app, _DMTO), item_id, 'cancel').status_code == 403
    r = _act(client, author, item_id, 'cancel')
    assert r.get_json()['item']['status'] == 'cancelled'


def test_feed_has_the_link(app, client):
    item_id = _create(client, _auth(app, _AUTHOR)).get_json()['item']['id']
    feed = client.get('/api/notifications', headers=_auth(app, _DMTO)).get_json()
    mine = [n for n in feed['items'] if n['kind'] == 'approval']
    assert mine[0]['ref'] == str(item_id)
