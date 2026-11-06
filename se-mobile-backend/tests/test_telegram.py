"""Уведомления в Telegram: подключение по ссылке, вебхук, отправка.

Сам Telegram здесь не нужен: подменяем вызов Bot API (telegram_bot._call) и
смотрим, что сервер у него просил и что сделал с ответом.
"""

import hashlib
import io
import json
import os
import time
import urllib.error
from datetime import datetime, timedelta
from types import SimpleNamespace

import pytest
from werkzeug.security import generate_password_hash

import app as app_module
import telegram_bot
from models import db, Employee, FcmToken, NewsItem, Notification, UserAccount
from telegram_bot import TelegramChat, TelegramError, TelegramLinkCode

_TOKEN = '123456:TEST-not-a-real-token'
_BOT = 'se_mobile_test_bot'
_ONE, _TWO = 'TGRM0001', 'TGRM0002'
_CHAT_ONE, _CHAT_TWO = 700000001, 700000002


def _drain(timeout=10):
    """Дождаться, пока работник Telegram разберёт очередь."""
    q = telegram_bot._send_queue
    if q is None:
        return
    deadline = time.monotonic() + timeout
    while q.unfinished_tasks and time.monotonic() < deadline:
        time.sleep(0.02)


def _drain_notify(timeout=10):
    """И общую очередь уведомлений (пуш) — из неё ставится Telegram."""
    q = app_module._notify_queue
    if q is None:
        return
    deadline = time.monotonic() + timeout
    while q.unfinished_tasks and time.monotonic() < deadline:
        time.sleep(0.02)


@pytest.fixture
def bot(monkeypatch):
    """Бот «настроен», а Telegram записывает, что у него просили.

    `answers` — что ответить на метод: значение — его result, исключение —
    бросить, функция — спросить её (ей дают параметры вызова).
    """
    monkeypatch.setenv('TELEGRAM_PUSH_TOKEN', _TOKEN)
    monkeypatch.delenv('TELEGRAM_WEBHOOK_URL', raising=False)
    monkeypatch.setattr(telegram_bot, '_cache', {})
    monkeypatch.setattr(telegram_bot, '_paused_until', 0.0)
    monkeypatch.setattr(telegram_bot, '_SEND_GAP', 0)
    calls = []
    answers = {
        'getMe': {'id': 1, 'is_bot': True, 'username': _BOT},
        'getWebhookInfo': {'url': telegram_bot._DEFAULT_WEBHOOK_URL,
                           'pending_update_count': 0},
    }

    def _call(method, params=None, timeout=10):
        calls.append((method, params or {}))
        answer = answers.get(method, True)
        if callable(answer):
            answer = answer(params or {})
        if isinstance(answer, BaseException):
            raise answer
        return answer

    monkeypatch.setattr(telegram_bot, '_call', _call)
    state = SimpleNamespace(calls=calls, answers=answers)
    state.sent = lambda: [p for m, p in calls if m == 'sendMessage']
    yield state
    # До того, как monkeypatch вернёт настоящий _call: иначе работник дошлёт
    # остаток очереди уже в настоящий Telegram.
    _drain()


@pytest.fixture
def people(app, remove_employee):
    """Двое сотрудников, у каждого своя учётка."""
    with app.app_context():
        for employee_id in (_ONE, _TWO):
            remove_employee(employee_id)
            db.session.add(Employee(employee_id=employee_id,
                                    full_name='Телеграмов Тест Тестович',
                                    job_title='Слесарь'))
        db.session.flush()
        for employee_id in (_ONE, _TWO):
            db.session.add(UserAccount(login=employee_id.lower(),
                                       employee_id=employee_id,
                                       password_hash=generate_password_hash('x'),
                                       must_change_password=False))
        db.session.commit()
    yield (_ONE, _TWO)


def _bearer(app, employee_id):
    with app.app_context():
        return {'Authorization': f'Bearer {app_module._issue_token(employee_id)}'}


def _admin(app):
    with app.app_context():
        admin = app_module._authenticate('admin', os.environ['ADMIN_PASSWORD'])
    return _bearer(app, admin)


def _hook(client, update, secret=None):
    if secret is None:
        secret = telegram_bot._webhook_secret()
    return client.post('/api/telegram/webhook', data=json.dumps(update),
                       content_type='application/json',
                       headers={'X-Telegram-Bot-Api-Secret-Token': secret})


def _message(client, chat_id, text, chat_type='private', secret=None):
    return _hook(client, {
        'update_id': 1,
        'message': {'message_id': 1, 'date': 0, 'text': text,
                    'from': {'id': chat_id, 'is_bot': False, 'first_name': 'Т'},
                    'chat': {'id': chat_id, 'type': chat_type}},
    }, secret=secret)


def _new_link(client, headers):
    answer = client.post('/api/telegram/link', headers=headers)
    assert answer.status_code == 200, answer.get_json()
    return answer.get_json()


def _code(url):
    return url.split('?start=', 1)[1]


def _link(client, app, employee_id, chat_id):
    """Подключить Telegram, как это сделал бы человек: ссылка → «Запустить»."""
    url = _new_link(client, _bearer(app, employee_id))['url']
    reply = _message(client, chat_id, f'/start {_code(url)}').get_json()
    assert reply['text'].startswith('Готово'), reply


def _linked(app, employee_id):
    with app.app_context():
        return [c.chat_id for c in
                TelegramChat.query.filter_by(employee_id=employee_id)]


# ── Без бота ─────────────────────────────────────────────────────────────────

def test_without_a_bot_nothing_is_offered(app, client, people, monkeypatch):
    """Строки в «Настройках» нет, ссылку не выдать, вебхука нет."""
    monkeypatch.delenv('TELEGRAM_PUSH_TOKEN', raising=False)
    headers = _bearer(app, _ONE)
    answer = client.get('/api/telegram', headers=headers).get_json()
    assert answer == {'message': 'Success', 'enabled': False, 'linked': False}
    assert client.post('/api/telegram/link', headers=headers).status_code == 503
    assert _message(client, _CHAT_ONE, '/start x', secret='').status_code == 404
    with app.app_context():
        assert telegram_bot.deliver([_ONE], 'Т', 'т') == 0
        assert telegram_bot.linked_employee_ids() == []
        state = telegram_bot.state()
    assert state['enabled'] is False
    assert 'TELEGRAM_PUSH_TOKEN' in state['problem']


def test_without_a_pass_there_is_nobody_to_link(client, bot):
    """Чей чат подключать, без пропуска не узнать — даже в переходном режиме."""
    assert client.get('/api/telegram').status_code == 401
    assert client.post('/api/telegram/link').status_code == 401
    assert client.delete('/api/telegram').status_code == 401


# ── Подключение ──────────────────────────────────────────────────────────────

def test_link_start_and_done(app, client, people, bot):
    headers = _bearer(app, _ONE)
    assert client.get('/api/telegram', headers=headers).get_json()['linked'] is False

    link = _new_link(client, headers)
    assert link['url'].startswith(f'https://t.me/{_BOT}?start=')
    assert link['expires_in'] == 1800
    code = _code(link['url'])
    # Telegram пропускает в ?start= только это и не длиннее 64 знаков.
    assert len(code) <= 64 and all(c.isalnum() or c in '-_' for c in code)

    # Адрес вебхука сервер сообщил сам, с секретом.
    (hook,) = [p for m, p in bot.calls if m == 'setWebhook']
    assert hook['url'] == 'https://api.se-btrz.com/api/telegram/webhook'
    assert hook['secret_token'] == telegram_bot._webhook_secret()
    assert set(hook['allowed_updates']) == {'message', 'my_chat_member'}

    # В базе — хеш кода, а не он сам.
    with app.app_context():
        (row,) = TelegramLinkCode.query.filter_by(employee_id=_ONE).all()
        assert row.code_hash == hashlib.sha256(code.encode()).hexdigest()
        assert code not in row.code_hash

    reply = _message(client, _CHAT_ONE, f'/start {code}').get_json()
    assert reply['method'] == 'sendMessage'
    assert reply['chat_id'] == _CHAT_ONE
    assert reply['text'].startswith('Готово')
    assert _linked(app, _ONE) == [str(_CHAT_ONE)]
    assert client.get('/api/telegram', headers=headers).get_json() == {
        'message': 'Success', 'enabled': True, 'linked': True}


def test_a_code_works_once(app, client, people, bot):
    """Ссылку переслали или открыли второй раз — второй чат не подключится."""
    code = _code(_new_link(client, _bearer(app, _ONE))['url'])
    _message(client, _CHAT_ONE, f'/start {code}')
    reply = _message(client, _CHAT_TWO, f'/start {code}').get_json()
    assert 'устарела' in reply['text']
    assert _linked(app, _ONE) == [str(_CHAT_ONE)]


def test_an_old_code_does_not_link(app, client, people, bot):
    code = _code(_new_link(client, _bearer(app, _ONE))['url'])
    with app.app_context():
        row = TelegramLinkCode.query.filter_by(employee_id=_ONE).one()
        row.expires_at = datetime.utcnow() - timedelta(seconds=1)
        db.session.commit()
    reply = _message(client, _CHAT_ONE, f'/start {code}').get_json()
    assert 'устарела' in reply['text']
    assert _linked(app, _ONE) == []
    with app.app_context():
        assert TelegramLinkCode.query.filter_by(employee_id=_ONE).count() == 0


def test_a_new_link_cancels_the_previous_one(app, client, people, bot):
    headers = _bearer(app, _ONE)
    first = _code(_new_link(client, headers)['url'])
    second = _code(_new_link(client, headers)['url'])
    assert 'устарела' in _message(client, _CHAT_ONE, f'/start {first}').get_json()['text']
    assert _message(client, _CHAT_ONE, f'/start {second}').get_json()['text'].startswith('Готово')
    # Вебхук задаётся раз на процесс, а не на каждую ссылку.
    assert [m for m, _ in bot.calls].count('setWebhook') == 1


def test_a_new_chat_replaces_the_old_one(app, client, people, bot):
    _link(client, app, _ONE, _CHAT_ONE)
    _link(client, app, _ONE, _CHAT_TWO)
    assert _linked(app, _ONE) == [str(_CHAT_TWO)]


def test_the_webhook_wants_the_secret(app, client, people, bot):
    code = _code(_new_link(client, _bearer(app, _ONE))['url'])
    assert _message(client, _CHAT_ONE, f'/start {code}', secret='угадал').status_code == 403
    answer = client.post('/api/telegram/webhook', json={'message': {}})
    assert answer.status_code == 403
    assert _linked(app, _ONE) == []


def test_groups_are_not_linked(app, client, people, bot):
    """Уведомления личные: бота добавили в группу — в группу их не шлём."""
    code = _code(_new_link(client, _bearer(app, _ONE))['url'])
    answer = _message(client, -100123, f'/start {code}', chat_type='supergroup')
    assert answer.status_code == 200
    assert answer.get_json() == {}
    assert _linked(app, _ONE) == []


def test_start_without_a_code_explains_where_to_link(client, bot):
    reply = _message(client, _CHAT_ONE, '/start').get_json()
    assert '«Настройки» → «Уведомления в Telegram»' in reply['text']
    reply = _message(client, _CHAT_ONE, 'привет').get_json()
    assert 'не приходят' in reply['text']


@pytest.mark.parametrize('update', [
    [], 'мусор', {}, {'message': 'мусор'}, {'message': {'chat': 'мусор'}},
    {'message': {'chat': {'type': 'private'}}},
    {'message': {'chat': {'id': 1, 'type': 'private'}, 'text': ['/start']}},
    {'my_chat_member': {'chat': {'id': 1}, 'new_chat_member': 'мусор'}},
    {'edited_message': {'text': '/stop'}},
])
def test_odd_updates_are_answered_not_crashed_on(client, bot, update):
    """Что бы ни принёс Telegram — 200: на ошибку он принёс бы то же снова."""
    assert _hook(client, update).status_code == 200


# ── Отключение ───────────────────────────────────────────────────────────────

def test_stop_command_unlinks(app, client, people, bot):
    _link(client, app, _ONE, _CHAT_ONE)
    assert 'отключены' in _message(client, _CHAT_ONE, '/stop').get_json()['text']
    assert _linked(app, _ONE) == []
    assert 'не приходят' in _message(client, _CHAT_ONE, '/stop').get_json()['text']


def test_blocking_the_bot_unlinks(app, client, people, bot):
    _link(client, app, _ONE, _CHAT_ONE)
    answer = _hook(client, {'update_id': 2, 'my_chat_member': {
        'chat': {'id': _CHAT_ONE, 'type': 'private'},
        'old_chat_member': {'status': 'member'},
        'new_chat_member': {'status': 'kicked'},
    }})
    assert answer.status_code == 200
    assert _linked(app, _ONE) == []


def test_unlink_in_the_app_says_goodbye(app, client, people, bot):
    _link(client, app, _ONE, _CHAT_ONE)
    headers = _bearer(app, _ONE)
    answer = client.delete('/api/telegram', headers=headers)
    assert answer.get_json() == {'message': 'Success', 'linked': False}
    assert client.get('/api/telegram', headers=headers).get_json()['linked'] is False
    _drain()
    (goodbye,) = bot.sent()
    assert goodbye['chat_id'] == str(_CHAT_ONE)
    assert 'больше не приходят' in goodbye['text']


def test_a_disabled_account_loses_telegram(app, client, people, bot):
    """Уволенному уведомления предприятия в личный Telegram — незачем."""
    _link(client, app, _ONE, _CHAT_ONE)
    answer = client.post(f'/api/admin/accounts/{_ONE.lower()}/active',
                         headers=_admin(app), json={'active': False})
    assert answer.status_code == 200
    assert _linked(app, _ONE) == []


def test_a_password_reset_unlinks_telegram(app, client, people, bot):
    """Сброс закрывает вход на всех устройствах — и Telegram тоже: его мог
    подключить тот, кто вошёл под чужим табельным."""
    _link(client, app, _ONE, _CHAT_ONE)
    _new_link(client, _bearer(app, _TWO))
    with app.app_context():
        for employee_id in (_ONE, _TWO):
            account = UserAccount.query.filter_by(employee_id=employee_id).one()
            app_module.reset_password(account, generate_password_hash('0000'))
        db.session.commit()
        assert TelegramLinkCode.query.filter_by(employee_id=_TWO).count() == 0
    assert _linked(app, _ONE) == []


# ── Отправка ─────────────────────────────────────────────────────────────────

def test_a_push_goes_to_telegram_too(app, client, people, bot, monkeypatch):
    """То же, что пушем, — и без Firebase: в веб-версии его нет."""
    monkeypatch.setattr(app_module, '_get_firebase', lambda: None)
    _link(client, app, _ONE, _CHAT_ONE)
    with app.app_context():
        app_module._push_to([_ONE, _TWO], 'Зарплата',
                            'Расчётный лист за сентябрь готов', {'type': 'payslip'})
    _drain()
    (message,) = bot.sent()
    assert message['chat_id'] == str(_CHAT_ONE)
    assert message['text'] == '<b>Зарплата</b>\nРасчётный лист за сентябрь готов'
    assert message['parse_mode'] == 'HTML'


def test_everyone_includes_people_without_the_android_app(app, client, people,
                                                          bot, monkeypatch):
    """Уведомление «всем» шло тем, у кого есть токен Firebase. У человека с
    iPhone его нет и не будет — есть Telegram."""
    monkeypatch.setattr(app_module, '_get_firebase', lambda: None)
    _link(client, app, _ONE, _CHAT_ONE)
    with app.app_context():
        assert FcmToken.query.filter_by(employee_id=_ONE).count() == 0
        app_module._notify_menu_published('Меню на завтра опубликовано')
    _drain()
    texts = [m['text'] for m in bot.sent() if m['chat_id'] == str(_CHAT_ONE)]
    assert texts == ['<b>Столовая</b>\nМеню на завтра опубликовано 🍽️']


def test_one_chat_gets_one_message(app, client, people, bot, monkeypatch):
    """Две учётки одного человека в одном чате — одно сообщение, не два."""
    monkeypatch.setattr(app_module, '_get_firebase', lambda: None)
    _link(client, app, _ONE, _CHAT_ONE)
    _link(client, app, _TWO, _CHAT_ONE)
    with app.app_context():
        app_module._push_to([_ONE, _TWO], 'Новость', 'Заголовок')
    _drain()
    assert len(bot.sent()) == 1


def test_markup_in_the_text_is_just_text(app, client, people, bot):
    _link(client, app, _ONE, _CHAT_ONE)
    with app.app_context():
        telegram_bot.deliver([_ONE], 'Новость', 'Цех <№3> & склад')
    _drain()
    (message,) = bot.sent()
    assert message['text'] == '<b>Новость</b>\nЦех &lt;№3&gt; &amp; склад'


def test_announcement_text_stays_off_telegram(app, client, people, bot):
    """Как и в пуше: текст внутреннего объявления — в ленте приложения, а в
    Telegram только «Новое объявление»."""
    _link(client, app, _ONE, _CHAT_ONE)
    with app.app_context():
        before = db.session.query(db.func.max(Notification.id)).scalar() or 0
    title = 'Сокращение смены в цехе №3 с 1 декабря'
    answer = client.post('/api/admin/news', headers=_admin(app),
                         json={'title': title, 'summary': 'Подробности'})
    assert answer.status_code == 200
    _drain_notify()
    _drain()
    texts = [m['text'] for m in bot.sent() if m['chat_id'] == str(_CHAT_ONE)]
    assert texts == ['<b>Объявление</b>\nНовое объявление — откройте SE-mobile']
    with app.app_context():
        db.session.delete(db.session.get(NewsItem, answer.get_json()['item']['id']))
        Notification.query.filter(Notification.id > before).delete()
        db.session.commit()


def test_a_blocked_bot_forgets_the_chat(app, client, people, bot):
    _link(client, app, _ONE, _CHAT_ONE)
    bot.answers['sendMessage'] = TelegramError(
        403, 'Forbidden: bot was blocked by the user')
    with app.app_context():
        telegram_bot.deliver([_ONE], 'Т', 'т')
    _drain()
    assert _linked(app, _ONE) == []


def test_too_fast_waits_and_repeats(app, client, people, bot):
    """429 — Telegram говорит, сколько подождать; ждём и повторяем."""
    _link(client, app, _ONE, _CHAT_ONE)
    answers = [TelegramError(429, 'Too Many Requests', retry_after=0), True]
    bot.answers['sendMessage'] = lambda params: answers.pop(0)
    with app.app_context():
        telegram_bot.deliver([_ONE], 'Т', 'т')
    _drain()
    assert len(bot.sent()) == 2
    assert answers == []
    assert _linked(app, _ONE) == [str(_CHAT_ONE)]


def test_telegram_down_does_not_hold_up_everyone(app, client, people, bot):
    """Сеть до Telegram упала — минуту его не ждём: иначе пятьсот сообщений
    по десять секунд ожидания каждое."""
    _link(client, app, _ONE, _CHAT_ONE)
    _link(client, app, _TWO, _CHAT_TWO)
    bot.answers['sendMessage'] = OSError('Network is unreachable')
    with app.app_context():
        assert telegram_bot.deliver([_ONE, _TWO], 'Т', 'т') == 2
    _drain()
    assert len(bot.sent()) == 1
    # И чаты остаются: сеть — не повод отвязывать людей.
    assert _linked(app, _ONE) and _linked(app, _TWO)


def test_telegram_down_link_says_so(app, client, people, bot):
    bot.answers['getMe'] = OSError('Network is unreachable')
    answer = client.post('/api/telegram/link', headers=_bearer(app, _ONE))
    assert answer.status_code == 503
    assert answer.get_json()['error'] == 'telegram_unavailable'


# ── «Обновление» у администратора ────────────────────────────────────────────

def test_the_admin_sees_the_bot_and_who_linked(app, client, people, bot):
    _link(client, app, _ONE, _CHAT_ONE)
    report = client.get('/api/admin/rollout', headers=_admin(app)).get_json()
    state = report['telegram']
    assert state['enabled'] is True
    assert state['bot'] == f'@{_BOT}'
    assert state['people'] >= 1
    assert state['problem'] == ''


def test_the_admin_screen_sets_a_missing_webhook(app, bot):
    """Бота завели, никто ещё не нажимал «Подключить» — адрес задаётся сразу."""
    bot.answers['getWebhookInfo'] = lambda params: (
        {'url': telegram_bot._DEFAULT_WEBHOOK_URL}
        if any(m == 'setWebhook' for m, _ in bot.calls) else {'url': ''})
    with app.app_context():
        state = telegram_bot.state()
    assert state['problem'] == ''
    assert [m for m, _ in bot.calls].count('setWebhook') == 1


def test_the_admin_sees_a_wrong_token(app, bot):
    bot.answers['getMe'] = TelegramError(401, 'Unauthorized')
    with app.app_context():
        state = telegram_bot.state()
    assert state['enabled'] is True
    assert 'TELEGRAM_PUSH_TOKEN' in state['problem']


def test_the_admin_sees_a_fresh_delivery_error(app, bot):
    bot.answers['getWebhookInfo'] = {
        'url': telegram_bot._DEFAULT_WEBHOOK_URL,
        'last_error_date': int(time.time()) - 60,
        'last_error_message': 'Wrong response from the webhook: 502 Bad Gateway',
    }
    with app.app_context():
        assert '502' in telegram_bot.state()['problem']
    # Вчерашнюю, давно починенную, Telegram помнит — мы о ней молчим.
    bot.answers['getWebhookInfo']['last_error_date'] = int(time.time()) - 3 * 86400
    with app.app_context():
        assert telegram_bot.state()['problem'] == ''


# ── Сам вызов Bot API ────────────────────────────────────────────────────────

class _Answer(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_call_reads_answers_and_refusals(monkeypatch):
    """Отказ Telegram — с кодом и сроком повтора; токен — ни в одной ошибке."""
    monkeypatch.setenv('TELEGRAM_PUSH_TOKEN', _TOKEN)
    seen = []

    def _ok(req, timeout):
        seen.append(req)
        return _Answer(b'{"ok": true, "result": {"username": "b"}}')

    monkeypatch.setattr(telegram_bot.urllib.request, 'urlopen', _ok)
    assert telegram_bot._call('getMe') == {'username': 'b'}
    assert seen[0].full_url == f'https://api.telegram.org/bot{_TOKEN}/getMe'

    def _refused(req, timeout):
        raise urllib.error.HTTPError(
            req.full_url, 429, 'Too Many Requests', {},
            io.BytesIO(b'{"ok": false, "error_code": 429, "description": '
                       b'"Too Many Requests: retry after 7", '
                       b'"parameters": {"retry_after": 7}}'))

    monkeypatch.setattr(telegram_bot.urllib.request, 'urlopen', _refused)
    with pytest.raises(TelegramError) as caught:
        telegram_bot._call('sendMessage', {'chat_id': 1, 'text': 'т'})
    assert caught.value.code == 429
    assert caught.value.retry_after == 7
    assert _TOKEN not in str(caught.value)

    def _garbage(req, timeout):
        return _Answer(b'<html>502</html>')

    monkeypatch.setattr(telegram_bot.urllib.request, 'urlopen', _garbage)
    with pytest.raises(TelegramError):
        telegram_bot._call('getMe')

    # Если токен всё же оказался в тексте ошибки — в журнал он не попадёт.
    assert _TOKEN not in telegram_bot._safe(
        OSError(f'https://api.telegram.org/bot{_TOKEN}/getMe'))


def test_a_mangled_token_never_reaches_the_url(monkeypatch):
    """Перевод строки внутри токена urllib отверг бы вместе с адресом в
    тексте ошибки — то есть с токеном. До адреса такой токен не доходит."""
    mangled = '123456:ABC\ndef'
    monkeypatch.setenv('TELEGRAM_PUSH_TOKEN', mangled)
    monkeypatch.setattr(telegram_bot.urllib.request, 'urlopen',
                        lambda *a, **k: pytest.fail('ушло в сеть'))
    with pytest.raises(TelegramError) as caught:
        telegram_bot._call('getMe')
    assert caught.value.code == 401
    assert 'ABC' not in str(caught.value)
