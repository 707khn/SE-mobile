"""Поручения: кому можно поручать, отчёт, возврат, перенос срока."""

from datetime import date, datetime, timedelta

import pytest

import app as app_module
from assignments import Assignment, AssignmentEvent
from models import db, Notification

_HEAD = '0000000016'      # начальник ПЭО
_PEO = '0000001445'       # менеджер ПЭО
_PEO2 = '0000001864'      # менеджер ПЭО
_DIRECTOR = '0000002183'  # генеральный директор
_OTHER = '0000002107'     # менеджер по учёту ТМЦ — чужой отдел

_TODAY = date(2030, 1, 15)


@pytest.fixture(autouse=True)
def clean(app, monkeypatch):
    monkeypatch.setattr(app_module, '_plant_today', lambda: _TODAY)
    yield
    with app.app_context():
        AssignmentEvent.query.delete()
        Assignment.query.delete()
        Notification.query.filter_by(kind='assignment').delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        assert kind == 'assignment'
        sent.append((sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _give(client, headers, **fields):
    body = {'title': 'Подготовить план на ноябрь', 'text': 'По всем участкам.',
            'due_date': '2030-01-20', 'assignee_ids': [_PEO]}
    body.update(fields)
    return client.post('/api/assignments', json=body, headers=headers)


def _act(client, headers, item_id, action, **body):
    return client.post(f'/api/assignments/{item_id}',
                       json={'action': action, **body}, headers=headers)


@pytest.mark.parametrize('fields, error', [
    ({'title': ' '}, 'title_required'),
    ({'due_date': '2030-01-14'}, 'bad_date'),
    ({'due_date': 'завтра'}, 'bad_date'),
    ({'assignee_ids': []}, 'assignee_required'),
    ({'assignee_ids': ['нет такого']}, 'bad_assignee'),
    ({'assignee_ids': [_HEAD]}, 'bad_assignee'),
])
def test_bad_requests(app, client, pushes, fields, error):
    r = _give(client, _auth(app, _HEAD), **fields)
    assert r.status_code == 400
    assert r.get_json()['error'] == error


def test_who_assigns_to_whom(app, client, pushes):
    # Начальник — только своему отделу.
    head = _auth(app, _HEAD)
    assert _give(client, head, assignee_ids=[_OTHER]).status_code == 403
    people = client.get('/api/assignments/people', headers=head).get_json()['people']
    ids = {p['id'] for p in people}
    assert _PEO in ids and _OTHER not in ids and _HEAD not in ids
    # Рядовой — никому.
    peo = _auth(app, _PEO)
    assert _give(client, peo, assignee_ids=[_PEO2]).status_code == 403
    assert client.get('/api/assignments', headers=peo).get_json()['can_assign'] is False
    # Директор — кому угодно.
    director = _auth(app, _DIRECTOR)
    r = _give(client, director, assignee_ids=[_OTHER, _HEAD])
    assert r.status_code == 201
    assert len(r.get_json()['items']) == 2
    assert sorted(p[0][0] for p in pushes) == sorted([_OTHER, _HEAD])
    found = client.get('/api/assignments/people?q=ТМЦ',
                       headers=director).get_json()['people']
    assert _OTHER in {p['id'] for p in found}


def test_accept_done_return_close(app, client, pushes):
    head, peo = _auth(app, _HEAD), _auth(app, _PEO)
    r = _give(client, head, important=True)
    item = r.get_json()['items'][0]
    assert pushes[-1] == ([_PEO], 'Важная задача: Подготовить план на ноябрь',
                          f'{_name(app, _HEAD)}, срок 20.01')

    # Чужой не видит.
    assert client.get(f'/api/assignments/{item["id"]}',
                      headers=_auth(app, _PEO2)).status_code == 404
    # Поручивший не может отчитаться за исполнителя.
    assert _act(client, head, item['id'], 'done', comment='x').status_code == 403

    assert _act(client, peo, item['id'], 'accept').get_json()['item']['status'] == 'in_progress'
    assert _act(client, peo, item['id'], 'done').status_code == 400
    r = _act(client, peo, item['id'], 'done', comment='План в общей папке.')
    assert r.get_json()['item']['status'] == 'done'
    assert pushes[-1][0] == [_HEAD] and pushes[-1][1].startswith('Выполнено')

    given = client.get('/api/assignments?scope=given', headers=head).get_json()
    assert given['counts']['given_done'] == 1

    r = _act(client, head, item['id'], 'return', comment='Нет участка 3',
             due_date='2030-01-22')
    got = r.get_json()['item']
    assert got['status'] == 'in_progress' and got['due_date'] == '2030-01-22'
    _act(client, peo, item['id'], 'done', comment='Добавил участок 3.')
    r = _act(client, head, item['id'], 'close')
    got = r.get_json()['item']
    assert got['status'] == 'closed'
    assert [e['action'] for e in got['events']] == [
        'created', 'accept', 'done', 'return', 'done', 'close']
    assert _act(client, head, item['id'], 'remind').status_code == 409
    # Закрытое — внизу списка, но ещё месяц видно.
    mine = client.get('/api/assignments', headers=peo).get_json()
    assert mine['items'][0]['status'] == 'closed'
    assert mine['counts']['mine_open'] == 0


def test_extend_and_overdue(app, client, pushes, monkeypatch):
    head, peo = _auth(app, _HEAD), _auth(app, _PEO)
    item_id = _give(client, head).get_json()['items'][0]['id']
    assert _act(client, peo, item_id, 'extend', due_date='2030-01-25').status_code == 400
    assert _act(client, peo, item_id, 'extend', due_date='2030-01-19',
                comment='Жду данные').status_code == 400
    r = _act(client, peo, item_id, 'extend', due_date='2030-01-25',
             comment='Жду данные от ОП')
    assert r.get_json()['item']['proposed_due'] == '2030-01-25'
    assert pushes[-1][0] == [_HEAD]

    r = _act(client, head, item_id, 'extend_ok')
    got = r.get_json()['item']
    assert got['due_date'] == '2030-01-25' and got['proposed_due'] is None
    assert _act(client, head, item_id, 'extend_no').status_code == 409

    monkeypatch.setattr(app_module, '_plant_today', lambda: date(2030, 1, 26))
    mine = client.get('/api/assignments', headers=peo).get_json()
    assert mine['counts']['mine_overdue'] == 1
    assert mine['items'][0]['overdue'] is True


def test_remind_rate_and_cancel(app, client, pushes):
    head, peo = _auth(app, _HEAD), _auth(app, _PEO)
    item_id = _give(client, head).get_json()['items'][0]['id']
    pushes.clear()
    assert _act(client, peo, item_id, 'remind').status_code == 403
    assert _act(client, head, item_id, 'remind').status_code == 200
    assert pushes[-1][1] == 'Напоминание: «Подготовить план на ноябрь»'
    assert _act(client, head, item_id, 'remind').status_code == 429
    with app.app_context():
        item = db.session.get(Assignment, item_id)
        item.reminded_at = datetime.utcnow() - timedelta(hours=5)
        db.session.commit()
    assert _act(client, head, item_id, 'remind').status_code == 200

    r = _act(client, peo, item_id, 'comment', comment='Начал')
    assert pushes[-1] == ([_HEAD], 'Комментарий: «Подготовить план на ноябрь»',
                          f'{_name(app, _PEO)}: Начал')
    r = _act(client, head, item_id, 'cancel', comment='Уже не нужно')
    assert r.get_json()['item']['status'] == 'cancelled'
    assert _act(client, peo, item_id, 'done', comment='x').status_code == 409


def _name(app, employee_id):
    from models import Employee
    with app.app_context():
        return db.session.get(Employee, employee_id).full_name
