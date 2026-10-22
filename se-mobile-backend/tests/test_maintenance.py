"""График ППР: оборудование, сроки, «выполнено», перенос и напоминание."""

from datetime import date

import pytest

import app as app_module
import maintenance
from maintenance import Equipment, MaintenancePlan, MaintenanceRecord
from models import db, Notification

_PLANNER = '0000002206'    # главный инженер
_ENERGETIC = '0000001674'  # инженер-технолог ТО — ответственный, не служба
_MASTER = '0000000082'     # мастер ОП — мастер участка
_HEAD = '0000000016'       # начальник ПЭО — видит весь график
_DRIVER = '0000000155'     # водитель — не видит
_TODAY = date(2030, 1, 15)


@pytest.fixture(autouse=True)
def clean(app, monkeypatch):
    monkeypatch.setattr(app_module, '_plant_today', lambda: _TODAY)
    yield
    with app.app_context():
        MaintenanceRecord.query.delete()
        MaintenancePlan.query.delete()
        Equipment.query.delete()
        Notification.query.filter_by(kind='maintenance').delete()
        db.session.commit()


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _notices(app, employee_id):
    with app.app_context():
        return [(n.title, n.body) for n in Notification.query.filter_by(
            kind='maintenance', employee_id=employee_id)]


def _setup(app, client, next_on='2030-01-20'):
    headers = _auth(app, _PLANNER)
    item = client.post('/api/maintenance/equipment', headers=headers, json={
        'name': 'Токарный станок 16К20', 'inventory_no': 'ИН-0042',
        'location': 'Участок 3', 'master_id': _MASTER, 'engineer_id': _ENERGETIC})
    assert item.status_code == 201, item.get_json()
    item_id = item.get_json()['item']['id']
    plan = client.post('/api/maintenance/plans', headers=headers, json={
        'equipment_id': item_id, 'kind': 'service', 'every_months': '3',
        'next_on': next_on, 'hours': 8})
    assert plan.status_code == 201, plan.get_json()
    return item_id, plan.get_json()['plan']['id']


def test_only_planners_build_the_schedule(app, client):
    assert client.post('/api/maintenance/equipment', headers=_auth(app, _MASTER),
                       json={'name': 'Станок'}).status_code == 403
    headers = _auth(app, _PLANNER)
    assert client.post('/api/maintenance/equipment', headers=headers,
                       json={'name': ''}).get_json()['error'] == 'name_required'
    assert client.post('/api/maintenance/equipment', headers=headers, json={
        'name': 'Станок', 'master_id': 'nope'}).get_json()['error'] == 'no_master'
    item_id, _ = _setup(app, client)
    assert client.post('/api/maintenance/plans', headers=headers, json={
        'equipment_id': item_id, 'kind': 'service', 'every_months': 0,
        'next_on': '2030-02-01'}).get_json()['error'] == 'bad_every_months'


def test_who_sees_what(app, client):
    item_id, plan_id = _setup(app, client)
    for who in (_PLANNER, _ENERGETIC, _MASTER, _HEAD):
        items = client.get('/api/maintenance', headers=_auth(app, who)).get_json()['items']
        assert [i['id'] for i in items] == [plan_id], who
    assert client.get('/api/maintenance',
                      headers=_auth(app, _DRIVER)).get_json()['items'] == []
    assert client.get(f'/api/maintenance/equipment/{item_id}',
                      headers=_auth(app, _DRIVER)).status_code == 404

    item = client.get('/api/maintenance', headers=_auth(app, _MASTER)).get_json()['items'][0]
    assert item['state'] == 'week' and item['can_mark'] is False
    assert item['equipment']['master']['id'] == _MASTER
    own = client.get('/api/maintenance', headers=_auth(app, _ENERGETIC)).get_json()
    assert own['planner'] is False and own['items'][0]['can_mark'] is True


def test_reminder_once_per_date(app, client):
    _, plan_id = _setup(app, client)
    _setup(app, client, next_on='2030-03-01')
    with app.app_context():
        assert maintenance.remind_due(app_module) == 1
        assert maintenance.remind_due(app_module) == 0
    assert _notices(app, _MASTER) == [(
        'ППР 20.01.2030: Токарный станок 16К20',
        'Техобслуживание, около 8 ч. Участок 3')]
    assert _notices(app, _ENERGETIC) == _notices(app, _MASTER)

    # Перенос — новая дата, о ней напомнят снова.
    moved = client.post(f'/api/maintenance/plans/{plan_id}', headers=_auth(app, _PLANNER),
                        json={'action': 'postpone', 'next_on': '2030-01-18',
                              'note': 'Срочный заказ'})
    assert moved.status_code == 200
    assert ('ППР перенесён: Токарный станок 16К20',
            '20.01.2030 → 18.01.2030. Срочный заказ') in _notices(app, _MASTER)
    with app.app_context():
        assert maintenance.remind_due(app_module) == 1


def test_done_and_postpone(app, client):
    item_id, plan_id = _setup(app, client)
    url = f'/api/maintenance/plans/{plan_id}'
    assert client.post(url, headers=_auth(app, _MASTER),
                       json={'action': 'done'}).status_code == 403
    assert client.post(url, headers=_auth(app, _ENERGETIC),
                       json={'action': 'postpone', 'next_on': '2030-02-01',
                             'note': 'x'}).status_code == 403
    assert client.post(url, headers=_auth(app, _PLANNER), json={
        'action': 'postpone', 'next_on': '2030-02-01'}).get_json()['error'] == 'note_required'

    done = client.post(url, headers=_auth(app, _ENERGETIC),
                       json={'action': 'done', 'note': 'Заменили масло'}).get_json()
    assert done['plan']['next_on'] == '2030-04-15' and done['plan']['state'] == 'later'

    detail = client.get(f'/api/maintenance/equipment/{item_id}',
                        headers=_auth(app, _MASTER)).get_json()['item']
    history = detail['plans'][0]['history']
    assert [(h['action'], h['planned_on'], h['done_on'], h['note']) for h in history] == [
        ('done', '2030-01-20', '2030-01-15', 'Заменили масло')]
    assert history[0]['actor']['id'] == _ENERGETIC

    listing = client.get('/api/maintenance/equipment',
                         headers=_auth(app, _HEAD)).get_json()['items']
    assert listing[0]['plans'][0]['next_on'] == '2030-04-15'

    client.post(url, headers=_auth(app, _PLANNER), json={'action': 'remove'})
    assert client.get('/api/maintenance', headers=_auth(app, _PLANNER)).get_json()['items'] == []
    client.post(f'/api/maintenance/equipment/{item_id}', headers=_auth(app, _PLANNER),
                json={'active': False})
    assert client.get('/api/maintenance/equipment',
                      headers=_auth(app, _PLANNER)).get_json()['items'] == []


def test_reminders_run_with_requests(app, client, monkeypatch):
    _setup(app, client)
    monkeypatch.setattr(maintenance, '_reminded_at', None)
    client.get('/api/maintenance', headers=_auth(app, _DRIVER))
    assert len(_notices(app, _MASTER)) == 1
