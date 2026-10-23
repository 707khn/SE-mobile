"""Медосмотры: сроки от медпункта, напоминания, запись на свободное время."""

from datetime import date, datetime

import pytest

import app as app_module
from medical_visits import MedicalExam, MedicalSlot
from models import db, Employee, Notification

_MEDIC = '0000001977'      # медицинский работник
_WORKER = '0000000082'     # мастер ОП
_OTHER = '0000000150'      # другой мастер ОП
_TODAY = date(2030, 1, 15)
_NOW = datetime(2030, 1, 15, 8, 0)


@pytest.fixture(autouse=True)
def clean(app, monkeypatch):
    monkeypatch.setattr(app_module, '_plant_today', lambda: _TODAY)
    monkeypatch.setattr(app_module, '_plant_now', lambda: _NOW)
    yield
    with app.app_context():
        MedicalSlot.query.delete()
        MedicalExam.query.delete()
        Notification.query.filter_by(kind='medical').delete()
        db.session.commit()


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _notices(app, employee_id):
    with app.app_context():
        return [(n.title, n.body) for n in Notification.query.filter_by(
            kind='medical', employee_id=employee_id)]


def _open_slots(app, client, **extra):
    body = {'date': '2030-01-16', 'from': '09:00', 'to': '10:00', 'step': 20,
            'kind': 'exam', **extra}
    return client.post('/api/medical/slots', headers=_auth(app, _MEDIC), json=body)


def test_medic_sets_due_for_department(app, client):
    with app.app_context():
        department = db.session.get(Employee, _WORKER).department
        size = Employee.query.filter_by(department=department).count()
    headers = _auth(app, _MEDIC)
    assert client.post('/api/medical/exams', headers=_auth(app, _WORKER), json={
        'kind': 'periodic', 'due_on': '2030-02-01', 'employee_ids': [_WORKER]}
    ).status_code == 403
    assert client.post('/api/medical/exams', headers=headers, json={
        'kind': 'periodic', 'due_on': '2029-12-01', 'department': department}
    ).get_json()['error'] == 'bad_date'

    answer = client.post('/api/medical/exams', headers=headers, json={
        'kind': 'periodic', 'due_on': '2030-02-01', 'department': department})
    assert answer.status_code == 201 and answer.get_json()['count'] == size
    assert ('Медпункт: периодический медосмотр',
            'Пройти до 01.02.2030. Записаться можно в приложении') in _notices(app, _WORKER)

    # Повторное назначение заменяет срок, а не добавляет второй.
    client.post('/api/medical/exams', headers=headers, json={
        'kind': 'periodic', 'due_on': '2030-03-01', 'employee_ids': [_WORKER]})
    mine = client.get('/api/medical', headers=_auth(app, _WORKER)).get_json()
    assert mine['medic'] is False
    assert [(e['kind'], e['due_on'], e['state']) for e in mine['exams']] == [
        ('periodic', '2030-03-01', 'ok')]

    departments = client.get('/api/medical/departments', headers=headers).get_json()
    assert {'name': department, 'count': size} in departments['departments']


def test_done_moves_due_and_remind(app, client):
    headers = _auth(app, _MEDIC)
    client.post('/api/medical/exams', headers=headers, json={
        'kind': 'fluorography', 'due_on': '2030-01-20', 'employee_ids': [_WORKER]})
    client.post('/api/medical/exams', headers=headers, json={
        'kind': 'vaccination', 'due_on': '2030-06-01', 'employee_ids': [_OTHER]})

    desk = client.get('/api/medical/desk', headers=headers).get_json()
    assert [(d['employee']['id'], d['state']) for d in desk['due']] == [(_WORKER, 'soon')]

    reminded = client.post('/api/medical/remind-due', headers=headers).get_json()
    assert reminded['reminded'] == 1
    assert ('Медпункт: флюорография', 'Пройти до 20.01.2030') in _notices(app, _WORKER)
    # Через минуту — не повторяет.
    assert client.post('/api/medical/remind-due',
                       headers=headers).get_json()['reminded'] == 0

    exam_id = desk['due'][0]['id']
    done = client.post(f'/api/medical/exams/{exam_id}', headers=headers,
                       json={'action': 'done'}).get_json()['exam']
    assert done['last_done_on'] == '2030-01-15' and done['due_on'] == '2031-01-15'
    assert client.post(f'/api/medical/exams/{exam_id}', headers=headers, json={
        'action': 'done', 'next_due_on': '2030-01-01'}).get_json()['error'] == 'bad_date'


def test_slots_booking(app, client):
    assert _open_slots(app, client, to='08:00').get_json()['error'] == 'bad_time'
    assert _open_slots(app, client).get_json()['added'] == 3
    assert _open_slots(app, client).get_json()['added'] == 0
    assert _open_slots(app, client, kind='vaccination', to='09:30',
                       step='30').get_json()['added'] == 1

    worker = _auth(app, _WORKER)
    free = client.get('/api/medical', headers=worker).get_json()['free']
    assert [(s['starts_at'], s['kind']) for s in free] == [
        ('2030-01-16T09:00', 'exam'), ('2030-01-16T09:00', 'vaccination'),
        ('2030-01-16T09:20', 'exam'), ('2030-01-16T09:40', 'exam')]
    first, second, third = free[0]['id'], free[2]['id'], free[3]['id']

    booked = client.post(f'/api/medical/slots/{first}/book', headers=worker)
    assert booked.get_json()['slot']['mine'] is True
    assert client.post(f'/api/medical/slots/{first}/book',
                       headers=_auth(app, _OTHER)).get_json()['error'] == 'taken'
    client.post(f'/api/medical/slots/{second}/book', headers=worker)
    assert client.post(f'/api/medical/slots/{third}/book',
                       headers=worker).get_json()['error'] == 'too_many'

    mine = client.get('/api/medical', headers=worker).get_json()
    assert [b['id'] for b in mine['bookings']] == [first, second]
    assert first not in [s['id'] for s in mine['free']]

    desk = client.get('/api/medical/desk?date=2030-01-16',
                      headers=_auth(app, _MEDIC)).get_json()
    assert [s['employee']['id'] if s['employee'] else None for s in desk['slots']] == [
        _WORKER, None, _WORKER, None]

    # Чужую запись отменить нельзя, свою — можно; медпункт — любую, с оповещением.
    assert client.post(f'/api/medical/slots/{first}/cancel',
                       headers=_auth(app, _OTHER)).status_code == 403
    assert client.post(f'/api/medical/slots/{first}/cancel',
                       headers=worker).get_json()['slot']['booked'] is False
    assert client.post(f'/api/medical/slots/{second}/cancel',
                       headers=_auth(app, _MEDIC)).status_code == 200
    assert ('Запись в медпункт отменена', '16.01.2030 09:20') in _notices(app, _WORKER)


def test_delete_booked_slot_tells_employee(app, client):
    _open_slots(app, client, to='09:20')
    slot_id = client.get('/api/medical', headers=_auth(app, _WORKER)).get_json()['free'][0]['id']
    client.post(f'/api/medical/slots/{slot_id}/book', headers=_auth(app, _WORKER))
    assert client.delete(f'/api/medical/slots/{slot_id}',
                         headers=_auth(app, _WORKER)).status_code == 403
    assert client.delete(f'/api/medical/slots/{slot_id}',
                         headers=_auth(app, _MEDIC)).status_code == 200
    assert ('Запись в медпункт отменена', '16.01.2030 09:00') in _notices(app, _WORKER)
