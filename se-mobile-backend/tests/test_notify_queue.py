"""Уведомления не должны задерживать того, из-за кого они отправляются.

Уведомления уходят через Firebase, то есть через сеть до Google. Пока
Firebase не настроен, это ничего не стоит — но в день, когда его настроят,
каждая отправка станет ожиданием внутри запроса. Звать её умеют турникет,
выкладка меню, загрузка расчётных листков и объявление.

Хуже всего турникет: в пересменку это пятьсот проходов за несколько минут, и
каждый ждал бы Google, прежде чем СКУД получит ответ.
"""

import threading
import time

import app as app_module

_SARSEKEN = '0000002114'


def _drain(timeout=10):
    """Дождаться, пока работник разберёт очередь."""
    queue = app_module._notify_queue
    if queue is None:
        return
    deadline = time.monotonic() + timeout
    while not queue.empty() and time.monotonic() < deadline:
        time.sleep(0.05)
    queue.join()


def test_a_slow_notification_does_not_hold_up_the_turnstile(app, client, monkeypatch):
    monkeypatch.setenv('TURNSTILE_SECRET', 'проверка')

    sent = threading.Event()

    def _slow(*args, **kwargs):
        time.sleep(2)
        sent.set()

    monkeypatch.setattr(app_module, '_send_turnstile_notification', _slow)

    started = time.monotonic()
    answer = client.post('/api/turnstile', json={
        'secret': 'проверка',
        'employee_id': _SARSEKEN,
        'direction': 'in',
    })
    spent = time.monotonic() - started

    assert answer.get_json()['message'] == 'Success'
    assert spent < 1.0, f'СКУД ждал {spent:.1f} с'

    # И уведомление всё-таки уходит — просто не в чужое время.
    assert sent.wait(timeout=10), 'уведомление не отправилось вовсе'
    _drain()

    with app.app_context():
        from models import db, TurnstileEvent
        event = db.session.get(TurnstileEvent, answer.get_json()['id'])
        db.session.delete(event)
        db.session.commit()


def test_one_worker_not_a_thread_per_event(app, monkeypatch):
    """Пятьсот проходов — это пятьсот потоков, если делать по потоку на событие.

    Лекарство вышло бы хуже болезни, поэтому работник один.
    """
    done = []
    monkeypatch.setattr(app_module, '_push_to_everyone',
                        lambda *a, **k: done.append(a))

    before = {t.name for t in threading.enumerate()}
    for i in range(50):
        app_module._notify_later(app, app_module._push_to_everyone, 'Т', f'{i}')
    _drain()

    after = {t.name for t in threading.enumerate()}
    assert len([n for n in after if n == 'notify']) <= 1
    assert len(done) == 50, f'разобрано {len(done)} из 50'
    assert 'notify' in after or 'notify' in before


def test_a_failing_notification_does_not_kill_the_worker(app, monkeypatch):
    """Одно упавшее уведомление не должно уносить с собой все следующие."""
    survived = []

    def _boom(*args, **kwargs):
        raise RuntimeError('Firebase отказал')

    app_module._notify_later(app, _boom)
    app_module._notify_later(app, lambda: survived.append(True))
    _drain()

    assert survived == [True], 'работник умер на первой же ошибке'
