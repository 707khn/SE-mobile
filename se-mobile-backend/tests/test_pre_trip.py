"""Предрейсовый медосмотр и выпуск на линию."""

from datetime import date

import pytest

import app as app_module
import pre_trip
from pre_trip import PreTripExam, VehicleCheck
from models import db, Employee, Notification

_DRIVER = '0000000155'    # водитель
_DRIVER2 = '0000000602'   # водитель
_MEDIC = '0000001977'     # медицинский работник
_MECHANIC = '0000002029'  # механик
_HEAD = '0000002198'      # руководитель ДМТО
_DEPUTY = '0000001777'    # заместитель руководителя ДМТО
_HO_HEAD = '0000001573'   # заведующий ХО
_OTHER = '0000002107'     # менеджер по учёту ТМЦ

_TODAY = date(2030, 1, 15)


@pytest.fixture(autouse=True)
def clean(app, monkeypatch):
    monkeypatch.setattr(app_module, '_plant_today', lambda: _TODAY)
    yield
    with app.app_context():
        PreTripExam.query.delete()
        VehicleCheck.query.delete()
        Notification.query.filter_by(kind='pretrip').delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        assert kind == 'pretrip'
        sent.append((sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _exam(client, headers, **fields):
    body = {'employee_id': _DRIVER, 'systolic': 125, 'diastolic': 80,
            'pulse': 72, 'temperature': '36,6', 'alcohol': 0, 'admitted': True}
    body.update(fields)
    return client.post('/api/pretrip/exams', json=body, headers=headers)


def _check(client, headers, **fields):
    body = {'employee_id': _DRIVER, 'plate': '123 abc 02', 'odometer': 154200,
            'ok': True}
    body.update(fields)
    return client.post('/api/pretrip/checks', json=body, headers=headers)


def test_roles(app):
    with app.app_context():
        get = lambda i: db.session.get(Employee, i)
        assert pre_trip.is_driver(get(_DRIVER))
        assert pre_trip.is_medic(get(_MEDIC))
        assert pre_trip.is_mechanic(get(_MECHANIC))
        assert pre_trip.is_fleet_manager(get(_HEAD))
        assert pre_trip.is_fleet_manager(get(_HO_HEAD))
        assert not pre_trip.is_driver(get(_OTHER))


def test_warnings():
    assert pre_trip.warnings_for(150, 85, 110, 37.2, 0.1) == [
        'pressure', 'pulse', 'temperature', 'alcohol']
    assert pre_trip.warnings_for(120, 80, 70, 36.6, 0) == []


@pytest.mark.parametrize('fields, error', [
    ({'employee_id': _OTHER}, 'bad_driver'),
    ({'systolic': None}, 'pressure_required'),
    ({'systolic': 400}, 'bad_systolic'),
    ({'pulse': 'много'}, 'bad_pulse'),
    ({'temperature': 45}, 'bad_temperature'),
    ({'alcohol': None}, 'alcohol_required'),
    ({'admitted': 'да'}, 'admitted_required'),
    ({'admitted': False}, 'reason_required'),
    ({'kind': 'mid'}, 'bad_kind'),
])
def test_bad_exams(app, client, pushes, fields, error):
    r = _exam(client, _auth(app, _MEDIC), **fields)
    assert r.status_code == 400
    assert r.get_json()['error'] == error


def test_only_medics_examine_and_alcohol_blocks(app, client, pushes):
    assert _exam(client, _auth(app, _MECHANIC)).status_code == 403
    assert _exam(client, _auth(app, _DRIVER)).status_code == 403
    r = _exam(client, _auth(app, _MEDIC), alcohol=0.2)
    assert r.status_code == 409
    assert r.get_json()['error'] == 'alcohol_positive'


def test_day_flow_and_privacy(app, client, pushes):
    medic, mechanic = _auth(app, _MEDIC), _auth(app, _MECHANIC)
    r = _exam(client, medic, systolic=145)
    assert r.status_code == 201
    assert r.get_json()['item']['warnings'] == ['pressure']
    assert pushes == [([_DRIVER], 'Медосмотр пройден',
                       'Допущены к рейсу по медосмотру')]
    pushes.clear()
    r = _exam(client, medic, employee_id=_DRIVER2, admitted=False,
              temperature=38.1, reason='Температура 38,1')
    assert r.status_code == 201
    assert pushes[0] == ([_DRIVER2], 'Не допущены к рейсу', 'Температура 38,1')
    assert pushes[1][0] == sorted([_HEAD, _DEPUTY, _HO_HEAD])
    assert pushes[1][1].startswith('Не допущен к рейсу: ')
    # Руководству — без причины по здоровью.
    assert '38' not in pushes[1][2]

    assert _check(client, mechanic, odometer=-1).status_code == 400
    assert _check(client, mechanic, plate=' ').status_code == 400
    assert _check(client, medic).status_code == 403
    r = _check(client, mechanic)
    assert r.get_json()['item']['plate'] == '123ABC02'

    day = client.get('/api/pretrip', headers=_auth(app, _HEAD)).get_json()
    rows = {r['driver']['id']: r for r in day['drivers']}
    assert rows[_DRIVER]['status'] == 'admitted'
    assert rows[_DRIVER2]['status'] == 'not_admitted'
    # Руководитель видит допуск, но не давление и не причину.
    assert 'systolic' not in rows[_DRIVER]['exam']
    assert 'reason' not in rows[_DRIVER2]['exam']
    assert day['counts']['admitted'] == 1 and day['counts']['not_admitted'] == 1

    full = client.get('/api/pretrip', headers=medic).get_json()
    rows = {r['driver']['id']: r for r in full['drivers']}
    assert rows[_DRIVER]['exam']['systolic'] == 145
    assert rows[_DRIVER2]['exam']['reason'] == 'Температура 38,1'

    mine = client.get('/api/pretrip', headers=_auth(app, _DRIVER)).get_json()
    assert 'drivers' not in mine
    assert mine['me']['status'] == 'admitted'
    assert mine['me']['exam']['temperature'] == 36.6
    assert mine['me']['check']['plate'] == '123ABC02'

    # Другой день — пусто.
    other = client.get('/api/pretrip?date=2030-01-14', headers=medic).get_json()
    assert other['counts']['pending'] == len(other['drivers'])
    assert client.get('/api/pretrip?date=вчера', headers=medic).status_code == 400
    assert client.get('/api/pretrip', headers=_auth(app, _OTHER)).status_code == 403


def test_failed_vehicle_blocks(app, client, pushes):
    _exam(client, _auth(app, _MEDIC))
    pushes.clear()
    mechanic = _auth(app, _MECHANIC)
    assert _check(client, mechanic, ok=False).status_code == 400
    _check(client, mechanic, ok=False, reason='Течь тормозной жидкости')
    assert pushes[0][0] == sorted([_DRIVER, _HEAD, _DEPUTY, _HO_HEAD])
    day = client.get('/api/pretrip', headers=mechanic).get_json()
    row = next(r for r in day['drivers'] if r['driver']['id'] == _DRIVER)
    assert row['status'] == 'not_admitted'
    # Повторная проверка после ремонта — считается последняя.
    _check(client, mechanic)
    day = client.get('/api/pretrip', headers=mechanic).get_json()
    row = next(r for r in day['drivers'] if r['driver']['id'] == _DRIVER)
    assert row['status'] == 'admitted'
