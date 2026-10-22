"""Материальный пропуск: согласование, выпуск через КПП в свой день, код."""

from datetime import timedelta

import pytest

import app as app_module
import material_passes
from material_passes import MaterialPass, MaterialPassEvent, MaterialPassLine
from models import db, Employee, Notification

_AUTHOR = '0000002152'      # кладовщик склада №1
_APPROVER = '0000002198'    # руководитель ДМТО
_GD = '0000002183'          # генеральный директор
_GUARD = '0000001542'       # специалист СБ
_GUARD_HEAD = '0000001490'  # начальник СБ
_SAFETY = '0000001972'      # инженер по БиОТ — не охрана
_STRANGER = '0000002063'    # офис-менеджер приёмной


@pytest.fixture(autouse=True)
def clean(app):
    yield
    with app.app_context():
        MaterialPassEvent.query.delete()
        MaterialPassLine.query.delete()
        MaterialPass.query.delete()
        Notification.query.filter_by(kind='pass').delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        assert kind == 'pass'
        sent.append((sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _today(app):
    with app.app_context():
        return app_module._plant_today()


def _create(app, client, headers, **fields):
    body = {'purpose': 'В ремонт ТОО «Сервис», договор 12',
            'carrier': 'Водитель Тестов', 'vehicle': '123abc02',
            'exit_date': _today(app).isoformat(),
            'lines': [{'name': 'Насос К-80', 'quantity': 1, 'unit': 'шт'},
                      {'name': 'Кабель ВВГ 3×2,5', 'quantity': '25,5', 'unit': 'м'}]}
    body.update(fields)
    return client.post('/api/material-passes', json=body, headers=headers)


def _act(client, headers, item_id, action, **body):
    return client.post(f'/api/material-passes/{item_id}',
                       json={'action': action, **body}, headers=headers)


def test_who_is_who(app):
    with app.app_context():
        get = lambda i: db.session.get(Employee, i)
        assert material_passes.is_approver(get(_APPROVER))
        assert material_passes.is_approver(get(_GD))
        assert not material_passes.is_approver(get(_AUTHOR))
        assert material_passes.is_guard(get(_GUARD))
        assert not material_passes.is_guard(get(_SAFETY))


@pytest.mark.parametrize('fields, error', [
    ({'purpose': ''}, 'purpose_required'),
    ({'carrier': ''}, 'carrier_required'),
    ({'exit_date': 'завтра'}, 'bad_date'),
    ({'lines': []}, 'lines_required'),
    ({'lines': [{'name': 'Болт', 'quantity': 0}]}, 'bad_quantity'),
    ({'lines': [{'name': 'Болт', 'quantity': 1, 'unit': 'ведро'}]}, 'bad_unit'),
])
def test_bad_requests(app, client, pushes, fields, error):
    r = _create(app, client, _auth(app, _AUTHOR), **fields)
    assert r.status_code == 400
    assert r.get_json()['error'] == error
    assert not pushes


def test_date_window(app, client, pushes):
    author = _auth(app, _AUTHOR)
    today = _today(app)
    assert _create(app, client, author, exit_date=(today - timedelta(days=1))
                   .isoformat()).get_json()['error'] == 'bad_date'
    assert _create(app, client, author, exit_date=(today + timedelta(days=15))
                   .isoformat()).get_json()['error'] == 'bad_date'
    assert _create(app, client, author, exit_date=(today + timedelta(days=14))
                   .isoformat()).status_code == 201


def test_approve_then_release_at_gate(app, client, pushes):
    author = _auth(app, _AUTHOR)
    r = _create(app, client, author)
    assert r.status_code == 201, r.get_json()
    item = r.get_json()['item']
    assert len(item['code']) == 4 and item['code'].isdigit()
    assert item['vehicle'] == '123ABC02'
    assert [l['quantity'] for l in item['lines']] == [1, 25.5]
    ids, title, body = pushes[0]
    assert _APPROVER in ids and _GD in ids and _AUTHOR not in ids
    assert title.startswith(f'Пропуск №{item["id"]} на ')
    assert body.endswith('Насос К-80 — 1 шт; Кабель ВВГ 3×2,5 — 25,5 м')

    # Охрана не видит несогласованное, автор не согласует сам себе.
    guard = _auth(app, _GUARD)
    assert client.get(f'/api/material-passes/{item["id"]}',
                      headers=guard).status_code == 404
    assert _act(client, author, item['id'], 'approve').status_code == 403

    approver = _auth(app, _APPROVER)
    queue = client.get('/api/material-passes?scope=approve',
                       headers=approver).get_json()
    assert queue['pending'] == 1
    assert queue['items'][0]['can_approve'] is True
    assert 'code' not in queue['items'][0]

    pushes.clear()
    r = _act(client, approver, item['id'], 'approve')
    assert r.get_json()['item']['status'] == 'approved'
    to_author = [p for p in pushes if p[0] == [_AUTHOR]][0]
    assert to_author[2].endswith(f'код {item["code"]}')
    to_gate = [p for p in pushes if p[0] != [_AUTHOR]][0]
    assert _GUARD in to_gate[0] and _GUARD_HEAD in to_gate[0]

    gate = client.get('/api/material-passes?scope=gate', headers=guard).get_json()
    assert [i['id'] for i in gate['items']] == [item['id']]
    assert gate['items'][0]['can_release'] is True
    detail = client.get(f'/api/material-passes/{item["id"]}',
                        headers=guard).get_json()['item']
    assert detail['code'] == item['code']

    pushes.clear()
    r = _act(client, guard, item['id'], 'release')
    assert r.get_json()['item']['status'] == 'released'
    assert pushes[0][0] == [_AUTHOR]
    assert pushes[0][1] == f'Пропуск №{item["id"]}: выпущено через КПП'
    assert _act(client, guard, item['id'], 'release').status_code == 409
    events = [e['action'] for e in r.get_json()['item']['events']]
    assert events == ['created', 'approve', 'release']


def test_gate_only_on_its_day(app, client, pushes):
    author = _auth(app, _AUTHOR)
    tomorrow = (_today(app) + timedelta(days=1)).isoformat()
    item_id = _create(app, client, author, exit_date=tomorrow).get_json()['item']['id']
    _act(client, _auth(app, _APPROVER), item_id, 'approve')
    guard = _auth(app, _GUARD)
    assert client.get('/api/material-passes?scope=gate',
                      headers=guard).get_json()['items'] == []
    assert _act(client, guard, item_id, 'release').get_json()['error'] == 'not_today'

    # Просроченный — не выпускают.
    with app.app_context():
        db.session.get(MaterialPass, item_id).exit_date = _today(app) - timedelta(days=1)
        db.session.commit()
    r = _act(client, guard, item_id, 'release')
    assert r.get_json()['error'] == 'expired'
    assert client.get(f'/api/material-passes/{item_id}',
                      headers=author).get_json()['item']['expired'] is True


def test_hold_and_reject_need_reason(app, client, pushes):
    author = _auth(app, _AUTHOR)
    approver = _auth(app, _APPROVER)
    guard = _auth(app, _GUARD)
    first = _create(app, client, author).get_json()['item']['id']
    assert _act(client, approver, first, 'reject').get_json()['error'] == 'comment_required'
    r = _act(client, approver, first, 'reject', comment='Нет договора')
    assert r.get_json()['item']['reason'] == 'Нет договора'

    second = _create(app, client, author).get_json()['item']['id']
    _act(client, approver, second, 'approve')
    assert _act(client, guard, second, 'hold').get_json()['error'] == 'comment_required'
    pushes.clear()
    r = _act(client, guard, second, 'hold', comment='Насосов два, в пропуске один')
    assert r.get_json()['item']['status'] == 'held'
    assert pushes[0][0] == sorted([_AUTHOR, _APPROVER])


def test_privacy_and_cancel(app, client, pushes):
    author = _auth(app, _AUTHOR)
    item_id = _create(app, client, author).get_json()['item']['id']
    stranger = _auth(app, _STRANGER)
    assert client.get(f'/api/material-passes/{item_id}',
                      headers=stranger).status_code == 404
    assert client.get('/api/material-passes?scope=gate',
                      headers=stranger).status_code == 403
    assert client.get('/api/material-passes?scope=approve',
                      headers=_auth(app, _GUARD)).status_code == 403
    assert _act(client, _auth(app, _APPROVER), item_id, 'cancel').status_code == 403
    assert _act(client, author, item_id, 'cancel').get_json()['item']['status'] == 'cancelled'
