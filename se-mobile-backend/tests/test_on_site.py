"""«Кто из моих сейчас на территории»: весь отдел, а не только прошедшие."""

from datetime import date, datetime

import pytest

import app as app_module
from away import AwayNote
from models import db, AccessRecord, TurnstileEvent

_HEAD = '0000000016'      # начальник ПЭО
_EARLY = '0000001445'     # менеджер ПЭО — пришёл вовремя
_LATE = '0000001864'      # менеджер ПЭО — опоздал и ушёл
_AWAY = '0000001919'      # менеджер ПЭО — в отпуске
_ABSENT = '0000001295'    # главный менеджер ПЭО — ничего не известно
_OTHER = '0000002107'     # из другого отдела

_DAY = date(2030, 1, 15)  # день без выгрузок и событий из сидов


@pytest.fixture
def at(monkeypatch):
    def set_time(hh, mm):
        monkeypatch.setattr(app_module, '_plant_now',
                            lambda: datetime(2030, 1, 15, hh, mm))
    set_time(9, 30)
    return set_time


@pytest.fixture(autouse=True)
def day(app):
    with app.app_context():
        def ts(hh, mm):
            return datetime(2030, 1, 15, hh, mm)
        db.session.add_all([
            TurnstileEvent(employee_id=_EARLY, direction='in', timestamp=ts(7, 55)),
            TurnstileEvent(employee_id=_LATE, direction='in', timestamp=ts(8, 20)),
            TurnstileEvent(employee_id=_LATE, direction='out', timestamp=ts(9, 10)),
            TurnstileEvent(employee_id=_OTHER, direction='in', timestamp=ts(7, 40)),
            # Тот же проход из выгрузки СКУД — не второй проход.
            AccessRecord(employee_id=_EARLY, access_date=_DAY, access_time='07:55',
                         event_type='Вход', door_location='КПП'),
            AwayNote(employee_id=_AWAY, reason='vacation', start_date=_DAY,
                     end_date=date(2030, 1, 30), deputy_name='Заместитель Тест'),
        ])
        db.session.commit()
    yield
    with app.app_context():
        TurnstileEvent.query.filter(TurnstileEvent.timestamp >= datetime(2030, 1, 1)).delete()
        AccessRecord.query.filter_by(access_date=_DAY).delete()
        AwayNote.query.filter_by(employee_id=_AWAY).delete()
        db.session.commit()


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def test_whole_department_with_status(app, client, at):
    r = client.get('/api/attendance/now', headers=_auth(app, _HEAD))
    assert r.status_code == 200
    body = r.get_json()
    by_id = {p['id']: p for p in body['people']}
    assert _OTHER not in by_id and _HEAD not in by_id
    assert by_id[_EARLY]['status'] == 'inside'
    assert by_id[_EARLY]['first_in'] == '07:55'
    assert by_id[_EARLY]['late'] is False
    assert by_id[_LATE]['status'] == 'left'
    assert by_id[_LATE]['late'] is True
    assert by_id[_LATE]['last_out'] == '09:10'
    assert by_id[_AWAY]['status'] == 'away'
    assert by_id[_AWAY]['away']['deputy'] == 'Заместитель Тест'
    assert by_id[_ABSENT]['status'] == 'absent'
    # Про кого ничего не известно — первыми.
    assert body['people'][0]['status'] == 'absent'
    assert body['counts']['inside'] == 1
    assert body['counts']['late'] == 1
    assert body['counts']['away'] == 1
    assert body['last_event'].startswith('2030-01-15T09:10')


def test_before_shift_nobody_is_absent_yet(app, client, at):
    at(7, 50)
    body = client.get('/api/attendance/now', headers=_auth(app, _HEAD)).get_json()
    statuses = {p['id']: p['status'] for p in body['people']}
    assert statuses[_ABSENT] == 'not_yet'


def test_shift_start_from_env(app, client, at, monkeypatch):
    monkeypatch.setenv('SHIFT_START', '08:30')
    body = client.get('/api/attendance/now', headers=_auth(app, _HEAD)).get_json()
    assert body['shift_start'] == '08:30'
    late = {p['id']: p['late'] for p in body['people']}
    assert late[_LATE] is False


def test_only_managers(app, client, at):
    assert client.get('/api/attendance/now',
                      headers=_auth(app, _EARLY)).status_code == 403
