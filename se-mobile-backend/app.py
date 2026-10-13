import hashlib
import hmac
import os
import logging
import math
import re
import secrets
import threading
from functools import wraps
from io import BytesIO
from datetime import date, datetime, timedelta, timezone
from flask import Flask, Response, request, jsonify, g, send_file
from flask_cors import CORS
# Werkzeug идёт вместе с Flask, ставить ничего не нужно. По умолчанию scrypt.
from werkzeug.exceptions import HTTPException
from werkzeug.security import generate_password_hash, check_password_hash
from models import (db, Employee, AccessRecord, Payslip,
                    PayslipAccrual, PayslipDeduction, PayslipPaid, PayslipBenefit,
                    PayslipReference, LeaveBalance, LeaveHistory,
                    FcmToken, TurnstileEvent, MenuDate, MenuItem, AppliedSeed,
                    UserAccount, AuthToken, DirectoryEntry, NewsItem,
                    AuthMiss)
from parser_1c_xml import parse_1c_xml
from parser_menu_excel import parse_menu_excel
from parser_directory_excel import parse_directory_excel
from parser_news_feed import parse_news_feed, looks_like_feed, feed_links
from parser_news_html import parse_news_html
from parser_employees_excel import parse_employees_excel
from privacy import privacy_page
from payslip_xlsx import build_payslip_xlsx, file_name as payslip_file_name

_ONE_DAY = timedelta(days=1)

# Сколько живёт пропуск без обращений. Срок сдвигается при каждом запросе,
# так что человек, который открывает приложение хотя бы раз в месяц, входа
# не увидит.
_TOKEN_LIFETIME = timedelta(days=30)

# Требовать пропуск или только просить.
#
# Пока выключено, запрос без пропуска проходит, но пишется в лог
# предупреждением — иначе включение обрушило бы все установленные сборки
# разом: они пропуск присылать не умеют. Порядок такой: выложить сервер,
# раздать новую сборку всем 500, убедиться по логам, что запросов без
# пропуска не осталось, и только тогда поставить REQUIRE_AUTH=1.
_AUTH_REQUIRED = os.environ.get('REQUIRE_AUTH', '').strip().lower() in (
    '1', 'true', 'yes', 'on')

try:
    import firebase_admin
    from firebase_admin import credentials, messaging as fb_messaging
    _FIREBASE_AVAILABLE = True
except ImportError:
    _FIREBASE_AVAILABLE = False

_fb_app = None


def _get_firebase():
    global _fb_app
    if not _FIREBASE_AVAILABLE:
        return None
    if _fb_app is None:
        cred_path = os.environ.get('FIREBASE_CREDENTIALS_PATH', 'firebase-credentials.json')
        if os.path.exists(cred_path):
            try:
                cred = credentials.Certificate(cred_path)
                _fb_app = firebase_admin.initialize_app(cred)
            except Exception as e:
                logging.warning(f'Firebase init failed: {e}')
    return _fb_app


def _is_admin_role(job_title: str) -> bool:
    j = job_title.lower()
    return any(k in j for k in ('руководитель', 'начальник', 'директор', 'главный', 'заместитель'))


# FCM принимает не больше 500 адресатов за раз, а на предприятии их ровно
# столько же — шлём частями.
_PUSH_BATCH = 450


def _push_to(employee_ids, title, body, data=None):
    """Шлёт уведомление на устройства перечисленных сотрудников.

    Возвращает, скольким устройствам ушло. Молчит, если Firebase не настроен
    или ни у кого нет установленного приложения: уведомление — не повод
    ломать запрос, из-за которого оно отправляется.
    """
    if not _get_firebase():
        return 0
    employee_ids = [e for e in set(employee_ids or []) if e]
    if not employee_ids:
        return 0

    tokens = [t.token for t in FcmToken.query.filter(
        FcmToken.employee_id.in_(employee_ids)).all()]
    if not tokens:
        return 0

    sent = 0
    invalid = set()
    for start in range(0, len(tokens), _PUSH_BATCH):
        chunk = tokens[start:start + _PUSH_BATCH]
        message = fb_messaging.MulticastMessage(
            tokens=chunk,
            notification=fb_messaging.Notification(title=title, body=body),
            data={k: str(v) for k, v in (data or {}).items()},
        )
        try:
            response = fb_messaging.send_each_for_multicast(message)
        except Exception as e:
            logging.warning('Уведомление не ушло: %s', e)
            continue
        for index, result in enumerate(response.responses):
            if result.success:
                sent += 1
                continue
            code = getattr(result.exception, 'code', '')
            # Приложение снесли или переустановили — держать такой пропуск
            # незачем, иначе список адресатов растёт без конца.
            if code in ('registration-token-not-registered', 'invalid-argument'):
                invalid.add(chunk[index])

    if invalid:
        try:
            FcmToken.query.filter(FcmToken.token.in_(invalid)).delete(
                synchronize_session=False)
            db.session.commit()
        except Exception:
            db.session.rollback()
    return sent


# Очередь уведомлений и один работник на неё.
#
# Уведомления уходят через Firebase, то есть через сеть до Google. Пока
# Firebase не настроен, всё это ничего не стоит: _push_to возвращает ноль и
# сразу. Но в тот день, когда его настроят, каждая такая отправка станет
# ожиданием внутри запроса — а звать её умеют турникет, выкладка меню,
# загрузка расчётных листков и объявление.
#
# Хуже всего турникет. В пересменку это пятьсот проходов за несколько минут,
# и каждый ждал бы Google, прежде чем ответить СКУД. Поэтому отправка уходит
# в сторону.
#
# Работник один, а не поток на событие: пятьсот проходов — это пятьсот
# потоков, и лекарство вышло бы хуже болезни. Очередь ограничена; переполнилась
# — уведомление теряется с записью в журнал, потому что пропуск человека
# важнее сообщения о нём.
_NOTIFY_QUEUE_LIMIT = 1000
_notify_queue = None
_notify_worker = None
_notify_start_lock = threading.Lock()


def _notify_later(app, fn, *args, **kwargs):
    """Сделать отправку уведомления, не задерживая запрос."""
    global _notify_queue, _notify_worker
    with _notify_start_lock:
        if _notify_queue is None:
            import queue as _queue
            _notify_queue = _queue.Queue(maxsize=_NOTIFY_QUEUE_LIMIT)
        if _notify_worker is None or not _notify_worker.is_alive():
            _notify_worker = threading.Thread(
                target=_notify_loop, args=(app,), name='notify', daemon=True)
            _notify_worker.start()
    try:
        _notify_queue.put_nowait((fn, args, kwargs))
    except Exception:
        logging.warning('Очередь уведомлений переполнена — %s пропущено',
                        getattr(fn, '__name__', fn))


def _notify_loop(app):
    while True:
        fn, args, kwargs = _notify_queue.get()
        try:
            with app.app_context():
                fn(*args, **kwargs)
        except Exception as e:
            logging.warning('Уведомление не отправлено: %s', e)
        finally:
            _notify_queue.task_done()


def _push_to_everyone(title, body, data=None):
    """Уведомление всем, у кого установлено приложение."""
    return _push_to([t.employee_id for t in FcmToken.query.all()],
                    title, body, data)


_XLSX_MIME = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'

_MONTHS_RU = ('январь', 'февраль', 'март', 'апрель', 'май', 'июнь', 'июль',
              'август', 'сентябрь', 'октябрь', 'ноябрь', 'декабрь')


def _month_name(month):
    return _MONTHS_RU[month - 1] if 1 <= month <= 12 else str(month)


def _notify_menu_published():
    """Одно уведомление на выкладку меню.

    Одно, а не по дню на каждый: в файле из 1С бывает сразу неделя, и семь
    сообщений подряд означают только то, что уведомления отключат.
    """
    _push_to_everyone('Столовая', 'Меню на сегодня 🍽️', {'type': 'menu'})


def _send_turnstile_notification(employee_name: str, direction: str, timestamp_str: str, employee_id: str):
    if not _get_firebase():
        return
    admin_employee_ids = [
        e.employee_id for e in Employee.query.all() if _is_admin_role(e.job_title)
    ]
    if not admin_employee_ids:
        return
    tokens = [
        t.token for t in FcmToken.query.filter(
            FcmToken.employee_id.in_(admin_employee_ids)
        ).all()
    ]
    if not tokens:
        return
    direction_text = 'вошёл' if direction == 'in' else 'вышел'
    message = fb_messaging.MulticastMessage(
        tokens=tokens,
        notification=fb_messaging.Notification(
            title='СКУД — проход сотрудника',
            body=f'{employee_name} {direction_text} в {timestamp_str}',
        ),
        data={'type': 'turnstile', 'employee_id': employee_id, 'direction': direction},
    )
    try:
        resp = fb_messaging.send_each_for_multicast(message)
        invalid_tokens = set()
        for i, r in enumerate(resp.responses):
            if not r.success and r.exception:
                code = getattr(r.exception, 'code', '')
                if code in ('registration-token-not-registered', 'invalid-argument'):
                    invalid_tokens.add(tokens[i])
        if invalid_tokens:
            FcmToken.query.filter(FcmToken.token.in_(invalid_tokens)).delete(synchronize_session=False)
            db.session.commit()
    except Exception as e:
        logging.warning(f'FCM send failed: {e}')


def _update_employee_names():
    """Sync employee display names to current seed values (non-destructive)."""
    name_map = {
        '001':  ('Сарсекенов Батырхан Арманұлы', 'Техник-программист'),
        '002':  ('Касымов Нурлан Серикович',      'Руководитель отдела'),
        '003':  ('Сидорова Анна Сергеевна',       'Бухгалтер'),
        '1874': ('Кумарова Мадина Кумаровна',     'Специалист по кадрам'),
    }
    changed = False
    for emp_id, (name, job) in name_map.items():
        emp = Employee.query.filter_by(employee_id=emp_id).first()
        if emp and (emp.full_name != name or emp.job_title != job):
            emp.full_name = name
            emp.job_title = job
            changed = True
            logging.info(f'Updated employee {emp_id} name → {name}')
    if changed:
        db.session.commit()


def _update_employee_iins():
    """Patch IINs for existing employees when seeds change.

    `iin` is UNIQUE, so before assigning a target IIN we must release it from
    any other row that currently holds it (e.g. a legacy seed or an
    auto-registered demo user). Otherwise the commit hits an IntegrityError.
    """
    iin_map = {
        '001': '000000002114',
    }
    changed = False
    for emp_id, new_iin in iin_map.items():
        emp = Employee.query.filter_by(employee_id=emp_id).first()
        if not emp or emp.iin == new_iin:
            continue
        # Free the unique IIN from any other employee holding it.
        for other in Employee.query.filter(
                Employee.iin == new_iin,
                Employee.employee_id != emp_id).all():
            other.iin = None
            logging.info(f'Released IIN {new_iin} from employee {other.employee_id}')
        db.session.flush()
        emp.iin = new_iin
        changed = True
        logging.info(f'Updated employee {emp_id} IIN → {new_iin}')
    if changed:
        db.session.commit()


def _column_sql(column, dialect):
    """Описание колонки для ALTER TABLE ... ADD COLUMN — по самой модели.

    Возвращает None, если колонку дописать нельзя (первичный ключ), — такую
    таблицу правят руками, а не на старте службы.
    """
    if column.primary_key:
        return None

    parts = [f'"{column.name}"', column.type.compile(dialect)]

    literal = None
    if column.server_default is not None:
        literal = getattr(column.server_default.arg, 'text', None) or \
            str(column.server_default.arg)
    elif column.default is not None and getattr(column.default, 'is_scalar', False):
        value = column.default.arg
        if isinstance(value, bool):
            literal = 'TRUE' if value else 'FALSE'
        elif isinstance(value, (int, float)):
            literal = repr(value)
        elif isinstance(value, str):
            escaped = value.replace("'", "''")
            literal = f"'{escaped}'"
    if literal is not None:
        parts.append(f'DEFAULT {literal}')

    if not column.nullable:
        if literal is None:
            # NOT NULL без значения по умолчанию к непустой таблице не
            # добавить. Лучше колонка без запрета пустоты, чем несостоявшаяся
            # правка схемы и отказ на каждом запросе.
            logging.warning('Migration: %s.%s added as nullable — no default',
                            column.table.name, column.name)
        else:
            parts.append('NOT NULL')
    return ' '.join(parts)


def _migrate_schema():
    """Add columns missing from existing tables without dropping data.

    db.create_all() only creates whole tables — it never adds new columns to
    tables that already exist. Columns added to the models after the live
    database was first created must be back-filled here, otherwise every
    query that mentions them fails on strict backends like PostgreSQL.

    Список недостающих колонок раньше вёлся здесь руками — и однажды в нём
    не хватило строки: в модель добавили `user_accounts.failed_attempts`, а
    сюда не вписали, и вход стал отвечать «ошибка сервера» на боевой базе,
    оставаясь зелёным в проверках (SQLite создаёт таблицу заново и всегда со
    всеми колонками). Поэтому теперь колонки берутся из самих моделей:
    забыть строку больше негде.
    """
    from sqlalchemy import text, inspect
    inspector = inspect(db.engine)
    tables = inspector.get_table_names()
    dialect = db.engine.dialect

    # Расширение колонок, которым не хватило объявленной длины. Добавить
    # недостающую умеет проход по моделям, а растянуть существующую — только
    # это:
    # PostgreSQL режет значение длиннее объявленного и валит весь запрос,
    # тогда как SQLite длину не проверяет вовсе, и на ней это не всплывает.
    widen = {
        'directory_entries': {
            'extension': 100,
            'mobile': 100,
        },
    }

    # Индексы. db.create_all() создаёт их только вместе с новой таблицей —
    # к уже существующей ни один индекс он не добавит, поэтому здесь.
    # Порядок колонок в составном индексе важен: сначала то, по чему равенство,
    # потом то, по чему диапазон.
    indexes = {
        'access_records': [
            ('ix_access_records_emp_date', '"employee_id", "access_date"'),
        ],
        'turnstile_events': [
            ('ix_turnstile_events_ts', '"timestamp"'),
            ('ix_turnstile_events_emp', '"employee_id"'),
        ],
    }

    with db.engine.connect() as conn:
        for name, table in db.metadata.tables.items():
            if name not in tables:
                continue                      # такую создаст create_all целиком
            existing = {c['name'] for c in inspector.get_columns(name)}
            for column in table.columns:
                if column.name in existing:
                    continue
                definition = _column_sql(column, dialect)
                if definition is None:
                    logging.error('Migration: %s.%s требует правки вручную',
                                  name, column.name)
                    continue
                try:
                    conn.execute(text(f'ALTER TABLE {name} ADD COLUMN {definition}'))
                    conn.commit()
                    logging.info('Migration: added %s.%s', name, column.name)
                except Exception as e:
                    # Поодиночке: одна неудачная колонка не должна уносить с
                    # собой остальные правки схемы.
                    conn.rollback()
                    logging.error('Migration: %s.%s не добавилась: %s',
                                  name, column.name, e)

        # ALTER COLUMN TYPE есть в PostgreSQL; в SQLite длина не проверяется,
        # поэтому там расширять нечего.
        if db.engine.dialect.name == 'postgresql':
            for table, columns in widen.items():
                if table not in tables:
                    continue
                current = {c['name']: c['type'] for c in inspector.get_columns(table)}
                for col, length in columns.items():
                    existing_type = current.get(col)
                    if existing_type is None:
                        continue
                    if (getattr(existing_type, 'length', None) or 0) >= length:
                        continue
                    conn.execute(text(
                        f'ALTER TABLE {table} ALTER COLUMN "{col}" TYPE VARCHAR({length})'))
                    logging.info(f'Migration: widened {table}.{col} to VARCHAR({length})')

        for table, defs in indexes.items():
            if table not in tables:
                continue
            existing = {i['name'] for i in inspector.get_indexes(table)}
            for name, cols in defs:
                if name in existing:
                    continue
                conn.execute(text(
                    f'CREATE INDEX IF NOT EXISTS {name} ON {table} ({cols})'))
                logging.info(f'Migration: created index {name} on {table}')

        conn.commit()


def _seed_sarseken():
    """Remove legacy emp_id='2114' to avoid duplicate IIN collision with emp '001'."""
    legacy = Employee.query.filter_by(employee_id='2114').first()
    if legacy:
        # Delete child payslip rows first to satisfy FK constraints
        for ps in Payslip.query.filter_by(employee_id='2114').all():
            PayslipAccrual.query.filter_by(payslip_id=ps.id).delete()
            PayslipDeduction.query.filter_by(payslip_id=ps.id).delete()
            PayslipPaid.query.filter_by(payslip_id=ps.id).delete()
            PayslipBenefit.query.filter_by(payslip_id=ps.id).delete()
            db.session.delete(ps)
        db.session.delete(legacy)
        db.session.commit()
        logging.info('Removed legacy employee 2114 (IIN merged into employee 001)')


# login → employee_id
#
# Кто заводился до того, как учётные записи переехали в базу. Паролей здесь
# больше нет: они были равны табельному номеру, лежали открытым текстом в
# этом файле и оставались действующими паролями двадцати трёх живых учёток —
# всякий, кто видел исходники, мог войти под начальником отдела. Теперь
# список нужен только затем, чтобы восстановить пропавшую строку в
# user_accounts (пароль при этом ставится временный, как у всех) и чтобы
# админ-панель знала логин сотрудника, заведённого до таблицы.
_CREDENTIALS = {
    'admin': 'ADMIN',
    '2114': '001',
    '1874': '0000001874',
    '44':   '0000000044',
    '644':  '0000000644',
    '674':  '0000000674',
    '726':  '0000000726',
    '910':  '0000000910',
    '1093': '0000001093',
    '1236': '0000001236',
    '1295': '0000001295',
    '1296': '0000001296',
    '1445': '0000001445',
    '1579': '0000001579',
    '1668': '0000001668',
    '1681': '0000001681',
    '1864': '0000001864',
    '1965': '0000001965',
    '1978': '0000001978',
    '2005': '0000002005',
    '2063': '0000002063',
    '2148': '0000002148',
    '2162': '0000002162',
}


# Сколько неудач подряд терпим, прежде чем закрыть вход, и на сколько.
#
# Пятая подряд закрывает на минуту, каждая следующая удваивает срок до
# получаса. Человеку, перепутавшему раскладку, это стоит минуты; перебору
# четырёхзначного номера — десятков лет. Замок отпирается сам: администратор
# для этого не нужен, хотя сброс пароля его тоже снимает.
_LOCK_AFTER = 5
_LOCK_BASE = timedelta(minutes=1)
_LOCK_MAX = timedelta(minutes=30)


def _lock_delay(failed_attempts):
    """На сколько закрыть вход после стольких неудач подряд."""
    if failed_attempts < _LOCK_AFTER:
        return None
    doubling = 2 ** min(failed_attempts - _LOCK_AFTER, 16)
    return min(_LOCK_BASE * doubling, _LOCK_MAX)


def locked_for(login):
    """Сколько секунд ещё закрыт вход под этим логином, или 0.

    Логин ищем так же, как при входе: человек, набравший «450», должен
    увидеть «слишком много попыток», а не «неверный пароль».
    """
    account = _find_account((login or '').strip())
    if account is None or account.locked_until is None:
        return 0
    left = (account.locked_until - datetime.utcnow()).total_seconds()
    return int(left) if left > 0 else 0


def _credentials_refused(login):
    """Ответ на неверные логин и пароль у загрузок и объявлений.

    Различаем «не тот пароль» и «слишком много попыток», как на входе:
    технолог, которому пишут «неверный пароль», вводит верный снова и снова
    и только продлевает себе замок.
    """
    seconds = locked_for(login)
    if seconds:
        minutes = max(1, -(-seconds // 60))
        return jsonify({'message': f'Слишком много неверных попыток. '
                                   f'Попробуйте через {minutes} мин.',
                        'error': 'locked', 'retry_after': seconds}), 429
    return jsonify({'message': 'Неверный логин или пароль', 'error': True}), 401


# Часовой пояс предприятия. Казахстан с 1 марта 2024 года живёт в одном
# поясе, UTC+5, — Семей в том числе.
#
# В базе лежат часы двух родов, и это важно не перепутать:
#
# * то, что принесли системы предприятия, — проходы из СКУД, периоды
#   расчётных листков, — записано **местным** временем: в выгрузке стоит
#   07:40, и это 07:40 у проходной;
# * то, что сервер записал сам, — сроки пропусков, время новостей, отметки
#   сидеров, — записано в **UTC**, как datetime.utcnow() и отдаёт.
#
# Пока эти два рода не встречаются, всё сходится. Встречаются они там, где
# сервер спрашивает «а какое сегодня число» про местные данные: сервер стоит
# в Астане и живёт по UTC, поэтому с полуночи до пяти утра его «сегодня» —
# это вчера у проходной. Меню столовой на сегодня в эти часы показывалось
# вчерашнее, табель за «сегодня» — за вчера.
#
# Отсюда правило: там, где «сегодня» значит «сегодня на предприятии», берём
# _plant_today(), а не date.today().
_PLANT_TZ = timezone(timedelta(hours=5))


def _plant_now():
    """Время на предприятии, без пояса — как всё в базе."""
    return datetime.now(_PLANT_TZ).replace(tzinfo=None)


def _plant_today():
    """Какое сегодня число у проходной."""
    return _plant_now().date()


def _number_forms(value):
    """Как человек называет табельный номер и как он записан в базе.

    В базе номер полный — «0000000450», а вслух и на пропуске он «450».
    Заставлять пятьсот человек набирать восемь нулей — значит получить
    пятьсот звонков «не пускает». Принимаем обе формы.
    """
    forms = [value]
    if value.isdigit():
        short = value.lstrip('0') or '0'
        for form in (short.zfill(10), short):
            if form not in forms:
                forms.append(form)
    return forms


def _random_password(length=14):
    """Пароль, который придётся переписать глазами.

    Буквы и цифры без похожих друг на друга: ноль и «O», единица и «l». Его
    диктуют по телефону и переписывают с экрана журнала, и «l» вместо «1»
    стоит второго захода.
    """
    alphabet = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    return ''.join(secrets.choice(alphabet) for _ in range(length))


def _is_default_password(password, login):
    """Это выданный при заведении пароль, а не придуманный человеком?

    Заводим мы всех одинаково: пароль равен табельному номеру. Поэтому
    «пароль совпадает с логином в любой его форме» и значит «временный».
    Обратное невозможно: _password_problem не даёт выбрать себе пароль,
    совпадающий с логином, — так что ошибиться тут не на чем.
    """
    password = (password or '').strip()
    if not password:
        return False
    return password in _number_forms((login or '').strip())


def _find_account(login):
    """Учётная запись по логину в любой из привычных форм номера."""
    for form in _number_forms(login):
        account = UserAccount.query.filter_by(login=form, is_active=True).first()
        if account is not None:
            return account
    return None


def _authenticate(login, password):
    """Проверяет пару логин/пароль. Возвращает employee_id или None.

    Источник истины — таблица user_accounts, и только она. Раньше рядом был
    запасной путь: логин, которого нет в таблице, проверялся по словарю
    _CREDENTIALS с паролями в коде. Он пропускал и выключенную учётку —
    _find_account ищет только среди is_active, выключенный вход до таблицы не
    доходил и попадал прямо в словарь, где про is_active никто не знает. То
    есть уволенный входил тем же паролем, что и раньше. Запасного пути
    больше нет: пропавшую строку восстанавливает _seed_user_accounts при
    запуске, с временным паролем и обязательной сменой.
    """
    login = (login or '').strip()
    password = (password or '').strip()
    if not login or not password:
        return None

    account = _find_account(login)
    if account is not None:
        now = datetime.utcnow()
        # Пока замок держит, пароль даже не проверяем: иначе перебор просто
        # замедлился бы, а не остановился.
        if account.locked_until is not None and account.locked_until > now:
            logging.warning('Вход под %r закрыт ещё %d с', login,
                            (account.locked_until - now).total_seconds())
            return None

        # Пароль у заведённых нами учёток равен табельному номеру, поэтому
        # его тоже принимаем в обеих формах — но только пока пароль
        # временный. У придуманного человеком пароля никаких «похожих»
        # вариантов не перебираем.
        candidates = [password]
        if account.must_change_password:
            candidates += [form for form in _number_forms(password)
                           if form not in candidates]
        matched = None
        try:
            for candidate in candidates:
                if check_password_hash(account.password_hash, candidate):
                    matched = candidate
                    break
        except Exception as e:
            # Испорченный или незнакомый формат хеша — это не «верный пароль».
            logging.error('Cannot verify password hash for %r: %s', login, e)
            matched = None
        ok = matched is not None
        try:
            if ok:
                account.last_login_at = now
                account.failed_attempts = 0
                account.locked_until = None
                # Пароль, равный табельному номеру, — это выданный при
                # заведении, а не придуманный: придумать такой нельзя,
                # _password_problem запрещает пароль, совпадающий с логином.
                # Значит, его пора менять, и узнаём мы об этом здесь бесплатно
                # — хеш только что проверен. Прежде такие учётки приходилось
                # перечислять руками, и в списке стояла ровно одна из
                # двадцати трёх.
                if not account.must_change_password and _is_default_password(
                        matched, account.login):
                    account.must_change_password = True
                    logging.info('Пароль у %r всё ещё временный — просим сменить',
                                 account.login)
            else:
                account.failed_attempts = (account.failed_attempts or 0) + 1
                delay = _lock_delay(account.failed_attempts)
                if delay is not None:
                    account.locked_until = now + delay
                    logging.warning('Вход под %r закрыт на %s после %d неудач',
                                    login, delay, account.failed_attempts)
            db.session.commit()
        except Exception:
            # Счётчик и отметка о входе не должны ломать сам вход.
            db.session.rollback()
        return account.employee_id if ok else None

    # Строки нет — значит, входить не под чем. Если логин при этом знаком
    # коду, это не «неверный пароль», а пропавшая учётка: пишем об этом, её
    # восстановит сидер при следующем запуске.
    if login in _CREDENTIALS:
        logging.error('Учётной записи %r нет в user_accounts, хотя она должна '
                      'быть: восстановит _seed_user_accounts при запуске', login)
        try:
            _count_today('fallback_logins')
        except Exception:
            db.session.rollback()
    return None


_MIN_PASSWORD_LENGTH = 6


def _password_problem(password, login):
    """Что не так с новым паролем, или None если всё в порядке.

    Правило про табельный номер здесь главное: именно им пароли и были,
    и ради этого всё затевалось.
    """
    if len(password) < _MIN_PASSWORD_LENGTH:
        return 'too_short'
    if password.strip().lower() == (login or '').strip().lower():
        return 'same_as_login'
    if password.isdigit() and len(set(password)) <= 2:
        return 'too_simple'
    return None


def _is_system_admin(job_title):
    return 'администратор системы' in (job_title or '').lower()


def _token_key(raw):
    """Под каким ключом пропуск лежит в базе: SHA-256, а не он сам.

    Пропуск — это доступ к листкам без пароля. Лежи он в базе как есть,
    утёкшая база или её резервная копия открывала бы листки каждого, кто
    сейчас вошёл. По хешу пропуск не восстановить, а случайных байт в нём
    32 — подбирать нечего, поэтому соль не нужна.
    """
    return hashlib.sha256(raw.encode()).hexdigest()


def _hash_stored_tokens():
    """Переписывает пропуска, лежащие в базе как есть, на их хеши.

    Пропуска, выданные до этого, хранились открыто. Переписываем, а не
    гасим: иначе обновление сервера выкинуло бы из приложения всех разом.
    Хеш — 64 знака, сам пропуск — 43: так их и различаем. Gunicorn
    запускает несколько процессов, и каждый доходит сюда; строку, которую
    уже переписал соседний, просто пропускаем.
    """
    legacy = [row.token for row in AuthToken.query.with_entities(AuthToken.token)
              if len(row.token) != 64]
    for raw in legacy:
        try:
            row = db.session.get(AuthToken, raw)
            if row is None:
                continue
            db.session.add(AuthToken(
                token=_token_key(raw), employee_id=row.employee_id,
                created_at=row.created_at, last_used_at=row.last_used_at,
                expires_at=row.expires_at))
            db.session.delete(row)
            db.session.commit()
        except Exception:
            db.session.rollback()
    if legacy:
        logging.info('Пропуска переписаны на хеши: %d', len(legacy))


def _issue_token(employee_id):
    """Выдаёт новый пропуск. Старые не трогает: у человека может быть
    и телефон, и планшет. В базу ложится хеш, а пропуск уходит телефону."""
    now = datetime.utcnow()
    raw = secrets.token_urlsafe(32)
    token = AuthToken(
        token=_token_key(raw),
        employee_id=employee_id,
        created_at=now,
        last_used_at=now,
        expires_at=now + _TOKEN_LIFETIME,
    )
    db.session.add(token)
    # Заодно подчищаем протухшие, чтобы таблица не росла бесконечно.
    AuthToken.query.filter(AuthToken.expires_at < now).delete()
    db.session.commit()
    return raw


def _bearer_token():
    """Достаёт пропуск из заголовка Authorization: Bearer <...>."""
    header = request.headers.get('Authorization', '')
    if header.lower().startswith('bearer '):
        return header[7:].strip()
    return ''


def _resolve_token(raw):
    """Пропуск → сотрудник, или None. Заодно сдвигает срок годности."""
    if not raw:
        return None
    row = db.session.get(AuthToken, _token_key(raw))
    if row is None:
        return None
    now = datetime.utcnow()
    if row.expires_at <= now:
        db.session.delete(row)
        db.session.commit()
        return None
    employee = db.session.get(Employee, row.employee_id)
    if employee is None:
        return None
    try:
        row.last_used_at = now
        row.expires_at = now + _TOKEN_LIFETIME
        db.session.commit()
    except Exception:
        # Продление — не повод отказать в самом запросе.
        db.session.rollback()
    return employee


# Как часто записываем, что человек заходил. Чаще незачем: запись нужна,
# чтобы понять, обновился ли он, а не чтобы следить за ним поминутно.
_SEEN_EVERY = timedelta(hours=6)


def _note_app_version(employee_id):
    """Запоминает версию приложения у того, кто пришёл с пропуском."""
    version = (request.headers.get('X-App-Version') or '').strip()[:20]
    account = UserAccount.query.filter_by(employee_id=employee_id).first()
    if account is None:
        return
    now = datetime.utcnow()
    fresh = account.last_seen_at and now - account.last_seen_at < _SEEN_EVERY
    if fresh and account.app_version == (version or account.app_version):
        return
    account.last_seen_at = now
    if version:
        account.app_version = version
    db.session.commit()


def _count_today(field):
    """Прибавляет единицу к дневному счётчику.

    Счётчики нужны, чтобы отвечать на вопросы «можно ли уже включать
    обязательную проверку пропуска» и «можно ли уже удалить словарь паролей
    из кода». На оба отвечает одно: несколько дней подряд ноль.
    """
    today = _plant_today()
    row = db.session.get(AuthMiss, today)
    if row is None:
        row = AuthMiss(day=today, count=0, fallback_logins=0)
        db.session.add(row)
    setattr(row, field, (getattr(row, field) or 0) + 1)
    db.session.commit()


def _note_auth_miss():
    """Считает запрос, пришедший без пропуска."""
    _count_today('count')


def require_auth(view):
    """Пускает только с действующим пропуском.

    Пока REQUIRE_AUTH выключен, запрос без пропуска проходит, но считается:
    по тому, как это число падает, видно, дошла ли новая сборка до всех и
    можно ли включать проверку (см. /api/admin/rollout).
    """
    @wraps(view)
    def wrapper(*args, **kwargs):
        g.employee = _resolve_token(_bearer_token())
        if g.employee is None:
            if _AUTH_REQUIRED:
                return jsonify({'message': 'Failure', 'error': 'unauthorized'}), 401
            logging.warning('Unauthenticated request to %s — old app build?',
                            request.path)
            try:
                _note_auth_miss()
            except Exception as e:      # счётчик не повод ронять запрос
                db.session.rollback()
                logging.warning('Не удалось учесть запрос без пропуска: %s', e)
        else:
            try:
                _note_app_version(g.employee.employee_id)
            except Exception as e:
                db.session.rollback()
                logging.warning('Не удалось записать версию приложения: %s', e)
        return view(*args, **kwargs)
    return wrapper


def _json_body():
    """Тело запроса словарём — всегда.

    request.get_json() на пустое тело, «null» или список отдаёт не словарь,
    и следующий же data.get(...) превращался в пятисотую ошибку: в журнале
    сбой сервера, а на деле кривой запрос.
    """
    data = request.get_json(silent=True)
    return data if isinstance(data, dict) else {}


def _text(data, key):
    """Строковое поле тела запроса, без пробелов по краям; иначе — «».

    Поля ждали строку и сразу звали .strip(): число, список или true вместо
    неё превращались в пятисотую ошибку. Номер, присланный числом, — тот же
    номер, поэтому целое переводим в строку; остальное считаем пустым.
    """
    value = data.get(key)
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    return ''


_ISO_DAY = re.compile(r'\d{4}-\d{2}-\d{2}')


def _iso_date(value):
    """«2026-10-08» → date; что угодно другое — None.

    Строка сравнивалась с колонкой даты как есть: PostgreSQL на «abc»
    отвечал ошибкой, и запрос заканчивался пятисотой. Формат — только тот,
    что шлёт приложение: fromisoformat сам по себе принимает и «20260301»,
    и номер недели, а это уже не дата из календаря на экране.
    """
    if not isinstance(value, str) or not _ISO_DAY.fullmatch(value.strip()):
        return None
    try:
        return date.fromisoformat(value.strip())
    except ValueError:
        return None


def _menu_items(raw):
    """Блюда из тела запроса — списком полей MenuItem, или None, если кривые.

    Строка без категории или названия пропускается, как и раньше. Цена,
    которая не число, — это отказ, а не молча пустая цена: технолог должна
    увидеть, что ошиблась.
    """
    if not isinstance(raw, list):
        return None
    items = []
    for item in raw:
        if not isinstance(item, dict):
            return None
        category = _text(item, 'category')
        name = _text(item, 'name')
        if not category or not name:
            continue
        price = item.get('price')
        if price is not None:
            if isinstance(price, bool):
                return None
            try:
                price = float(price)
            except (TypeError, ValueError):
                return None
            # «nan» float() пропускает, а в ответе он сломал бы JSON.
            if not math.isfinite(price):
                return None
        portion = item.get('portion')
        if isinstance(portion, float):
            portion = f'{portion:g}'
        else:
            portion = _text(item, 'portion')
        items.append({'category': category, 'name': name, 'price': price,
                      'portion': portion or None})
    return items


def _bad_period():
    return jsonify({'message': 'Failure', 'error': 'bad_period'}), 400


def _deny():
    return jsonify({'message': 'Failure', 'error': 'forbidden'}), 403


def _norm_title(job_title):
    """Должность в сравнимом виде: без регистра, лишних пробелов и «ё».

    Сравниваем должности целиком, а не по вхождению: «Генеральный директор»
    входит подстрокой в «Заместитель Генерального директора по экономике и
    финансам», и проверка на вхождение спутала бы одного с другим.
    """
    return re.sub(r'\s+', ' ', (job_title or '').lower().replace('ё', 'е')).strip()


# Кто смотрит проходы по всему предприятию, а не только по своему
# подразделению — и чьи проходы при этом всё равно не видит.
#
# Правило общего вида (начальник видит свой отдел) для заместителя
# Генерального директора бессмысленно: его «отдел» — это Руководство, то
# есть ровно те трое, кого ему как раз смотреть и не нужно. Поэтому доступ
# задаётся явно: всё предприятие минус перечисленные должности.
_PLANT_WIDE_VIEWERS = {
    'заместитель генерального директора по экономике и финансам': (
        'генеральный директор',
        'заместитель генерального директора по производству',
    ),
}


def _visible_employee_ids():
    """Чьи проходы этот смотрящий видит. None — значит всех без ограничений.

    Одно место на все экраны: и на «Отчёт сотрудников», и на табель. Пока
    правил было два — по одному на экран, — начальник отдела видел в отчёте
    свой отдел, а в табеле всё предприятие.
    """
    viewer = getattr(g, 'employee', None)
    if viewer is None:
        # Пропуска нет, а проверки ещё не включены: старая сборка.
        return None
    if _is_system_admin(viewer.job_title):
        return None

    hidden = _PLANT_WIDE_VIEWERS.get(_norm_title(viewer.job_title))
    if hidden is not None:
        return {e.employee_id for e in Employee.query.all()
                if e.employee_id == viewer.employee_id
                or _norm_title(e.job_title) not in hidden}

    if _is_admin_role(viewer.job_title) and viewer.department:
        ids = {e.employee_id for e in
               Employee.query.filter_by(department=viewer.department).all()}
        ids.add(viewer.employee_id)
        return ids

    return {viewer.employee_id}


def _may_view(target_employee_id):
    """Свои данные — себе, чужие — начальнику того же отдела или админу."""
    viewer = getattr(g, 'employee', None)
    if viewer is None:
        return not _AUTH_REQUIRED
    if viewer.employee_id == target_employee_id:
        return True
    allowed = _visible_employee_ids()
    return allowed is None or target_employee_id in allowed


def _is_manager():
    """Кому вообще открыт табель: начальникам и админу.

    Кого они там увидят — решает _visible_employee_ids: начальник отдела
    видит свой отдел, администратор системы — всех.
    """
    viewer = getattr(g, 'employee', None)
    if viewer is None:
        return not _AUTH_REQUIRED
    return _is_system_admin(viewer.job_title) or _is_admin_role(viewer.job_title)


def _is_admin_account():
    viewer = getattr(g, 'employee', None)
    if viewer is None:
        return not _AUTH_REQUIRED
    return _is_system_admin(viewer.job_title)


def _may_edit_menu():
    """Меню столовой пишет технолог; админ — чтобы починить, когда она не может."""
    viewer = getattr(g, 'employee', None)
    if viewer is None:
        return not _AUTH_REQUIRED
    job = (viewer.job_title or '').lower()
    return ('технолог' in job and 'столов' in job) or _is_system_admin(job)


def _employee_names():
    """employee_id → ФИО, одним запросом.

    Имя раньше доставалось внутри цикла по событиям турникета — по запросу
    к базе на каждое событие. На месячном табеле это одиннадцать тысяч
    запросов вместо двух. Сотрудников несколько сотен, весь список
    помещается в память без всяких раздумий.
    """
    return dict(db.session.query(Employee.employee_id, Employee.full_name).all())


def _resolve_employee_id(tab_number):
    """Табельный номер из таблицы → идентификатор, который уже есть в базе.

    Идентификаторы в базе разной формы: и «0000002005», и «001», и «1874» —
    так их завели разные выгрузки. Логин при этом всегда без ведущих нулей.
    Поэтому сначала спрашиваем учётную запись (она знает своего сотрудника),
    потом пробуем номер как есть и дополненный нулями. Без этого загрузка
    списка кадров заводила бы уже работающих людей заново.
    """
    account = db.session.get(UserAccount, tab_number)
    if account is not None:
        return account.employee_id
    for candidate in (tab_number, tab_number.zfill(10)):
        if db.session.get(Employee, candidate) is not None:
            return candidate
    return tab_number


def _must_change_password(login):
    # Через _find_account: иначе вошедший как «450» не увидит требования
    # сменить пароль — учётная запись-то записана как «0000000450».
    account = _find_account((login or '').strip())
    return bool(account and account.must_change_password)


def _login_by_employee():
    """employee_id → логин, для админ-панели.

    Словарь в коде даёт основу, база поверх него — она главнее.
    """
    mapping = {emp_id: login for login, emp_id in _CREDENTIALS.items()}
    for account in UserAccount.query.filter_by(is_active=True).all():
        mapping[account.employee_id] = account.login
    return mapping


# Как часто ходим на сайт за новостями. Реже — сайт не заметит нагрузки,
# чаще — незачем: новости там появляются не ежеминутно.
_NEWS_REFRESH = timedelta(minutes=15)
_news_checked_at = None

# Откуда берём новости, если в окружении ничего не задано. Раздел новостей
# сайта предприятия: адрес постоянный, а переменную NEWS_FEED_URL на боевом
# сервере ещё нужно не забыть прописать — вот и забыли.
_NEWS_SOURCE = 'https://se-btrz.com/news/'

# Куда заглядываем за лентой, если страница о ней не объявила. Так ленту
# кладут распространённые системы управления сайтом.
_FEED_GUESSES = ('feed/', 'rss/', 'feed.xml', 'rss.xml', '?feed=rss2')

# Чем закончился последний поход за новостями — для админ-панели. Отсюда
# видно, нашлась ли лента, и почему в ленте пусто.
_news_status = {'checked_at': None, 'source': '', 'kind': '',
                'found': 0, 'added': 0, 'error': ''}

# Найденный адрес ленты — чтобы не искать её заново при каждом обходе.
_news_feed_url = ''


# Потолок ответа чужого сайта. Страница новостей весит сотни килобайт; без
# потолка ошибка на той стороне — ссылка на видео вместо ленты, бесконечная
# выдача — читалась бы в память целиком, и так в каждом из трёх процессов.
_FETCH_LIMIT = 5 * 1024 * 1024


def _fetch(url, timeout=8):
    import urllib.request
    request_ = urllib.request.Request(
        url, headers={'User-Agent': 'SE-mobile/1.0',
                      'Accept': 'application/rss+xml, application/xml, text/html'})
    with urllib.request.urlopen(request_, timeout=timeout) as response:
        data = response.read(_FETCH_LIMIT + 1)
        if len(data) > _FETCH_LIMIT:
            raise ValueError(f'{url}: ответ больше {_FETCH_LIMIT // 2**20} МБ')
        return data, response.geturl()


def _load_site_news(page_url):
    """Новости с сайта: сначала лента, потом сама страница.

    Порядок именно такой. Лента описана стандартом и живёт годами, разбор
    страницы держится на вёрстке и ломается при первом же обновлении сайта.
    Но если ленты у сайта нет, новости всё равно нужны — тогда страница.

    Ходим отсюда же, из обработчика запроса, поэтому держим общий срок: пока
    сайт молчит, у сотрудника крутится ожидание ленты.

    Возвращает (список новостей, чем именно взяли).
    """
    global _news_feed_url
    import time
    deadline = time.monotonic() + 12

    # Ленту, найденную в прошлый раз, пробуем первой: искать её заново каждые
    # четверть часа значит каждые четверть часа ждать чужой сайт.
    if _news_feed_url:
        try:
            data, _ = _fetch(_news_feed_url, timeout=8)
            if looks_like_feed(data):
                return parse_news_feed(data), f'лента {_news_feed_url}'
        except Exception as e:
            logging.info('Прежняя лента %s не отвечает: %s', _news_feed_url, e)
        _news_feed_url = ''

    try:
        body, final_url = _fetch(page_url)
    except Exception:
        # Адрес в окружении может указывать на ленту, которой у сайта нет.
        # Тогда возвращаемся к разделу новостей — он-то на месте.
        if page_url == _NEWS_SOURCE:
            raise
        logging.info('Адрес %s не отвечает, берём раздел новостей', page_url)
        body, final_url = _fetch(_NEWS_SOURCE)

    if looks_like_feed(body):
        _news_feed_url = final_url
        return parse_news_feed(body), 'лента'

    # Страница. Спрашиваем у неё саму, где её лента, и только потом гадаем.
    candidates = feed_links(body, final_url)
    for guess in _FEED_GUESSES:
        url = (final_url.rstrip('/') + '/' + guess if not guess.startswith('?')
               else final_url + guess)
        if url not in candidates:
            candidates.append(url)

    for url in candidates[:6]:
        if time.monotonic() > deadline:
            logging.info('Ленту искать некогда, берём страницу')
            break
        try:
            data, _ = _fetch(url, timeout=5)
            if not looks_like_feed(data):
                continue
            items = parse_news_feed(data)
            _news_feed_url = url
            return items, f'лента {url}'
        except Exception as e:
            logging.debug('Лента %s не подошла: %s', url, e)

    return parse_news_html(body, final_url), 'страница'


# Пока один поток ходит за новостями, второму ходить незачем.
_news_lock = threading.Lock()


def _refresh_news_later(app):
    """Сходить за новостями, не задерживая того, кто открыл ленту.

    Раньше ходили прямо в его запросе. Срок на поход — двенадцать секунд, и
    пока чужой сайт молчит, у человека крутится ожидание: раз в четверть часа
    кому-то одному доставался именно такой вход в «Новости». Лента — едва ли
    не единственное, что в приложении обновляется само, и заставлять ждать
    как раз её — хуже всего.

    Теперь ему отдаётся то, что уже в базе, а за новым идёт отдельный поток.
    Следующий открывший увидит свежее.

    Пора ли идти — решается здесь же, а не в обработчике: обработчику для
    этого пришлось бы объявлять глобальную переменную, а такую забытую
    строку Python встречает `UnboundLocalError` на каждом запросе ленты.
    """
    global _news_checked_at
    now = datetime.utcnow()
    if _news_checked_at is not None and now - _news_checked_at < _NEWS_REFRESH:
        return
    if not _news_lock.acquire(blocking=False):
        return  # кто-то уже пошёл
    _news_checked_at = now

    def _run():
        try:
            with app.app_context():
                _refresh_site_news(force=True)
        except Exception as e:
            logging.warning('Фоновое обновление новостей не удалось: %s', e)
        finally:
            _news_lock.release()

    threading.Thread(target=_run, name='news-refresh', daemon=True).start()


def _refresh_site_news(force=False):
    """Забирает новости сайта, если давно не забирали.

    Ходим лениво, по факту чтения ленты, а не по расписанию: отдельный
    таймер — ещё одна деталь, которая ломается молча. Ошибка сети здесь не
    ошибка запроса: показываем то, что уже лежит в базе.

    Сам поход блокирующий и занимает до двенадцати секунд. Из обработчика
    запроса его зовут через _refresh_news_later, чтобы эти секунды ждал не
    человек; напрямую — только администратор, который нажал «обновить» и ждёт
    ответа по делу.
    """
    global _news_checked_at
    page_url = os.environ.get('NEWS_FEED_URL', '').strip() or _NEWS_SOURCE
    now = datetime.utcnow()
    if not force and _news_checked_at and now - _news_checked_at < _NEWS_REFRESH:
        return
    _news_checked_at = now
    _news_status.update({'checked_at': now.isoformat(), 'source': page_url,
                         'kind': '', 'found': 0, 'added': 0, 'error': ''})

    try:
        items, kind = _load_site_news(page_url)
    except Exception as e:
        _news_status['error'] = f'{type(e).__name__}: {e}'
        logging.warning('Не удалось обновить новости с сайта: %s', e)
        return
    _news_status.update({'kind': kind, 'found': len(items)})

    added = 0
    for order, item in enumerate(items):
        if not item['external_id']:
            continue
        if NewsItem.query.filter_by(external_id=item['external_id']).first():
            continue
        db.session.add(NewsItem(
            source='site',
            external_id=item['external_id'],
            title=item['title'],
            summary=item['summary'],
            url=item['url'] or None,
            image_url=item['image_url'] or None,
            # Без даты — сохраняем порядок страницы: первая сверху.
            published_at=item['published_at'] or (now - timedelta(minutes=order)),
            # С сайта — сразу в ленту: там материал уже прошёл редактуру.
            is_published=True,
        ))
        added += 1
    if not added:
        return
    try:
        db.session.commit()
    except Exception as e:
        # Три работника gunicorn ходят за новостями каждый сам по себе, и на
        # одинаковый external_id база отвечает отказом. Это не потеря: новость
        # уже записал сосед.
        db.session.rollback()
        _news_status['error'] = f'{type(e).__name__}: {str(getattr(e, "orig", e)).splitlines()[0]}'
        logging.warning('Не удалось сохранить новости: %s', e)
        return

    _news_status['added'] = added
    logging.info('Новостей с сайта добавлено: %d', added)
    # Об одной новости говорим по заголовку, о нескольких — счётом:
    # выкладывать пять уведомлений подряд значит, что их отключат.
    newest = (NewsItem.query.filter_by(source='site', is_published=True)
              .order_by(NewsItem.published_at.desc()).first())
    if newest is None:
        return
    if added == 1:
        _push_to_everyone('Новость', newest.title, {'type': 'news'})
    else:
        _push_to_everyone('Новости',
                          f'На сайте появилось новых материалов: {added}',
                          {'type': 'news'})


def _news_json(item):
    return {
        'id': item.id,
        'source': item.source,
        'title': item.title,
        'summary': item.summary or '',
        'url': item.url or '',
        'image_url': item.image_url or '',
        'author': item.author or '',
        # Со смещением: время новости сервер хранит в UTC, а телефон стоит
        # в местном поясе и переводит сам — но только если знает, что перед
        # ним UTC. Без смещения он считал время местным, и новость, вышедшая
        # ночью, показывалась вчерашней.
        'published_at': (item.published_at.replace(tzinfo=timezone.utc).isoformat()
                         if item.published_at else None),
        'is_published': item.is_published,
    }


# Версия сидера. Пока она совпадает с записанной в журнале, сидер не
# запускается. Изменили данные внутри сидера — повысьте здесь версию, и он
# отработает один раз на боевой базе. Отсутствующие здесь считаются версией '1'.
_SEED_VERSIONS = {
    # Даурембекова переехала с временного D013 на табельный 0000001465.
    '_seed_org_directory': '3',
    # Вместе с ней в списке дублей появилась вторая пара.
    '_merge_duplicate_employees': '3',
    # Должность и подразделение на листках переписаны с печатных на настоящие.
    '_seed_daurembekova': '3',
    # Пароли больше не переносятся из кода: новая строка заводится с
    # временным паролем. Версия поднята ещё и затем, чтобы сидер прошёл
    # заново и восстановил строку, если какая-то пропала, — запасного пути
    # через _CREDENTIALS больше нет.
    '_seed_user_accounts': '2',
    # Вместо списка из одной учётки — проверка всех: пароль, равный логину,
    # временный у кого угодно.
    '_force_password_change': '2',
}


def _load_applied_seeds():
    """Журнал отработавших сидеров: {имя функции: версия}.

    При первом запуске после обновления таблицы ещё нет — тогда журнал пуст и
    отработают все сидеры, как и раньше.
    """
    try:
        return {row.name: row.version for row in AppliedSeed.query.all()}
    except Exception as e:
        db.session.rollback()
        logging.warning(f'Cannot read applied_seeds ({e}); running all seeders')
        return {}


def _mark_seed_applied(name, version):
    try:
        row = db.session.get(AppliedSeed, name)
        if row is None:
            db.session.add(AppliedSeed(name=name, version=version))
        else:
            row.version = version
            row.applied_at = datetime.utcnow()
        db.session.commit()
    except Exception as e:
        db.session.rollback()
        # Не отметился — значит в следующий раз отработает снова. Медленно,
        # но безопасно: сидеры идемпотентны.
        logging.warning(f'Cannot record seed {name} ({e})')


def create_app():
    app = Flask(__name__)
    # Только те источники, которые названы явно. Приложению на телефоне CORS
    # не нужен вовсе — заголовок Origin шлёт браузер, — поэтому по умолчанию
    # список пуст и чужой сайт до сервера не достучится.
    origins = [o.strip() for o in
               os.environ.get('CORS_ORIGINS', '').split(',') if o.strip()]
    if origins:
        CORS(app, origins=origins)
        logging.info('CORS разрешён для: %s', ', '.join(origins))

    logging.basicConfig(level=logging.INFO)

    # Пустая строка — это «не задано». `DATABASE_URL=` без значения в
    # /etc/se-mobile.env иначе уехал бы в SQLAlchemy как адрес базы, и
    # приложение упало бы на разборе строки вместо понятного отказа.
    db_url = os.environ.get('DATABASE_URL', '').strip() or 'sqlite:///se_mobile.db'
    # Драйвер называем явно. «postgresql://» без драйвера SQLAlchemy
    # раскрывает сам, и в версии 2.1 раскрывает иначе, чем в 2.0: вместо
    # psycopg2, который стоит в requirements.txt, ищет psycopg третьей
    # версии, которого там нет. Приложение при этом не поднимается вовсе —
    # «No module named 'psycopg'» ещё до первого запроса. Так упала первая же
    # сборка на чистой машине, и так упал бы боевой сервер при первой
    # переустановке зависимостей: в /etc/se-mobile.env у него стоит ровно
    # «postgresql://». Render выдаёт ещё и «postgres://» — его тоже сюда.
    for bare in ('postgres://', 'postgresql://'):
        if db_url.startswith(bare):
            db_url = 'postgresql+psycopg2://' + db_url[len(bare):]
            break
    # Маскируем пароль в логе
    safe_url = db_url.split('@')[-1] if '@' in db_url else db_url
    logging.info(f'DB backend: {safe_url}')
    app.config['SQLALCHEMY_DATABASE_URI'] = db_url
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
    # Сервер на бесплатном тарифе подолгу простаивает, и соединение в пуле к
    # этому моменту базой уже закрыто. Без pre_ping первый же запрос после
    # простоя падает на мёртвом соединении, а следующий берёт новое и проходит
    # — отсюда «не зарегистрирован» при первом входе и успех со второго раза.
    # pre_ping проверяет соединение перед выдачей и молча заменяет мёртвое.
    app.config['SQLALCHEMY_ENGINE_OPTIONS'] = {
        'pool_pre_ping': True,
        # Меньше типичного таймаута простоя у провайдера: соединение старше
        # этого возраста пул переоткрывает сам.
        'pool_recycle': 280,
    }

    db.init_app(app)

    with app.app_context():
        logging.info('Running db.create_all()...')
        try:
            db.create_all()
        except Exception as e:
            logging.error(f'db.create_all() failed (non-fatal): {e}', exc_info=True)
        logging.info('db.create_all() done')
        # _migrate_schema идёт отдельно и всегда: он приводит схему в
        # соответствие с моделями, а не наполняет её данными.
        try:
            _migrate_schema()
        except Exception as e:
            db.session.rollback()
            logging.error(f'_migrate_schema failed (non-fatal): {e}', exc_info=True)
        try:
            _hash_stored_tokens()
        except Exception as e:
            db.session.rollback()
            logging.error(f'_hash_stored_tokens failed (non-fatal): {e}', exc_info=True)

        # Сеем под замком. Gunicorn держит три процесса, и каждый при старте
        # доходит сюда; журнал applied_seeds спасает, только если первый успел
        # в него записаться. При одновременном старте не успевает — все трое
        # читают «не отработано» и вставляют одно и то же. Замок пропускает
        # по одному: пока первый сеет, остальные ждут, а дождавшись, читают
        # журнал уже заполненным и пропускают всё.
        #
        # Замок берётся на отдельном соединении и живёт до его закрытия, так
        # что упавший процесс его не удержит. В SQLite процесс всего один —
        # там делить нечего.
        _lock = None
        if db.engine.dialect.name == 'postgresql':
            from sqlalchemy import text as _text
            try:
                _lock = db.engine.connect()
                _lock.execute(_text('SELECT pg_advisory_lock(:key)'),
                              {'key': _SEED_LOCK_KEY})
                _lock.commit()
            except Exception as e:
                logging.warning(f'Cannot take the seeding lock ({e}); seeding anyway')
                if _lock is not None:
                    _lock.close()
                _lock = None

        try:
            _seed_all()
        finally:
            if _lock is not None:
                try:
                    _lock.execute(_text('SELECT pg_advisory_unlock(:key)'),
                                  {'key': _SEED_LOCK_KEY})
                    _lock.commit()
                except Exception as e:
                    logging.warning(f'Cannot release the seeding lock ({e})')
                _lock.close()

    register_routes(app)

    @app.errorhandler(Exception)
    def _unhandled(error):
        """Последняя сетка: любая незамеченная ошибка — чистый JSON, не HTML.

        Приложение всюду разбирает ответ как JSON. Когда обработчик падал,
        Flask отдавал страницу с описанием ошибки, разбор ломался, и человек
        видел «ошибка сети» — то есть ровно то же, что при пропавшей связи.
        Отличить одно от другого было нельзя ни ему, ни поддержке.

        Отказы вида 403 и 404 сюда тоже приходят: их отдаём как есть, со
        своим кодом, а неожиданное — пятисотым и в журнал вместе с адресом.
        """
        if isinstance(error, HTTPException):
            return jsonify({'message': 'Failure',
                            'error': error.name,
                            'status': error.code}), error.code
        db.session.rollback()
        logging.error('Необработанная ошибка на %s %s: %s',
                      request.method, request.path, error, exc_info=True)
        return jsonify({'message': 'Failure', 'error': 'internal'}), 500

    return app


# Произвольное число: важно лишь, чтобы все процессы брали один и тот же замок.
_SEED_LOCK_KEY = 8_146_501


def _seed_all():
    """Прогоняет сидеры по журналу. Вызывается под замком — см. create_app."""
    _applied = _load_applied_seeds()
    _ran = _skipped = 0
    for _fn in [
        _auto_seed,
        _update_employee_names,
        _update_employee_iins,
        _seed_sarseken,
        _seed_leave_2026,
        _seed_kumarova,
        _seed_docx_employees_2026,
        _seed_org_directory,
        _seed_admin_account,
        _seed_daurembekova,
        _seed_beisekina,
        _merge_duplicate_employees,
        _remove_departed_employees,
        # Последним: ссылается на сотрудников, которых сидеры выше ещё
        # создают, склеивают и удаляют.
        _seed_user_accounts,
        _seed_extra_accounts,
        # После учёток из кода: справочник заводит людей и логины пачкой, и
        # ему важно видеть, у кого учётная запись уже есть.
        _seed_directory_staff_2026,
        # После всех, кто заводит учётные записи: проверяет пароли у тех,
        # кого они успели создать.
        _force_password_change,
        _secure_admin_account,
        _seed_access_august_2026,
        _seed_legacy_from_data,
        _seed_payslips_from_data,
        # Последним: подчищает следы прежних одновременных запусков.
        _dedupe_access_records,
    ]:
        _name = _fn.__name__
        _version = _SEED_VERSIONS.get(_name, '1')
        if _applied.get(_name) == _version:
            _skipped += 1
            continue
        _ran += 1
        try:
            _fn()
        except Exception as e:
            db.session.rollback()
            logging.error(f'{_name} failed (non-fatal): {e}', exc_info=True)
        else:
            _mark_seed_applied(_name, _version)
    logging.info('Seeders: %d executed, %d skipped', _ran, _skipped)


def _data_freshness():
    """По какое число заполнен каждый источник данных и скольких он покрывает.

    Собрано в одном месте потому, что все, кого я находил, — одного рода:
    данные в приложении отстают, а видно это только сотруднику, который
    открыл экран и увидел пустоту. Расчётные листки кончались июлем, и
    экран открывался пустым у всех ста тридцати; проходы — 20 августа, и
    «Сегодня» был пуст у всех; меню перенесли один раз и больше не трогали.
    Каждый раз об этом узнавали от людей, а не от приложения.

    Здесь то же самое видит тот, кто может это исправить.
    """
    today = _plant_today()

    def behind(value):
        if value is None:
            return None
        if isinstance(value, datetime):
            value = value.date()
        return (today - value).days

    def source(key, last, rows, people=None, note=''):
        return {'key': key, 'last': last.isoformat() if last else None,
                'days_behind': behind(last), 'rows': rows,
                'people': people, 'note': note}

    out = []
    try:
        latest = (db.session.query(Payslip.period_year, Payslip.period_month)
                  .order_by(Payslip.period_year.desc(),
                            Payslip.period_month.desc()).first())
        # Последний день месяца, а не первый: листок за июль закрывает июль,
        # и отставание считается от его конца, иначе оно на месяц больше
        # правды.
        last = (date(latest[0] + 1, 1, 1) - _ONE_DAY if latest[1] == 12
                else date(latest[0], latest[1] + 1, 1) - _ONE_DAY) if latest else None
        # Считаем по последнему месяцу, а не по всей таблице: «сколько человек
        # получили листок» — это про свежую выгрузку, а не про историю.
        covered = (db.session.query(Payslip.employee_id)
                   .filter(Payslip.period_year == latest[0],
                           Payslip.period_month == latest[1])
                   .distinct().count()) if latest else 0
        out.append(source('payslips', last, Payslip.query.count(), covered))
    except Exception as e:
        db.session.rollback()
        out.append(source('payslips', None, 0, None, str(e)))

    try:
        last = db.session.query(db.func.max(AccessRecord.access_date)).scalar()
        covered = (db.session.query(AccessRecord.employee_id)
                   .filter(AccessRecord.access_date == last)
                   .distinct().count()) if last else 0
        out.append(source('access', last, AccessRecord.query.count(), covered))
    except Exception as e:
        db.session.rollback()
        out.append(source('access', None, 0, None, str(e)))

    try:
        last = db.session.query(db.func.max(MenuDate.date)).scalar()
        out.append(source('menu', last, MenuItem.query.count()))
    except Exception as e:
        db.session.rollback()
        out.append(source('menu', None, 0, None, str(e)))

    try:
        last = db.session.query(db.func.max(NewsItem.published_at)).scalar()
        out.append(source('news', last, NewsItem.query.count()))
    except Exception as e:
        db.session.rollback()
        out.append(source('news', None, 0, None, str(e)))

    try:
        covered = db.session.query(LeaveBalance.employee_id).distinct().count()
        out.append(source('leaves', None, LeaveBalance.query.count(), covered))
    except Exception as e:
        db.session.rollback()
        out.append(source('leaves', None, 0, None, str(e)))

    try:
        out.append(source('directory', None, DirectoryEntry.query.count()))
    except Exception as e:
        db.session.rollback()
        out.append(source('directory', None, 0, None, str(e)))

    try:
        out.append(source('employees', None, Employee.query.count(),
                          UserAccount.query.filter_by(is_active=True).count()))
    except Exception as e:
        db.session.rollback()
        out.append(source('employees', None, 0, None, str(e)))

    return out


# Где лежит собранное приложение. nginx отдаёт эту же папку по /app/,
# поэтому телефону хватает ссылки, а серверу — прочитать имя файла.
_APK_DIR = os.environ.get('APK_DIR', '/var/www/se-mobile')

# Имя файла и есть версия: se-mobile-1.8.2+12.apk. Так её неоткуда потерять —
# сборка записывает её в имя, сервер оттуда же и читает. Отдельного файла с
# номером версии нет намеренно: любой номер, который надо где-то повторить,
# рано или поздно отстаёт.
_APK_NAME = re.compile(r'^se-mobile-(\d+)\.(\d+)\.(\d+)\+(\d+)\.apk$')


def _public_origin():
    """Адрес, по которому к нам пришли снаружи, — со схемой и именем."""
    proto = (request.headers.get('X-Forwarded-Proto') or '').split(',')[0].strip()
    if proto not in ('http', 'https'):
        proto = request.scheme
    host = (request.headers.get('X-Forwarded-Host')
            or request.host or '').split(',')[0].strip()
    return f'{proto}://{host}'


def _latest_apk():
    """Самая свежая сборка, лежащая на сервере, или None.

    Приложение раздаётся руками: пятистам людям нужно сказать, что вышла
    новая сборка, и дать её скачать. Пока этого не было, обязательную
    проверку пропуска нельзя включить — необновившиеся перестали бы
    работать, — а узнать, кто обновился, можно было только по их запросам.
    """
    try:
        names = os.listdir(_APK_DIR)
    except OSError as e:
        return {'available': False, 'reason': str(e)}

    builds = []
    for name in names:
        found = _APK_NAME.match(name)
        if not found:
            continue
        major, minor, patch, build = (int(x) for x in found.groups())
        builds.append((build, (major, minor, patch), name))
    if not builds:
        return {'available': False,
                'reason': f'в {_APK_DIR} нет файлов вида se-mobile-1.8.2+12.apk'}

    # По номеру сборки: Android ставит поверх только его, а не «1.8.2».
    build, version, name = max(builds)
    path = os.path.join(_APK_DIR, name)
    try:
        size = os.path.getsize(path)
        built_at = datetime.utcfromtimestamp(os.path.getmtime(path))
    except OSError as e:
        return {'available': False, 'reason': str(e)}

    return {
        'available': True,
        'version': '.'.join(str(x) for x in version),
        'build': build,
        'file': name,
        # Схему берём из заголовка nginx: до gunicorn запрос доходит по http,
        # и request.host_url всегда сказал бы http — даже тому, кто пришёл по
        # https. Телефон получил бы ссылку на скачивание без шифрования.
        'url': f'{_public_origin()}/app/{name}',
        'size': size,
        'built_at': built_at.replace(tzinfo=timezone.utc).isoformat(),
    }


# Что сторож записал о перебоях. Файл пишет /usr/local/bin/se-mobile-watchdog,
# приложение только читает.
_WATCHDOG_LOG = os.environ.get(
    'WATCHDOG_LOG', '/var/lib/se-mobile/watchdog/outages.log')


def _outage_state(limit=5):
    """Когда сервер в последний раз не отвечал.

    Сбой 12 сентября прожил восемь дней, и узнали о нём от сотрудника.
    Сторож теперь его заметит и поднимет упавшее, но заметить мало: надо,
    чтобы это увидел человек. Поэтому последние записи показываются там же,
    где копии базы и свежесть данных.

    Пусто — хорошо: сервер не падал с тех пор, как завели журнал.
    """
    try:
        with open(_WATCHDOG_LOG, encoding='utf-8', errors='replace') as f:
            # Журнал растёт медленно (строка на сбой), но читать его целиком
            # незачем: берём хвост.
            lines = f.readlines()[-200:]
    except FileNotFoundError:
        return {'available': True, 'entries': [], 'total': 0}
    except OSError as e:
        return {'available': False, 'reason': str(e), 'entries': [], 'total': 0}

    entries = []
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        when, _, what = line.partition(' ')
        entries.append({'at': when, 'what': what})
        if len(entries) >= limit:
            break
    return {'available': True, 'entries': entries,
            'total': sum(1 for l in lines if l.strip())}


def _backup_state():
    """Когда была последняя копия базы и сколько их всего.

    Копирование идёт отдельной службой, и три недели подряд оно падало на
    том, что папку нельзя создать, — узнали об этом случайно. Раз уж
    администратор открывает эту страницу, пусть видит и это.
    """
    directory = os.environ.get('BACKUP_DIR', '/var/backups/se-mobile')
    try:
        files = [f for f in os.listdir(directory) if f.startswith('se_mobile_')]
    except OSError as e:
        return {'available': False, 'reason': str(e), 'count': 0}
    if not files:
        return {'available': True, 'count': 0, 'last': None, 'days_ago': None}
    newest = max(files, key=lambda f: os.path.getmtime(os.path.join(directory, f)))
    when = datetime.utcfromtimestamp(
        os.path.getmtime(os.path.join(directory, newest)))
    return {
        'available': True,
        'count': len(files),
        'last': when.date().isoformat(),
        'days_ago': (datetime.utcnow() - when).days,
        'encrypted': newest.endswith('.enc'),
    }


def register_routes(app):

    @app.route('/')
    def index():
        return jsonify({
            'status': 'ok',
            'service': 'SE-mobile API',
            'version': '3.0 (PostgreSQL + FCM + Canteen)',
            'endpoints': [
                'POST /login',
                'POST /report',
                'POST /reportdate',
                'POST /director_report',
                'POST /get_sname',
                'POST /payslip',
                'POST /payslip/xlsx',
                'POST /api/home',
                'POST /leaves',
                'POST /api/fcm-token',
                'DELETE /api/fcm-token',
                'POST /api/turnstile',
                'GET /api/attendance',
                'GET /api/attendance/summary',
                'GET /api/menu',
                'POST /api/menu',
                'DELETE /api/menu/<date>',
            ]
        })

    @app.route('/login', methods=['POST'])
    def login():
        data = _json_body()
        login_id = _text(data, 'login')
        password  = _text(data, 'password')

        try:
            employee_id = _authenticate(login_id, password)
            if employee_id:
                emp = Employee.query.get(employee_id)
                if emp:
                    return jsonify({
                        'message': 'Success',
                        'full_name': emp.full_name,
                        'job': emp.job_title,
                        'employee_id': emp.employee_id,
                        # Пропуск для всех последующих запросов. Старые сборки
                        # его просто игнорируют.
                        'token': _issue_token(emp.employee_id),
                        # Временный пароль: приложение сразу попросит новый.
                        'must_change_password': _must_change_password(login_id),
                    })
        except Exception as e:
            db.session.rollback()
            logging.error(f'login failed for login={login_id!r}: {e}', exc_info=True)
            # 503, а не 200: сбой базы — это не «неверный пароль». С кодом 200
            # приложение показывало «логин не зарегистрирован» и человек думал,
            # что перепутал пароль.
            return jsonify({'message': 'Failure', 'error': 'internal'}), 503

        # Отличаем «не тот пароль» от «слишком много попыток»: иначе человек
        # будет молотить по кнопке и продлевать себе замок.
        seconds = locked_for(login_id)
        if seconds:
            return jsonify({'message': 'Failure', 'error': 'locked',
                            'retry_after': seconds}), 429
        return jsonify({'message': 'Failure'})

    @app.route('/privacy', methods=['GET'])
    def privacy():
        """Политика конфиденциальности — ссылка на неё нужна Google Play.

        Без пропуска: её открывают из магазина, до всякого входа.
        """
        return Response(privacy_page(), mimetype='text/html')

    @app.route('/health', methods=['GET'])
    def health():
        """Жив ли сервер — вместе с базой, а не сам по себе.

        Двенадцатого сентября приложение отвечало, а база лежала: процесс был
        на месте, systemd считал службу исправной, и сбой прожил восемь дней —
        ровно до первой жалобы сотрудника. Значит, «работает» надо проверять
        запросом в базу, а не тем, что порт открыт.

        Отвечает 503, когда базы нет: по этому коду за него может взяться и
        сторож на сервере, и любой сторонний присмотр, если его когда-нибудь
        заведут.
        """
        try:
            db.session.execute(db.text('SELECT 1'))
            return jsonify({'status': 'ok', 'database': 'ok'})
        except Exception as e:
            db.session.rollback()
            logging.error('Проверка здоровья не прошла: %s', e)
            return jsonify({'status': 'fail', 'database': str(e)[:200]}), 503

    @app.route('/api/app/latest', methods=['GET'])
    def app_latest():
        """Какая сборка лежит на сервере — чтобы телефон сам предложил её.

        Без пропуска: приложение спрашивает это и на экране входа, и когда
        пропуск уже просрочен, — а узнать про обновление ему в этот момент
        нужнее всего.

        Отвечаем и когда файла нет: приложение тогда просто молчит, а
        администратор видит причину на экране «Обновление».
        """
        return jsonify({'message': 'Success', 'app': _latest_apk()})

    @app.route('/api/me', methods=['GET'])
    @require_auth
    def whoami():
        """Кто я, по пропуску.

        Приложение спрашивает это при каждом запуске. Раньше оно для этого
        входило заново — хранило на телефоне пароль и отправляло его. Пароль
        там больше не нужен: пропуск и сам продлевается этим запросом.

        Заодно отсюда приложение узнаёт, что пароль сброшен и его пора
        сменить: до этого о сбросе знал только экран входа, и человек,
        который уже вошёл, не узнавал о нём никогда.
        """
        viewer = getattr(g, 'employee', None)
        if viewer is None:
            return jsonify({'message': 'Failure', 'error': 'unauthorized'}), 401
        account = UserAccount.query.filter_by(
            employee_id=viewer.employee_id).first()
        return jsonify({
            'message': 'Success',
            'employee_id': viewer.employee_id,
            'full_name': viewer.full_name,
            'job': viewer.job_title,
            'department': viewer.department or '',
            'must_change_password': bool(account and account.must_change_password),
        })

    @app.route('/change-password', methods=['POST'])
    @require_auth
    def change_password():
        """Смена своего пароля. Старый обязателен — иначе чужой оставленный
        без присмотра телефон позволил бы забрать учётную запись насовсем."""
        viewer = getattr(g, 'employee', None)
        if viewer is None:
            return jsonify({'message': 'Failure', 'error': 'unauthorized'}), 401

        data = _json_body()
        old_password = _text(data, 'old_password')
        new_password = _text(data, 'new_password')

        account = UserAccount.query.filter_by(
            employee_id=viewer.employee_id, is_active=True).first()
        if account is None:
            return jsonify({'message': 'Failure', 'error': 'no_account'}), 404
        # Тот же замок, что на входе, и тот же счётчик. Без него старый
        # пароль здесь можно было перебирать сколько угодно: хватало чужого
        # телефона, оставленного открытым, — а подобрав пароль, сменить его
        # и забрать учётную запись насовсем.
        now = datetime.utcnow()
        if account.locked_until is not None and account.locked_until > now:
            return jsonify({'message': 'Failure', 'error': 'locked',
                            'retry_after': max(1, int(
                                (account.locked_until - now).total_seconds()))}), 429
        if not check_password_hash(account.password_hash, old_password):
            account.failed_attempts = (account.failed_attempts or 0) + 1
            delay = _lock_delay(account.failed_attempts)
            if delay is not None:
                account.locked_until = now + delay
                logging.warning('Смена пароля %r закрыта на %s после %d неудач',
                                account.login, delay, account.failed_attempts)
            db.session.commit()
            return jsonify({'message': 'Failure', 'error': 'wrong_password'}), 403

        problem = _password_problem(new_password, account.login)
        if problem:
            return jsonify({'message': 'Failure', 'error': problem}), 400

        account.password_hash = generate_password_hash(new_password)
        account.must_change_password = False
        account.failed_attempts = 0
        account.locked_until = None
        # Гасим все пропуска: если пароль меняют потому, что его подсмотрели,
        # чужое устройство должно перестать работать сразу.
        AuthToken.query.filter_by(employee_id=viewer.employee_id).delete()
        db.session.commit()

        return jsonify({
            'message': 'Success',
            'token': _issue_token(viewer.employee_id),
        })

    @app.route('/api/admin/accounts', methods=['GET'])
    @require_auth
    def admin_accounts():
        """Список учётных записей для админ-панели: кто заходил, кто ещё нет."""
        if not _is_admin_account():
            return _deny()
        names = _employee_names()
        rows = [{
            'login': a.login,
            'employee_id': a.employee_id,
            'full_name': names.get(a.employee_id, a.employee_id),
            'must_change_password': a.must_change_password,
            'is_active': a.is_active,
            'failed_attempts': a.failed_attempts,
            'locked_seconds': locked_for(a.login),
            'last_login_at': a.last_login_at.isoformat() if a.last_login_at else None,
        } for a in UserAccount.query.order_by(UserAccount.login).all()]
        never = sum(1 for r in rows if r['last_login_at'] is None)
        return jsonify({'message': 'Success', 'accounts': rows,
                        'total': len(rows), 'never_signed_in': never})

    @app.route('/api/admin/accounts/<login>/reset', methods=['POST'])
    @require_auth
    def admin_reset_password(login):
        """Сброс пароля админом: временным становится табельный номер, и при
        первом же входе человека попросят придумать свой."""
        if not _is_admin_account():
            return _deny()
        account = db.session.get(UserAccount, login)
        if account is None:
            return jsonify({'message': 'Failure', 'error': 'not_found'}), 404

        # Табельный номер годится во временные: он у человека на пропуске и
        # меняется при первом же входе. Для именованной учётки — «admin» —
        # это означало бы пароль «admin», то есть ровно то, от чего мы
        # уходили; такой придумываем случайно и показываем тому, кто сбросил.
        temporary = account.login if account.login.isdigit() else _random_password()
        account.password_hash = generate_password_hash(temporary)
        account.must_change_password = True
        account.failed_attempts = 0
        account.locked_until = None
        account.is_active = True
        AuthToken.query.filter_by(employee_id=account.employee_id).delete()
        db.session.commit()
        logging.info('Password reset for %r by administrator', login)
        return jsonify({'message': 'Success', 'temporary_password': temporary})

    @app.route('/api/admin/employees/import-excel', methods=['POST'])
    @require_auth
    def import_employees_excel():
        """Заводит сотрудников и учётные записи из таблицы отдела кадров.

        Повторная загрузка того же файла безопасна: существующие обновляются,
        новые добавляются, пароли не трогаются. Временный пароль у новых равен
        табельному номеру, и сменить его попросят при первом входе.
        """
        if not _is_admin_account():
            return _deny()
        if 'file' not in request.files:
            return jsonify({'message': 'Файл не передан', 'error': True}), 400
        upload = request.files['file']
        if not (upload.filename or '').lower().endswith(('.xlsx', '.xlsm')):
            return jsonify({'message': 'Нужен файл Excel (.xlsx)', 'error': True}), 400

        try:
            people, skipped = parse_employees_excel(upload.read())
        except ValueError as e:
            return jsonify({'message': str(e), 'error': True}), 422

        # ФИО тех, кто уже заведён. Совпадение имени при новом табельном
        # номере — почти всегда опечатка в таблице, и молча плодить второго
        # человека нельзя: именно так в базе однажды появилась вторая
        # Кумарова с потерянными проходами. Полные тёзки бывают, поэтому
        # не запрещаем, а показываем в отчёте.
        existing_names = {}
        for emp in Employee.query.all():
            existing_names.setdefault(emp.full_name.strip().lower(),
                                      emp.employee_id)
        warnings = []

        created_employees = updated_employees = created_accounts = 0
        for person in people:
            # Логин — табельный номер без ведущих нулей; сотрудник в базе
            # может лежать под другой формой того же номера.
            login = person['employee_id']
            emp_id = _resolve_employee_id(login)
            employee = db.session.get(Employee, emp_id)
            if employee is None:
                twin = existing_names.get(person['full_name'].strip().lower())
                if twin:
                    warnings.append(
                        f"{person['full_name']}: табельный {login} новый, но "
                        f"такое ФИО уже у сотрудника {twin} — проверьте номер")
                employee = Employee(employee_id=emp_id,
                                    full_name=person['full_name'],
                                    job_title=person['job_title'])
                db.session.add(employee)
                existing_names.setdefault(person['full_name'].strip().lower(), emp_id)
                created_employees += 1
            else:
                changed = (employee.full_name != person['full_name']
                           or employee.job_title != person['job_title']
                           or (employee.department or '') != person['department'])
                employee.full_name = person['full_name']
                employee.job_title = person['job_title']
                if changed:
                    updated_employees += 1
            employee.department = person['department'] or employee.department
            # ИИН уникален: чужой занятый номер молча пропускаем, а не роняем
            # всю загрузку из-за одной опечатки в таблице.
            if person['iin'] and employee.iin != person['iin']:
                clash = Employee.query.filter(
                    Employee.iin == person['iin'],
                    Employee.employee_id != emp_id).first()
                if clash is None:
                    employee.iin = person['iin']
                else:
                    skipped.append({'row': 0, 'content': person['full_name'],
                                    'reason': f"ИИН уже у {clash.full_name}"})

            if db.session.get(UserAccount, login) is None:
                db.session.add(UserAccount(
                    login=login,
                    employee_id=emp_id,
                    password_hash=generate_password_hash(login),
                    must_change_password=True,
                ))
                created_accounts += 1

        db.session.commit()
        logging.info('Employee import: %d new, %d updated, %d accounts, '
                     '%d skipped, %d warnings', created_employees,
                     updated_employees, created_accounts, len(skipped),
                     len(warnings))
        return jsonify({
            'message': 'Success',
            'employees_created': created_employees,
            'employees_updated': updated_employees,
            'accounts_created': created_accounts,
            'skipped': skipped,
            'warnings': warnings,
            'total_employees': Employee.query.count(),
        })

    @app.route('/logout', methods=['POST'])
    def logout():
        """Гасит пропуск этого устройства. Остальные устройства не трогает."""
        raw = _bearer_token()
        if raw:
            row = db.session.get(AuthToken, _token_key(raw))
            if row is not None:
                db.session.delete(row)
                db.session.commit()
        return jsonify({'message': 'Success'})

    @app.route('/report', methods=['POST'])
    @require_auth
    def report():
        data = _json_body()
        key_suffix = _text(data, 'key_suffix')
        if not _may_view(key_suffix):
            return _deny()

        records = AccessRecord.query.filter_by(employee_id=key_suffix)\
            .order_by(AccessRecord.access_date, AccessRecord.access_time).all()
        # Пусто — это не отказ. Отвечать «Failure» на «проходов нет» значило
        # сваливать в одну кучу сбой связи и человека, которого нет в выгрузке
        # СКУД; экран показывал одно и то же и в том, и в другом случае.
        return jsonify({
            'message': 'Success',
            'report': [_access_to_dict(r) for r in records],
            'coverage': _access_coverage(key_suffix),
        })

    @app.route('/reportdate', methods=['POST'])
    @require_auth
    def reportdate():
        data = _json_body()
        key_suffix = _text(data, 'key_suffix')
        if not _may_view(key_suffix):
            return _deny()
        start_date = _iso_date(data.get('start_date'))
        end_date = _iso_date(data.get('end_date'))
        if start_date is None or end_date is None:
            return _bad_period()

        records = AccessRecord.query.filter(
            AccessRecord.employee_id == key_suffix,
            AccessRecord.access_date >= start_date,
            AccessRecord.access_date <= end_date
        ).order_by(AccessRecord.access_date, AccessRecord.access_time).all()

        return jsonify({
            'message': 'Success',
            'report': [_access_to_dict(r) for r in records],
            'coverage': _access_coverage(key_suffix),
        })

    @app.route('/director_report', methods=['POST'])
    @require_auth
    def director_report():
        data = _json_body()
        emp_sname = _text(data, 'emp_sname')
        start_date = _iso_date(data.get('start_date'))
        end_date = _iso_date(data.get('end_date'))
        if start_date is None or end_date is None:
            return _bad_period()

        emp = _find_reportable(emp_sname)
        if not emp:
            # Отдельно от «проходов нет»: это разные ответы на разные вопросы,
            # а выглядели они одинаково.
            return jsonify({'message': 'Failure', 'error': 'not_found'})
        # Сотрудника здесь ищут по фамилии, поэтому право проверяем после того,
        # как узнали, кто это.
        if not _may_view(emp.employee_id):
            return _deny()

        records = AccessRecord.query.filter(
            AccessRecord.employee_id == emp.employee_id,
            AccessRecord.access_date >= start_date,
            AccessRecord.access_date <= end_date
        ).order_by(AccessRecord.access_date, AccessRecord.access_time).all()

        return jsonify({
            'message': 'Success',
            'director_report': [_access_to_dict(r) for r in records],
            'coverage': _access_coverage(emp.employee_id),
        })

    @app.route('/api/admin/employees', methods=['GET'])
    @require_auth
    def admin_employees():
        # Здесь ИИН всех сотрудников — только администратору системы.
        if not _is_admin_account():
            return _deny()
        """Full staff directory for the admin panel, with what data each has."""
        from sqlalchemy import func as sa_func

        payslip_counts = dict(
            db.session.query(Payslip.employee_id, sa_func.count(Payslip.id))
            .group_by(Payslip.employee_id).all())
        access_counts = dict(
            db.session.query(AccessRecord.employee_id, sa_func.count(AccessRecord.id))
            .group_by(AccessRecord.employee_id).all())
        leave_counts = dict(
            db.session.query(LeaveBalance.employee_id, sa_func.count(LeaveBalance.id))
            .group_by(LeaveBalance.employee_id).all())
        logins = _login_by_employee()

        employees = [{
            'employee_id': e.employee_id,
            'full_name': e.full_name,
            'job_title': e.job_title,
            'department': e.department or '',
            'iin': e.iin or '',
            'login': logins.get(e.employee_id, ''),
            'payslip_count': payslip_counts.get(e.employee_id, 0),
            'access_count': access_counts.get(e.employee_id, 0),
            'leave_count': leave_counts.get(e.employee_id, 0),
        } for e in Employee.query.order_by(Employee.full_name).all()]

        return jsonify({'message': 'Success', 'employees': employees})

    @app.route('/get_sname', methods=['POST'])
    @require_auth
    def get_sname():
        """Кого руководитель может выбрать в «Отчёте сотрудников».

        Список строится той же _visible_employee_ids, что проверяет право
        открыть отчёт (/director_report). Раньше он строился отдельно — по
        отделу из табельного номера в запросе: подставив чужой номер, можно
        было получить список чужого отдела, а у человека без отдела — всё
        предприятие. И тем, кому положено видеть больше своего отдела, список
        показывал меньше, чем им разрешено открыть.

        Поиск по ИИН («emp_iin») закрыт: приложение его не вызывает, а
        отвечал он любому вошедшему, чей это ИИН — ФИО и должность. ИИН
        содержит дату рождения и пол, и такой ответ — это сведения о человеке
        по его номеру.
        """
        data = _json_body()
        if 'key_suffix' not in data:
            return jsonify({'message': 'Failure'})
        if not _is_manager():
            return _deny()

        allowed = _visible_employee_ids()
        query = Employee.query
        if allowed is not None:
            query = query.filter(Employee.employee_id.in_(allowed))
        viewer = getattr(g, 'employee', None)
        if viewer is not None:
            query = query.filter(Employee.employee_id != viewer.employee_id)
        # Some people exist twice (a legacy id kept alongside the tabular
        # one), so collapse repeats to keep the picker clean.
        names = list(dict.fromkeys(e.full_name for e in query.all()))
        return jsonify({'fio': names})

    @app.route('/payslip/periods', methods=['POST'])
    @require_auth
    def payslip_periods():
        """За какие месяцы у человека вообще есть расчётный лист.

        Экран листка открывался на прошлом месяце — и был пуст. Сегодня
        23 сентября, прошлый месяц — август, а листки загружены по июль:
        каждый, кто открывал «Расчётный лист», первым делом видел «листок не
        найден». Выбор месяца при этом предлагал любой месяц за пять лет,
        из которых заполнено два.

        Список месяцев решает обе задачи сразу: приложение открывается на
        самом свежем листке, а в выборе месяца видно, где что-то есть.
        """
        data = _json_body()
        key_suffix = _text(data, 'key_suffix')
        if not key_suffix:
            viewer = getattr(g, 'employee', None)
            key_suffix = viewer.employee_id if viewer is not None else ''
        if not key_suffix or not _may_view(key_suffix):
            return _deny()

        rows = (db.session.query(Payslip.period_year, Payslip.period_month)
                .filter(Payslip.employee_id == key_suffix)
                .distinct().all())
        periods = sorted(({'year': int(y), 'month': int(m)} for y, m in rows),
                         key=lambda p: (p['year'], p['month']), reverse=True)
        return jsonify({'message': 'Success', 'periods': periods})

    def _requested_payslip():
        """Листок из тела запроса — или готовый ответ-отказ вторым значением.

        Общий для /payslip и /payslip/xlsx: файл не должен открываться
        там, где не открывается сам листок.
        """
        data = _json_body()
        key_suffix = _text(data, 'key_suffix')
        if not _may_view(key_suffix):
            return None, _deny()
        # Месяц и год приходят снаружи. int('август') — это ValueError и
        # пятисотый ответ, который приложение показывает как «ошибка сети».
        try:
            month = int(data.get('month', ''))
            year = int(data.get('year', ''))
        except (TypeError, ValueError):
            return None, (jsonify({'message': 'Failure',
                                   'error': 'bad_period'}), 400)

        ps = Payslip.query.filter_by(
            employee_id=key_suffix,
            period_month=month,
            period_year=year
        ).first()
        if not ps:
            return None, jsonify({'message': 'Failure'})
        return ps, None

    @app.route('/payslip', methods=['POST'])
    @require_auth
    def payslip():
        ps, refusal = _requested_payslip()
        if refusal is not None:
            return refusal

        return jsonify({
            'message': 'Success',
            'payslip': {
                'period': ps.period_display,
                'employee': ps.employee.full_name,
                'position': ps.position or '',
                'department': ps.department or '',
                'accruals': [
                    {'name': a.name, 'amount': a.amount,
                     'period': a.period or '', 'working_days': a.working_days,
                     'working_hours': a.working_hours}
                    for a in ps.accruals
                ],
                'deductions': [
                    {'name': d.name, 'amount': d.amount, 'period': d.period or ''}
                    for d in ps.deductions
                ],
                'paid': [
                    {'payment_type': p.payment_type or '', 'period': p.period or '',
                     'document': p.document or '', 'date': p.date or '', 'amount': p.amount}
                    for p in ps.paid
                ],
                'benefits': [{'name': b.name, 'amount': b.amount} for b in ps.benefits],
                'reference': [{'name': r.name, 'amount': r.amount} for r in ps.reference],
                'total_accruals': ps.total_accruals,
                'total_deductions': ps.total_deductions,
                'total_paid': ps.total_paid or 0.0,
                'net_pay': ps.net_pay,
                'debt_start': ps.debt_start or 0.0,
                'debt_end': ps.debt_end or 0.0,
            }
        })

    @app.route('/payslip/xlsx', methods=['POST'])
    @require_auth
    def payslip_xlsx():
        """Тот же листок файлом Excel — для кнопки «Поделиться».

        Тело и права — как у /payslip. Нет листка — тот же ответ
        «Failure», что и там: приложение тогда делится текстом.
        """
        ps, refusal = _requested_payslip()
        if refusal is not None:
            return refusal
        body = build_payslip_xlsx(ps, ps.employee.full_name)
        response = send_file(
            BytesIO(body), mimetype=_XLSX_MIME, as_attachment=True,
            download_name=payslip_file_name(ps))
        # Листок — это зарплата. Ни один промежуточный кэш хранить его не
        # должен.
        response.headers['Cache-Control'] = 'no-store'
        return response

    @app.route('/api/admin/upload-payslip-xml', methods=['POST'])
    def upload_payslip_xml():
        admin_token = os.environ.get('ADMIN_TOKEN', '')
        # Как и у турникета: незаданный секрет — не повод пускать всех.
        # Иначе этот путь заводит сотрудников и грузит расчётные листки
        # вообще без спроса.
        provided = request.headers.get('X-Admin-Token', '')
        # Сравнение за одно и то же время, как у секрета турникета: по
        # обычному `!=` секрет можно подбирать знак за знаком по задержке.
        if not admin_token or not hmac.compare_digest(
                provided.encode(), admin_token.encode()):
            if not admin_token:
                logging.error('ADMIN_TOKEN не задан — загрузка расчётных листков '
                              'отклоняется. Проверьте /etc/se-mobile.env')
            return jsonify({'message': 'Forbidden'}), 403

        if 'file' not in request.files:
            return jsonify({'message': 'Файл не передан', 'error': True}), 400

        file = request.files['file']
        if not file.filename.lower().endswith('.xml'):
            return jsonify({'message': 'Ожидается XML файл', 'error': True}), 400

        try:
            payslips = parse_1c_xml(file.read())
        except ValueError as e:
            return jsonify({'message': str(e), 'error': True}), 422

        imported = []
        latest = {}
        for slip in payslips:
            emp_id = slip['employee_1c_id']

            emp = Employee.query.get(emp_id)
            if emp is None:
                emp = Employee(
                    employee_id=emp_id,
                    full_name=slip['full_name'],
                    job_title=slip['position'] or 'Сотрудник',
                    iin=None,
                )
                db.session.add(emp)
                db.session.flush()
            else:
                if slip['full_name']:
                    emp.full_name = slip['full_name']
                if slip['position']:
                    emp.job_title = slip['position']

            ps = Payslip.query.filter_by(
                employee_id=emp_id,
                period_year=slip['period_year'],
                period_month=slip['period_month'],
            ).first()

            if ps is None:
                ps = Payslip(
                    employee_id=emp_id,
                    period_month=slip['period_month'],
                    period_year=slip['period_year'],
                    period_display=slip['period_display'],
                    total_accruals=slip['total_accruals'],
                    total_deductions=slip['total_deductions'],
                    net_pay=slip['net_pay'],
                    position=slip['position'],
                    department=slip['department'],
                    salary_rate=slip['salary_rate'],
                    debt_start=slip['debt_start'],
                    debt_end=slip['debt_end'],
                    total_paid=slip['total_paid'],
                )
                db.session.add(ps)
                db.session.flush()
            else:
                ps.period_display = slip['period_display']
                ps.total_accruals = slip['total_accruals']
                ps.total_deductions = slip['total_deductions']
                ps.net_pay = slip['net_pay']
                ps.position = slip['position']
                ps.department = slip['department']
                ps.salary_rate = slip['salary_rate']
                ps.debt_start = slip['debt_start']
                ps.debt_end = slip['debt_end']
                ps.total_paid = slip['total_paid']
                PayslipAccrual.query.filter_by(payslip_id=ps.id).delete()
                PayslipDeduction.query.filter_by(payslip_id=ps.id).delete()
                PayslipPaid.query.filter_by(payslip_id=ps.id).delete()
                PayslipBenefit.query.filter_by(payslip_id=ps.id).delete()
                PayslipReference.query.filter_by(payslip_id=ps.id).delete()

            for a in slip['accruals']:
                db.session.add(PayslipAccrual(
                    payslip_id=ps.id, name=a['name'], amount=a['amount'],
                    period=a['period'], working_days=a['working_days'],
                    working_hours=a['working_hours'],
                ))
            for d in slip['deductions']:
                db.session.add(PayslipDeduction(
                    payslip_id=ps.id, name=d['name'], amount=d['amount'],
                    period=d['period'],
                ))
            for p in slip['paid']:
                db.session.add(PayslipPaid(
                    payslip_id=ps.id, payment_type=p['payment_type'],
                    period=p['period'], document=p['document'],
                    date=p['date'], amount=p['amount'],
                ))
            for b in slip['benefits']:
                db.session.add(PayslipBenefit(
                    payslip_id=ps.id, name=b['name'], amount=b['amount'],
                ))
            for r in slip['reference']:
                db.session.add(PayslipReference(
                    payslip_id=ps.id, name=r['name'], amount=r['amount'],
                ))

            imported.append({
                'employee_id': emp_id,
                'full_name': slip['full_name'],
                'period': slip['period_display'],
            })
            # У кого какой период приехал: по одному человеку может прийти
            # сразу несколько месяцев, а сказать надо про самый свежий.
            key = (slip['period_year'], slip['period_month'])
            if key >= latest.get(emp_id, ((0, 0), ''))[0]:
                latest[emp_id] = (key, slip['period_display'])

        db.session.commit()

        # Шлём по одному сообщению на период, а не на человека: зарплату
        # выгружают за месяц сразу на всех, и это одна отправка вместо пятисот.
        by_period = {}
        for emp_id, (_, display) in latest.items():
            by_period.setdefault(display, []).append(emp_id)
        for display, employee_ids in by_period.items():
            # «Июль 2026» в середине фразы читается как заголовок — снижаем.
            period = display[:1].lower() + display[1:] if display else ''
            _notify_later(app, _push_to, employee_ids, 'Зарплата',
                          f'Расчётный лист за {period} готов'.replace('  ', ' '),
                          {'type': 'payslip'})

        return jsonify({
            'message': 'Success',
            'imported': len(imported),
            'employees': imported,
        })

    @app.route('/leaves', methods=['POST'])
    @require_auth
    def leaves():
        data = _json_body()
        key_suffix = _text(data, 'key_suffix')
        if not _may_view(key_suffix):
            return _deny()

        emp = Employee.query.get(key_suffix)
        if not emp:
            return jsonify({'message': 'Failure'})

        balances = LeaveBalance.query.filter_by(employee_id=key_suffix).all()
        history = LeaveHistory.query.filter_by(employee_id=key_suffix)\
            .order_by(LeaveHistory.start_date.desc()).all()

        return jsonify({
            'message': 'Success',
            'leaves': {
                'employee': emp.full_name,
                'balances': [{
                    'type': b.leave_type,
                    'total_days': b.total_days,
                    'used_days': b.used_days,
                    'remaining_days': b.remaining_days
                } for b in balances],
                'history': [{
                    'type': h.leave_type,
                    'start_date': h.start_date.isoformat(),
                    'end_date': h.end_date.isoformat(),
                    'days': h.days,
                    'status': h.status
                } for h in history]
            }
        })


    # ── FCM token registration ────────────────────────────────────────────────

    @app.route('/api/fcm-token', methods=['POST'])
    @require_auth
    def register_fcm_token():
        data = _json_body()
        employee_id = _text(data, 'employee_id')
        token = _text(data, 'token')
        if not employee_id or not token:
            return jsonify({'message': 'Failure', 'error': 'employee_id and token required'}), 400
        # Подписаться можно только на свои уведомления: иначе чужой телефон
        # начнёт получать проходы сотрудников вместе с их именами.
        if not _may_view(employee_id):
            return _deny()
        emp = Employee.query.get(employee_id)
        if not emp:
            return jsonify({'message': 'Failure', 'error': 'Employee not found'}), 404
        existing = FcmToken.query.filter_by(token=token).first()
        if existing:
            existing.employee_id = employee_id
        else:
            db.session.add(FcmToken(employee_id=employee_id, token=token))
        db.session.commit()
        return jsonify({'message': 'Success'})

    @app.route('/api/fcm-token', methods=['DELETE'])
    @require_auth
    def unregister_fcm_token():
        data = _json_body()
        token = _text(data, 'token')
        if not token:
            return jsonify({'message': 'Failure', 'error': 'token required'}), 400
        # Снять можно только свою подписку. Иначе любой, кто узнал чужой
        # токен, отключил бы человеку уведомления. Без пропуска (старая сборка,
        # проверки ещё не включены) — как раньше, по одному токену.
        rows = FcmToken.query.filter_by(token=token)
        viewer = getattr(g, 'employee', None)
        if viewer is not None:
            rows = rows.filter_by(employee_id=viewer.employee_id)
        rows.delete()
        db.session.commit()
        return jsonify({'message': 'Success'})

    # ── СКУД turnstile webhook ────────────────────────────────────────────────

    @app.route('/api/turnstile', methods=['POST'])
    def turnstile_event():
        data = _json_body()
        secret = _text(data, 'secret')
        expected = os.environ.get('TURNSTILE_SECRET', '')
        # Отказ в безопасную сторону: пустой секрет раньше отключал проверку
        # целиком, и кто угодно мог слать поддельные проходы. Теперь пустой
        # TURNSTILE_SECRET значит «настроить забыли», а не «пускать всех».
        # compare_digest — чтобы по времени ответа нельзя было подбирать
        # секрет по букве.
        if not expected or not hmac.compare_digest(secret.encode(),
                                                   expected.encode()):
            if not expected:
                logging.error('TURNSTILE_SECRET не задан — события турникета '
                              'отклоняются. Проверьте /etc/se-mobile.env')
            return jsonify({'message': 'Failure', 'error': 'Unauthorized'}), 403

        employee_id = _text(data, 'employee_id')
        direction = _text(data, 'direction')  # 'in' | 'out'
        ts_raw = _text(data, 'timestamp')

        if not employee_id or direction not in ('in', 'out'):
            return jsonify({'message': 'Failure', 'error': 'employee_id and direction required'}), 400

        emp = Employee.query.get(employee_id)
        if not emp:
            return jsonify({'message': 'Failure', 'error': 'Employee not found'}), 404

        # Своего времени СКУД может и не прислать. Тогда берём местное, а не
        # utcnow: в этой же таблице лежат проходы из выгрузки, записанные
        # местным временем, и приход в 08:00 оказался бы рядом с приходом в
        # 03:00 — по одному и тому же турникету.
        if ts_raw:
            try:
                ts = datetime.fromisoformat(ts_raw)
                # Прислали со смещением — приводим к местному и снимаем пояс.
                if ts.tzinfo is not None:
                    ts = ts.astimezone(_PLANT_TZ).replace(tzinfo=None)
            except ValueError:
                ts = _plant_now()
        else:
            ts = _plant_now()

        # Повтор того же прохода — не новый проход. СКУД, не дождавшись
        # ответа (оборвалась связь, сервер ответил медленно), шлёт событие ещё
        # раз; раньше оно ложилось второй строкой, и человеку приходило второе
        # «вход в 08:01». Узнаём повтор по времени самого турникета: у
        # событий без него время наше, и совпасть оно не может.
        if ts_raw:
            same = TurnstileEvent.query.filter_by(
                employee_id=employee_id, direction=direction,
                timestamp=ts).first()
            if same is not None:
                return jsonify({'message': 'Success', 'id': same.id,
                                'duplicate': True})

        event = TurnstileEvent(employee_id=employee_id, direction=direction, timestamp=ts)
        db.session.add(event)
        db.session.commit()

        ts_str = ts.strftime('%H:%M')
        # В стороне: в пересменку это пятьсот проходов за несколько минут, и
        # каждый ждал бы ответа Google, прежде чем СКУД получит своё «Success».
        _notify_later(app, _send_turnstile_notification,
                      emp.full_name, direction, ts_str, employee_id)

        return jsonify({'message': 'Success', 'id': event.id})

    # ── Attendance statistics ─────────────────────────────────────────────────

    @app.route('/api/attendance', methods=['GET'])
    @require_auth
    def attendance():
        if not _is_manager():
            return _deny()
        date_str = request.args.get('date', _plant_today().isoformat())
        try:
            query_date = date.fromisoformat(date_str)
        except ValueError:
            return jsonify({'message': 'Failure', 'error': 'Invalid date'}), 400

        # Сравнение диапазоном, а не db.func.date(timestamp) == день:
        # колонка, обёрнутая в функцию, индексом не пользуется.
        day_start = datetime.combine(query_date, datetime.min.time())
        day_end = datetime.combine(query_date + _ONE_DAY, datetime.min.time())
        events = TurnstileEvent.query.filter(
            TurnstileEvent.timestamp >= day_start,
            TurnstileEvent.timestamp < day_end,
        ).order_by(TurnstileEvent.timestamp).all()

        allowed = _visible_employee_ids()
        if allowed is not None:
            events = [e for e in events if e.employee_id in allowed]

        names = _employee_names()
        result = [{
            'id': e.id,
            'employee_id': e.employee_id,
            'full_name': names.get(e.employee_id, e.employee_id),
            'direction': e.direction,
            'timestamp': e.timestamp.isoformat(),
        } for e in events]
        return jsonify({'message': 'Success', 'date': date_str, 'events': result})

    @app.route('/api/attendance/summary', methods=['GET'])
    @require_auth
    def attendance_summary():
        if not _is_manager():
            return _deny()
        month_str = request.args.get('month', _plant_now().strftime('%Y-%m'))
        try:
            year, month = (int(x) for x in month_str.split('-'))
            # Границы месяца считаем сразу: они же и проверяют, что месяц
            # существует — «2026-13» падает здесь, а не при запросе к базе.
            month_start = datetime(year, month, 1)
            month_end = (datetime(year + 1, 1, 1) if month == 12
                         else datetime(year, month + 1, 1))
        except (ValueError, AttributeError):
            return jsonify({'message': 'Failure', 'error': 'Invalid month, use YYYY-MM'}), 400

        # Диапазон вместо db.extract(...): извлечение года и месяца из колонки
        # не даёт воспользоваться индексом по времени.
        events = TurnstileEvent.query.filter(
            TurnstileEvent.timestamp >= month_start,
            TurnstileEvent.timestamp < month_end,
        ).order_by(TurnstileEvent.timestamp).all()

        allowed = _visible_employee_ids()
        if allowed is not None:
            events = [e for e in events if e.employee_id in allowed]

        names = _employee_names()
        by_day: dict = {}
        for e in events:
            day_key = e.timestamp.date().isoformat()
            name = names.get(e.employee_id, e.employee_id)
            entry = by_day.setdefault(day_key, {'date': day_key, 'arrivals': 0, 'departures': 0, 'employees': {}})
            if e.direction == 'in':
                entry['arrivals'] += 1
            else:
                entry['departures'] += 1
            entry['employees'].setdefault(e.employee_id, {'full_name': name, 'in': None, 'out': None})
            if e.direction == 'in' and entry['employees'][e.employee_id]['in'] is None:
                entry['employees'][e.employee_id]['in'] = e.timestamp.strftime('%H:%M')
            if e.direction == 'out':
                entry['employees'][e.employee_id]['out'] = e.timestamp.strftime('%H:%M')

        days_list = []
        for day_key in sorted(by_day):
            d = by_day[day_key]
            d['employees'] = list(d['employees'].values())
            days_list.append(d)

        return jsonify({'message': 'Success', 'month': month_str, 'days': days_list})

    # ── Canteen menu ──────────────────────────────────────────────────────────

    @app.route('/api/home', methods=['POST'])
    @require_auth
    def home_summary():
        """Сводка для главного экрана — одним запросом.

        Главный экран был плиткой из тех же пяти разделов, что и нижняя
        панель: чтобы узнать, во сколько тебя отметил турникет или вышел ли
        листок, надо было зайти в раздел и подождать. Здесь — по строке на
        раздел. Один запрос, а не четыре: главный экран открывают все пятьсот
        человек, и каждый раз.

        Сумм здесь нет: главный экран показывают через плечо, а зарплата — не
        то, что должен увидеть сосед. Только месяц, за который листок есть.
        """
        data = _json_body()
        key_suffix = _text(data, 'key_suffix')
        if not key_suffix:
            viewer = getattr(g, 'employee', None)
            key_suffix = viewer.employee_id if viewer is not None else ''
        if not key_suffix or not _may_view(key_suffix):
            return _deny()
        today = _plant_today()
        return jsonify({
            'message': 'Success',
            'today': today.isoformat(),
            'access': _home_access(key_suffix, today),
            'payslip': _home_payslip(key_suffix),
            'leave': _home_leave(key_suffix),
            'menu': _home_menu(today),
        })

    @app.route('/api/menu', methods=['GET'])
    @require_auth
    def get_menu():
        date_str = request.args.get('date', _plant_today().isoformat())
        try:
            query_date = date.fromisoformat(date_str)
        except ValueError:
            return jsonify({'message': 'Failure', 'error': 'Invalid date'}), 400

        menu = MenuDate.query.filter_by(date=query_date).first()
        if not menu:
            return jsonify({'message': 'Success', 'date': date_str, 'items': []})

        items = [{'id': i.id, 'category': i.category, 'name': i.name,
                  'price': float(i.price) if i.price is not None else None,
                  'portion': i.portion}
                 for i in menu.items]
        return jsonify({'message': 'Success', 'date': date_str, 'items': items})

    @app.route('/api/menu', methods=['POST'])
    @require_auth
    def save_menu():
        if not _may_edit_menu():
            return _deny()
        data = _json_body()
        date_str = _text(data, 'date')
        try:
            menu_date = date.fromisoformat(date_str)
        except (ValueError, TypeError):
            return jsonify({'message': 'Failure', 'error': 'Invalid or missing date'}), 400
        # Блюда разбираем до того, как стереть старые: раньше кривая цена
        # роняла запрос уже после удаления, и день оставался без меню.
        items = _menu_items(data.get('items', []))
        if items is None:
            return jsonify({'message': 'Failure', 'error': 'bad_items'}), 400

        menu = MenuDate.query.filter_by(date=menu_date).first()
        # Правка уже выложенного дня — не повод для уведомления: технолог
        # поправит цену одного блюда, а разбудит всё предприятие.
        was_new = menu is None
        if menu:
            MenuItem.query.filter_by(menu_date_id=menu.id).delete()
        else:
            menu = MenuDate(date=menu_date)
            db.session.add(menu)
            db.session.flush()

        for item in items:
            db.session.add(MenuItem(menu_date_id=menu.id, **item))

        db.session.commit()
        if was_new:
            _notify_later(app, _notify_menu_published)
        return jsonify({'message': 'Success'})

    @app.route('/api/menu/import-excel', methods=['POST'])
    def import_menu_excel():
        """Loads a canteen menu straight from the spreadsheet 1C exports.

        Takes multipart form-data: the file plus the technologist's login and
        password. Writing the menu must stay closed, and she already has those
        credentials — no separate secret to hand out.
        """
        login = (request.form.get('login') or '').strip()
        password = (request.form.get('password') or '').strip()
        employee_id = _authenticate(login, password)
        if not employee_id:
            return _credentials_refused(login)

        uploader = Employee.query.get(employee_id)
        job = (uploader.job_title if uploader else '').lower()
        allowed = ('технолог' in job and 'столов' in job) or 'администратор системы' in job
        if not allowed:
            return jsonify({
                'message': 'Загружать меню может технолог столовой',
                'error': True,
            }), 403

        if 'file' not in request.files:
            return jsonify({'message': 'Файл не передан', 'error': True}), 400
        upload = request.files['file']
        if not upload.filename.lower().endswith(('.xlsx', '.xlsm', '.xls')):
            return jsonify({'message': 'Ожидается файл Excel', 'error': True}), 400

        # Dishes listed before any date in the sheet fall back to this day.
        fallback = None
        if request.form.get('date'):
            try:
                fallback = date.fromisoformat(request.form['date'])
            except ValueError:
                return jsonify({'message': 'Неверная дата', 'error': True}), 400

        # Загрузка «на сегодня»: что бы ни стояло в файле, меню ложится на
        # этот день. 1С проставляет дату по своему расписанию, а в столовой
        # нужно одно — чтобы в приложении было видно сегодняшнее меню.
        forced = None
        if request.form.get('force_date'):
            try:
                forced = date.fromisoformat(request.form['force_date'])
            except ValueError:
                return jsonify({'message': 'Неверная дата', 'error': True}), 400
            # Файл может быть и вовсе без дат — тогда блюда без этой подсказки
            # разбор просто пропустит.
            if fallback is None:
                fallback = forced

        try:
            days = parse_menu_excel(upload.read(), fallback_date=fallback)
        except ValueError as e:
            return jsonify({'message': str(e), 'error': True}), 422

        if forced is not None:
            if len(days) > 1:
                dates = ', '.join(d['date'].strftime('%d.%m.%Y') for d in days)
                return jsonify({
                    'message': ('В файле несколько дней (' + dates + ') — какой '
                                'из них сегодняшний, программе не решить. '
                                'Загрузите такой файл обычной кнопкой '
                                '«Загрузить меню»: даты возьмутся из файла.'),
                    'error': True,
                }), 422
            days[0]['date'] = forced

        summary = []
        for day in days:
            menu = MenuDate.query.filter_by(date=day['date']).first()
            if menu:
                MenuItem.query.filter_by(menu_date_id=menu.id).delete()
            else:
                menu = MenuDate(date=day['date'])
                db.session.add(menu)
                db.session.flush()

            sections = {}
            for item in day['items']:
                db.session.add(MenuItem(
                    menu_date_id=menu.id,
                    category=item['category'],
                    name=item['name'],
                    price=item['price'],
                    portion=item.get('portion'),
                ))
                sections[item['category']] = sections.get(item['category'], 0) + 1

            summary.append({
                'date': day['date'].isoformat(),
                'date_display': day['date'].strftime('%d.%m.%Y'),
                'count': len(day['items']),
                'sections': sections,
            })

        db.session.commit()
        _notify_later(app, _notify_menu_published)

        lines = [
            f"{d['date_display']} — {d['count']} блюд "
            f"({', '.join(f'{k} {v}' for k, v in d['sections'].items())})"
            for d in summary
        ]
        logging.info('Menu import by %s: %s', login, '; '.join(lines))
        return jsonify({
            'message': 'Загружено:\n' + '\n'.join(lines),
            'days': summary,
        })

    @app.route('/api/news', methods=['GET'])
    @require_auth
    def get_news():
        """Лента для сотрудников: новости сайта и одобренные объявления."""
        # За новыми ходим в стороне: двенадцать секунд чужого молчания не
        # должны быть его двенадцатью секундами.
        _refresh_news_later(app)
        # Сколько новостей отдать. Не число — берём обычные пятьдесят: это
        # лента, а не запрос, который стоит отклонять из-за опечатки.
        try:
            limit = min(max(int(request.args.get('limit') or 50), 1), 200)
        except (TypeError, ValueError):
            limit = 50
        rows = (NewsItem.query
                .filter_by(is_published=True)
                .order_by(NewsItem.published_at.desc())
                .limit(limit).all())
        return jsonify({'message': 'Success',
                        'items': [_news_json(r) for r in rows]})

    @app.route('/api/admin/news', methods=['GET'])
    @require_auth
    def admin_news_list():
        """Всё, включая неодобренное: очередь объявлений."""
        if not _is_admin_account():
            return _deny()
        rows = NewsItem.query.order_by(
            NewsItem.is_published.asc(), NewsItem.published_at.desc()).limit(200).all()
        pending = sum(1 for r in rows if not r.is_published)
        return jsonify({'message': 'Success', 'pending': pending,
                        'items': [_news_json(r) for r in rows]})

    @app.route('/api/admin/rollout', methods=['GET'])
    @require_auth
    def rollout_readiness():
        """Готовность к включению обязательной проверки пропуска.

        Один вопрос, один ответ: дошла ли новая сборка до всех. Пока в
        `without_pass` за сегодня и вчера не появятся нули, включать
        REQUIRE_AUTH=1 нельзя — у кого-то приложение перестанет работать.
        """
        if not _is_admin_account():
            return _deny()

        accounts = UserAccount.query.filter_by(is_active=True).all()
        by_version = {}
        for account in accounts:
            by_version[account.app_version or 'неизвестно'] = \
                by_version.get(account.app_version or 'неизвестно', 0) + 1

        # Кто не заходил дольше недели: их сборку мы не знаем и знать не
        # можем, пока они не откроют приложение.
        week_ago = datetime.utcnow() - timedelta(days=7)
        asleep = [a.login for a in accounts
                  if a.last_seen_at is None or a.last_seen_at < week_ago]

        misses = (AuthMiss.query.order_by(AuthMiss.day.desc()).limit(14).all())
        return jsonify({
            'message': 'Success',
            'require_auth': _AUTH_REQUIRED,
            'accounts': len(accounts),
            'by_version': by_version,
            'not_seen_for_a_week': len(asleep),
            'not_seen_logins': sorted(asleep)[:50],
            'backups': _backup_state(),
            'without_pass': [{'day': m.day.isoformat(), 'count': m.count}
                             for m in misses],
            # Пока не ноль — где-то пропала строка в user_accounts: вход под
            # таким логином теперь не проходит вовсе.
            'in_code_passwords': [{'day': m.day.isoformat(),
                                   'count': m.fallback_logins or 0}
                                  for m in misses],
            # Сколько учётных записей всё ещё с выданным паролем — табельным
            # номером. Пока не ноль, столько людей можно открыть, зная одно
            # лишь число с пропуска.
            'temporary_passwords': sum(
                1 for a in accounts if a.must_change_password),
            # По какое число заполнен каждый источник. Пока этого не было
            # видно, об отставших данных узнавали от сотрудников.
            'data': _data_freshness(),
            # Какая сборка лежит на сервере для скачивания. Пока её нет,
            # «сколько людей на старой версии» не на что и смотреть: обновиться
            # им неоткуда.
            'app': _latest_apk(),
            # Что сторож записал о перебоях. Пусто — сервер не падал.
            'outages': _outage_state(),
        })

    @app.route('/api/admin/news/refresh', methods=['GET', 'POST'])
    @require_auth
    def admin_news_refresh():
        """Сходить за новостями прямо сейчас и рассказать, чем кончилось.

        Из приложения не видно, почему лента пуста: сайт недоступен, ленты у
        него нет, разбор не удался — снаружи всё выглядит одинаково. Здесь
        видно.
        """
        if not _is_admin_account():
            return _deny()
        if request.method == 'POST':
            _refresh_site_news(force=True)
        total = NewsItem.query.filter_by(source='site').count()
        return jsonify({'message': 'Success', 'status': dict(_news_status),
                        'site_items': total})

    @app.route('/api/admin/news', methods=['POST'])
    @require_auth
    def admin_news_create():
        """Объявление, набранное администратором прямо в приложении."""
        if not _is_admin_account():
            return _deny()
        data = _json_body()
        title = _text(data, 'title')
        summary = _text(data, 'summary')
        if not title:
            return jsonify({'message': 'Failure', 'error': 'title_required'}), 400

        viewer = getattr(g, 'employee', None)
        item = NewsItem(
            source='announcement',
            title=title[:500],
            summary=summary,
            author=(_text(data, 'author') or (viewer.full_name if viewer else ''))[:255] or None,
            published_at=datetime.utcnow(),
            # Набрал администратор — значит уже одобрено, второй раз не спрашиваем.
            is_published=True,
        )
        db.session.add(item)
        db.session.commit()
        return jsonify({'message': 'Success', 'item': _news_json(item)})

    @app.route('/api/admin/news/<int:item_id>', methods=['POST', 'DELETE'])
    @require_auth
    def admin_news_change(item_id):
        """Одобрить объявление из очереди или убрать его из ленты."""
        if not _is_admin_account():
            return _deny()
        item = db.session.get(NewsItem, item_id)
        if item is None:
            return jsonify({'message': 'Failure', 'error': 'not_found'}), 404

        if request.method == 'DELETE':
            db.session.delete(item)
            db.session.commit()
            return jsonify({'message': 'Success'})

        data = _json_body()
        # Запоминаем до правки: уведомление шлём только на переходе
        # «в очереди» → «в ленте», иначе правка опечатки разбудит всех заново.
        was_published = item.is_published
        if 'is_published' in data:
            item.is_published = bool(data['is_published'])
        if _text(data, 'title'):
            item.title = _text(data, 'title')[:500]
        if 'summary' in data:
            item.summary = _text(data, 'summary')
        db.session.commit()

        if item.is_published and not was_published:
            _notify_later(app, _push_to_everyone, 'Объявление', item.title,
                          {'type': 'news', 'id': item.id})
        return jsonify({'message': 'Success', 'item': _news_json(item)})

    @app.route('/api/news/announcements', methods=['POST'])
    def push_announcement():
        """Приём объявления извне — от программы, читающей почту.

        Почтовый сервер стоит внутри сети предприятия, а этот сервер снаружи,
        и достучаться до почты он не может. Поэтому направление обратное:
        программа на конторском компьютере читает ящик и присылает письма
        сюда. Логин и пароль в теле запроса — как у загрузки меню.

        Присланное **не публикуется**: ждёт одобрения в админ-панели.
        """
        data = _json_body()
        employee_id = _authenticate(_text(data, 'login'),
                                    _text(data, 'password'))
        if not employee_id:
            return _credentials_refused(_text(data, 'login'))
        uploader = Employee.query.get(employee_id)
        if not _is_system_admin(uploader.job_title if uploader else ''):
            return jsonify({'message': 'Присылать объявления может администратор',
                            'error': True}), 403

        title = _text(data, 'title')
        if not title:
            return jsonify({'message': 'Пустая тема письма', 'error': True}), 400

        # Письмо узнаём по Message-ID: рассылку читают повторно, и одно и то
        # же письмо не должно попасть в очередь дважды.
        external = _text(data, 'message_id')[:500] or None
        if external and NewsItem.query.filter_by(external_id=external).first():
            return jsonify({'message': 'Уже принято', 'duplicate': True})

        published = None
        if _text(data, 'sent_at'):
            try:
                published = datetime.fromisoformat(
                    _text(data, 'sent_at').replace('Z', '+00:00'))
                if published.tzinfo is not None:
                    published = published.astimezone(timezone.utc).replace(tzinfo=None)
            except ValueError:
                published = None

        item = NewsItem(
            source='announcement',
            external_id=external,
            title=title[:500],
            summary=_text(data, 'summary'),
            author=_text(data, 'author')[:255] or None,
            published_at=published or datetime.utcnow(),
            is_published=False,
        )
        db.session.add(item)
        db.session.commit()
        logging.info('Объявление принято в очередь: %r', title[:80])
        return jsonify({'message': 'Принято, ждёт одобрения', 'id': item.id})

    @app.route('/api/directory', methods=['GET'])
    @require_auth
    def get_directory():
        """Телефонный справочник предприятия — всем сотрудникам.

        Отдаётся целиком: 129 строк, меньше сотни килобайт. Поиск и разбивку
        по отделам делает приложение, зато справочник открывается мгновенно и
        работает, когда связь пропала.
        """
        rows = DirectoryEntry.query.order_by(DirectoryEntry.sort_order).all()
        # Все строки приезжают одной загрузкой, поэтому дата у них общая —
        # приложение показывает её как «справочник от такого-то числа».
        updated = max((r.updated_at for r in rows if r.updated_at), default=None)
        return jsonify({
            'message': 'Success',
            'entries': [{
                'department': row.department or '',
                'name': row.name,
                'position': row.position or '',
                'extension': row.extension or '',
                'email': row.email or '',
                'mobile': row.mobile or '',
            } for row in rows],
            'updated_at': updated.isoformat() if updated else None,
        })

    @app.route('/api/directory/import-excel', methods=['POST'])
    def import_directory_excel():
        """Загружает справочник из Excel. Логин и пароль — в теле запроса.

        Как и у меню: отдельного секрета не заводим, у администратора уже
        есть учётная запись. Отправляет программка с рабочего стола.
        """
        login = (request.form.get('login') or '').strip()
        password = (request.form.get('password') or '').strip()
        employee_id = _authenticate(login, password)
        if not employee_id:
            return _credentials_refused(login)

        uploader = Employee.query.get(employee_id)
        if not _is_system_admin(uploader.job_title if uploader else ''):
            return jsonify({
                'message': 'Загружать справочник может администратор',
                'error': True,
            }), 403

        if 'file' not in request.files:
            return jsonify({'message': 'Файл не передан', 'error': True}), 400
        upload = request.files['file']
        if not (upload.filename or '').lower().endswith(('.xlsx', '.xlsm', '.xls')):
            return jsonify({'message': 'Ожидается файл Excel', 'error': True}), 400

        try:
            entries = parse_directory_excel(upload.read())
        except ValueError as e:
            return jsonify({'message': str(e), 'error': True}), 422

        # Заменяем целиком: справочник — снимок на дату, а не журнал. Иначе
        # уволенные остались бы в нём навсегда.
        try:
            DirectoryEntry.query.delete()
            now = datetime.utcnow()
            for order, entry in enumerate(entries):
                db.session.add(DirectoryEntry(
                    sort_order=order,
                    department=entry['department'],
                    name=entry['name'],
                    position=entry['position'] or None,
                    extension=entry['extension'] or None,
                    email=entry['email'] or None,
                    mobile=entry['mobile'] or None,
                    updated_at=now,
                ))
            db.session.commit()
        except Exception as e:
            # Прежде отсюда уходил голый 500 в виде страницы HTML, и в окне
            # программы на другом конце было нечего прочесть.
            db.session.rollback()
            logging.error('Directory import failed: %s', e, exc_info=True)
            # Только суть: у ошибки SQLAlchemy в str() лежит весь запрос
            # вместе со всеми строками справочника — читать невозможно, да и
            # незачем отправлять телефоны всего предприятия обратно в ответе.
            cause = str(getattr(e, 'orig', e)).strip().splitlines()
            detail = cause[0][:200] if cause else e.__class__.__name__
            return jsonify({
                'message': f'Сервер не смог сохранить справочник: {detail}',
                'error': True,
            }), 500

        departments = []
        for entry in entries:
            if entry['department'] and entry['department'] not in departments:
                departments.append(entry['department'])
        logging.info('Directory import by %s: %d entries', login, len(entries))
        return jsonify({
            'message': (f'Загружено: {len(entries)} записей, '
                        f'{len(departments)} подразделений'),
            'count': len(entries),
            'departments': len(departments),
        })

    @app.route('/api/menu/<date_str>', methods=['DELETE'])
    @require_auth
    def delete_menu(date_str):
        if not _may_edit_menu():
            return _deny()
        try:
            menu_date = date.fromisoformat(date_str)
        except ValueError:
            return jsonify({'message': 'Failure', 'error': 'Invalid date'}), 400
        menu = MenuDate.query.filter_by(date=menu_date).first()
        if menu:
            db.session.delete(menu)
            db.session.commit()
        return jsonify({'message': 'Success'})


def _find_reportable(name):
    """Сотрудник для «Отчёта сотрудников» по ФИО из списка выбора.

    Раньше брался первый попавшийся, в ком ФИО встречается хоть кусочком,
    — по всему предприятию. Если первым оказывался однофамилец из чужого
    отдела, начальник получал «нет доступа», хотя нужный человек был у него
    в отделе; человек, заведённый дважды, мог открыться по пустой записи.

    Теперь: сначала точное совпадение, потом вхождение — и только среди
    тех, кого смотрящему видно. Из нескольких точных — тот, у кого есть
    проходы, и из них с самым свежим.
    """
    name = (name or '').strip()
    if not name:
        return None
    allowed = _visible_employee_ids()

    def pick(query):
        if allowed is not None:
            query = query.filter(Employee.employee_id.in_(allowed))
        found = query.all()
        if len(found) <= 1:
            return found[0] if found else None
        last = dict(db.session.query(AccessRecord.employee_id,
                                     db.func.max(AccessRecord.access_date))
                    .filter(AccessRecord.employee_id.in_(
                        [e.employee_id for e in found]))
                    .group_by(AccessRecord.employee_id).all())
        return max(found, key=lambda e: (last.get(e.employee_id) is not None,
                                         last.get(e.employee_id) or date.min))

    exact = pick(Employee.query.filter(Employee.full_name == name))
    if exact is not None:
        return exact
    partial = pick(Employee.query.filter(Employee.full_name.contains(name)))
    if partial is not None:
        return partial
    # Есть, но не виден — пусть /director_report ответит «нет доступа», а не
    # «не найден»: это разные ответы.
    return Employee.query.filter(Employee.full_name.contains(name)).first()


def _home_access(employee_id, today):
    """Последний день с проходами: когда пришёл и когда ушёл.

    Сегодняшний день берётся из событий турникета — они приходят сразу.
    Выгрузку СКУД приносят раз в месяц, поэтому, если сегодня событий нет,
    показываем последний загруженный день, с его датой: «06.10, вход 07:52»
    честнее пустоты.
    """
    try:
        start = datetime(today.year, today.month, today.day)
        events = (TurnstileEvent.query
                  .filter(TurnstileEvent.employee_id == employee_id,
                          TurnstileEvent.timestamp >= start,
                          TurnstileEvent.timestamp < start + _ONE_DAY)
                  .order_by(TurnstileEvent.timestamp).all())
        if events:
            ins = [e.timestamp for e in events if e.direction == 'in']
            outs = [e.timestamp for e in events if e.direction == 'out']
            return {'date': today.isoformat(),
                    'first_in': min(ins).strftime('%H:%M') if ins else None,
                    'last_out': max(outs).strftime('%H:%M') if outs else None}

        last = (db.session.query(db.func.max(AccessRecord.access_date))
                .filter(AccessRecord.employee_id == employee_id).scalar())
        if last is None:
            return None
        rows = AccessRecord.query.filter_by(employee_id=employee_id,
                                            access_date=last).all()
        # «Проход» — точка без направления; приходом её считаем, уходом нет.
        ins = [r.access_time for r in rows if r.event_type in ('Вход', 'Проход')]
        outs = [r.access_time for r in rows if r.event_type == 'Выход']
        return {'date': last.isoformat(),
                'first_in': min(ins) if ins else None,
                'last_out': max(outs) if outs else None}
    except Exception as e:
        db.session.rollback()
        logging.warning('Сводка: проходы %s не прочитались: %s', employee_id, e)
        return None


def _home_payslip(employee_id):
    row = (db.session.query(Payslip.period_year, Payslip.period_month)
           .filter(Payslip.employee_id == employee_id)
           .order_by(Payslip.period_year.desc(), Payslip.period_month.desc())
           .first())
    return {'year': int(row[0]), 'month': int(row[1])} if row else None


def _home_leave(employee_id):
    """Сколько дней отпуска осталось — всех видов вместе.

    Видов обычно два: ежегодный и экологический. На главном экране важно
    одно число — сколько ещё можно отдыхать; по видам — в разделе «Отпуск».
    """
    balances = LeaveBalance.query.filter_by(employee_id=employee_id).all()
    if not balances:
        return None
    return {'remaining_days': sum(max(b.remaining_days or 0, 0)
                                  for b in balances)}


def _home_menu(today):
    menu = MenuDate.query.filter_by(date=today).first()
    items = sorted(menu.items, key=lambda i: i.id) if menu else []
    return {'count': len(items), 'dishes': [i.name for i in items[:3]]}


def _access_to_dict(record):
    return {
        'date': record.access_date.isoformat(),
        'time': record.access_time,
        'event': record.event_type,
        'door': record.door_location
    }


# Самая поздняя дата, по которую вообще загружены проходы. Считается редко:
# таблица самая большая в базе, а пополняется она выгрузками из СКУД, то есть
# раз в месяц, а не ежеминутно.
_ACCESS_COVERAGE_TTL = timedelta(minutes=10)
_access_loaded_until = {'checked_at': None, 'date': None}


def _loaded_until():
    """До какого числа в базе есть проходы — по всему предприятию."""
    now = datetime.utcnow()
    checked = _access_loaded_until['checked_at']
    if checked is not None and now - checked < _ACCESS_COVERAGE_TTL:
        return _access_loaded_until['date']
    try:
        latest = db.session.query(db.func.max(AccessRecord.access_date)).scalar()
    except Exception as e:
        db.session.rollback()
        logging.warning('Не смог узнать, по какое число загружены проходы: %s', e)
        return _access_loaded_until['date']
    _access_loaded_until['checked_at'] = now
    _access_loaded_until['date'] = latest
    return latest


@db.event.listens_for(AccessRecord, 'after_insert')
def _forget_loaded_until(mapper, connection, target):
    """Новая запись о проходе — старый ответ про «загружено по» неверен.

    Вешаем на саму модель, а не на тринадцать мест, где проходы добавляются:
    список таких мест пришлось бы помнить, а он бы отстал. Дороже всего это
    обходится при загрузке выгрузки — три тысячи строк, три тысячи раз
    присвоить None, — и всё равно не стоит ничего.

    Без этого администратор, загрузив сентябрьскую выгрузку, ещё десять минут
    видел бы «проходы загружены по 20 августа» и решил бы, что загрузка не
    прошла.

    На удаление не вешаем: последняя дата от него сдвигается, только если
    удалить саму последнюю выгрузку, а на это никто не ходит. Да и срок
    жизни ответа всё равно десять минут — через них пересчитается само.
    """
    _access_loaded_until['checked_at'] = None


def _access_coverage(employee_id):
    """Чем объяснить пустой список проходов.

    Пустота бывает трёх разных видов, и раньше все три выглядели одинаково —
    экран говорил «нет данных» и предлагал выбрать период:

    * человека нет в выгрузке СКУД вовсе. Из 130 человек справочника проходы
      заведены у 110: остальным выбирать период бессмысленно, там не
      появится ничего;
    * период позже последней выгрузки. Это главный случай: выгрузку приносят
      раз в месяц, и 22 сентября проходы в базе были по 20 августа — то есть
      «Сегодня», «Последние 7 дней» и «Этот месяц» пусты у всех подряд, и
      выглядит это как поломка;
    * в эти дни человек действительно не проходил.

    Отсюда приложение и узнаёт, какой именно случай перед ним.
    """
    until = _loaded_until()
    try:
        mine = (db.session.query(db.func.max(AccessRecord.access_date))
                .filter(AccessRecord.employee_id == employee_id).scalar())
    except Exception as e:
        db.session.rollback()
        logging.warning('Не смог узнать проходы сотрудника %s: %s', employee_id, e)
        mine = None
    return {
        'loaded_until': until.isoformat() if until else None,
        'employee_until': mine.isoformat() if mine else None,
        'employee_has_any': mine is not None,
    }


def _auto_seed():
    """Три сотрудника и их отпуска — для пустой базы.

    Проходы и расчётные листки, которые здесь тоже заводились, вынесены в
    выгрузку legacy_seed.json (см. _seed_legacy_from_data): в исходниках
    зарплатам и проходам не место.
    """
    if Employee.query.first():
        return

    e1 = Employee(employee_id='001', full_name='Сарсекенов Батырхан Арманұлы', job_title='Техник-программист', iin='000000002114')
    e2 = Employee(employee_id='002', full_name='Касымов Нурлан Серикович', job_title='Руководитель отдела', iin='850515400456',
                  department='Администрация')
    e3 = Employee(employee_id='003', full_name='Сидорова Анна Сергеевна', job_title='Бухгалтер', iin='920720450789',
                  department='Бухгалтерия')
    db.session.add_all([e1, e2, e3])

    for eid, lt, total, used, rem in [
        ('001', 'Ежегодный трудовой отпуск', 24, 10, 14),
        ('001', 'Экологический отпуск', 10, 0, 10),
        ('002', 'Ежегодный трудовой отпуск', 30, 24, 6),
        ('002', 'Экологический отпуск', 10, 5, 5),
        ('003', 'Ежегодный трудовой отпуск', 24, 0, 24),
        ('003', 'Экологический отпуск', 10, 0, 10),
    ]:
        db.session.add(LeaveBalance(
            employee_id=eid, leave_type=lt,
            total_days=total, used_days=used, remaining_days=rem
        ))

    for eid, lt, sd, ed, days, status in [
        ('001', 'Ежегодный трудовой отпуск', '2024-01-15', '2024-01-24', 10, 'Утверждён'),
        ('001', 'Больничный лист', '2023-11-05', '2023-11-12', 7, 'Закрыт'),
        ('001', 'Больничный лист', '2023-06-20', '2023-06-23', 3, 'Закрыт'),
        ('002', 'Ежегодный трудовой отпуск', '2024-02-01', '2024-02-14', 14, 'Утверждён'),
        ('002', 'Ежегодный трудовой отпуск', '2023-07-10', '2023-07-19', 10, 'Утверждён'),
        ('002', 'Экологический отпуск', '2023-09-01', '2023-09-05', 5, 'Утверждён'),
        ('003', 'Больничный лист', '2024-01-08', '2024-01-12', 5, 'Закрыт'),
    ]:
        sy, sm, sday = sd.split('-')
        ey, em, eday = ed.split('-')
        db.session.add(LeaveHistory(
            employee_id=eid, leave_type=lt,
            start_date=date(int(sy), int(sm), int(sday)),
            end_date=date(int(ey), int(em), int(eday)),
            days=days, status=status
        ))

    db.session.commit()


def _seed_leave_2026():
    """Остатки и история отпусков/больничных за 2026 год (КЗ)."""
    if LeaveHistory.query.filter(
        LeaveHistory.start_date >= date(2026, 1, 1)
    ).first():
        return

    # Обновляем остатки отпусков на 2026 год
    # Ежегодный отпуск КЗ: 24 к.д. (рядовые), 30 к.д. (руководители)
    # Экологический отпуск (г. Семей — зона повышенного радиационного риска): 14 к.д.
    balance_updates = [
        # (emp_id, тип, всего, использовано, осталось)
        ('001', 'Ежегодный трудовой отпуск',  24,  5, 19),
        ('001', 'Экологический отпуск',        14,  0, 14),
        ('002', 'Ежегодный трудовой отпуск',  30, 14, 16),
        ('002', 'Экологический отпуск',        14,  0, 14),
        ('003', 'Ежегодный трудовой отпуск',  24,  0, 24),
        ('003', 'Экологический отпуск',        14,  0, 14),
    ]
    for eid, lt, total, used, rem in balance_updates:
        bal = LeaveBalance.query.filter_by(employee_id=eid, leave_type=lt).first()
        if bal:
            bal.total_days = total
            bal.used_days = used
            bal.remaining_days = rem
        else:
            db.session.add(LeaveBalance(
                employee_id=eid, leave_type=lt,
                total_days=total, used_days=used, remaining_days=rem))

    # История отпусков/больничных 2026
    history = [
        # Иванов: ежегодный отпуск 5-9 янв (5 к.д.; 7 янв — праздник, не включается)
        ('001', 'Ежегодный трудовой отпуск', '2026-01-05', '2026-01-09',  5, 'Утверждён'),
        # Иванов: больничный 16-20 фев
        ('001', 'Больничный лист',           '2026-02-16', '2026-02-20',  5, 'Закрыт'),
        # Петров: ежегодный отпуск 9-22 фев (14 к.д.)
        ('002', 'Ежегодный трудовой отпуск', '2026-02-09', '2026-02-22', 14, 'Утверждён'),
        # Сидорова: больничный 16-20 фев
        ('003', 'Больничный лист',           '2026-02-16', '2026-02-20',  5, 'Закрыт'),
    ]
    for eid, lt, sd, ed, days, status in history:
        sy, sm, sday = sd.split('-')
        ey, em, eday = ed.split('-')
        db.session.add(LeaveHistory(
            employee_id=eid, leave_type=lt,
            start_date=date(int(sy), int(sm), int(sday)),
            end_date=date(int(ey), int(em), int(eday)),
            days=days, status=status))

    db.session.commit()


def _seed_kumarova():
    """Сотрудник 1874 (Кумарова).

    Её листок за сентябрь 2025 и проходы того же месяца — в выгрузке
    legacy_seed.json (см. _seed_legacy_from_data).
    """
    if not Employee.query.filter_by(employee_id='1874').first():
        db.session.add(Employee(
            employee_id='1874',
            full_name='Кумарова Мадина Кумаровна',
            job_title='Специалист по кадрам',
        ))
        db.session.flush()

    db.session.commit()


# ── docx payslip data (employees + Jan–Apr 2026 payslips with line items) ──
# employee_id, full_name, job_title[, department]. Отдел — только у тех, кого
# нет в справочнике: раньше его брали с листка, а листков в коде больше нет.
_DOCX_EMPLOYEES = [
    ('0000000044', 'Ибраева Эльмира Кудайбергеновна', 'Технолог'),
    ('0000000644', 'Жиешев Кайрат Казахстанович', 'Заведующий складом'),
    ('0000000674', 'Жолдыбалинова Альмира Аманбековна', 'Заведующий складом'),
    ('0000000726', 'Саманова Жулдыз Аргымбаевна', 'Бухгалтер'),
    ('0000000910', 'Кузбаев Канат Мукаметканович', 'Начальник отдела'),
    ('0000001093', 'Павленко Александр Александрович', 'Контрольный мастер'),
    ('0000001236', 'Бахтинова Малика Жумабековна', 'Заместитель главного бухгалтера'),
    ('0000001295', 'Ахметова Алия Тураровна', 'Главный менеджер'),
    ('0000001296', 'Арзуева Ирина Александровна', 'Главный менеджер'),
    ('0000001445', 'Елеубекова Айжан Сайдыгалиевна', 'Менеджер'),
    ('0000001579', 'Калиева Алмагуль Копышевна', 'Кладовщик'),
    ('0000001668', 'Николаев Даниил Олегович', 'Заместитель начальника'),
    ('0000001681', 'Чирков Максим Сергеевич', 'Контрольный мастер'),
    ('0000001864', 'Кутанова Асель Даниярбековна', 'Менеджер'),
    ('0000001874', 'Кумарова Мадина Кумаровна', 'Специалист по кадрам'),
    ('0000001965', 'Жамбазар Ерсұлтан Мырзабекұлы', 'инженер-программист'),
    ('0000001978', 'Габдулин Роллан Жумагазыевич', 'Мастер СУ'),
    ('0000002005', 'Ияшева Эльмира Тимуровна', 'Бухгалтер'),
    ('0000002063', 'Тусупжанова Айым Темирболаткызы', 'Офис менеджер'),
    ('0000002148', 'Диппель Ольга Владимировна', 'Повар', 'Столовая'),
    ('0000002162', 'Науканов Мерхат Кайсарович', 'Менеджер'),
]


def _seed_docx_employees_2026():
    """Сотрудники из docx-листков январь-апрель 2026.

    Сами листки — в выгрузке legacy_seed.json (см. _seed_legacy_from_data).
    """
    for eid, name, job, *department in _DOCX_EMPLOYEES:
        if not Employee.query.filter_by(employee_id=eid).first():
            db.session.add(Employee(employee_id=eid, full_name=name, job_title=job,
                                    department=department[0] if department else None))
    db.session.commit()


# ── Официальный справочник АО "Семей инжиниринг" (07.07.2026) ──
# (employee_id, ФИО, должность, подразделение). Записи с id вида D### —
# сотрудники из справочника, у которых нет учётной записи в приложении.
_ORG_DIRECTORY = [
    ('D001', 'Асқаров Қайрат Мейрамұлы', 'Генеральный директор', 'Руководство'),
    ('D002', 'Мусипов Арман Серикбекулы', 'Заместитель Генерального директора по производству', 'Руководство'),
    ('D003', 'Шаяхметов Данияр Бексултанович', 'Заместитель Генерального директора по экономике и финансам', 'Руководство'),
    ('0000002063', 'Тусупжанова Айым Темирболаткызы', 'Офис-менеджер', 'Приемная'),
    ('D004', 'Иманбеков Ринат Мейрамбекович', 'Руководитель службы внутреннего аудита', 'Служба внутреннего аудита'),
    ('0000000083', 'Бейсекина Айман Муратовна', 'Корпоративный секретарь', 'Корпоративный отдел'),
    ('D006', 'Матаев Ахмет Хафизович', 'Комплаенс-офицер', 'Комплаенс-офицер'),
    ('D007', 'Утепов Нурлан Кутайбаевич', 'Главный менеджер по ЗГС', 'Защита Государственных секретов (ЗГС)'),
    ('D008', 'Нургали Эльвира Андреевна', 'Специалист по мобилизационной работе', 'Защита Государственных секретов (ЗГС)'),
    ('D009', 'Омаргалиева Меруетгүль Кабылкаковна', 'Начальник юридического отдела', 'Юридический отдел'),
    ('D010', 'Нургазинов Кайрат Быкиянович', 'Заместитель начальника юридического отдела', 'Юридический отдел'),
    ('D011', 'Бостандыков Алихан Ерсинович', 'Юрист', 'Юридический отдел'),
    ('0000002162', 'Науканов Мерхат Кайсарович', 'Начальник административного отдела', 'Административный отдел (АО)'),
    ('0000001296', 'Арзуева Ирина Александровна', 'Главный менеджер', 'Административный отдел (АО)'),
    ('0000001874', 'Кумарова Мадина Кумаровна', 'Специалист по кадрам', 'Административный отдел (АО)'),
    ('D012', 'Каупбаева Меруерт Муратбековна', 'Делопроизводитель', 'Административный отдел (АО)'),
    ('0000001465', 'Даурембекова Умут Ергазыевна', 'Начальник ОИТиС', 'Отдел информационных технологий и связи (ОИТиС)'),
    ('0000001668', 'Николаев Даниил Олегович', 'Заместитель начальника ОИТиС', 'Отдел информационных технологий и связи (ОИТиС)'),
    ('0000001965', 'Жамбазар Ерсұлтан Мырзабекұлы', 'Инженер-программист', 'Отдел информационных технологий и связи (ОИТиС)'),
    ('001', 'Сарсекенов Батырхан Арманулы', 'Техник-программист', 'Отдел информационных технологий и связи (ОИТиС)'),
    ('D014', 'Доскалиев Марат Бимухамбетович', 'Начальник ОП', 'Основное производство (ОП)'),
    ('D015', 'Бектемиров Ринат Рафаилович', 'Заместитель начальника ОП', 'Основное производство (ОП)'),
    ('D016', 'Атаканова Жанаргуль Тулегеновна', 'Менеджер ОП', 'Основное производство (ОП)'),
    ('D017', 'Литвинова Снежана Армановна', 'Менеджер по учету ТМЦ', 'Основное производство (ОП)'),
    ('D018', 'Аманбаева Юлия Федоровна', 'Оператор по учету ТМЦ', 'Основное производство (ОП)'),
    ('D019', 'Сакенова Тогжан Мейрамхановна', 'Оператор по учету ТМЦ', 'Основное производство (ОП)'),
    ('D020', 'Богданова Индира Аскаровна', 'Оператор по учету ТМЦ', 'Основное производство (ОП)'),
    ('D021', 'Кинолбаев Махмуд Нажатович', 'Специалист-инструментальщик', 'Основное производство (ОП)'),
    ('D022', 'Арынов Айдар Азимович', 'Мастер', 'Основное производство (ОП)'),
    ('D023', 'Нұрғали Дастан Нурғалиұлы', 'Мастер', 'Основное производство (ОП)'),
    ('D024', 'Кучерявый Дмитрий Сергеевич', 'Мастер', 'Основное производство (ОП)'),
    ('D025', 'Скаков Токтар Турарович', 'Мастер', 'Основное производство (ОП)'),
    ('D026', 'Саудагеров Максут Кайратович', 'Мастер', 'Основное производство (ОП)'),
    ('D027', 'Дюсембинов Думан Уразгалиевич', 'Мастер', 'Основное производство (ОП)'),
    ('D028', 'Кажаев Талгат Кабдрашитович', 'Мастер', 'Основное производство (ОП)'),
    ('D029', 'Койшыбаев Куат Ергалиевич', 'Мастер', 'Основное производство (ОП)'),
    ('D030', 'Отаров Нурлан Даниярулы', 'Начальник ТО', 'Технический отдел (ТО)'),
    ('D031', 'Мендыбаев Наиль Раильевич', 'Заместитель начальника ТО', 'Технический отдел (ТО)'),
    ('D032', 'Табаев Асет Елеусизович', 'Инженер-технолог', 'Технический отдел (ТО)'),
    ('D033', 'Бопабаев Нияз Еркешевич', 'Инженер-технолог', 'Технический отдел (ТО)'),
    ('D034', 'Козырев Владислав Константинович', 'Инженер-технолог', 'Технический отдел (ТО)'),
    ('D035', 'Одатханов Серіжан Қабылұлы', 'Инженер-технолог', 'Технический отдел (ТО)'),
    ('D036', 'Омарбеков Айдын Берікқазыұлы', 'Инженер-конструктор', 'Технический отдел (ТО)'),
    ('D037', 'Манежанов Болат Аскербекович', 'Инженер-конструктор', 'Технический отдел (ТО)'),
    ('D038', 'Қазисов Дастан Серікұлы', 'Инженер-конструктор', 'Технический отдел (ТО)'),
    ('D039', 'Ділдәбеков Еркебұлан Дуанұлы', 'Инженер-конструктор', 'Технический отдел (ТО)'),
    ('D040', 'Шакенова Айжан Алшынгазыновна', 'Инженер по комплектации нормативно-технической документации', 'Технический отдел (ТО)'),
    ('D041', 'Рахымханова Альфия Багдатовна', 'Проектный менеджер', 'Технический отдел (ТО)'),
    ('D042', 'Омаров Еркебұлан Әубәкірұлы', 'Руководитель ДМТО', 'Департамент материально-технического обеспечения (ДМТО)'),
    ('D043', 'Бейсенбаев Айдос Сагатбекулы', 'Заместитель руководителя ДМТО', 'Департамент материально-технического обеспечения (ДМТО)'),
    ('D044', 'Ильяшев Данияр Муратович', 'Главный менеджер', 'Департамент материально-технического обеспечения (ДМТО)'),
    ('D045', 'Сулейменов Диас Агыбайулы', 'Главный менеджер', 'Департамент материально-технического обеспечения (ДМТО)'),
    ('D046', 'Мусин Арман Манарович', 'Главный менеджер', 'Департамент материально-технического обеспечения (ДМТО)'),
    ('D047', 'Тілеуғали Еркінғали Тілеуғалиұлы', 'Менеджер', 'Департамент материально-технического обеспечения (ДМТО)'),
    ('D048', 'Орынбасаров Танат Тунгатулы', 'Менеджер', 'Департамент материально-технического обеспечения (ДМТО)'),
    ('D049', 'Жабекова Лаура Сергеевна', 'Менеджер', 'Департамент материально-технического обеспечения (ДМТО)'),
    ('D050', 'Рахимов Мухаметнур Николаевич', 'Менеджер', 'Департамент материально-технического обеспечения (ДМТО)'),
    ('D051', 'Тусупжанов Алихан Темирболатович', 'Менеджер', 'Департамент материально-технического обеспечения (ДМТО)'),
    ('D052', 'Мухаметжанов Куат Азатович', 'Менеджер', 'Департамент материально-технического обеспечения (ДМТО)'),
    ('D053', 'Ашимова Арай Иляловна', 'Менеджер', 'Департамент материально-технического обеспечения (ДМТО)'),
    ('D054', 'Сафонова Руслана Витальевна', 'Менеджер', 'Департамент материально-технического обеспечения (ДМТО)'),
    ('D055', 'Мамадилов Серикбол Жумагазыевич', 'Начальник ОХВиТ', 'Отдел хранения вооружения и техники (ОХВиТ)'),
    ('D056', 'Беркімбай Дулат Ғазезұлы', 'Специалист', 'Отдел хранения вооружения и техники (ОХВиТ)'),
    ('D057', 'Жакаев Самат Кабдылахметович', 'Специалист', 'Отдел хранения вооружения и техники (ОХВиТ)'),
    ('D058', 'Торыбаев Сейт Нариманович', 'Зав. Складом №1', 'Служба учета ТМЦ'),
    ('0000000674', 'Жолдыбалинова Альмира Аманбековна', 'Зав. Складом №2', 'Служба учета ТМЦ'),
    ('0000000644', 'Жиешев Кайрат Казахстанович', 'Зав. Складом №3', 'Служба учета ТМЦ'),
    ('0000001579', 'Калиева Алмагуль Копышевна', 'Кладовщик склада №2', 'Служба учета ТМЦ'),
    ('D059', 'Абдрахманов Нурлан Жанатович', 'Кладовщик склада №1', 'Служба учета ТМЦ'),
    ('D060', 'Болатов Ерсин Бостандыкович', 'Главный бухгалтер', 'Отдел бухгалтерского и налогового учета (ОБиНУ)'),
    ('0000001236', 'Бахтинова Малика Жумабековна', 'Заместитель главного бухгалтера', 'Отдел бухгалтерского и налогового учета (ОБиНУ)'),
    ('D061', 'Бейсембаева Динара Манарбековна', 'Бухгалтер расчетной группы', 'Отдел бухгалтерского и налогового учета (ОБиНУ)'),
    ('D062', 'Оспанова Динара Бауржановна', 'Бухгалтер', 'Отдел бухгалтерского и налогового учета (ОБиНУ)'),
    ('0000002005', 'Ияшева Эльмира Тимуровна', 'Бухгалтер', 'Отдел бухгалтерского и налогового учета (ОБиНУ)'),
    ('0000000726', 'Саманова Жулдыз Аргымбаевна', 'Бухгалтер', 'Отдел бухгалтерского и налогового учета (ОБиНУ)'),
    ('D063', 'Мухаметжанова Малика Нурлановна', 'Бухгалтер', 'Отдел бухгалтерского и налогового учета (ОБиНУ)'),
    ('D064', 'Баймолдинова Айгуль Мухаметкаримовна', 'Начальник ПЭО', 'Планово-экономический отдел (ПЭО)'),
    ('0000001295', 'Ахметова Алия Тураровна', 'Главный менеджер', 'Планово-экономический отдел (ПЭО)'),
    ('D065', 'Мухаметкалиева Еркежан Узбековна', 'Менеджер', 'Планово-экономический отдел (ПЭО)'),
    ('0000001864', 'Кутанова Асель Даниярбековна', 'Менеджер', 'Планово-экономический отдел (ПЭО)'),
    ('0000001445', 'Елеубекова Айжан Сайдыгалиевна', 'Менеджер', 'Планово-экономический отдел (ПЭО)'),
    ('0000000910', 'Кузбаев Канат Мукаметканович', 'Начальник ОТК', 'Отдел технического контроля (ОТК)'),
    ('D066', 'Слямбеков Ермек Женисбекович', 'Контрольный мастер', 'Отдел технического контроля (ОТК)'),
    ('D067', 'Джумин Еркин Махамбетович', 'Контрольный мастер', 'Отдел технического контроля (ОТК)'),
    ('D068', 'Нургожинов Нурмухамед Муратбекович', 'Контрольный мастер', 'Отдел технического контроля (ОТК)'),
    ('0000001681', 'Чирков Максим Сергеевич', 'Контрольный мастер', 'Отдел технического контроля (ОТК)'),
    ('D069', 'Рахимова Диляра Толешевна', 'Контрольный мастер', 'Отдел технического контроля (ОТК)'),
    ('0000001093', 'Павленко Александр Александрович', 'Контрольный мастер', 'Отдел технического контроля (ОТК)'),
    ('D070', 'Есенжолов Мухамедкали Болаткалиевич', 'Начальник СБ', 'Служба безопасности (СБ)'),
    ('D071', 'Азбергенов Нурбек Мухтарович', 'Специалист службы безопасности', 'Служба безопасности (СБ)'),
    ('D072', 'Махмутов Рустам Маратович', 'Главный технический руководитель по БиОТ', 'Служба безопасности и охраны труда (БиОТ)'),
    ('D073', 'Атаканова Гульнар Айтказыевна', 'Инженер по БиОТ', 'Служба безопасности и охраны труда (БиОТ)'),
    ('D074', 'Семенюк Сергей Игоревич', 'Инженер по обслуживанию слаботочных систем', 'Служба безопасности и охраны труда (БиОТ)'),
    ('D075', 'Жанболатова Кулчан Сейтжагипаровна', 'Заведующая медицинским пунктом', 'Медицинский пункт'),
    ('D076', 'Амренова Фатима Токтаровна', 'Медицинский работник', 'Медицинский пункт'),
    ('D077', 'Коркембаева Сауле Мухсиыновна', 'Медицинский работник', 'Медицинский пункт'),
    ('D078', 'Байбеков Арман Айтпаевич', 'Главный инженер', 'Служба главного инженера'),
    ('D079', 'Касымханов Ернар Маратбекович', 'Главный энергетик', 'Служба главного инженера'),
    ('D080', 'Абилгазин Асхат Турсынгалиевич', 'Старший мастер', 'Служба главного инженера'),
    ('D081', 'Дуйсенбаев Диас Советбекович', 'Мастер', 'Служба главного инженера'),
    ('0000001978', 'Габдулин Роллан Жумагазыевич', 'Мастер СУ', 'Строительный участок (СУ)'),
    ('D082', 'Падерин Вячеслав Николаевич', 'Столяр-станочник', 'Строительный участок (СУ)'),
    ('D083', 'Амренов Бауыржан Турарханович', 'Заведующий ХО', 'Хозяйственный отдел (ХО)'),
    ('D084', 'Накишев Алмас Айткалиевич', 'Механик', 'Хозяйственный отдел (ХО)'),
    ('D085', 'Алексеева Полина Ивановна', 'Специалист', 'Хозяйственный отдел (ХО)'),
    ('D086', 'Сабиев Жандос Какимсеитович', 'Подсобный рабочий', 'Хозяйственный отдел (ХО)'),
    ('D087', 'Сейткамалова Бакытгуль Айдарбековна', 'Машинист по стирке и ремонту спец.одежды', 'Хозяйственный отдел (ХО)'),
    ('D088', 'Кочаков Сергей Петрович', 'Водитель', 'Гараж'),
    ('D089', 'Гузаиров Тахир Габдулхакович', 'Водитель', 'Гараж'),
    ('D090', 'Нурыбеков Тимур Жумагельдиевич', 'Водитель', 'Гараж'),
    ('D091', 'Абдульменов Ернат Михайлович', 'Водитель', 'Гараж'),
    ('D092', 'Утельбаев Нурлан Хайрулаевич', 'Водитель', 'Гараж'),
    ('D093', 'Утробин Игорь Иванович', 'Водитель', 'Гараж'),
    ('D094', 'Майканов Вячеслав Николаевич', 'Водитель', 'Гараж'),
    ('D095', 'Майканов Николай Николаевич', 'Водитель', 'Гараж'),
    ('D096', 'Кагарманов Шамиль Батыршинович', 'Водитель', 'Гараж'),
    ('D097', 'Ожайтов Нурлан Сайланович', 'Водитель', 'Гараж'),
    ('D098', 'Туктибаев Сабит Акилбаевич', 'Водитель', 'Гараж'),
    ('0000000044', 'Ибраева Эльмира Кудайбергеновна', 'Технолог столовой', 'Столовая'),
    ('D099', 'Зайнулина Елена Владимировна', 'Старший повар', 'Столовая'),
    ('D100', 'Юнашев Павел Павлович', 'Начальник военного представительства № 16', 'Военное представительство №16 МО РК'),
    ('D101', 'Аймуханбетов Чингиз Муратович', 'Старший инженер', 'Военное представительство №16 МО РК'),
    ('D102', 'Хилькевич Александр Сергеевич', 'Старший инженер', 'Военное представительство №16 МО РК'),
    ('D103', 'Жанжуменов Талгат Женисович', 'Директор представительства АО"Семей инжиниринг"', 'Представительство в г. Астана'),
    ('D104', 'Жаукенов Валерий Тулебаевич', 'Главный менеджер', 'Представительство в г. Астана'),
    ('D105', 'Ашимов Серікбол', 'Менеджер', 'Представительство в г. Астана'),
]


def _norm_name(name):
    """Fold Kazakh-specific letters so directory and DB spellings compare equal
    (e.g. "Арманұлы" vs "Арманулы")."""
    folded = name.lower().translate(str.maketrans('ұүөәіңғқһ', 'ууоаингкх'))
    return ' '.join(re.sub(r'[^а-яё ]', ' ', folded).split())


def _seed_org_directory():
    """Sync job titles and departments with the official company directory.

    Updates existing employees in place and adds directory staff who have no
    account yet, so a manager's employee report lists their real team.
    Idempotent — re-running only rewrites the same values.
    """
    for emp_id, full_name, position, department in _ORG_DIRECTORY:
        emp = Employee.query.get(emp_id)
        if emp:
            emp.job_title = position
            emp.department = department
        else:
            db.session.add(Employee(
                employee_id=emp_id, full_name=full_name,
                job_title=position, department=department))
    db.session.flush()

    _departments_from_payslips()
    db.session.commit()


def _departments_from_payslips():
    """Отдел для тех, кого нет в справочнике, — с их расчётного листка.

    Названия приводятся к справочнику: на листке нет сокращения в скобках
    («Отдел технического контроля» против «Отдел технического контроля
    (ОТК)»). Зовётся и после загрузки листков из выгрузки: на пустой базе
    справочник проходит раньше, чем листки появляются.
    """
    dept_names = {d for _, _, _, d in _ORG_DIRECTORY}
    for emp in Employee.query.filter(Employee.department.is_(None)).all():
        slip = Payslip.query.filter(
            Payslip.employee_id == emp.employee_id,
            Payslip.department.isnot(None),
        ).order_by(Payslip.period_year.desc(), Payslip.period_month.desc()).first()
        if not slip or not slip.department:
            continue
        emp.department = next(
            (d for d in dept_names if d == slip.department or d.startswith(slip.department + ' (')),
            slip.department,
        )


# Employees who have left the company. Their seed data is gone from the tables
# above, but the live database still holds rows from earlier deployments.
_DEPARTED_EMPLOYEES = ['0000000820']  # Фадеев Юрий Борисович


def _remove_departed_employees():
    """Purge employees who no longer work here, along with everything of theirs.

    Deleting the Payslip rows through the ORM lets the configured cascades take
    out the accrual/deduction/paid children. Idempotent: a second run finds
    nothing to remove.
    """
    for emp_id in _DEPARTED_EMPLOYEES:
        emp = Employee.query.get(emp_id)
        payslips = Payslip.query.filter_by(employee_id=emp_id).all()
        if not emp and not payslips:
            continue

        for slip in payslips:
            db.session.delete(slip)

        for model in (AccessRecord, LeaveBalance, LeaveHistory,
                      FcmToken, TurnstileEvent, UserAccount):
            model.query.filter_by(employee_id=emp_id).delete()

        if emp:
            db.session.delete(emp)
        logging.info(f'Removed departed employee {emp_id}')

    db.session.commit()


_ADMIN_EMPLOYEE_ID = 'ADMIN'
_ADMIN_DISPLAY_NAME = 'Админ'


# ── Откуда сидеры берут выгрузки ─────────────────────────────────────────
#
# Из папки на сервере, а не из репозитория. Раньше файлы лежали рядом с
# кодом, и это были не «данные для примера»: зарплата 124 человек по
# статьям, их табельные номера, должности и время каждого прохода через
# турникет. Всё это разъезжалось с каждой копией репозитория, с каждой
# сборкой и оставалось в истории git навсегда.
#
# Держать такое в исходниках незачем: сидеры своё отработали, данные живут в
# базе и в зашифрованных копиях, а поднимать сервер с нуля правильнее из
# копии, а не повторной загрузкой.
#
# Что здесь ищется, если папка всё-таки заполнена:
#
#   employees_2026_07.csv — табельный номер, временный id, ФИО, должность,
#       подразделение. Номера взяты из июльских расчётных листков: в самом
#       справочнике их нет.
#   access_2026_08.csv — проходы с 1 по 20 августа. Направление проставлено
#       только для дверей на улицу; считыватели у кабинетов стоят внутри, и
#       «выход» по дороге к своему столу — не выход.
#   payslips_ГОД_МЕСЯЦ.json — книга расчётных листков за месяц.
#
# Пусто или папки нет — сидеры молча ничего не делают. Так и должно быть:
# на боевом сервере они давно отработали и второй раз не запускаются.
_SEED_DATA_DIR = os.environ.get('SEED_DATA_DIR', '/var/lib/se-mobile/seed-data')

# Запасной путь — папка рядом с кодом. Пустая в репозитории; нужна тому, у
# кого выгрузки лежат под рукой при разработке.
_REPO_SEED_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data')


def _seed_dirs():
    """Где искать выгрузки — по очереди, папка сервера первой."""
    return [_SEED_DATA_DIR, _REPO_SEED_DIR]


def _seed_path(name):
    """Путь к выгрузке или None.

    Ищем по файлам, а не по папке целиком: у того, кто положил на сервер одни
    расчётные листки, список сотрудников остаётся там, где лежал, — иначе
    одна новая папка молча отменяла бы всё остальное.
    """
    for directory in _seed_dirs():
        path = os.path.join(directory, name)
        if os.path.exists(path):
            return path
    return None


def _seed_files(pattern):
    """Все выгрузки, подходящие под образец, без повторов по имени."""
    import fnmatch
    found = {}
    for directory in _seed_dirs():
        try:
            names = os.listdir(directory)
        except OSError:
            continue
        for name in sorted(names):
            if fnmatch.fnmatch(name, pattern) and name not in found:
                found[name] = os.path.join(directory, name)
    return [found[name] for name in sorted(found)]


def _read_data_csv(name):
    import csv
    path = _seed_path(name)
    if path is None:
        logging.warning('Выгрузки %s нет ни в %s — пропускаю',
                        name, ', ни в '.join(_seed_dirs()))
        return []
    with open(path, newline='', encoding='utf-8') as f:
        return list(csv.DictReader(f, delimiter=';'))


def _seed_directory_staff_2026():
    """Заводит сотрудников и учётные записи по справочнику.

    Логин и пароль — табельный номер, смена пароля при первом входе
    обязательна. Тому, у кого учётная запись уже есть (под любым логином),
    вторую не заводим: человек входит так, как привык.
    """
    rows = _read_data_csv('employees_2026_07.csv')
    if not rows:
        return

    accounts = {a.employee_id for a in UserAccount.query.all()}
    created_emp = created_acc = merged = 0

    for row in rows:
        tab, old_id = row['tab'].strip(), row['old_id'].strip()
        emp = db.session.get(Employee, tab)
        if emp is None:
            db.session.add(Employee(
                employee_id=tab,
                full_name=row['fio'].strip(),
                job_title=row['job'].strip()[:100],
                department=row['dept'].strip()[:200],
            ))
            created_emp += 1
        else:
            # Справочник главнее: должности в нём свежее, чем в базе.
            emp.job_title = row['job'].strip()[:100]
            emp.department = row['dept'].strip()[:200]
    db.session.commit()

    # Прежняя запись и настоящая — это один человек. Переносим на настоящую
    # всё, что успело накопиться на прежней, и удаляем её.
    #
    # Условие именно «номер другой», а не «номер начинается с D»: у техника
    # ОИТиС прежний номер был «001», под ним лежали его листки и проходы, и
    # по признаку D он бы не склеился — в базе оказались бы два Сарсекеновых
    # и две учётные записи, одна из них пустая.
    for row in rows:
        tab, old_id = row['tab'].strip(), row['old_id'].strip()
        if old_id and old_id != tab and _absorb_employee(old_id, tab) is not None:
            merged += 1

    accounts = {a.employee_id for a in UserAccount.query.all()}
    for row in rows:
        tab = row['tab'].strip()
        if tab in accounts or db.session.get(UserAccount, tab) is not None:
            continue
        db.session.add(UserAccount(
            login=tab,
            employee_id=tab,
            password_hash=generate_password_hash(tab),
            must_change_password=True,
        ))
        accounts.add(tab)
        created_acc += 1
    db.session.commit()
    logging.info('Справочник: сотрудников заведено %d, склеено %d, '
                 'учётных записей заведено %d',
                 created_emp, merged, created_acc)


def _seed_access_august_2026():
    """Грузит проходы за август из файла отчёта турникета.

    Две таблицы на один проход: access_records — то, что показывает «Отчёт
    сотрудников» (время, событие, дверь), turnstile_events — то, из чего
    считается табель (вход/выход). Повторный запуск ничего не задваивает:
    уже загруженные строки узнаём по сотруднику, дате, времени и двери.
    """
    rows = _read_data_csv('access_2026_08.csv')
    if not rows:
        return

    known = {e.employee_id for e in Employee.query.all()}
    start, end = date(2026, 8, 1), date(2026, 8, 31)

    existing = {(r.employee_id, r.access_date, r.access_time, r.door_location)
                for r in AccessRecord.query.filter(
                    AccessRecord.access_date >= start,
                    AccessRecord.access_date <= end).all()}
    existing_events = {(e.employee_id, e.timestamp)
                       for e in TurnstileEvent.query.filter(
                           TurnstileEvent.timestamp >= datetime(2026, 8, 1),
                           TurnstileEvent.timestamp < datetime(2026, 9, 1)).all()}

    added_rec = added_ev = skipped = 0
    for row in rows:
        tab = row['tab'].strip()
        if tab not in known:
            skipped += 1
            continue
        day = date.fromisoformat(row['date'])
        at = row['time'].strip()
        door = row['door'].strip()[:100]

        direction = row['direction'].strip()
        # В отчёте человек читает слово, а не код: «Вход» и «Выход» — как в
        # прежних записях. У внутренних дверей направления нет, и выдумывать
        # его нечестно: там просто «Проход».
        event = {'in': 'Вход', 'out': 'Выход'}.get(direction, 'Проход')

        if (tab, day, at, door) not in existing:
            db.session.add(AccessRecord(
                employee_id=tab, access_date=day, access_time=at,
                event_type=event, door_location=door))
            existing.add((tab, day, at, door))
            added_rec += 1

        if direction:
            hour, minute = (int(x) for x in at.split(':'))
            stamp = datetime(day.year, day.month, day.day, hour, minute)
            if (tab, stamp) not in existing_events:
                db.session.add(TurnstileEvent(
                    employee_id=tab, direction=direction, timestamp=stamp))
                existing_events.add((tab, stamp))
                added_ev += 1

    db.session.commit()
    logging.info('Август: проходов добавлено %d, событий турникета %d, '
                 'пропущено (нет такого сотрудника) %d',
                 added_rec, added_ev, skipped)


# Расчётные листки лежат по месяцам: payslips_ГОД_МЕСЯЦ.json в папке выгрузок
# (см. _SEED_DATA_DIR). Чтобы добавить новый месяц, достаточно положить туда
# такой же файл — и поднять версию сидера в _SEED_VERSIONS, иначе на боевой
# базе он второй раз не запустится: журнал посчитает, что своё уже отработал.
_PAYSLIP_FILE = re.compile(r'^payslips_(\d{4})_(\d{2})\.json$')

_MONTHS_RU = ['Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль',
              'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь']


# Листки и проходы, которые раньше заводились прямо из кода: демо-набор
# 2024-2026 годов, книга docx-листков, листки и проходы Кумаровой,
# Даурембековой, Бейсекиной. В исходниках им не место — это зарплата и время
# прихода живых людей, — поэтому они вынесены в legacy_seed.json в папке
# выгрузок. На боевой базе всё это давно лежит; файл нужен только тому, кто
# поднимает базу с нуля и хочет те же данные.
_LEGACY_SEED_FILE = 'legacy_seed.json'
_LEGACY_PAYSLIP_PARTS = {
    'accruals': PayslipAccrual,
    'deductions': PayslipDeduction,
    'paid': PayslipPaid,
    'benefits': PayslipBenefit,
    'reference': PayslipReference,
}


def _legacy_row(model, data):
    """Поля модели из словаря выгрузки; даты — из ISO-строк."""
    values = {}
    for column in model.__table__.columns:
        if column.primary_key or column.name not in data:
            continue
        value = data[column.name]
        if isinstance(value, str):
            if isinstance(column.type, db.DateTime):
                value = datetime.fromisoformat(value)
            elif isinstance(column.type, db.Date):
                value = date.fromisoformat(value)
        values[column.name] = value
    return model(**values)


def _seed_legacy_from_data():
    """Грузит legacy_seed.json, если он есть.

    Повторный запуск ничего не задваивает: листок узнаётся по сотруднику и
    месяцу, проход — по всем полям. Записи тех, кого в базе нет, пропускаются.
    """
    import json
    path = _seed_path(_LEGACY_SEED_FILE)
    if path is None:
        return
    with open(path, encoding='utf-8') as f:
        data = json.load(f)

    known = {e.employee_id for e in Employee.query.all()}
    have = {(p.employee_id, p.period_year, p.period_month)
            for p in Payslip.query.all()}
    slips = 0
    for slip in data.get('payslips', []):
        key = (slip['employee_id'], slip['period_year'], slip['period_month'])
        if slip['employee_id'] not in known or key in have:
            continue
        payslip = _legacy_row(Payslip, slip)
        db.session.add(payslip)
        db.session.flush()          # нужен id для строк листка
        for part, model in _LEGACY_PAYSLIP_PARTS.items():
            for row in slip.get(part, []):
                db.session.add(_legacy_row(model, dict(row, payslip_id=payslip.id)))
        have.add(key)
        slips += 1

    passes = {(r.employee_id, r.access_date, r.access_time, r.event_type,
               r.door_location) for r in AccessRecord.query.all()}
    added_passes = 0
    for row in data.get('access_records', []):
        record = _legacy_row(AccessRecord, row)
        key = (record.employee_id, record.access_date, record.access_time,
               record.event_type, record.door_location)
        if record.employee_id not in known or key in passes:
            continue
        db.session.add(record)
        passes.add(key)
        added_passes += 1

    events = {(e.employee_id, e.direction, e.timestamp)
              for e in TurnstileEvent.query.all()}
    added_events = 0
    for row in data.get('turnstile_events', []):
        event = _legacy_row(TurnstileEvent, row)
        key = (event.employee_id, event.direction, event.timestamp)
        if event.employee_id not in known or key in events:
            continue
        db.session.add(event)
        events.add(key)
        added_events += 1

    _departments_from_payslips()
    db.session.commit()
    logging.info('%s: листков %d, проходов %d, событий турникета %d',
                 _LEGACY_SEED_FILE, slips, added_passes, added_events)


def _seed_payslips_from_data():
    """Грузит все книги расчётных листков, какие найдутся."""
    for path in _seed_files('payslips_*.json'):
        found = _PAYSLIP_FILE.match(os.path.basename(path))
        if found:
            _load_payslip_book(path, int(found.group(1)), int(found.group(2)))


def _load_payslip_book(path, year, month):
    """Кладёт в базу книгу листков за один месяц.

    В книге всё предприятие — 374 листка; кладём те, чей табельный номер
    есть в базе. Остальные не пропадают: появится сотрудник — следующий
    запуск подберёт и его листок.

    Повторный запуск ничего не задваивает: на (сотрудник, год, месяц) в базе
    стоит требование неповторимости, и уже загруженные пропускаются.
    """
    import json
    with open(path, encoding='utf-8') as f:
        slips = json.load(f)

    known = {e.employee_id for e in Employee.query.all()}
    have = {p.employee_id for p in Payslip.query.filter_by(
        period_year=year, period_month=month).all()}
    period_display = f'{_MONTHS_RU[month - 1]} {year}'

    added = skipped = 0
    for slip in slips:
        tab = (slip.get('tab') or '').strip()
        if tab not in known:
            skipped += 1
            continue
        if tab in have:
            continue

        accruals = slip.get('total_accruals') or 0.0
        deductions = slip.get('total_deductions') or 0.0
        payslip = Payslip(
            employee_id=tab,
            period_month=month,
            period_year=year,
            period_display=period_display,
            total_accruals=accruals,
            total_deductions=deductions,
            # «К выплате» — начисленное минус удержанное. Выплаченное и долги
            # живут отдельными полями: выплатить могли и больше, и меньше.
            net_pay=round(accruals - deductions, 2),
            position=(slip.get('position') or '')[:200] or None,
            department=(slip.get('department') or '')[:200] or None,
            salary_rate=slip.get('salary_rate'),
            debt_start=slip.get('debt_start') or 0.0,
            debt_end=slip.get('debt_end') or 0.0,
            total_paid=slip.get('total_paid') or 0.0,
        )
        db.session.add(payslip)
        db.session.flush()          # нужен id для строк листка

        for row in slip.get('accruals', []):
            db.session.add(PayslipAccrual(
                payslip_id=payslip.id, name=row['name'][:200],
                amount=row['amount'], period=(row.get('period') or '')[:50],
                working_days=row.get('days'), working_hours=row.get('hours')))
        for row in slip.get('deductions', []):
            db.session.add(PayslipDeduction(
                payslip_id=payslip.id, name=row['name'][:200],
                amount=row['amount'], period=(row.get('period') or '')[:50]))
        for row in slip.get('paid', []):
            db.session.add(PayslipPaid(
                payslip_id=payslip.id,
                payment_type=(row.get('payment_type') or '')[:200],
                period=(row.get('period') or '')[:50], amount=row['amount']))
        for row in slip.get('benefits', []):
            db.session.add(PayslipBenefit(
                payslip_id=payslip.id, name=row['name'][:200],
                amount=row['amount']))
        for row in slip.get('reference', []):
            db.session.add(PayslipReference(
                payslip_id=payslip.id, name=row['name'][:200],
                amount=row['amount']))
        have.add(tab)
        added += 1

    db.session.commit()
    logging.info('%s: листков добавлено %d, пропущено (нет такого '
                 'сотрудника) %d', period_display, added, skipped)


def _dedupe_access_records():
    """Убирает задвоенные проходы турникета, оставляя по одному.

    Gunicorn поднимает три процесса, и каждый при старте прогоняет сидеры.
    Журнал applied_seeds их обычно и останавливает, но при одновременном
    старте все трое успевают прочитать его до того, как первый отметится, —
    и вставляют одно и то же. У расчётных листков от этого есть ограничение
    уникальности, а у проходов не было, поэтому задвоились именно они.

    Саму гонку закрывает блокировка в create_app; здесь — уборка следов.
    Дубль — полное совпадение сотрудника, даты, времени, события и двери:
    два прохода в одну минуту турникет пишет и по-настоящему, но тогда
    отличается хотя бы что-то одно.
    """
    from sqlalchemy import text
    removed = db.session.execute(text("""
        DELETE FROM access_records WHERE id NOT IN (
            SELECT MIN(id) FROM access_records
            GROUP BY employee_id, access_date, access_time, event_type, door_location
        )
    """)).rowcount
    db.session.commit()
    if removed:
        logging.info('Removed %d duplicate access records', removed)


def _seed_admin_account():
    """Create the system administrator account used by the in-app admin panel.

    The name is a single word on purpose: greetings address people by the given
    name, the second word of ФИО, so "Администратор системы" would come out as
    "Доброе утро, системы". The role still reads from the job title.

    Deliberately has no department: /get_sname falls back to listing everyone
    when the requester has none, so the admin sees the whole company.
    """
    admin = Employee.query.get(_ADMIN_EMPLOYEE_ID)
    if admin:
        admin.full_name = _ADMIN_DISPLAY_NAME
        admin.job_title = 'Администратор системы'
        admin.department = None
    else:
        db.session.add(Employee(
            employee_id=_ADMIN_EMPLOYEE_ID,
            full_name=_ADMIN_DISPLAY_NAME,
            job_title='Администратор системы',
        ))
    db.session.commit()


_DAUREMBEKOVA_ID = '0000001465'
_DAUREMBEKOVA_POSITION = 'Начальник ОИТиС'
_DAUREMBEKOVA_DEPARTMENT = 'Отдел информационных технологий и связи (ОИТиС)'


def _seed_daurembekova():
    """Сотрудник 1465 (Даурембекова).

    В справочнике она была заведена под временным номером D013: табельного
    ещё не знали. Листки его принесли — 0000001465, — и справочник теперь
    ведёт на него, а строку D013 подбирает _merge_duplicate_employees.

    В листках напечатано «Начальник отдела» и «АУП», но АУП — категория
    персонала в расчёте зарплаты, а не отдел. Экран листка склеивает
    должность с подразделением через точку, и получалось «Начальник отдела ·
    АУП» — читается как будто она начальник АУП, тогда как она начальник
    ОИТиС. Поэтому и в карточке, и на листках стоит настоящее: у остальных
    листков в подразделении тоже живой отдел, а не категория.

    Листки за июнь-июль и проходы июля-августа — в выгрузке
    legacy_seed.json (см. _seed_legacy_from_data).
    """
    if not Employee.query.filter_by(employee_id=_DAUREMBEKOVA_ID).first():
        db.session.add(Employee(
            employee_id=_DAUREMBEKOVA_ID,
            full_name='Даурембекова Умут Ергазыевна',
            job_title=_DAUREMBEKOVA_POSITION,
            department=_DAUREMBEKOVA_DEPARTMENT,
        ))
        db.session.flush()

    # ── Учётная запись ───────────────────────────────────────────────────────
    #
    # Пароль — табельный номер, как у всех при заведении, но, в отличие от
    # перенесённых из _CREDENTIALS, со сменой при первом входе: экран смены
    # в сборке уже есть. Сам этот пароль оставить нельзя — он короче шести
    # знаков и совпадает с логином, обе проверки его отклонят.
    if db.session.get(UserAccount, '1465') is None:
        db.session.add(UserAccount(
            login='1465',
            employee_id=_DAUREMBEKOVA_ID,
            password_hash=generate_password_hash('1465'),
            must_change_password=True,
        ))

    db.session.commit()


# Одни и те же люди, заведённые дважды: (лишний id, id который остаётся).
# Записи-сироты остались от ранних сидеров, заводивших сотрудника под коротким
# номером до того, как появились полные табельные.
_DUPLICATE_EMPLOYEES = [
    ('1874', '0000001874'),  # Кумарова Мадина Кумаровна
    ('D013', '0000001465'),  # Даурембекова Умут Ергазыевна
    ('D005', '0000000083'),  # Бейсекина Айман Муратовна
]


def _merge_duplicate_employees():
    """Переносит данные с записи-дубля на действующую и удаляет дубль.

    Логин Кумаровой ведёт на полный табельный номер, а её проходы турникета
    лежали на старом коротком — вкладка «Турникет» у неё была пустой.
    Идемпотентно: повторный запуск не находит, что переносить.
    """
    for stale_id, keep_id in _DUPLICATE_EMPLOYEES:
        _absorb_employee(stale_id, keep_id)


def _employee_referrers():
    """Столбцы, ссылающиеся на employees.employee_id, — по описанию моделей."""
    found = []
    for table in db.metadata.tables.values():
        if table.name == 'employees':
            continue
        for column in table.columns:
            if any(fk.column.table.name == 'employees'
                   for fk in column.foreign_keys):
                found.append((table, column))
    return found


def _absorb_employee(stale_id, keep_id):
    """Переносит всё с записи-дубля на действующую и удаляет дубль.

    Возвращает число перенесённых строк, None — если переносить нечего.
    """
    stale = db.session.get(Employee, stale_id)
    keep = db.session.get(Employee, keep_id)
    if stale is None or keep is None:
        return None

    # Таблицы берём из самих моделей, а не списком.
    #
    # Список был, и в нём не хватало пропусков (auth_tokens): на боевой базе
    # у людей они есть, и удаление прежней записи упёрлось во внешний ключ —
    # «update or delete on table employees violates foreign key constraint».
    # Забыть строку теперь негде: кто ссылается на сотрудника, тот и едет.
    moved = 0
    for table, column in _employee_referrers():
        if table.name == 'payslips':
            continue                    # у них своё ограничение, ниже
        moved += db.session.execute(
            table.update().where(column == stale_id).values({column: keep_id})
        ).rowcount

    # У расчётных листков есть ограничение на (сотрудник, год, месяц):
    # переносим только те периоды, которых у действующей записи нет.
    for slip in Payslip.query.filter_by(employee_id=stale_id).all():
        clash = Payslip.query.filter_by(
            employee_id=keep_id,
            period_year=slip.period_year,
            period_month=slip.period_month).first()
        if clash:
            db.session.delete(slip)
        else:
            slip.employee_id = keep_id
            moved += 1

    # Сначала фиксируем перенос и только потом удаляем дубль: если удалить
    # его в том же flush, SQLAlchemy обнулит employee_id у «осиротевших»
    # листков и перезапишет только что сделанное присваивание.
    db.session.commit()

    # ИИН — колонка самой записи, а не отдельная строка, и вместе с дублем он
    # бы пропал: поиск сотрудника по ИИН перестал бы его находить. Переносим
    # после удаления — на ИИН стоит требование неповторимости, и до удаления
    # дубля такое присваивание не прошло бы.
    orphan_iin = stale.iin
    db.session.delete(stale)
    db.session.commit()
    if orphan_iin and not keep.iin:
        keep.iin = orphan_iin
        db.session.commit()

    logging.info('Merged duplicate employee %s into %s (%d rows moved)',
                 stale_id, keep_id, moved)
    return moved


def _seed_user_accounts():
    """Восстанавливает строку в user_accounts для логинов, заведённых в коде.

    Раньше этот сидер переносил сюда и пароли из _CREDENTIALS — они там
    лежали открытым текстом, — и ставил must_change_password=False: пароль
    оставался прежним, чтобы никого не тревожить. Из-за этого двадцать три
    живых учётки годами ходили с паролем, напечатанным в исходниках.

    Теперь правило одно на всех, как при заведении любой новой учётки:
    временный пароль — табельный номер, сменить при первом входе. Строки,
    которые уже есть, сидер не трогает: чей пароль уже сменён, тот сменён.

    Запускается последним: сидеры выше ещё создают, склеивают и удаляют
    сотрудников, а учётная запись ссылается на существующего.
    """
    created = 0
    for login, employee_id in _CREDENTIALS.items():
        if db.session.get(UserAccount, login) is not None:
            continue
        if db.session.get(Employee, employee_id) is None:
            logging.warning('Account %r skipped: employee %s does not exist',
                            login, employee_id)
            continue
        db.session.add(UserAccount(
            login=login,
            employee_id=employee_id,
            password_hash=generate_password_hash(login),
            must_change_password=True,
        ))
        created += 1
    if created:
        db.session.commit()
    logging.info('user_accounts: %d created, %d total',
                 created, UserAccount.query.count())


_BEISEKINA_ID = '0000000083'
_BEISEKINA_POSITION = 'Корпоративный секретарь'
_BEISEKINA_DEPARTMENT = 'Корпоративный отдел'


def _seed_beisekina():
    """Сотрудник 83 (Бейсекина).

    Как и Даурембекова, в справочнике она стояла под временным номером —
    D005; листки принесли настоящий, 0000000083.

    В листках напечатана другая должность, «Представитель руководства по
    СМК»: это роль по системе менеджмента качества, её держат вдобавок к
    основной. В карточке оставлена должность из справочника, как и
    подразделение, — «АУП» на листке снова категория персонала, а не отдел.

    Её листки за июнь-июль — в выгрузке legacy_seed.json
    (см. _seed_legacy_from_data).
    """
    if not Employee.query.filter_by(employee_id=_BEISEKINA_ID).first():
        db.session.add(Employee(
            employee_id=_BEISEKINA_ID,
            full_name='Бейсекина Айман Муратовна',
            job_title=_BEISEKINA_POSITION,
            department=_BEISEKINA_DEPARTMENT,
        ))
        db.session.flush()

    # Пароль — табельный номер, со сменой при первом входе. Без учётной записи
    # листки ей негде смотреть: их увидел бы только администратор.
    if db.session.get(UserAccount, '83') is None:
        db.session.add(UserAccount(
            login='83',
            employee_id=_BEISEKINA_ID,
            password_hash=generate_password_hash('83'),
            must_change_password=True,
        ))

    db.session.commit()


# Учётки, которым пора сменить временный пароль. Пока он равен табельному
# номеру, войти может любой, кто видел табель.


# Входы, заведённые поимённо для людей из справочника, у которых учётной
# записи ещё не было: (логин, employee_id).
#
# Табельный номер тут не выдумывается. У кого он известен — стоит полный,
# как у всех; у кого нет — временный номер из справочника, и когда придёт
# расчётный лист с настоящим, учётку перенесёт _merge_duplicate_employees
# вместе с остальным.
_EXTRA_ACCOUNTS = [
    ('2222', 'D003'),  # Шаяхметов Данияр Бексултанович
]


def _seed_extra_accounts():
    """Заводит перечисленные входы. Пароль равен логину и меняется при первом
    входе — как у всех заводимых вручную.

    Идёт после переносов и после _seed_user_accounts: к этому времени
    сотрудник уже создан справочником, а дубли склеены.
    """
    created = 0
    for login, employee_id in _EXTRA_ACCOUNTS:
        if db.session.get(UserAccount, login) is not None:
            continue
        if db.session.get(Employee, employee_id) is None:
            logging.warning('Учётка %r пропущена: сотрудника %s нет',
                            login, employee_id)
            continue
        db.session.add(UserAccount(
            login=login,
            employee_id=employee_id,
            password_hash=generate_password_hash(login),
            must_change_password=True,
        ))
        created += 1
    if created:
        db.session.commit()
        logging.info('Заведено учётных записей: %d', created)


def _force_password_change():
    """Просит сменить пароль всех, у кого он остался временным.

    Кого просить, сидер выясняет сам: пароль, совпадающий с логином, придумать
    нельзя — _password_problem такой отклоняет, — значит, он выданный при
    заведении. Раньше здесь стоял список, и в нём была ровно одна учётка из
    двадцати трёх: остальные двадцать два ходили с паролем-табельным номером,
    напечатанным в app.py, и никто этого не замечал, потому что список никто
    не пополнял. Списки, которые нужно помнить, всегда отстают от данных.

    Сам вход теперь ставит тот же флаг (см. _authenticate), так что впредь
    такое ловится без сидера. Этот проход нужен для тех, кто уже вошёл и
    сидит на пропуске с кодом-паролем: на экран входа они не попадают
    неделями, а приложение спрашивает про смену и при запуске, через /api/me.

    Проверяем только тех, у кого флаг ещё не стоит: сверка хеша стоит около
    ста миллисекунд, и гонять её по всем пяти сотням учёток при каждом
    обновлении сидера незачем.

    Запускается после всех сидеров, заводящих учётные записи.
    """
    changed = 0
    checked = 0
    for account in UserAccount.query.filter_by(must_change_password=False).all():
        forms = _number_forms(account.login)
        checked += 1
        try:
            temporary = any(check_password_hash(account.password_hash, form)
                            for form in forms)
        except Exception as e:
            logging.error('Не читается хеш пароля у %r: %s', account.login, e)
            continue
        if not temporary:
            continue
        account.must_change_password = True
        changed += 1
    if changed:
        db.session.commit()
    logging.info('Временный пароль у %d из %d проверенных учётных записей',
                 changed, checked)


# Пароль администратора, если его нужно задать самим. Пусто — придумаем
# случайный и напечатаем в журнал один раз.
_ADMIN_PASSWORD_ENV = 'ADMIN_PASSWORD'


def _secure_admin_account():
    """Убирает пароль «admin» у учётной записи «admin».

    Логин администратора назывался admin, и паролем у него было слово admin.
    Сервер смотрит в интернет; такую пару подбирают не люди, а сканеры, и
    первым же запросом. Обязательная смена пароля тут не спасает: она
    показывается в приложении, а вошедший уже вошёл — пропуск у него на
    руках, и сменить пароль он может на свой.

    Поэтому пароль заменяется здесь. Если в окружении задан ADMIN_PASSWORD —
    берём его, иначе придумываем случайный и печатаем один раз в журнал
    службы: прочитать его можно `journalctl -u se-mobile | grep -i пароль`.
    Выданные ранее пропуска администратора при этом гасятся — если паролем
    «admin» кто-то уже воспользовался, его пропуск перестанет работать.

    Трогаем, только если пароль всё ещё «admin»: сменённый — не наше дело.
    """
    account = db.session.get(UserAccount, 'admin')
    if account is None:
        logging.info('Учётной записи admin нет — менять нечего')
        return
    try:
        if not check_password_hash(account.password_hash, 'admin'):
            logging.info('Пароль администратора уже не «admin» — не трогаем')
            return
    except Exception as e:
        logging.error('Не читается хеш пароля администратора: %s', e)
        return

    chosen = (os.environ.get(_ADMIN_PASSWORD_ENV) or '').strip()
    generated = not chosen
    if generated:
        chosen = _random_password()

    account.password_hash = generate_password_hash(chosen)
    account.must_change_password = True
    account.failed_attempts = 0
    account.locked_until = None
    AuthToken.query.filter_by(employee_id=account.employee_id).delete()
    db.session.commit()

    if generated:
        logging.warning(
            'Пароль администратора был «admin» и заменён на случайный. '
            'Новый пароль администратора: %s — запишите его и смените в '
            'приложении. Задать свой заранее можно переменной %s.',
            chosen, _ADMIN_PASSWORD_ENV)
    else:
        logging.warning('Пароль администратора был «admin» и взят из %s',
                        _ADMIN_PASSWORD_ENV)


app = create_app()

if __name__ == '__main__':
    # Без debug=True. Отладчик Flask позволяет выполнять произвольный код
    # через браузер, и один запуск «python app.py» на боевом сервере открыл
    # бы её наружу. Разработке хватит FLASK_DEBUG=1 в окружении.
    app.run(host='127.0.0.1', port=5000,
            debug=os.environ.get('FLASK_DEBUG', '').strip() == '1')
