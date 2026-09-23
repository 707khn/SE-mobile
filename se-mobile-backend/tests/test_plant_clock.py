"""Часы предприятия и часы сервера — не одни и те же.

Сервер стоит в Астане и живёт по UTC. Проходы из СКУД и периоды расчётных
листков записаны местным временем: в выгрузке стоит 07:40, и это 07:40 у
проходной. Пока эти двое не встречаются, всё сходится; встречаются они там,
где сервер спрашивает «какое сегодня число» про местные данные — и с полуночи
до пяти утра его «сегодня» это вчера у проходной.
"""

import os
from datetime import datetime, timedelta, timezone

import app as app_module
from models import db, Employee, TurnstileEvent

_SARSEKEN = '0000002114'


def test_plant_time_is_five_hours_ahead_of_the_server():
    """Казахстан с 1 марта 2024 года живёт в одном поясе, UTC+5."""
    delta = app_module._plant_now() - datetime.utcnow()
    assert timedelta(hours=4, minutes=59) < delta < timedelta(hours=5, minutes=1)


def test_today_is_taken_from_the_plant_not_the_server(app, client, monkeypatch):
    """«Сегодня» на экранах должно быть сегодня у проходной.

    С полуночи до пяти утра оно расходилось с серверным — не «иногда», а
    ровно эти пять часов каждые сутки: меню столовой показывалось вчерашнее,
    табель за «сегодня» — за вчера. Проверка подменяет дату предприятия: если
    экран берёт её у себя (date.today()), подмена до него не дойдёт.
    """
    from datetime import date as _date
    pretend = _date(2031, 5, 6)
    monkeypatch.setattr(app_module, '_plant_today', lambda: pretend)
    assert pretend != _date.today(), 'подменять надо на другой день'

    assert client.get('/api/menu').get_json().get('date') == pretend.isoformat()

    with app.app_context():
        token = app_module._issue_token(
            app_module._authenticate('admin', os.environ['ADMIN_PASSWORD']))
    table = client.get('/api/attendance',
                       headers={'Authorization': f'Bearer {token}'}).get_json()
    assert table.get('date') == pretend.isoformat()


def test_a_live_pass_lands_in_the_same_hours_as_the_upload(app, client, monkeypatch):
    """Турникет без своего времени не должен записывать проход на пять часов раньше.

    В той же таблице лежат проходы из выгрузки, записанные местным временем.
    С utcnow приход в 08:00 оказался бы рядом с приходом в 03:00 — по одному
    и тому же турникету.
    """
    monkeypatch.setenv('TURNSTILE_SECRET', 'проверка')

    before = app_module._plant_now()
    answer = client.post('/api/turnstile', json={
        'secret': 'проверка',
        'employee_id': _SARSEKEN,
        'direction': 'in',
    })
    assert answer.get_json()['message'] == 'Success'
    event_id = answer.get_json()['id']

    with app.app_context():
        event = db.session.get(TurnstileEvent, event_id)
        assert before - timedelta(minutes=1) <= event.timestamp \
            <= app_module._plant_now() + timedelta(minutes=1)
        db.session.delete(event)
        db.session.commit()


def test_a_pass_with_an_offset_is_converted_not_trusted(app, client, monkeypatch):
    """Прислали время со смещением — приводим к местному, а не кладём как есть."""
    monkeypatch.setenv('TURNSTILE_SECRET', 'проверка')

    answer = client.post('/api/turnstile', json={
        'secret': 'проверка',
        'employee_id': _SARSEKEN,
        'direction': 'out',
        # Полночь UTC — это пять утра у проходной.
        'timestamp': '2031-05-06T00:00:00+00:00',
    })
    event_id = answer.get_json()['id']

    with app.app_context():
        event = db.session.get(TurnstileEvent, event_id)
        assert event.timestamp == datetime(2031, 5, 6, 5, 0)
        db.session.delete(event)
        db.session.commit()


def test_news_time_says_which_clock_it_is_on(app, client):
    """Время новости сервер хранит в UTC — пусть телефон об этом знает.

    Без смещения телефон считал его местным, и новость, вышедшая ночью,
    показывалась вчерашней.
    """
    from models import NewsItem
    with app.app_context():
        item = NewsItem(source='announcement', title='Проверка часов',
                        summary='', is_published=True,
                        published_at=datetime(2031, 5, 6, 20, 30))
        db.session.add(item)
        db.session.commit()
        payload = app_module._news_json(item)
        db.session.delete(item)
        db.session.commit()

    assert payload['published_at'].endswith('+00:00')
    # И это ровно то же мгновение, а не сдвинутое.
    assert datetime.fromisoformat(payload['published_at']) == \
        datetime(2031, 5, 6, 20, 30, tzinfo=timezone.utc)
