"""Спецодежда и СИЗ: выдача со сроком замены, стирка с «заберите»."""

from datetime import date

import pytest

import app as app_module
from models import db, Notification
from workwear import WorkwearIssue, WorkwearLaundry, add_months, is_workwear_staff

_STAFF = '0000000114'     # машинист по стирке и ремонту спецодежды
_HEAD = '0000001573'      # заведующий ХО
_MECHANIC = '0000002029'  # механик ХО — спецодежду не выдаёт
_WORKER = '0000000082'    # мастер ОП
_OTHER = '0000000150'
_TODAY = date(2030, 1, 15)


@pytest.fixture(autouse=True)
def clean(app, monkeypatch):
    monkeypatch.setattr(app_module, '_plant_today', lambda: _TODAY)
    yield
    with app.app_context():
        WorkwearLaundry.query.delete()
        WorkwearIssue.query.delete()
        Notification.query.filter_by(kind='workwear').delete()
        db.session.commit()


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _issue(app, client, who=_STAFF, **extra):
    body = {'employee_id': _WORKER, 'item': 'Костюм х/б', 'size': '52-54',
            'quantity': 1, 'wear_months': 12, 'issued_on': '2029-02-01', **extra}
    return client.post('/api/workwear/issues', headers=_auth(app, who), json=body)


def _notices(app, employee_id):
    with app.app_context():
        return [(n.title, n.body) for n in Notification.query.filter_by(
            kind='workwear', employee_id=employee_id)]


def test_add_months():
    assert add_months(date(2030, 1, 31), 1) == date(2030, 2, 28)
    assert add_months(date(2030, 11, 15), 3) == date(2031, 2, 15)
    assert add_months(date(2028, 1, 31), 1) == date(2028, 2, 29)


def test_who_is_staff(app):
    with app.app_context():
        from models import Employee
        assert is_workwear_staff(db.session.get(Employee, _STAFF))
        assert is_workwear_staff(db.session.get(Employee, _HEAD))
        assert not is_workwear_staff(db.session.get(Employee, _MECHANIC))
        assert not is_workwear_staff(db.session.get(Employee, _WORKER))


def test_issue_and_due_dates(app, client):
    assert _issue(app, client, who=_WORKER).status_code == 403
    assert _issue(app, client, item='').get_json()['error'] == 'item_required'
    assert _issue(app, client, wear_months=0).get_json()['error'] == 'bad_months'
    assert _issue(app, client, issued_on='2030-02-01').get_json()['error'] == 'bad_date'

    answer = _issue(app, client)
    assert answer.status_code == 201, answer.get_json()
    issue = answer.get_json()['issue']
    assert issue['due_on'] == '2030-02-01' and issue['due'] == 'soon'
    assert _issue(app, client, item='Перчатки', quantity='6', wear_months='1',
                  issued_on='2029-12-01').status_code == 201
    assert _issue(app, client, item='Каска', wear_months=None).status_code == 201

    mine = client.get('/api/workwear', headers=_auth(app, _WORKER)).get_json()
    assert mine['staff'] is False
    assert [(i['item'], i['due']) for i in mine['issues']] == [
        ('Перчатки', 'overdue'), ('Костюм х/б', 'soon'), ('Каска', 'none')]
    assert mine['issues'][0]['quantity'] == 6
    assert ('Выдано: Костюм х/б', 'Замена — 01.02.2030') in _notices(app, _WORKER)
    assert client.get('/api/workwear', headers=_auth(app, _OTHER)).get_json()['issues'] == []


def test_replace_and_remind(app, client):
    issue_id = _issue(app, client).get_json()['issue']['id']
    _issue(app, client, employee_id=_OTHER, item='Ботинки', wear_months=24,
           issued_on='2029-06-01')

    staff = client.get('/api/workwear/staff', headers=_auth(app, _HEAD)).get_json()
    assert [i['item'] for i in staff['due']] == ['Костюм х/б']
    assert staff['due'][0]['employee']['id'] == _WORKER
    assert client.get('/api/workwear/staff',
                      headers=_auth(app, _WORKER)).status_code == 403

    reminded = client.post('/api/workwear/remind-due', headers=_auth(app, _STAFF))
    assert reminded.get_json()['reminded'] == 1
    assert ('Подходит срок замены спецодежды',
            'Подойдите в хозотдел: Костюм х/б') in _notices(app, _WORKER)
    assert not any(t.startswith('Подходит') for t, _ in _notices(app, _OTHER))

    replaced = client.post(f'/api/workwear/issues/{issue_id}',
                           headers=_auth(app, _STAFF), json={'action': 'replace'})
    fresh = replaced.get_json()['issue']
    assert fresh['issued_on'] == '2030-01-15' and fresh['due_on'] == '2031-01-15'
    assert client.post(f'/api/workwear/issues/{issue_id}', headers=_auth(app, _STAFF),
                       json={'action': 'return'}).get_json()['error'] == 'returned'
    mine = client.get('/api/workwear', headers=_auth(app, _WORKER)).get_json()
    assert [i['id'] for i in mine['issues']] == [fresh['id']]

    card = client.get(f'/api/workwear/employees/{_WORKER}',
                      headers=_auth(app, _STAFF)).get_json()
    assert card['employee']['id'] == _WORKER and len(card['issues']) == 1


def test_laundry_ready_and_collected(app, client):
    headers = _auth(app, _STAFF)
    assert client.post('/api/workwear/laundry', headers=headers, json={
        'employee_id': _WORKER, 'kind': 'dry', 'items': 'Костюм'}
    ).get_json()['error'] == 'bad_kind'
    accepted = client.post('/api/workwear/laundry', headers=headers, json={
        'employee_id': _WORKER, 'kind': 'repair', 'items': 'Куртка — молния'})
    assert accepted.status_code == 201
    row_id = accepted.get_json()['laundry']['id']

    mine = client.get('/api/workwear', headers=_auth(app, _WORKER)).get_json()
    assert mine['laundry'][0]['status'] == 'accepted'
    assert client.post(f'/api/workwear/laundry/{row_id}', headers=_auth(app, _WORKER),
                       json={'action': 'ready'}).status_code == 403

    ready = client.post(f'/api/workwear/laundry/{row_id}', headers=headers,
                        json={'action': 'ready'}).get_json()
    assert ready['laundry']['status'] == 'ready'
    assert ('Готово из ремонта, заберите в хозотделе',
            'Куртка — молния') in _notices(app, _WORKER)
    queue = client.get('/api/workwear/staff', headers=headers).get_json()['laundry']
    assert [r['id'] for r in queue] == [row_id]

    collected = client.post(f'/api/workwear/laundry/{row_id}', headers=headers,
                            json={'action': 'collected'}).get_json()
    assert collected['laundry']['status'] == 'collected'
    assert client.get('/api/workwear/staff', headers=headers).get_json()['laundry'] == []
    assert client.post(f'/api/workwear/laundry/{row_id}', headers=headers,
                       json={'action': 'ready'}).get_json()['error'] == 'bad_state'
