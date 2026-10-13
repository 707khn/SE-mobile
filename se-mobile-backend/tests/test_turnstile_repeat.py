"""Повтор того же прохода от СКУД — не второй проход.

Не дождавшись ответа, СКУД шлёт событие ещё раз. Раньше оно ложилось второй
строкой, и человеку приходило второе «вход в 08:01».
"""

import pytest

import app as app_module
from models import db, Employee, TurnstileEvent

_ID = 'TRN00001'


@pytest.fixture
def gate(app, remove_employee, monkeypatch):
    monkeypatch.setenv('TURNSTILE_SECRET', 'проверка')
    sent = []
    monkeypatch.setattr(app_module, '_notify_later',
                        lambda *a, **k: sent.append(a))
    with app.app_context():
        remove_employee(_ID)
        db.session.add(Employee(employee_id=_ID, full_name='Проходной Тест',
                                job_title='Слесарь'))
        db.session.commit()
    yield sent
    with app.app_context():
        TurnstileEvent.query.filter_by(employee_id=_ID).delete()
        db.session.commit()


def _pass(client, direction='in', timestamp='2026-10-13T08:01:00'):
    body = {'secret': 'проверка', 'employee_id': _ID, 'direction': direction}
    if timestamp:
        body['timestamp'] = timestamp
    return client.post('/api/turnstile', json=body).get_json()


def _count(app):
    with app.app_context():
        return TurnstileEvent.query.filter_by(employee_id=_ID).count()


def test_the_same_event_twice_is_one_pass(app, client, gate):
    first = _pass(client)
    again = _pass(client)
    assert first['message'] == again['message'] == 'Success'
    assert again['id'] == first['id']
    assert again.get('duplicate') is True
    assert _count(app) == 1
    assert len(gate) == 1, 'уведомление ушло дважды'


def test_a_different_time_or_direction_is_a_new_pass(app, client, gate):
    _pass(client)
    _pass(client, timestamp='2026-10-13T08:02:00')
    _pass(client, direction='out')
    assert _count(app) == 3
    assert len(gate) == 3


def test_events_without_device_time_are_not_merged(app, client, gate):
    _pass(client, timestamp=None)
    _pass(client, timestamp=None)
    assert _count(app) == 2
