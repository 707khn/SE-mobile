"""Путевой лист: открыть после допуска, поездки, возврат, закрытие."""

from datetime import date

import pytest

import app as app_module
from models import db, Notification
from pre_trip import PreTripExam, VehicleCheck
from waybills import Waybill, WaybillTrip

_DRIVER = '0000000155'    # водитель
_DRIVER2 = '0000000602'   # другой водитель
_MEDIC = '0000001977'     # медицинский работник
_MECHANIC = '0000002029'  # механик ХО
_HEAD = '0000001573'      # заведующий ХО
_OUTSIDER = '0000000137'  # бухгалтер
_TODAY = date(2030, 1, 15)


@pytest.fixture(autouse=True)
def clean(app, monkeypatch):
    monkeypatch.setattr(app_module, '_plant_today', lambda: _TODAY)
    yield
    with app.app_context():
        WaybillTrip.query.delete()
        Waybill.query.delete()
        PreTripExam.query.delete()
        VehicleCheck.query.delete()
        Notification.query.filter(Notification.kind.in_(('waybill', 'pretrip'))).delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        sent.append((kind, sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _admit(app, client, driver=_DRIVER, admitted=True, ok=True):
    exam = client.post('/api/pretrip/exams', headers=_auth(app, _MEDIC), json={
        'employee_id': driver, 'systolic': 125, 'diastolic': 80, 'pulse': 72,
        'temperature': '36,6', 'alcohol': 0, 'admitted': admitted,
        'reason': '' if admitted else 'Давление'})
    assert exam.status_code == 201, exam.get_json()
    check = client.post('/api/pretrip/checks', headers=_auth(app, _MECHANIC), json={
        'employee_id': driver, 'plate': '123 abc 02', 'odometer': 154200, 'ok': ok,
        'reason': '' if ok else 'Тормоза'})
    assert check.status_code == 201, check.get_json()


def _open(client, headers, **fields):
    body = {'fuel_out': '35,5'}
    body.update(fields)
    return client.post('/api/waybills', json=body, headers=headers)


def _act(client, headers, item_id, action, **body):
    return client.post(f'/api/waybills/{item_id}', json={'action': action, **body},
                       headers=headers)


def _trip(client, headers, item_id, **fields):
    body = {'origin': 'Завод', 'destination': 'Налоговая, ул. Абая 1',
            'purpose': 'Документы', 'customer': 'ОБиНУ', 'departed': '9:10',
            'arrived': '09:40'}
    body.update(fields)
    return _act(client, headers, item_id, 'trip', **body)


def test_needs_admission_and_release(app, client):
    driver = _auth(app, _DRIVER)
    assert _open(client, driver).get_json()['error'] == 'not_admitted'
    _admit(app, client, ok=False)
    assert _open(client, driver).get_json()['error'] == 'not_released'
    assert _open(client, _auth(app, _OUTSIDER)).status_code == 403
    assert client.get('/api/waybills', headers=_auth(app, _OUTSIDER)).status_code == 403


def test_open_takes_plate_and_odometer_from_release(app, client):
    _admit(app, client)
    driver = _auth(app, _DRIVER)
    ready = client.get('/api/waybills', headers=driver).get_json()['ready']
    assert ready['admitted'] and ready['released'] and ready['plate'] == '123ABC02'
    answer = _open(client, driver)
    assert answer.status_code == 201, answer.get_json()
    item = answer.get_json()['item']
    assert item['plate'] == '123ABC02' and item['odometer_out'] == 154200
    assert item['fuel_out'] == 35.5 and item['can_edit'] is True
    assert _open(client, driver).get_json()['error'] == 'already_open'
    assert client.get('/api/waybills', headers=driver).get_json()['ready'][
        'open_id'] == item['id']


def test_trips_return_and_close(app, client, pushes):
    _admit(app, client)
    driver = _auth(app, _DRIVER)
    item_id = _open(client, driver).get_json()['item']['id']
    assert _act(client, driver, item_id, 'return', odometer_in=154250,
                fuel_in=30).get_json()['error'] == 'no_trips'
    assert _trip(client, driver, item_id, destination='').status_code == 400
    assert _trip(client, driver, item_id, departed='25:00').get_json()['error'] \
        == 'bad_time'
    first = _trip(client, driver, item_id).get_json()['item']
    assert first['trips'][0]['departed'] == '09:10'
    _trip(client, driver, item_id, origin='Налоговая', destination='Завод',
          departed='10:00', arrived='10:30')
    trips = _trip(client, driver, item_id, origin='x', destination='y',
                  departed='', arrived='').get_json()['item']['trips']
    removed = _act(client, driver, item_id, 'trip_remove',
                   trip_id=trips[0]['id']).get_json()['item']
    assert len(removed['trips']) == 2

    assert _act(client, driver, item_id, 'return', odometer_in=154100,
                fuel_in=30).get_json()['error'] == 'bad_odometer'
    assert _act(client, driver, item_id, 'return', odometer_in=154262,
                fuel_in=80).get_json()['error'] == 'bad_fuel'
    returned = _act(client, driver, item_id, 'return', odometer_in=154262,
                    fuel_added='20', fuel_in='41,5').get_json()['item']
    assert returned['status'] == 'returned'
    assert returned['distance'] == 62 and returned['fuel_used'] == 14
    kind, ids, title, body = pushes[-1]
    assert kind == 'waybill' and _MECHANIC in ids and _HEAD in ids
    assert body.endswith('62 км, расход 14 л')
    assert _trip(client, driver, item_id).get_json()['error'] == 'not_open'

    mechanic = _auth(app, _MECHANIC)
    day = client.get('/api/waybills', headers=mechanic).get_json()
    assert day['totals'] == {'count': 1, 'open': 0, 'returned': 1,
                             'distance': 62, 'fuel_used': 14}
    assert day['items'][0]['can_review'] is True
    assert _act(client, mechanic, item_id, 'reopen').get_json()['error'] \
        == 'text_required'
    reopened = _act(client, mechanic, item_id, 'reopen',
                    text='Не указан заказчик второй поездки').get_json()['item']
    assert reopened['status'] == 'open' and reopened['note']
    assert pushes[-1][1] == [_DRIVER]
    _act(client, driver, item_id, 'return', odometer_in=154262, fuel_added=20,
         fuel_in=41.5)
    closed = _act(client, _auth(app, _HEAD), item_id, 'close').get_json()['item']
    assert closed['status'] == 'closed' and closed['reviewer']['id'] == _HEAD


def test_other_driver_cannot_see(app, client):
    _admit(app, client)
    item_id = _open(client, _auth(app, _DRIVER)).get_json()['item']['id']
    other = _auth(app, _DRIVER2)
    assert client.get(f'/api/waybills/{item_id}', headers=other).status_code == 404
    assert _trip(client, other, item_id).status_code == 404
    assert _act(client, _auth(app, _DRIVER), item_id, 'close').status_code == 403
