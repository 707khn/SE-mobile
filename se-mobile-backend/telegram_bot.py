"""Уведомления в Telegram — там, куда пуш не доходит.

Пуш через Firebase доходит только до приложения для Android. В веб-версии
его нет: на iPhone SE-mobile открывают в Safari (сборку для iPhone без
платной учётной записи Apple не раздать), а уведомлений в браузер Firebase
у нас не настроен. Поэтому в веб-версии человек подключает Telegram —
«Настройки» → «Уведомления в Telegram», — и сервер присылает туда то же,
что Android-телефонам приходит пушем: «Расчётный лист за сентябрь готов»,
«Меню на завтра опубликовано», заголовок новости с сайта, «Новое объявление
— откройте SE-mobile». Отправка у обоих путей одна — _push_to в app.py, —
и разойтись они не могут.

Как подключается. «Подключить Telegram» в приложении — сервер выдаёт
одноразовую ссылку на бота, t.me/<бот>?start=<код>. Человек открывает её,
нажимает «Запустить» (Start), и бот получает «/start <код>». По коду сервер
узнаёт, чей это чат, и запоминает номер чата. Код живёт полчаса и годится
один раз; в базе лежит его хеш, как у пропусков: по утёкшей копии базы
чужой Telegram не подключить.

Как сервер узнаёт про «Запустить». Сообщения боту Telegram приносит сам, на
/api/telegram/webhook. Адрес сервер сообщает Telegram при первой выдаче
ссылки, а вместе с ним — секрет, который Telegram кладёт в заголовок каждого
такого запроса: чужой запрос на этот адрес ничего не подключит и не
отключит.

Что видит Telegram. То же, что Google в пуше, — только повод: ни сумм, ни
имён, ни текста внутренних объявлений. И номер чата: без него не доставить.

Настройка — одна строка в /etc/se-mobile.env (deploy/README.md,
«Уведомления в Telegram»):
    TELEGRAM_PUSH_TOKEN=123456:ABC…    токен бота от @BotFather
Без неё строки «Уведомления в Telegram» в «Настройках» нет, и всё здесь
молча ничего не делает. Бот — свой, не тот, что шлёт сигналы администратору
(/etc/se-mobile-alerts.env): тому пишет один человек, этому — сотни.
"""

import hashlib
import hmac
import html
import json
import logging
import os
import queue
import re
import secrets
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta

from flask import current_app, g, jsonify, request
from sqlalchemy import or_

from models import db

_API = 'https://api.telegram.org'
_WEBHOOK_PATH = '/api/telegram/webhook'
_DEFAULT_WEBHOOK_URL = 'https://api.se-btrz.com' + _WEBHOOK_PATH

# Сколько живёт ссылка «Подключить». Полчаса — с запасом на то, чтобы
# поставить Telegram, если его нет, и войти в него.
_CODE_LIFETIME = timedelta(minutes=30)

_TIMEOUT = 10

# Так выглядит токен от @BotFather: номер бота, двоеточие, секрет.
_TOKEN_SHAPE = re.compile(r'\d+:[A-Za-z0-9_-]+')

# Telegram пропускает от одного бота около тридцати сообщений в секунду.
# Держимся ниже: «Меню опубликовано» пятистам людям уйдёт за полминуты.
_SEND_GAP = 0.05
_SEND_QUEUE_LIMIT = 5000

# Сколько раз пробовать сообщение, на которое Telegram ответил «не так
# часто» (429): он сам говорит, через сколько секунд повторить.
_RETRIES = 3

# Telegram не отвечает — минуту не ждём его на каждом сообщении. Иначе
# рассылка пятистам при упавшей сети — это пятьсот ожиданий по десять секунд,
# и всё, что встанет в очередь после, придёт через полтора часа.
_PAUSE_AFTER_NETWORK_ERROR = 60


class TelegramChat(db.Model):
    """Чат с ботом, куда слать уведомления сотрудника.

    Строка на чат, а не столбец у сотрудника и не сотрудник ключом: при
    склейке записей сотрудника (_absorb_employee в app.py) строки переезжают
    на действующую запись, и одна строка на человека упёрлась бы там в
    ограничение. Второй чат приложение подключить не даёт: новый заменяет
    прежний.
    """
    __tablename__ = 'telegram_chats'
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    # Номер чата Telegram. Строкой: он бывает длиннее 32 бит.
    chat_id = db.Column(db.String(32), nullable=False, index=True)
    linked_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class TelegramLinkCode(db.Model):
    """Одноразовый код из ссылки на бота: чей чат сейчас подключается."""
    __tablename__ = 'telegram_link_codes'
    # SHA-256 кода, а не сам код — как у пропусков.
    code_hash = db.Column(db.String(64), primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    expires_at = db.Column(db.DateTime, nullable=False)


class TelegramError(Exception):
    """Telegram ответил отказом: код, описание и — при 429 — через сколько
    секунд повторить."""

    def __init__(self, code, description, retry_after=None):
        super().__init__(f'{code}: {description}')
        self.code = code
        self.description = description or ''
        self.retry_after = retry_after


def _token():
    return os.environ.get('TELEGRAM_PUSH_TOKEN', '').strip()


def enabled():
    """Задан ли бот. Нет — здесь не работает ничего."""
    return bool(_token())


def _webhook_url():
    """Куда Telegram приносит сообщения боту.

    Адрес сервера в коде уже есть — его же зовёт приложение. Переменная —
    для проверки на другом сервере.
    """
    return os.environ.get('TELEGRAM_WEBHOOK_URL', '').strip() or _DEFAULT_WEBHOOK_URL


def _webhook_secret():
    """Секрет, который Telegram кладёт в каждый запрос на вебхук.

    Выводится из токена: у трёх процессов gunicorn он один и тот же без
    отдельной настройки, а сменили бота — сменился и секрет.
    """
    return hmac.new(_token().encode(), b'se-mobile telegram webhook',
                    hashlib.sha256).hexdigest()


def _hash(code):
    return hashlib.sha256(code.encode()).hexdigest()


def _safe(error):
    """Текст ошибки для журнала — без токена бота, даже если он туда попал:
    токен стоит в адресе каждого запроса к Telegram."""
    text = str(error)
    token = _token()
    return text.replace(token, '***') if token else text


def _retry_after(answer):
    parameters = answer.get('parameters')
    return parameters.get('retry_after') if isinstance(parameters, dict) else None


def _call(method, params=None, timeout=_TIMEOUT):
    """Метод Bot API → его `result`.

    Отказ Telegram — TelegramError, сеть — OSError (urllib.error.URLError —
    его наследник).
    """
    token = _token()
    if not token:
        raise TelegramError(0, 'бот не настроен')
    # Токен идёт в адрес запроса. Кривой — с пробелом или переводом строки
    # внутри — urllib отверг бы вместе с адресом в тексте ошибки, и токен
    # уехал бы в журнал.
    if not _TOKEN_SHAPE.fullmatch(token):
        raise TelegramError(401, 'токен не похож на выданный @BotFather')
    data = json.dumps(params or {}, ensure_ascii=False).encode()
    req = urllib.request.Request(
        f'{_API}/bot{token}/{method}', data=data,
        headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read()
    except urllib.error.HTTPError as e:
        try:
            answer = json.loads(e.read() or b'{}')
        except Exception:
            answer = {}
        if not isinstance(answer, dict):
            answer = {}
        raise TelegramError(e.code, answer.get('description') or str(e.reason),
                            _retry_after(answer))
    try:
        answer = json.loads(raw or b'{}')
    except ValueError:
        answer = None
    if not isinstance(answer, dict):
        raise TelegramError(0, 'непонятный ответ')
    if not answer.get('ok'):
        raise TelegramError(answer.get('error_code') or 0,
                            answer.get('description') or 'отказ без объяснения',
                            _retry_after(answer))
    return answer.get('result')


# Что Telegram ответил однажды и от запуска к запуску не меняет: имя бота,
# заданный вебхук. По ключу с токеном — сменили бота, спросим заново.
_cache = {}


def bot_username():
    """Имя бота без «@» — у Telegram, один раз на процесс."""
    key = ('me', _token())
    if key not in _cache:
        me = _call('getMe', timeout=5)
        name = me.get('username') if isinstance(me, dict) else ''
        if not name:
            raise TelegramError(0, 'Telegram не назвал имя бота')
        _cache[key] = name
    return _cache[key]


def ensure_webhook(force=False):
    """Сказать Telegram, куда приносить сообщения боту, — один раз на процесс.

    Повторять не страшно: Telegram отвечает «уже задан». Но и незачем —
    адрес и секрет от запуска к запуску не меняются.
    """
    key = ('webhook', _token(), _webhook_url())
    if key in _cache and not force:
        return
    _call('setWebhook', {
        'url': _webhook_url(),
        'secret_token': _webhook_secret(),
        'allowed_updates': ['message', 'my_chat_member'],
    })
    # «/stop» — в меню бота, чтобы отключиться можно было и не открывая
    # приложение. Не вышло — не беда: команда работает и без меню.
    try:
        _call('setMyCommands', {'commands': [
            {'command': 'stop', 'description': 'Отключить уведомления SE-mobile'},
        ]})
    except (TelegramError, OSError) as e:
        logging.info('Telegram: меню бота не задано: %s', _safe(e))
    _cache[key] = True


def new_link(employee_id):
    """Одноразовая ссылка на бота для этого сотрудника. Прежняя гаснет."""
    username = bot_username()
    ensure_webhook()
    # 32 знака из [A-Za-z0-9_-] — ровно то, что Telegram пропускает в
    # ссылке ?start= (до 64 знаков).
    code = secrets.token_urlsafe(24)
    now = datetime.utcnow()
    TelegramLinkCode.query.filter(or_(
        TelegramLinkCode.employee_id == employee_id,
        TelegramLinkCode.expires_at < now,
    )).delete(synchronize_session=False)
    db.session.add(TelegramLinkCode(code_hash=_hash(code), employee_id=employee_id,
                                    expires_at=now + _CODE_LIFETIME))
    db.session.commit()
    return f'https://t.me/{username}?start={code}'


def is_linked(employee_id):
    return TelegramChat.query.filter_by(employee_id=employee_id).first() is not None


def forget(employee_id):
    """Отвязать Telegram сотрудника: учётную запись отключили или сбросили.

    Без commit — его делает тот, кто зовёт, вместе с остальным.
    """
    TelegramChat.query.filter_by(employee_id=employee_id).delete(
        synchronize_session=False)
    TelegramLinkCode.query.filter_by(employee_id=employee_id).delete(
        synchronize_session=False)


def _link(code, chat_id):
    """«/start <код>» → чат подключён к сотруднику, чей это код.

    True — подключён; False — кода нет, он уже погашен или устарел.
    """
    row = db.session.get(TelegramLinkCode, _hash(code)) if code else None
    if row is None:
        return False
    fresh = row.expires_at > datetime.utcnow()
    employee_id = row.employee_id
    db.session.delete(row)
    if fresh:
        TelegramChat.query.filter_by(employee_id=employee_id).delete(
            synchronize_session=False)
        db.session.add(TelegramChat(employee_id=employee_id, chat_id=str(chat_id)))
    db.session.commit()
    if fresh:
        logging.info('Telegram подключён: сотрудник %s', employee_id)
    return fresh


def _forget_chat(chat_id):
    """Чат больше не наш: человек остановил бота или удалил чат."""
    gone = TelegramChat.query.filter_by(chat_id=str(chat_id)).delete(
        synchronize_session=False)
    db.session.commit()
    return gone


def _chat_linked(chat_id):
    return TelegramChat.query.filter_by(chat_id=str(chat_id)).first() is not None


_WHERE = 'в SE-mobile: «Настройки» → «Уведомления в Telegram»'
_LINKED = ('Готово: сюда будут приходить уведомления SE-mobile — о расчётном '
           'листе, меню столовой, новостях и объявлениях.\n\n'
           f'Отключить — командой /stop или {_WHERE}.')
_EXPIRED = ('Ссылка устарела или уже использована. Откройте SE-mobile → '
            '«Настройки» → «Уведомления в Telegram» и нажмите «Подключить '
            'Telegram» ещё раз.')
_ACTIVE = f'Уведомления SE-mobile приходят сюда. Отключить — командой /stop или {_WHERE}.'
_INACTIVE = f'Уведомления SE-mobile сюда не приходят. Подключить — {_WHERE}.'
_STOPPED = f'Уведомления SE-mobile отключены. Подключить снова — {_WHERE}.'
_ONLY_NOTIFIES = ('Этот бот только присылает уведомления SE-mobile и сообщений '
                  'не читает. Отключить — командой /stop.')
_UNLINKED = 'Уведомления SE-mobile сюда больше не приходят: их отключили в приложении.'


def _say(chat_id, text):
    """Ответ боту — прямо в ответе на вебхук: Telegram отправит его сам, и
    отдельно ходить к нему не нужно."""
    return {'method': 'sendMessage', 'chat_id': chat_id, 'text': text}


def handle_update(update):
    """Одно сообщение от Telegram → ответ (см. _say) или None."""
    if not isinstance(update, dict):
        return None

    # Человек остановил бота («Остановить и заблокировать») — слать некуда.
    member = update.get('my_chat_member')
    if isinstance(member, dict):
        chat = member.get('chat')
        new = member.get('new_chat_member')
        if (isinstance(chat, dict) and chat.get('id') is not None
                and isinstance(new, dict)
                and new.get('status') in ('kicked', 'left')):
            _forget_chat(chat['id'])
        return None

    message = update.get('message')
    if not isinstance(message, dict):
        return None
    chat = message.get('chat')
    if not isinstance(chat, dict) or chat.get('id') is None:
        return None
    # Уведомления личные: в группу, куда бота добавили, их не подключаем.
    if chat.get('type') != 'private':
        return None
    chat_id = chat['id']
    text = message.get('text')
    command, _, argument = (text if isinstance(text, str) else '').strip().partition(' ')
    command = command.split('@', 1)[0].lower()

    if command == '/start':
        argument = argument.strip()
        if argument:
            return _say(chat_id, _LINKED if _link(argument, chat_id) else _EXPIRED)
        return _say(chat_id, _ACTIVE if _chat_linked(chat_id) else _INACTIVE)
    if command == '/stop':
        return _say(chat_id, _STOPPED if _forget_chat(chat_id) else _INACTIVE)
    return _say(chat_id, _ONLY_NOTIFIES if _chat_linked(chat_id) else _INACTIVE)


# ── Отправка ────────────────────────────────────────────────────────────────
#
# Своя очередь и свой работник, а не общая очередь уведомлений в app.py: у
# Telegram свои пределы частоты, и, дожидаясь их, работник не должен держать
# пуш на телефоны и проходы турникета.

_send_queue = None
_sender = None
_sender_lock = threading.Lock()
_paused_until = 0.0


def _format(title, body):
    """Заголовок жирным, текст под ним — как в уведомлении на телефоне."""
    title = html.escape((title or '').strip(), quote=False)
    body = html.escape((body or '').strip(), quote=False)
    if title and body:
        return f'<b>{title}</b>\n{body}'
    return f'<b>{title}</b>' if title else body


def linked_employee_ids():
    """Все, у кого подключён Telegram, — для уведомлений «всем»."""
    if not enabled():
        return []
    try:
        return [e for (e,) in db.session.query(TelegramChat.employee_id).distinct()]
    except Exception as e:
        db.session.rollback()
        logging.warning('Telegram: не прочитать, у кого он подключён: %s', e)
        return []


def deliver(employee_ids, title, body):
    """В очередь Telegram — тем из сотрудников, у кого он подключён.

    Возвращает, в сколько чатов поставлено. Молчит, если бот не настроен:
    уведомление — не повод ломать то, из-за чего оно отправляется.
    """
    if not enabled():
        return 0
    wanted = {e for e in (employee_ids or []) if e}
    if not wanted:
        return 0
    try:
        chats = sorted({c for (c,) in db.session.query(TelegramChat.chat_id)
                        .filter(TelegramChat.employee_id.in_(wanted))})
    except Exception as e:
        db.session.rollback()
        logging.warning('Telegram: не прочитать, кому слать: %s', e)
        return 0
    text = _format(title, body)
    return sum(1 for chat_id in chats if _enqueue(chat_id, text))


def _enqueue(chat_id, text):
    send_queue = _start_sender(current_app._get_current_object())
    try:
        send_queue.put_nowait((chat_id, text))
        return True
    except queue.Full:
        logging.warning('Очередь Telegram переполнена — сообщение в чат %s '
                        'пропущено', chat_id)
        return False


def _start_sender(app):
    global _send_queue, _sender
    with _sender_lock:
        if _send_queue is None:
            _send_queue = queue.Queue(maxsize=_SEND_QUEUE_LIMIT)
        if _sender is None or not _sender.is_alive():
            _sender = threading.Thread(target=_send_loop, args=(app, _send_queue),
                                       name='telegram', daemon=True)
            _sender.start()
    return _send_queue


def _send_loop(app, send_queue):
    while True:
        chat_id, text = send_queue.get()
        try:
            _send_one(app, chat_id, text)
        except Exception as e:
            logging.warning('Telegram: сообщение не отправлено: %s', _safe(e))
        finally:
            send_queue.task_done()
        time.sleep(_SEND_GAP)


def _send_one(app, chat_id, text):
    """Одно сообщение. True — доставлено."""
    global _paused_until
    if time.monotonic() < _paused_until:
        return False
    for attempt in range(_RETRIES):
        try:
            _call('sendMessage', {
                'chat_id': chat_id,
                'text': text,
                'parse_mode': 'HTML',
                'link_preview_options': {'is_disabled': True},
            })
            return True
        except TelegramError as e:
            if e.code == 429 and attempt + 1 < _RETRIES:
                time.sleep(min(float(e.retry_after or 1), 30))
                continue
            # 403 — человек остановил бота; «chat not found» — удалил чат.
            # Слать туда больше незачем, и строку держать тоже.
            if e.code == 403 or (e.code == 400 and
                                 'chat not found' in e.description.lower()):
                with app.app_context():
                    _forget_chat(chat_id)
                logging.info('Telegram: чат %s закрыт — отвязан', chat_id)
                return False
            logging.warning('Telegram не принял сообщение: %s', _safe(e))
            return False
        except OSError as e:
            _paused_until = time.monotonic() + _PAUSE_AFTER_NETWORK_ERROR
            logging.warning('Telegram не отвечает — минуту сообщения в него не '
                            'шлём: %s', _safe(e))
            return False
    return False


def state():
    """Работают ли уведомления в Telegram — для экрана «Обновление».

    Без этого проверить можно только одним способом: подключить себе и ждать,
    придёт ли что-нибудь, а не пришло — гадать, почему.
    """
    if not enabled():
        return {'enabled': False,
                'problem': 'Выключены: на сервере не задан TELEGRAM_PUSH_TOKEN'}
    out = {'enabled': True, 'bot': '', 'people': 0, 'problem': ''}
    try:
        out['people'] = db.session.query(
            db.func.count(db.distinct(TelegramChat.employee_id))).scalar() or 0
    except Exception:
        db.session.rollback()
    try:
        out['bot'] = '@' + bot_username()
        info = _call('getWebhookInfo', timeout=5) or {}
        if info.get('url') != _webhook_url():
            # Адрес ещё не задан (никто не нажимал «Подключить») или его
            # сбили руками — задаём сразу, не дожидаясь первого.
            ensure_webhook(force=True)
            info = _call('getWebhookInfo', timeout=5) or {}
    except TelegramError as e:
        out['problem'] = ('Telegram не принял токен — проверьте TELEGRAM_PUSH_TOKEN'
                          if e.code in (401, 404) else
                          f'Telegram ответил отказом: {_safe(e.description)}')
        return out
    except OSError as e:
        out['problem'] = f'Telegram не отвечает серверу: {_safe(e)}'
        return out
    # Ошибку доставки Telegram помнит и после того, как всё починилось, —
    # говорим только о свежей.
    last = info.get('last_error_date') or 0
    if info.get('last_error_message') and time.time() - last < 24 * 3600:
        out['problem'] = ('Telegram не может достучаться до сервера: '
                          f'{info["last_error_message"]}')
    return out


def register(app, core):
    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    @app.route('/api/telegram', methods=['GET'])
    @core.require_auth
    def telegram_get():
        """Включены ли уведомления в Telegram и подключены ли у вошедшего."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        on = enabled()
        return jsonify({'message': 'Success', 'enabled': on,
                        'linked': on and is_linked(viewer.employee_id)})

    @app.route('/api/telegram/link', methods=['POST'])
    @core.require_auth
    def telegram_link():
        """Одноразовая ссылка на бота: открыть, нажать «Запустить» — и готово."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not enabled():
            return _fail('not_configured', 503)
        try:
            url = new_link(viewer.employee_id)
        except (TelegramError, OSError) as e:
            db.session.rollback()
            logging.warning('Telegram: ссылку не выдать: %s', _safe(e))
            return _fail('telegram_unavailable', 503)
        return jsonify({'message': 'Success', 'url': url,
                        'expires_in': int(_CODE_LIFETIME.total_seconds())})

    @app.route('/api/telegram', methods=['DELETE'])
    @core.require_auth
    def telegram_unlink():
        """Отключить. Чату бот скажет, что уведомлений больше не будет."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        chats = {c for (c,) in db.session.query(TelegramChat.chat_id)
                 .filter_by(employee_id=viewer.employee_id)}
        forget(viewer.employee_id)
        db.session.commit()
        if enabled():
            # Тот же чат мог остаться за другой учёткой того же человека —
            # тогда уведомления туда идут, и прощаться рано.
            still = {c for (c,) in db.session.query(TelegramChat.chat_id)
                     .filter(TelegramChat.chat_id.in_(chats))} if chats else set()
            for chat_id in sorted(chats - still):
                _enqueue(chat_id, html.escape(_UNLINKED, quote=False))
        return jsonify({'message': 'Success', 'linked': False})

    @app.route(_WEBHOOK_PATH, methods=['POST'])
    def telegram_webhook():
        """Сообщения боту — их приносит сам Telegram, без пропуска, но с
        секретом в заголовке."""
        if not enabled():
            return _fail('not_found', 404)
        given = request.headers.get('X-Telegram-Bot-Api-Secret-Token', '')
        if not hmac.compare_digest(given.encode(), _webhook_secret().encode()):
            return _fail('forbidden', 403)
        try:
            reply = handle_update(request.get_json(silent=True))
        except Exception as e:
            # Отвечаем «принято» и на то, что не разобрали: иначе Telegram
            # приносил бы то же сообщение снова и снова.
            db.session.rollback()
            logging.warning('Telegram: сообщение боту не разобрано: %s', e)
            reply = None
        return jsonify(reply or {})
