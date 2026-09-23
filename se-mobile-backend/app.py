import os
import logging
import re
import secrets
from functools import wraps
from datetime import date, datetime, timedelta, timezone
from flask import Flask, request, jsonify, g
from flask_cors import CORS
# Werkzeug идёт вместе с Flask, ставить ничего не нужно. По умолчанию scrypt.
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


def _push_to_everyone(title, body, data=None):
    """Уведомление всем, у кого установлено приложение."""
    return _push_to([t.employee_id for t in FcmToken.query.all()],
                    title, body, data)


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


def _issue_token(employee_id):
    """Выдаёт новый пропуск. Старые не трогает: у человека может быть
    и телефон, и планшет."""
    now = datetime.utcnow()
    token = AuthToken(
        token=secrets.token_urlsafe(32),
        employee_id=employee_id,
        created_at=now,
        last_used_at=now,
        expires_at=now + _TOKEN_LIFETIME,
    )
    db.session.add(token)
    # Заодно подчищаем протухшие, чтобы таблица не росла бесконечно.
    AuthToken.query.filter(AuthToken.expires_at < now).delete()
    db.session.commit()
    return token.token


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
    row = db.session.get(AuthToken, raw)
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


def _fetch(url, timeout=8):
    import urllib.request
    request_ = urllib.request.Request(
        url, headers={'User-Agent': 'SE-mobile/1.0',
                      'Accept': 'application/rss+xml, application/xml, text/html'})
    with urllib.request.urlopen(request_, timeout=timeout) as response:
        return response.read(), response.geturl()


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


def _refresh_site_news(force=False):
    """Забирает новости сайта, если давно не забирали.

    Ходим лениво, при чтении ленты приложением, а не по расписанию: отдельный
    таймер — ещё одна деталь, которая ломается молча. Ошибка сети здесь не
    ошибка запроса: показываем то, что уже лежит в базе.
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

    db_url = os.environ.get('DATABASE_URL', 'sqlite:///se_mobile.db')
    # Render выдаёт postgres://, SQLAlchemy требует postgresql://
    if db_url.startswith('postgres://'):
        db_url = db_url.replace('postgres://', 'postgresql://', 1)
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
        _seed_2024_full,
        _seed_2025_full,
        _seed_2026,
        _seed_2026_full,
        _ensure_payslips_jan_apr_2026,
        _seed_may_2026,
        _ensure_all_payslips,
        _seed_sarseken,
        _seed_turnstile_events,
        _seed_leave_2026,
        _update_april_2026_001,
        _seed_april_2026_access_001,
        _seed_kumarova,
        _seed_docx_employees_2026,
        _seed_org_directory,
        _seed_admin_account,
        _seed_otk_july_2026,
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
        data = request.get_json(silent=True) or {}
        login_id = (data.get('login') or '').strip()
        password  = (data.get('password') or '').strip()

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

        data = request.get_json(silent=True) or {}
        old_password = (data.get('old_password') or '').strip()
        new_password = (data.get('new_password') or '').strip()

        account = UserAccount.query.filter_by(
            employee_id=viewer.employee_id, is_active=True).first()
        if account is None:
            return jsonify({'message': 'Failure', 'error': 'no_account'}), 404
        if not check_password_hash(account.password_hash, old_password):
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
            row = db.session.get(AuthToken, raw)
            if row is not None:
                db.session.delete(row)
                db.session.commit()
        return jsonify({'message': 'Success'})

    @app.route('/report', methods=['POST'])
    @require_auth
    def report():
        data = request.get_json()
        key_suffix = data.get('key_suffix', '')
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
        data = request.get_json()
        key_suffix = data.get('key_suffix', '')
        if not _may_view(key_suffix):
            return _deny()
        start_date = data.get('start_date', '')
        end_date = data.get('end_date', '')

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
        data = request.get_json()
        emp_sname = data.get('emp_sname', '')
        start_date = data.get('start_date', '')
        end_date = data.get('end_date', '')

        emp = Employee.query.filter(Employee.full_name.contains(emp_sname)).first()
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
        data = request.get_json()

        if 'key_suffix' in data:
            # The employee report lists the requester's own department only, so
            # a manager sees their team rather than the whole company. Falls
            # back to everyone when the requester has no department on record.
            me = Employee.query.get(data['key_suffix'])
            query = Employee.query
            if me and me.department:
                query = query.filter(
                    Employee.department == me.department,
                    Employee.employee_id != me.employee_id,
                )
            # Some people exist twice (a legacy id kept alongside the tabular
            # one), so collapse repeats to keep the picker clean.
            names = list(dict.fromkeys(e.full_name for e in query.all()))
            return jsonify({'fio': names})

        if 'emp_iin' in data:
            emp = Employee.query.filter_by(iin=data['emp_iin']).first()
            if emp:
                return jsonify({
                    'message': 'Success',
                    'employee': [{
                        'full_name': emp.full_name,
                        'job': emp.job_title,
                        'iin': emp.iin
                    }]
                })
            return jsonify({'message': 'Failure'})

        return jsonify({'message': 'Failure'})

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
        data = request.get_json(silent=True) or {}
        key_suffix = (data.get('key_suffix') or '').strip()
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

    @app.route('/payslip', methods=['POST'])
    @require_auth
    def payslip():
        data = request.get_json()
        key_suffix = data.get('key_suffix', '')
        if not _may_view(key_suffix):
            return _deny()
        month = data.get('month', '')
        year = data.get('year', '')

        ps = Payslip.query.filter_by(
            employee_id=key_suffix,
            period_month=int(month),
            period_year=int(year)
        ).first()

        if not ps:
            return jsonify({'message': 'Failure'})

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

    @app.route('/api/admin/upload-payslip-xml', methods=['POST'])
    def upload_payslip_xml():
        admin_token = os.environ.get('ADMIN_TOKEN', '')
        # Как и у турникета: незаданный секрет — не повод пускать всех.
        # Иначе этот путь заводит сотрудников и грузит расчётные листки
        # вообще без спроса.
        provided = request.headers.get('X-Admin-Token', '')
        if not admin_token or provided != admin_token:
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
            _push_to(employee_ids, 'Зарплата',
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
        data = request.get_json()
        key_suffix = data.get('key_suffix', '')
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
        data = request.get_json() or {}
        employee_id = data.get('employee_id', '').strip()
        token = data.get('token', '').strip()
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
        data = request.get_json() or {}
        token = data.get('token', '').strip()
        if not token:
            return jsonify({'message': 'Failure', 'error': 'token required'}), 400
        FcmToken.query.filter_by(token=token).delete()
        db.session.commit()
        return jsonify({'message': 'Success'})

    # ── СКУД turnstile webhook ────────────────────────────────────────────────

    @app.route('/api/turnstile', methods=['POST'])
    def turnstile_event():
        data = request.get_json() or {}
        secret = data.get('secret', '')
        expected = os.environ.get('TURNSTILE_SECRET', '')
        # Отказ в безопасную сторону: пустой секрет раньше отключал проверку
        # целиком, и кто угодно мог слать поддельные проходы. Теперь пустой
        # TURNSTILE_SECRET значит «настроить забыли», а не «пускать всех».
        if not expected or secret != expected:
            if not expected:
                logging.error('TURNSTILE_SECRET не задан — события турникета '
                              'отклоняются. Проверьте /etc/se-mobile.env')
            return jsonify({'message': 'Failure', 'error': 'Unauthorized'}), 403

        employee_id = data.get('employee_id', '').strip()
        direction = data.get('direction', '').strip()  # 'in' | 'out'
        ts_raw = data.get('timestamp')

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

        event = TurnstileEvent(employee_id=employee_id, direction=direction, timestamp=ts)
        db.session.add(event)
        db.session.commit()

        ts_str = ts.strftime('%H:%M')
        _send_turnstile_notification(emp.full_name, direction, ts_str, employee_id)

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
        data = request.get_json() or {}
        date_str = data.get('date', '')
        items_data = data.get('items', [])
        try:
            menu_date = date.fromisoformat(date_str)
        except (ValueError, TypeError):
            return jsonify({'message': 'Failure', 'error': 'Invalid or missing date'}), 400

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

        for item in items_data:
            category = str(item.get('category', '')).strip()
            name = str(item.get('name', '')).strip()
            price = item.get('price')
            if not category or not name:
                continue
            db.session.add(MenuItem(
                menu_date_id=menu.id,
                category=category,
                name=name,
                price=float(price) if price is not None else None,
                portion=(str(item.get('portion')).strip()
                         if item.get('portion') else None),
            ))

        db.session.commit()
        if was_new:
            _notify_menu_published()
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
            return jsonify({'message': 'Неверный логин или пароль', 'error': True}), 401

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
        _notify_menu_published()

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
        _refresh_site_news()
        limit = min(int(request.args.get('limit', 50) or 50), 200)
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
        data = request.get_json(silent=True) or {}
        title = (data.get('title') or '').strip()
        summary = (data.get('summary') or '').strip()
        if not title:
            return jsonify({'message': 'Failure', 'error': 'title_required'}), 400

        viewer = getattr(g, 'employee', None)
        item = NewsItem(
            source='announcement',
            title=title[:500],
            summary=summary,
            author=(data.get('author') or (viewer.full_name if viewer else ''))[:255] or None,
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

        data = request.get_json(silent=True) or {}
        # Запоминаем до правки: уведомление шлём только на переходе
        # «в очереди» → «в ленте», иначе правка опечатки разбудит всех заново.
        was_published = item.is_published
        if 'is_published' in data:
            item.is_published = bool(data['is_published'])
        if (data.get('title') or '').strip():
            item.title = data['title'].strip()[:500]
        if 'summary' in data:
            item.summary = (data.get('summary') or '').strip()
        db.session.commit()

        if item.is_published and not was_published:
            _push_to_everyone('Объявление', item.title,
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
        data = request.get_json(silent=True) or {}
        employee_id = _authenticate((data.get('login') or '').strip(),
                                    (data.get('password') or '').strip())
        if not employee_id:
            return jsonify({'message': 'Неверный логин или пароль', 'error': True}), 401
        uploader = Employee.query.get(employee_id)
        if not _is_system_admin(uploader.job_title if uploader else ''):
            return jsonify({'message': 'Присылать объявления может администратор',
                            'error': True}), 403

        title = (data.get('title') or '').strip()
        if not title:
            return jsonify({'message': 'Пустая тема письма', 'error': True}), 400

        # Письмо узнаём по Message-ID: рассылку читают повторно, и одно и то
        # же письмо не должно попасть в очередь дважды.
        external = (data.get('message_id') or '').strip()[:500] or None
        if external and NewsItem.query.filter_by(external_id=external).first():
            return jsonify({'message': 'Уже принято', 'duplicate': True})

        published = None
        if data.get('sent_at'):
            try:
                published = datetime.fromisoformat(data['sent_at'].replace('Z', '+00:00'))
                if published.tzinfo is not None:
                    published = published.astimezone(timezone.utc).replace(tzinfo=None)
            except ValueError:
                published = None

        item = NewsItem(
            source='announcement',
            external_id=external,
            title=title[:500],
            summary=(data.get('summary') or '').strip(),
            author=(data.get('author') or '').strip()[:255] or None,
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
            return jsonify({'message': 'Неверный логин или пароль', 'error': True}), 401

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
    if Employee.query.first():
        return

    e1 = Employee(employee_id='001', full_name='Сарсекенов Батырхан Арманұлы', job_title='Техник-программист', iin='000000002114')
    e2 = Employee(employee_id='002', full_name='Касымов Нурлан Серикович', job_title='Руководитель отдела', iin='850515400456')
    e3 = Employee(employee_id='003', full_name='Сидорова Анна Сергеевна', job_title='Бухгалтер', iin='920720450789')
    db.session.add_all([e1, e2, e3])

    for eid, d, t, ev, door in [
        ('001', '2024-01-15', '08:55', 'Вход', 'Главный вход'),
        ('001', '2024-01-15', '18:05', 'Выход', 'Главный вход'),
        ('001', '2024-01-16', '08:50', 'Вход', 'Главный вход'),
        ('001', '2024-01-16', '18:10', 'Выход', 'Главный вход'),
        ('001', '2024-02-01', '09:00', 'Вход', 'Главный вход'),
        ('001', '2024-02-01', '18:00', 'Выход', 'Главный вход'),
        ('002', '2024-01-15', '08:30', 'Вход', 'Офис'),
        ('002', '2024-01-15', '19:00', 'Выход', 'Офис'),
        ('002', '2024-01-16', '08:40', 'Вход', 'Офис'),
        ('002', '2024-01-16', '18:30', 'Выход', 'Офис'),
        ('003', '2024-01-15', '08:45', 'Вход', 'Бухгалтерия'),
        ('003', '2024-01-15', '17:45', 'Выход', 'Бухгалтерия'),
        ('003', '2024-01-16', '08:50', 'Вход', 'Бухгалтерия'),
        ('003', '2024-01-16', '17:50', 'Выход', 'Бухгалтерия'),
    ]:
        y, m, day = d.split('-')
        db.session.add(AccessRecord(
            employee_id=eid, access_date=date(int(y), int(m), int(day)),
            access_time=t, event_type=ev, door_location=door
        ))

    for eid, month, year, display, accs, deds, ta, td, np in [
        ('001', 1, 2024, 'Январь 2024',
         [('Оклад', 350000), ('Премия', 50000), ('Надбавка за стаж', 17500)],
         [('ИПН (10%)', 41750), ('ОПВ (10%)', 41750), ('ВОСМС (2%)', 8350)],
         417500, 91850, 325650),
        ('001', 2, 2024, 'Февраль 2024',
         [('Оклад', 350000), ('Надбавка за стаж', 17500)],
         [('ИПН (10%)', 36750), ('ОПВ (10%)', 36750), ('ВОСМС (2%)', 7350)],
         367500, 80850, 286650),
        ('002', 1, 2024, 'Январь 2024',
         [('Оклад', 500000), ('Премия за KPI', 100000)],
         [('ИПН (10%)', 60000), ('ОПВ (10%)', 60000), ('ВОСМС (2%)', 12000)],
         600000, 132000, 468000),
        ('002', 2, 2024, 'Февраль 2024',
         [('Оклад', 500000)],
         [('ИПН (10%)', 50000), ('ОПВ (10%)', 50000), ('ВОСМС (2%)', 10000)],
         500000, 110000, 390000),
        ('003', 1, 2024, 'Январь 2024',
         [('Оклад', 280000)],
         [('ИПН (10%)', 28000), ('ОПВ (10%)', 28000), ('ВОСМС (2%)', 5600)],
         280000, 61600, 218400),
    ]:
        ps = Payslip(employee_id=eid, period_month=month, period_year=year,
                     period_display=display, total_accruals=ta,
                     total_deductions=td, net_pay=np)
        db.session.add(ps)
        db.session.flush()
        for name, amount in accs:
            db.session.add(PayslipAccrual(payslip_id=ps.id, name=name, amount=amount))
        for name, amount in deds:
            db.session.add(PayslipDeduction(payslip_id=ps.id, name=name, amount=amount))

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


def _seed_2026():
    exists = AccessRecord.query.filter(
        AccessRecord.access_date >= date(2026, 1, 1)
    ).first()
    if exists:
        return

    # ─── Турникет Январь-Апрель 2026 ───────────────────
    for eid, d, t, ev, door in [
        # Иванов — Январь 2026
        ('001', '2026-01-12', '08:50', 'Вход', 'Главный вход'),
        ('001', '2026-01-12', '18:10', 'Выход', 'Главный вход'),
        ('001', '2026-01-13', '08:55', 'Вход', 'Главный вход'),
        ('001', '2026-01-13', '18:00', 'Выход', 'Главный вход'),
        ('001', '2026-01-14', '09:02', 'Вход', 'Главный вход'),
        ('001', '2026-01-14', '18:15', 'Выход', 'Главный вход'),
        # Иванов — Февраль 2026
        ('001', '2026-02-02', '08:45', 'Вход', 'Главный вход'),
        ('001', '2026-02-02', '18:05', 'Выход', 'Главный вход'),
        ('001', '2026-02-03', '08:58', 'Вход', 'Главный вход'),
        ('001', '2026-02-03', '18:20', 'Выход', 'Главный вход'),
        ('001', '2026-02-04', '08:52', 'Вход', 'Главный вход'),
        ('001', '2026-02-04', '18:00', 'Выход', 'Главный вход'),
        # Иванов — Март 2026
        ('001', '2026-03-02', '08:48', 'Вход', 'Главный вход'),
        ('001', '2026-03-02', '18:12', 'Выход', 'Главный вход'),
        ('001', '2026-03-03', '08:55', 'Вход', 'Главный вход'),
        ('001', '2026-03-03', '18:05', 'Выход', 'Главный вход'),
        ('001', '2026-03-04', '09:00', 'Вход', 'Главный вход'),
        ('001', '2026-03-04', '18:10', 'Выход', 'Главный вход'),
        # Иванов — Апрель 2026
        ('001', '2026-04-01', '08:50', 'Вход', 'Главный вход'),
        ('001', '2026-04-01', '18:00', 'Выход', 'Главный вход'),
        ('001', '2026-04-02', '08:47', 'Вход', 'Главный вход'),
        ('001', '2026-04-02', '18:08', 'Выход', 'Главный вход'),
        ('001', '2026-04-03', '08:53', 'Вход', 'Главный вход'),
        ('001', '2026-04-03', '18:15', 'Выход', 'Главный вход'),
        # Петров — Январь-Апрель 2026
        ('002', '2026-01-12', '08:30', 'Вход', 'Офис'),
        ('002', '2026-01-12', '19:00', 'Выход', 'Офис'),
        ('002', '2026-01-13', '08:25', 'Вход', 'Офис'),
        ('002', '2026-01-13', '18:45', 'Выход', 'Офис'),
        ('002', '2026-02-02', '08:35', 'Вход', 'Офис'),
        ('002', '2026-02-02', '18:50', 'Выход', 'Офис'),
        ('002', '2026-02-03', '08:28', 'Вход', 'Офис'),
        ('002', '2026-02-03', '19:10', 'Выход', 'Офис'),
        ('002', '2026-03-02', '08:30', 'Вход', 'Офис'),
        ('002', '2026-03-02', '18:55', 'Выход', 'Офис'),
        ('002', '2026-03-03', '08:32', 'Вход', 'Офис'),
        ('002', '2026-03-03', '19:00', 'Выход', 'Офис'),
        ('002', '2026-04-01', '08:28', 'Вход', 'Офис'),
        ('002', '2026-04-01', '18:40', 'Выход', 'Офис'),
        ('002', '2026-04-02', '08:35', 'Вход', 'Офис'),
        ('002', '2026-04-02', '19:05', 'Выход', 'Офис'),
        # Сидорова — Январь-Апрель 2026
        ('003', '2026-01-12', '08:40', 'Вход', 'Бухгалтерия'),
        ('003', '2026-01-12', '17:50', 'Выход', 'Бухгалтерия'),
        ('003', '2026-01-13', '08:45', 'Вход', 'Бухгалтерия'),
        ('003', '2026-01-13', '17:55', 'Выход', 'Бухгалтерия'),
        ('003', '2026-02-02', '08:42', 'Вход', 'Бухгалтерия'),
        ('003', '2026-02-02', '17:48', 'Выход', 'Бухгалтерия'),
        ('003', '2026-02-03', '08:50', 'Вход', 'Бухгалтерия'),
        ('003', '2026-02-03', '17:45', 'Выход', 'Бухгалтерия'),
        ('003', '2026-03-02', '08:44', 'Вход', 'Бухгалтерия'),
        ('003', '2026-03-02', '17:50', 'Выход', 'Бухгалтерия'),
        ('003', '2026-03-03', '08:48', 'Вход', 'Бухгалтерия'),
        ('003', '2026-03-03', '17:52', 'Выход', 'Бухгалтерия'),
        ('003', '2026-04-01', '08:46', 'Вход', 'Бухгалтерия'),
        ('003', '2026-04-01', '17:55', 'Выход', 'Бухгалтерия'),
        ('003', '2026-04-02', '08:43', 'Вход', 'Бухгалтерия'),
        ('003', '2026-04-02', '17:50', 'Выход', 'Бухгалтерия'),
    ]:
        y, m, day = d.split('-')
        db.session.add(AccessRecord(
            employee_id=eid, access_date=date(int(y), int(m), int(day)),
            access_time=t, event_type=ev, door_location=door
        ))

    # ─── Расчётные листы Январь-Март 2026 ──────────────
    for eid, month, year, display, accs, deds, ta, td, np in [
        ('001', 1, 2026, 'Январь 2026',
         [('Оклад', 380000), ('Премия', 45000), ('Надбавка за стаж', 19000)],
         [('ИПН (10%)', 44400), ('ОПВ (10%)', 44400), ('ВОСМС (2%)', 8880)],
         444000, 97680, 346320),
        ('001', 2, 2026, 'Февраль 2026',
         [('Оклад', 380000), ('Надбавка за стаж', 19000)],
         [('ИПН (10%)', 39900), ('ОПВ (10%)', 39900), ('ВОСМС (2%)', 7980)],
         399000, 87780, 311220),
        ('001', 3, 2026, 'Март 2026',
         [('Оклад', 380000), ('Премия', 60000), ('Надбавка за стаж', 19000)],
         [('ИПН (10%)', 45900), ('ОПВ (10%)', 45900), ('ВОСМС (2%)', 9180)],
         459000, 100980, 358020),
        ('002', 1, 2026, 'Январь 2026',
         [('Оклад', 550000), ('Премия за KPI', 120000)],
         [('ИПН (10%)', 67000), ('ОПВ (10%)', 67000), ('ВОСМС (2%)', 13400)],
         670000, 147400, 522600),
        ('002', 2, 2026, 'Февраль 2026',
         [('Оклад', 550000)],
         [('ИПН (10%)', 55000), ('ОПВ (10%)', 55000), ('ВОСМС (2%)', 11000)],
         550000, 121000, 429000),
        ('002', 3, 2026, 'Март 2026',
         [('Оклад', 550000), ('Премия за KPI', 80000)],
         [('ИПН (10%)', 63000), ('ОПВ (10%)', 63000), ('ВОСМС (2%)', 12600)],
         630000, 138600, 491400),
        ('003', 1, 2026, 'Январь 2026',
         [('Оклад', 300000)],
         [('ИПН (10%)', 30000), ('ОПВ (10%)', 30000), ('ВОСМС (2%)', 6000)],
         300000, 66000, 234000),
        ('003', 2, 2026, 'Февраль 2026',
         [('Оклад', 300000), ('Премия', 25000)],
         [('ИПН (10%)', 32500), ('ОПВ (10%)', 32500), ('ВОСМС (2%)', 6500)],
         325000, 71500, 253500),
        ('003', 3, 2026, 'Март 2026',
         [('Оклад', 300000)],
         [('ИПН (10%)', 30000), ('ОПВ (10%)', 30000), ('ВОСМС (2%)', 6000)],
         300000, 66000, 234000),
    ]:
        ps = Payslip(employee_id=eid, period_month=month, period_year=year,
                     period_display=display, total_accruals=ta,
                     total_deductions=td, net_pay=np)
        db.session.add(ps)
        db.session.flush()
        for name, amount in accs:
            db.session.add(PayslipAccrual(payslip_id=ps.id, name=name, amount=amount))
        for name, amount in deds:
            db.session.add(PayslipDeduction(payslip_id=ps.id, name=name, amount=amount))

    db.session.commit()


def _seed_2026_full():
    """Полные рабочие дни янв–апр 2026 + расчётные листы за апрель.

    _seed_2026() добавила лишь по 2-3 дня в месяц на сотрудника.
    Здесь добавляются все оставшиеся рабочие дни Казахстана (с учётом
    государственных праздников, отпусков и больничных).

    Маркер: 2026-01-05 сотрудника 002 — его нет в разреженных данных.
    """
    if AccessRecord.query.filter(
        AccessRecord.access_date == date(2026, 1, 5),
        AccessRecord.employee_id == '002'
    ).first():
        return

    # Пулы времён прихода/ухода (16 значений, циклически)
    _t001 = [
        ('08:52', '18:10'), ('08:55', '18:05'), ('09:01', '18:15'), ('08:48', '18:00'),
        ('09:05', '18:20'), ('08:50', '18:08'), ('08:58', '18:12'), ('09:03', '18:03'),
        ('08:45', '18:18'), ('09:00', '18:07'), ('08:53', '18:01'), ('09:07', '18:14'),
        ('08:47', '18:09'), ('08:59', '18:22'), ('09:02', '18:06'), ('08:51', '18:11'),
    ]
    _t002 = [
        ('08:30', '18:45'), ('08:35', '19:00'), ('08:28', '18:50'), ('08:40', '19:10'),
        ('08:32', '18:35'), ('08:25', '19:15'), ('08:38', '18:55'), ('08:33', '19:05'),
        ('08:27', '18:40'), ('08:42', '18:30'), ('08:29', '19:20'), ('08:36', '18:48'),
        ('08:31', '19:02'), ('08:26', '18:38'), ('08:39', '18:52'), ('08:34', '19:08'),
    ]
    _t003 = [
        ('08:42', '17:50'), ('08:50', '17:55'), ('08:45', '17:48'), ('08:55', '18:05'),
        ('08:48', '17:52'), ('08:40', '17:45'), ('08:52', '18:00'), ('08:43', '17:58'),
        ('08:57', '17:46'), ('08:46', '18:03'), ('08:51', '17:53'), ('08:44', '17:47'),
        ('08:53', '18:01'), ('08:47', '17:56'), ('08:41', '17:49'), ('08:49', '18:04'),
    ]

    # Государственные праздники КЗ 2026, влияющие на рабочие дни:
    # 1-2 янв (Новый год), 7 янв (Рождество), 8 марта — вс → пн 9 марта,
    # 21-23 марта (Наурыз), 1 мая, 7 мая, 9 мая.

    # Иванов 001: отпуск 5-9 янв, больничный 16-20 фев
    # (уже есть: янв 12,13,14; фев 2,3,4; мар 2,3,4; апр 1,2,3)
    emp001_days = [
        # Январь
        '2026-01-15','2026-01-16','2026-01-19','2026-01-20','2026-01-21',
        '2026-01-22','2026-01-23','2026-01-26','2026-01-27','2026-01-28',
        '2026-01-29','2026-01-30',
        # Февраль (пропуск 16-20 — больничный)
        '2026-02-05','2026-02-06','2026-02-09','2026-02-10','2026-02-11',
        '2026-02-12','2026-02-13','2026-02-23','2026-02-24','2026-02-25',
        '2026-02-26','2026-02-27',
        # Март (пропуск 9 — замена 8 марта; 21-23 — Наурыз)
        '2026-03-05','2026-03-06','2026-03-10','2026-03-11','2026-03-12',
        '2026-03-13','2026-03-16','2026-03-17','2026-03-18','2026-03-19',
        '2026-03-20','2026-03-24','2026-03-25','2026-03-26','2026-03-27',
        '2026-03-30','2026-03-31',
        # Апрель (до 23-го)
        '2026-04-06','2026-04-07','2026-04-08','2026-04-09','2026-04-10',
        '2026-04-13','2026-04-14','2026-04-15','2026-04-16','2026-04-17',
        '2026-04-20','2026-04-21','2026-04-22','2026-04-23',
    ]

    # Петров 002: отпуск 9-22 фев
    # (уже есть: янв 12,13; фев 2,3; мар 2,3; апр 1,2)
    emp002_days = [
        # Январь
        '2026-01-05','2026-01-06','2026-01-08','2026-01-09','2026-01-14',
        '2026-01-15','2026-01-16','2026-01-19','2026-01-20','2026-01-21',
        '2026-01-22','2026-01-23','2026-01-26','2026-01-27',
        # Февраль (пропуск 9-22 — отпуск)
        '2026-02-04','2026-02-05','2026-02-06','2026-02-23','2026-02-24',
        '2026-02-25','2026-02-26','2026-02-27',
        # Март
        '2026-03-04','2026-03-05','2026-03-06','2026-03-10','2026-03-11',
        '2026-03-12','2026-03-13','2026-03-16','2026-03-17','2026-03-18',
        '2026-03-19','2026-03-20','2026-03-24','2026-03-25','2026-03-26',
        '2026-03-27','2026-03-30','2026-03-31',
        # Апрель
        '2026-04-03','2026-04-06','2026-04-07','2026-04-08','2026-04-09',
        '2026-04-10','2026-04-13','2026-04-14','2026-04-15','2026-04-16',
        '2026-04-17','2026-04-20','2026-04-21','2026-04-22','2026-04-23',
    ]

    # Сидорова 003: больничный 16-20 фев
    # (уже есть: янв 12,13; фев 2,3; мар 2,3; апр 1,2)
    emp003_days = [
        # Январь
        '2026-01-05','2026-01-06','2026-01-08','2026-01-09','2026-01-14',
        '2026-01-15','2026-01-16','2026-01-19','2026-01-20','2026-01-21',
        '2026-01-22','2026-01-23','2026-01-26',
        # Февраль (пропуск 16-20 — больничный)
        '2026-02-04','2026-02-05','2026-02-06','2026-02-09','2026-02-10',
        '2026-02-11','2026-02-12','2026-02-13','2026-02-23','2026-02-24',
        '2026-02-25','2026-02-26','2026-02-27',
        # Март
        '2026-03-04','2026-03-05','2026-03-06','2026-03-10','2026-03-11',
        '2026-03-12','2026-03-13','2026-03-16','2026-03-17','2026-03-18',
        '2026-03-19','2026-03-20','2026-03-24','2026-03-25','2026-03-26',
        '2026-03-27','2026-03-30','2026-03-31',
        # Апрель
        '2026-04-03','2026-04-06','2026-04-07','2026-04-08','2026-04-09',
        '2026-04-10','2026-04-13','2026-04-14','2026-04-15','2026-04-16',
        '2026-04-17','2026-04-20','2026-04-21','2026-04-22','2026-04-23',
    ]

    def _add_records(emp_id, days, times, door):
        for i, d in enumerate(days):
            y, m, day = d.split('-')
            t_in, t_out = times[i % len(times)]
            db.session.add(AccessRecord(
                employee_id=emp_id,
                access_date=date(int(y), int(m), int(day)),
                access_time=t_in, event_type='Вход', door_location=door))
            db.session.add(AccessRecord(
                employee_id=emp_id,
                access_date=date(int(y), int(m), int(day)),
                access_time=t_out, event_type='Выход', door_location=door))

    _add_records('001', emp001_days, _t001, 'Главный вход')
    _add_records('002', emp002_days, _t002, 'Офис')
    _add_records('003', emp003_days, _t003, 'Бухгалтерия')

    # Расчётные листы за апрель 2026
    # ИПН 10%, ОПВ 10%, ВОСМС 2% — ставки Казахстана 2026
    if not Payslip.query.filter_by(
            employee_id='001', period_year=2026, period_month=4).first():
        april_payslips = [
            ('001', 'Апрель 2026',
             [('Оклад', 380000), ('Надбавка за стаж', 19000), ('Квартальная премия', 57000)],
             [('ИПН (10%)', 45600), ('ОПВ (10%)', 45600), ('ВОСМС (2%)', 9120)],
             456000, 100320, 355680),
            ('002', 'Апрель 2026',
             [('Оклад', 550000), ('Премия за KPI', 110000)],
             [('ИПН (10%)', 66000), ('ОПВ (10%)', 66000), ('ВОСМС (2%)', 13200)],
             660000, 145200, 514800),
            ('003', 'Апрель 2026',
             [('Оклад', 300000), ('Ежемесячная премия', 30000)],
             [('ИПН (10%)', 33000), ('ОПВ (10%)', 33000), ('ВОСМС (2%)', 6600)],
             330000, 72600, 257400),
        ]
        for eid, display, accs, deds, ta, td, np_ in april_payslips:
            ps = Payslip(employee_id=eid, period_month=4, period_year=2026,
                         period_display=display, total_accruals=ta,
                         total_deductions=td, net_pay=np_)
            db.session.add(ps)
            db.session.flush()
            for name, amount in accs:
                db.session.add(PayslipAccrual(payslip_id=ps.id, name=name, amount=amount))
            for name, amount in deds:
                db.session.add(PayslipDeduction(payslip_id=ps.id, name=name, amount=amount))

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


# ---------------------------------------------------------------------------
# Helpers shared by 2024/2025 seeders
# ---------------------------------------------------------------------------

_MONTH_RU = {
    1: 'Январь', 2: 'Февраль', 3: 'Март', 4: 'Апрель',
    5: 'Май', 6: 'Июнь', 7: 'Июль', 8: 'Август',
    9: 'Сентябрь', 10: 'Октябрь', 11: 'Ноябрь', 12: 'Декабрь',
}

_EMP_META = {
    '001': ('Техник-программист', 'Отдел информационных технологий и связи', 'Главный вход'),
    '002': ('Руководитель отдела', 'Администрация',         'Офис'),
    '003': ('Бухгалтер',        'Бухгалтерия',            'Бухгалтерия'),
}


def _add_payslip(emp_id, month, year, oklad, standard_deduction, vacation_days=0):
    """Create Payslip + all child rows for one employee/month."""
    from datetime import timedelta as td

    pitanie = 9_700
    worked_days = 22 - vacation_days
    worked_hours = round(worked_days * 8.0 + worked_days * 0.136)  # ~8h 8m/day → 173h full month

    pay_oklad   = round(oklad / 22 * worked_days)
    premiya     = round(oklad / 22 * worked_days)
    ekologia    = round(oklad * 0.017)
    vac_pay     = round(oklad / 22 * vacation_days) if vacation_days else 0
    total_accruals = pay_oklad + premiya + ekologia + vac_pay

    opv  = round(total_accruals * 0.10)
    osms = round(total_accruals * 0.02)
    ipn_base = max(0, total_accruals - opv - osms - standard_deduction)
    ipn  = round(ipn_base * 0.10)
    total_deductions = opv + osms + pitanie + ipn
    net_pay = total_accruals - total_deductions

    advance = round(net_pay * 0.45)
    final   = net_pay - advance
    next_month = month + 1 if month < 12 else 1
    next_year  = year if month < 12 else year + 1
    period_str = f'{month:02d}.{year}'

    pos, dept, _ = _EMP_META.get(emp_id, ('Сотрудник', 'Общий отдел', ''))
    ps = Payslip(
        employee_id=emp_id, period_month=month, period_year=year,
        period_display=f'{_MONTH_RU[month]} {year}',
        total_accruals=float(total_accruals),
        total_deductions=float(total_deductions),
        net_pay=float(net_pay), total_paid=float(net_pay),
        position=pos, department=dept,
        salary_rate=float(oklad), debt_start=0.0, debt_end=0.0,
    )
    db.session.add(ps)
    db.session.flush()

    # --- Начислено ---
    db.session.add(PayslipAccrual(
        payslip_id=ps.id, name='Оплата по окладу', amount=float(pay_oklad),
        period=period_str, working_days=worked_days, working_hours=float(worked_hours)))
    db.session.add(PayslipAccrual(
        payslip_id=ps.id, name='Премия постоянная', amount=float(premiya),
        period=period_str))
    db.session.add(PayslipAccrual(
        payslip_id=ps.id, name='Выплаты вследствии экологического бедствия',
        amount=float(ekologia), period=period_str))
    if vac_pay:
        db.session.add(PayslipAccrual(
            payslip_id=ps.id, name='Оплата ежегодного отпуска',
            amount=float(vac_pay), period=period_str))

    # --- Удержано ---
    for name, amt in [('ИПН', ipn), ('ОПВ', opv),
                      ('Взносы ОСМС', osms), ('Питание', pitanie)]:
        db.session.add(PayslipDeduction(
            payslip_id=ps.id, name=name, amount=float(amt), period=period_str))

    # --- Выплачено ---
    db.session.add(PayslipPaid(
        payslip_id=ps.id, payment_type='Аванс', period=period_str,
        document=f'Ведомость №{month * 2 - 1}',
        date=f'15.{month:02d}.{year}', amount=float(advance)))
    db.session.add(PayslipPaid(
        payslip_id=ps.id, payment_type='Зарплата за месяц', period=period_str,
        document=f'Ведомость №{month * 2}',
        date=f'05.{next_month:02d}.{next_year}', amount=float(final)))

    # --- Льготы ---
    db.session.add(PayslipBenefit(payslip_id=ps.id, name='Вычет ОПВ', amount=float(opv)))
    db.session.add(PayslipBenefit(payslip_id=ps.id, name='Вычет ВОСМС', amount=float(osms)))
    db.session.add(PayslipBenefit(
        payslip_id=ps.id, name='Стандартный 14 МРП (1 МЗП)', amount=float(standard_deduction)))

    # --- Справочно ---
    db.session.add(PayslipReference(
        payslip_id=ps.id, name='Обязательные пенсионные взносы работодателя',
        amount=float(round(total_accruals * 0.05))))
    db.session.add(PayslipReference(
        payslip_id=ps.id, name='Отчисления на ОСМС',
        amount=float(round(total_accruals * 0.03))))
    db.session.add(PayslipReference(
        payslip_id=ps.id, name='Социальные отчисления',
        amount=float(round(total_accruals * 0.095))))
    db.session.add(PayslipReference(
        payslip_id=ps.id, name='Социальный налог',
        amount=float(round(total_accruals * 0.0525))))


def _seed_kumarova():
    """Add employee 1874 (Кумарова), Sep 2025 payslip, and Sep 2025 access records."""
    from datetime import date as _date

    # ── Employee ──────────────────────────────────────────────────────────────
    if not Employee.query.filter_by(employee_id='1874').first():
        db.session.add(Employee(
            employee_id='1874',
            full_name='Кумарова Мадина Кумаровна',
            job_title='Специалист по кадрам',
        ))
        db.session.flush()

    # ── Payslip September 2025 ────────────────────────────────────────────────
    if not Payslip.query.filter_by(employee_id='1874', period_year=2025, period_month=9).first():
        ps = Payslip(
            employee_id='1874',
            period_month=9,
            period_year=2025,
            period_display='Сентябрь 2025',
            total_accruals=684_780.0,
            total_deductions=145_514.0,
            net_pay=539_266.0,
            total_paid=392_682.0,
            position='Специалист по кадрам',
            department='Отдел правового и административного обеспечения',
            salary_rate=334_464.0,
            debt_start=122_281.0,
            debt_end=268_865.0,
        )
        db.session.add(ps)
        db.session.flush()

        p = '09.2025'
        db.session.add(PayslipAccrual(
            payslip_id=ps.id, name='Выплаты вследствии экологического бедствия',
            amount=5_898.0, period=p))
        db.session.add(PayslipAccrual(
            payslip_id=ps.id, name='Премия постоянная для ср (доп)',
            amount=334_464.0, period=p))
        db.session.add(PayslipAccrual(
            payslip_id=ps.id, name='Оплата по окладу',
            amount=344_418.0, period=p, working_days=22, working_hours=173.0))

        for name, amt in [
            ('ИПН',          54_225.0),
            ('ОПВ',          67_888.0),
            ('Взносы ОСМС',  13_696.0),
            ('Питание',       9_705.0),
        ]:
            db.session.add(PayslipDeduction(payslip_id=ps.id, name=name, amount=amt, period=p))

        db.session.add(PayslipPaid(
            payslip_id=ps.id, payment_type='За первую половину месяца',
            period=p, document='вед. № 2', date='03.09.2025', amount=2_000.0))
        db.session.add(PayslipPaid(
            payslip_id=ps.id, payment_type='Зарплата за месяц',
            period='08.2025', document='вед. № 1', date='08.09.2025', amount=122_281.0))
        db.session.add(PayslipPaid(
            payslip_id=ps.id, payment_type='Премии, межрасчет',
            period=p, document='вед. № 18', date='26.09.2025', amount=268_401.0))

        db.session.add(PayslipBenefit(payslip_id=ps.id, name='Вычет ОПВ',                    amount=67_888.0))
        db.session.add(PayslipBenefit(payslip_id=ps.id, name='Вычет ВОСМС',                  amount=13_696.0))
        db.session.add(PayslipBenefit(payslip_id=ps.id, name='Стандартный 14 МРП (1 МЗП)',   amount=55_048.0))

        db.session.add(PayslipReference(payslip_id=ps.id, name='Обязательные пенсионные взносы работодателя', amount=16_972.0))
        db.session.add(PayslipReference(payslip_id=ps.id, name='Отчисления на ОСМС',         amount=20_543.0))
        db.session.add(PayslipReference(payslip_id=ps.id, name='Социальные отчисления',      amount=29_750.0))
        db.session.add(PayslipReference(payslip_id=ps.id, name='Социальный налог',           amount=35_953.0))

    # ── Access records September 2025 ─────────────────────────────────────────
    if not AccessRecord.query.filter_by(
        employee_id='1874'
    ).filter(
        AccessRecord.access_date >= _date(2025, 9, 1),
        AccessRecord.access_date <= _date(2025, 9, 30),
    ).first():
        _SEP_2025 = [
            (_date(2025, 9,  2), '07:38', 'Вход'),   (_date(2025, 9,  2), '17:06', 'Выход'),
            (_date(2025, 9,  3), '07:41', 'Вход'),   (_date(2025, 9,  3), '17:10', 'Выход'),
            (_date(2025, 9,  4), '07:39', 'Вход'),   (_date(2025, 9,  4), '17:10', 'Выход'),
            (_date(2025, 9,  5), '12:09', 'Вход'),   (_date(2025, 9,  5), '17:57', 'Выход'),
            (_date(2025, 9,  8), '07:41', 'Вход'),   (_date(2025, 9,  8), '17:07', 'Выход'),
            (_date(2025, 9,  9), '07:35', 'Вход'),   (_date(2025, 9,  9), '17:07', 'Выход'),
            (_date(2025, 9, 10), '07:43', 'Вход'),   (_date(2025, 9, 10), '17:48', 'Выход'),
            (_date(2025, 9, 11), '07:32', 'Вход'),   (_date(2025, 9, 11), '17:09', 'Выход'),
            (_date(2025, 9, 12), '07:28', 'Вход'),   (_date(2025, 9, 12), '17:08', 'Выход'),
            (_date(2025, 9, 15), '07:41', 'Вход'),   (_date(2025, 9, 15), '17:09', 'Выход'),
            (_date(2025, 9, 16), '07:39', 'Вход'),   (_date(2025, 9, 16), '17:03', 'Выход'),
            (_date(2025, 9, 17), '07:39', 'Вход'),   (_date(2025, 9, 17), '17:07', 'Выход'),
            (_date(2025, 9, 18), '07:34', 'Вход'),   (_date(2025, 9, 18), '17:11', 'Выход'),
            (_date(2025, 9, 19), '07:40', 'Вход'),   (_date(2025, 9, 19), '17:06', 'Выход'),
            (_date(2025, 9, 22), '07:41', 'Вход'),   (_date(2025, 9, 22), '17:06', 'Выход'),
            (_date(2025, 9, 23), '07:40', 'Вход'),   (_date(2025, 9, 23), '17:03', 'Выход'),
            (_date(2025, 9, 25), '07:39', 'Вход'),   (_date(2025, 9, 25), '17:07', 'Выход'),
            (_date(2025, 9, 26), '07:41', 'Вход'),   (_date(2025, 9, 26), '17:06', 'Выход'),
            (_date(2025, 9, 29), '17:06', 'Выход'),
            (_date(2025, 9, 30), '07:36', 'Вход'),   (_date(2025, 9, 30), '17:08', 'Выход'),
        ]
        for d, t, ev in _SEP_2025:
            db.session.add(AccessRecord(
                employee_id='1874',
                access_date=d,
                access_time=t,
                event_type=ev,
                door_location='Турникет 2',
            ))

    db.session.commit()
    logging.info('Seeded employee 1874 (Кумарова) with Sep 2025 payslip and access records')


def _seed_april_2026_access_001():
    """Replace April 2026 turnstile records for emp 001 with real data from the XML export."""
    from datetime import date as _date
    AccessRecord.query.filter(
        AccessRecord.employee_id == '001',
        AccessRecord.access_date >= _date(2026, 4, 1),
        AccessRecord.access_date <= _date(2026, 4, 30),
    ).delete()
    db.session.flush()

    _APRIL_2026_ACCESS = [
        (_date(2026,  4,  1), '07:53', 'Вход'),
        (_date(2026,  4,  1), '17:09', 'Выход'),
        (_date(2026,  4,  2), '07:53', 'Вход'),
        (_date(2026,  4,  2), '18:07', 'Выход'),
        (_date(2026,  4,  3), '07:53', 'Вход'),
        (_date(2026,  4,  3), '17:13', 'Выход'),
        (_date(2026,  4,  6), '07:47', 'Вход'),
        (_date(2026,  4,  6), '17:10', 'Выход'),
        (_date(2026,  4,  7), '07:49', 'Вход'),
        (_date(2026,  4,  7), '17:16', 'Выход'),
        (_date(2026,  4,  8), '07:54', 'Вход'),
        (_date(2026,  4,  8), '17:10', 'Выход'),
        (_date(2026,  4,  9), '07:52', 'Вход'),
        (_date(2026,  4,  9), '17:11', 'Выход'),
        (_date(2026,  4, 10), '07:50', 'Вход'),
        (_date(2026,  4, 10), '10:22', 'Выход'),
        (_date(2026,  4, 10), '11:46', 'Вход'),
        (_date(2026,  4, 10), '11:59', 'Выход'),
        (_date(2026,  4, 10), '13:20', 'Вход'),
        (_date(2026,  4, 10), '17:07', 'Выход'),
        (_date(2026,  4, 13), '07:54', 'Вход'),
        (_date(2026,  4, 13), '17:14', 'Выход'),
        (_date(2026,  4, 14), '07:54', 'Вход'),
        (_date(2026,  4, 14), '17:30', 'Выход'),
        (_date(2026,  4, 15), '07:51', 'Вход'),
        (_date(2026,  4, 15), '17:11', 'Выход'),
        (_date(2026,  4, 16), '07:51', 'Вход'),
        (_date(2026,  4, 16), '17:15', 'Выход'),
        (_date(2026,  4, 17), '07:51', 'Вход'),
        (_date(2026,  4, 20), '07:54', 'Вход'),
        (_date(2026,  4, 20), '11:59', 'Выход'),
        (_date(2026,  4, 20), '13:29', 'Вход'),
        (_date(2026,  4, 20), '17:11', 'Выход'),
        (_date(2026,  4, 21), '07:41', 'Вход'),
        (_date(2026,  4, 21), '17:13', 'Выход'),
        (_date(2026,  4, 22), '07:45', 'Вход'),
        (_date(2026,  4, 22), '17:36', 'Выход'),
        (_date(2026,  4, 23), '07:52', 'Вход'),
        (_date(2026,  4, 23), '17:12', 'Выход'),
        (_date(2026,  4, 24), '07:53', 'Вход'),
        (_date(2026,  4, 24), '18:20', 'Выход'),
        (_date(2026,  4, 24), '22:32', 'Вход'),
        (_date(2026,  4, 24), '22:40', 'Выход'),
        (_date(2026,  4, 26), '10:24', 'Вход'),
        (_date(2026,  4, 26), '12:57', 'Выход'),
        (_date(2026,  4, 27), '07:57', 'Вход'),
        (_date(2026,  4, 27), '17:15', 'Выход'),
        (_date(2026,  4, 28), '07:52', 'Вход'),
        (_date(2026,  4, 28), '17:12', 'Выход'),
        (_date(2026,  4, 29), '07:39', 'Вход'),
        (_date(2026,  4, 29), '17:19', 'Выход'),
        (_date(2026,  4, 30), '14:13', 'Вход'),
    ]

    for d, t, ev in _APRIL_2026_ACCESS:
        db.session.add(AccessRecord(
            employee_id='001',
            access_date=d,
            access_time=t,
            event_type=ev,
            door_location='Турникет 1',
        ))
    db.session.commit()
    logging.info(f'Seeded {len(_APRIL_2026_ACCESS)} April 2026 access records for emp 001')


def _update_april_2026_001():
    """Replace April 2026 payslip for emp 001 with exact data from the official PDF payslip."""
    existing = Payslip.query.filter_by(employee_id='001', period_year=2026, period_month=4).all()
    for ps in existing:
        PayslipAccrual.query.filter_by(payslip_id=ps.id).delete()
        PayslipDeduction.query.filter_by(payslip_id=ps.id).delete()
        PayslipPaid.query.filter_by(payslip_id=ps.id).delete()
        PayslipBenefit.query.filter_by(payslip_id=ps.id).delete()
        PayslipReference.query.filter_by(payslip_id=ps.id).delete()
        db.session.delete(ps)
    db.session.flush()

    ps = Payslip(
        employee_id='001',
        period_month=4,
        period_year=2026,
        period_display='Апрель 2026',
        total_accruals=332_608.0,
        total_deductions=52_249.0,
        net_pay=280_359.0,
        total_paid=277_770.0,
        position='Техник-программист',
        department='Отдел информационных технологий и связи',
        salary_rate=326_120.0,
        debt_start=277_770.0,
        debt_end=280_359.0,
    )
    db.session.add(ps)
    db.session.flush()

    period = '04.2026'

    db.session.add(PayslipAccrual(
        payslip_id=ps.id, name='Оклад по дням', amount=326_120.0,
        period=period, working_days=22, working_hours=176.0))
    db.session.add(PayslipAccrual(
        payslip_id=ps.id, name='Выплаты вследствии экологического бедствия',
        amount=6_488.0, period=period))

    db.session.add(PayslipDeduction(
        payslip_id=ps.id, name='Профсоюзный сбор', amount=3_261.0, period=period))
    db.session.add(PayslipDeduction(
        payslip_id=ps.id, name='ИПН исчисленный', amount=16_376.0, period=period))
    db.session.add(PayslipDeduction(
        payslip_id=ps.id, name='ОПВ исчисленные', amount=32_612.0, period=period))

    db.session.add(PayslipPaid(
        payslip_id=ps.id, payment_type='Перечислено в банк',
        period=period, document='ЗП000000689', date='09.04.2026', amount=277_770.0))

    db.session.add(PayslipBenefit(payslip_id=ps.id, name='Вычет ОПВ', amount=32_612.0))
    db.session.add(PayslipBenefit(payslip_id=ps.id, name='Базовый вычет', amount=129_750.0))

    db.session.commit()
    logging.info('Seeded April 2026 payslip for emp 001 from official PDF')


def _add_access_days(emp_id, start_date, end_date, holidays, absences=None):
    """Add Вход/Выход records for every working day in [start_date, end_date]."""
    from datetime import timedelta
    absences = absences or set()
    entry_times = ['08:45', '08:55', '09:05']
    exit_times  = ['17:45', '18:00', '18:15']
    _, _, door = _EMP_META.get(emp_id, ('', '', 'Главный вход'))
    records = []
    d = start_date
    while d <= end_date:
        if d.weekday() < 5 and d not in holidays and d not in absences:
            idx = d.timetuple().tm_yday % 3
            records.append(AccessRecord(
                employee_id=emp_id, access_date=d,
                access_time=entry_times[idx], event_type='Вход', door_location=door))
            records.append(AccessRecord(
                employee_id=emp_id, access_date=d,
                access_time=exit_times[idx], event_type='Выход', door_location=door))
        d += timedelta(days=1)
    db.session.add_all(records)


# ---------------------------------------------------------------------------
# Seeding: март–декабрь 2024
# ---------------------------------------------------------------------------

def _seed_2024_full():
    if AccessRecord.query.filter(AccessRecord.access_date == date(2024, 3, 4)).first():
        return

    holidays = {
        date(2024, 3, 8),   # Международный женский день
        date(2024, 3, 21),  # Наурыз
        date(2024, 3, 22),
        date(2024, 5, 1),   # День единства народа
        date(2024, 5, 7),   # День защитника Отечества
        date(2024, 5, 9),   # День Победы
        date(2024, 7, 8),   # День столицы (6 июл — сб, перенос на пн)
        date(2024, 8, 30),  # День Конституции
        date(2024, 10, 25), # День Республики
        date(2024, 12, 2),  # Первый Президент (1 дек — вс, перенос)
        date(2024, 12, 16), # День Независимости
        date(2024, 12, 17),
    }

    # Отпуск 002: август 5-16 (10 рабочих дней)
    abs_002 = {date(2024, 8, d) for d in range(5, 17)}
    # Больничный 003: май 13-17 (5 дней)
    abs_003 = {date(2024, 5, d) for d in range(13, 18)}

    start = date(2024, 3, 1)
    end   = date(2024, 12, 31)
    _add_access_days('001', start, end, holidays)
    _add_access_days('002', start, end, holidays, abs_002)
    _add_access_days('003', start, end, holidays, abs_003)

    # Расчётные листки март–декабрь 2024
    salaries = [('001', 350_000), ('002', 500_000), ('003', 280_000)]
    std_ded  = 55_048  # 14 МРП × 3 932 тг (МРП 2024)

    for emp_id, oklad in salaries:
        for month in range(3, 13):
            vac = 10 if (emp_id == '002' and month == 8) else \
                   5 if (emp_id == '003' and month == 5) else 0
            _add_payslip(emp_id, month, 2024, oklad, std_ded, vacation_days=vac)

    db.session.commit()


# ---------------------------------------------------------------------------
# Seeding: январь–декабрь 2025
# ---------------------------------------------------------------------------

def _seed_2025_full():
    if AccessRecord.query.filter(AccessRecord.access_date == date(2025, 1, 3)).first():
        return

    holidays = {
        date(2025, 1, 1),   # Новый год
        date(2025, 1, 2),
        date(2025, 1, 7),   # Рождество
        date(2025, 3, 10),  # Международный женский день (8 мар — сб, перенос на пн)
        date(2025, 3, 21),  # Наурыз
        date(2025, 3, 24),  # Наурыз (21 пт; 22 сб; 23 вс → 24 пн перенос)
        date(2025, 5, 1),   # День единства народа
        date(2025, 5, 7),   # День защитника Отечества
        date(2025, 5, 9),   # День Победы
        date(2025, 7, 7),   # День столицы (6 июл — вс, перенос на пн)
        date(2025, 9, 1),   # День Конституции (30 авг — сб, перенос на пн)
        date(2025, 10, 27), # День Республики (25 окт — сб, перенос на пн)
        date(2025, 12, 1),  # Первый Президент
        date(2025, 12, 16), # День Независимости
        date(2025, 12, 17),
    }

    # Отпуск 001: июль 8-18 (10 рабочих дней; 7 — праздник)
    abs_001 = {date(2025, 7, d) for d in range(8, 19)}
    # Отпуск 002: август 4-15 (10 рабочих дней)
    abs_002 = {date(2025, 8, d) for d in range(4, 16)}
    # Больничный 003: март 10-14 (перекрывается с праздником 10 мар; реальных 4 дня)
    abs_003 = {date(2025, 3, d) for d in range(10, 15)}

    start = date(2025, 1, 1)
    end   = date(2025, 12, 31)
    _add_access_days('001', start, end, holidays, abs_001)
    _add_access_days('002', start, end, holidays, abs_002)
    _add_access_days('003', start, end, holidays, abs_003)

    # Расчётные листки январь–декабрь 2025 (+5% индексация)
    salaries = [('001', 367_500), ('002', 525_000), ('003', 294_000)]
    std_ded  = 57_120  # 14 МРП × 4 080 тг (МРП 2025 приблизительно)

    for emp_id, oklad in salaries:
        for month in range(1, 13):
            vac = 10 if (emp_id == '001' and month == 7) else \
                  10 if (emp_id == '002' and month == 8) else \
                   4 if (emp_id == '003' and month == 3) else 0
            _add_payslip(emp_id, month, 2025, oklad, std_ded, vacation_days=vac)

    db.session.commit()


def _seed_may_2026():
    """Расчётные листы и записи турникета за май 2026 (текущий месяц)."""
    std_ded = 60_536  # 14 МРП × 4 324 тг (МРП 2026)
    salaries = [('001', 386_500), ('002', 558_000), ('003', 303_000)]
    added = False
    for emp_id, oklad in salaries:
        if not Payslip.query.filter_by(
            employee_id=emp_id, period_month=5, period_year=2026
        ).first():
            _add_payslip(emp_id, 5, 2026, oklad, std_ded)
            added = True
    if added:
        db.session.commit()

    # Записи турникета за 1-15 мая 2026 (только если ещё нет)
    if AccessRecord.query.filter(
        AccessRecord.access_date == date(2026, 5, 1),
        AccessRecord.employee_id == '001'
    ).first():
        return

    work_days = [1, 5, 6, 7, 8, 12, 13, 14, 15]
    times = [('001', '08:52', '18:10'), ('002', '08:30', '18:45'), ('003', '08:42', '17:50')]
    for emp_id, t_in, t_out in times:
        for d in work_days:
            db.session.add(AccessRecord(
                employee_id=emp_id,
                access_date=date(2026, 5, d),
                access_time=t_in,
                event_type='Вход',
                door_location='Главный вход'))
            db.session.add(AccessRecord(
                employee_id=emp_id,
                access_date=date(2026, 5, d),
                access_time=t_out,
                event_type='Выход',
                door_location='Главный вход'))
    db.session.commit()


def _ensure_all_payslips():
    """Catch-all: adds any missing payslips for 2024-2026 for the three demo employees.

    Runs after other seeders so it fills gaps left by any that failed silently.
    Fully idempotent — safe to run on every startup.
    """
    salaries = [('001', 380_000), ('002', 550_000), ('003', 300_000)]
    std_ded = 60_536
    added = 0
    for year, months in [(2024, range(1, 13)), (2025, range(1, 13)), (2026, range(1, 6))]:
        for emp_id, oklad in salaries:
            if not Employee.query.filter_by(employee_id=emp_id).first():
                continue
            for month in months:
                if not Payslip.query.filter_by(
                    employee_id=emp_id, period_year=year, period_month=month
                ).first():
                    _add_payslip(emp_id, month, year, oklad, std_ded)
                    added += 1
    if added:
        db.session.commit()
        logging.info(f'_ensure_all_payslips: added {added} missing payslip(s)')


def _ensure_payslips_jan_apr_2026():
    """Backfill Jan–Apr 2026 payslips for all employees if any were missed."""
    salaries = [('001', 380_000), ('002', 550_000), ('003', 300_000)]
    std_ded = 60_536  # 14 МРП × 4 324 тг (МРП 2026)
    added = False
    for emp_id, oklad in salaries:
        for month in range(1, 5):
            exists = Payslip.query.filter_by(
                employee_id=emp_id, period_year=2026, period_month=month
            ).first()
            if not exists:
                _add_payslip(emp_id, month, 2026, oklad, std_ded)
                added = True
                logging.info(f'Backfilled payslip {emp_id}/{month}/2026')
    if added:
        db.session.commit()


def _seed_turnstile_events():
    """TurnstileEvent — демо-данные для экрана «Проходы сотрудников»."""
    if TurnstileEvent.query.filter(
        TurnstileEvent.timestamp >= datetime(2026, 5, 1)
    ).first():
        return

    employees = [
        ('001', 'Сарсекенов Батырхан Арманұлы'),
        ('002', 'Касымов Нурлан Серикович'),
        ('003', 'Сидорова Анна Сергеевна'),
    ]
    work_days = [1, 5, 6, 7, 8, 12, 13, 14, 15]
    in_times  = ['08:52', '08:30', '08:42', '08:55', '08:35', '08:45',
                 '08:58', '08:28', '08:50']
    out_times = ['18:10', '18:45', '17:50', '18:05', '19:00', '17:55',
                 '18:12', '18:50', '17:48']
    for emp_id, _ in employees:
        for i, d in enumerate(work_days):
            t_in  = in_times[i % len(in_times)]
            t_out = out_times[i % len(out_times)]
            h_in,  m_in  = map(int, t_in.split(':'))
            h_out, m_out = map(int, t_out.split(':'))
            db.session.add(TurnstileEvent(
                employee_id=emp_id,
                direction='in',
                timestamp=datetime(2026, 5, d, h_in, m_in)))
            db.session.add(TurnstileEvent(
                employee_id=emp_id,
                direction='out',
                timestamp=datetime(2026, 5, d, h_out, m_out)))

    db.session.commit()


# ── docx payslip data (employees + Jan–Apr 2026 payslips with line items) ──
# employee_id, full_name, job_title
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
    ('0000002148', 'Диппель Ольга Владимировна', 'Повар'),
    ('0000002162', 'Науканов Мерхат Кайсарович', 'Менеджер'),
]

# Each payslip: dict with totals + accrual/deduction line items
# accrual item = (name, amount, period, working_days, working_hours)
# deduction item = (name, amount, period)
_DOCX_PAYSLIPS = [
    {
        'employee_id': '0000000044', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 361988.0, 'total_deductions': 64765.0, 'net_pay': 297223.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 375250.0, 'position': 'Технолог', 'department': 'Столовая',
        'accruals': [
            ('Оклад по дням', 296250.0, 'Янв 26', 15, 120.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Янв 26', None, None),
            ('Доплата за выслугу лет (по дням)', 59250.0, 'Янв 26', 15, 120.0),
        ],
        'deductions': [
            ('Питание', 716.0, 'Янв 26'),
            ('Профсоюзный сбор', 2963.0, 'Янв 26'),
            ('ИПН исчисленный', 18296.0, 'Янв 26'),
            ('ОПВ исчисленные', 35550.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 7240.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000000044', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 498998.0, 'total_deductions': 94907.0, 'net_pay': 404091.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 375250.0, 'position': 'Технолог', 'department': 'Столовая',
        'accruals': [
            ('Доплата', 42210.0, 'Фев 26', None, None),
            ('Оклад по дням', 375250.0, 'Фев 26', 20, 160.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
            ('Доплата за выслугу лет (по дням)', 75050.0, 'Фев 26', 20, 160.0),
        ],
        'deductions': [
            ('Питание', 1570.0, 'Фев 26'),
            ('Профсоюзный сбор', 3753.0, 'Фев 26'),
            ('ИПН исчисленный', 30353.0, 'Фев 26'),
            ('ОПВ исчисленные', 49251.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 9980.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000000044', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 621530.0, 'total_deductions': 121567.0, 'net_pay': 499963.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 375250.0, 'position': 'Технолог', 'department': 'Столовая',
        'accruals': [
            ('Доплата', 54726.0, 'Мар 26', None, None),
            ('Оклад по дням', 396097.0, 'Мар 26', 19, 152.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
            ('Доплата за выслугу лет (по дням)', 79219.0, 'Мар 26', 19, 152.0),
            ('Премия разовая', 85000.0, 'Мар 26', None, None),
        ],
        'deductions': [
            ('Питание', 1842.0, 'Мар 26'),
            ('Профсоюзный сбор', 3961.0, 'Мар 26'),
            ('ИПН исчисленный', 41429.0, 'Мар 26'),
            ('ОПВ исчисленные', 61838.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 12497.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000000044', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 456788.0, 'total_deductions': 88123.0, 'net_pay': 368665.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 375250.0, 'position': 'Технолог', 'department': 'Столовая',
        'accruals': [
            ('Оклад по дням', 375250.0, 'Апр 26', 22, 176.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
            ('Доплата за выслугу лет (по дням)', 75050.0, 'Апр 26', 22, 176.0),
        ],
        'deductions': [
            ('Питание', 3566.0, 'Апр 26'),
            ('Профсоюзный сбор', 3753.0, 'Апр 26'),
            ('ИПН исчисленный', 26638.0, 'Апр 26'),
            ('ОПВ исчисленные', 45030.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 9136.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000000644', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 310777.0, 'total_deductions': 169010.0, 'net_pay': 141767.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 350393.0, 'position': 'Заведующий складом', 'department': 'Служба учета ТМЦ',
        'accruals': [
            ('Оклад по дням', 276626.0, 'Янв 26', 15, 120.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Янв 26', None, None),
            ('Доплата за выслугу лет (по дням)', 27663.0, 'Янв 26', 15, 120.0),
        ],
        'deductions': [
            ('Вознаграждение по займу', 11626.0, 'Янв 26'),
            ('Займ', 97222.0, 'Янв 26'),
            ('Питание', 6962.0, 'Янв 26'),
            ('Профсоюзный сбор', 2766.0, 'Янв 26'),
            ('ИПН исчисленный', 13789.0, 'Янв 26'),
            ('ОПВ исчисленные', 30429.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 6216.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000000644', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 133885.0, 'total_deductions': 125078.0, 'net_pay': 8807.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 350393.0, 'position': 'Заведующий складом', 'department': 'Служба учета ТМЦ',
        'accruals': [
            ('Оклад по дням', 17520.0, 'Фев 26', 1, 8.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
            ('Доплата за выслугу лет (по дням)', 1752.0, 'Фев 26', 1, 8.0),
            ('Оплата больничных листов', 108125.0, '3-17 Фев 26', 11, 88.0),
        ],
        'deductions': [
            ('Вознаграждение по займу', 11343.0, 'Фев 26'),
            ('Займ', 97222.0, 'Фев 26'),
            ('Питание', 920.0, 'Фев 26'),
            ('Профсоюзный сбор', 175.0, 'Фев 26'),
            ('ОПВ исчисленные', 12740.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 2678.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000000644', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 415679.0, 'total_deductions': 193838.0, 'net_pay': 221841.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 350393.0, 'position': 'Заведующий складом', 'department': 'Служба учета ТМЦ',
        'accruals': [
            ('Оклад по дням', 311460.0, 'Мар 26', 16, 128.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
            ('Доплата за выслугу лет (по дням)', 31146.0, 'Мар 26', 16, 128.0),
            ('Оплата больничных листов', 66585.0, '1-4 Мар 26', 3, 24.0),
        ],
        'deductions': [
            ('Вознаграждение по займу', 11059.0, 'Мар 26'),
            ('Займ', 97222.0, 'Мар 26'),
            ('Питание', 11272.0, 'Мар 26'),
            ('Профсоюзный сбор', 3115.0, 'Мар 26'),
            ('ИПН исчисленный', 21537.0, 'Мар 26'),
            ('ОПВ исчисленные', 41253.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 8380.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000000644', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 391920.0, 'total_deductions': 196252.0, 'net_pay': 195668.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 350393.0, 'position': 'Заведующий складом', 'department': 'Служба учета ТМЦ',
        'accruals': [
            ('Оклад по дням', 350393.0, 'Апр 26', 22, 176.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
            ('Доплата за выслугу лет (по дням)', 35039.0, 'Апр 26', 22, 176.0),
        ],
        'deductions': [
            ('Вознаграждение по займу', 10775.0, 'Апр 26'),
            ('Займ', 97222.0, 'Апр 26'),
            ('Питание', 17440.0, 'Апр 26'),
            ('Профсоюзный сбор', 3504.0, 'Апр 26'),
            ('ИПН исчисленный', 20930.0, 'Апр 26'),
            ('ОПВ исчисленные', 38543.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 7838.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000000674', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 310777.0, 'total_deductions': 54323.0, 'net_pay': 256454.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 350393.0, 'position': 'Заведующий складом', 'department': 'Служба учета ТМЦ',
        'accruals': [
            ('Оклад по дням', 276626.0, 'Янв 26', 15, 120.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Янв 26', None, None),
            ('Доплата за выслугу лет (по дням)', 27663.0, 'Янв 26', 15, 120.0),
        ],
        'deductions': [
            ('Питание', 1123.0, 'Янв 26'),
            ('Профсоюзный сбор', 2766.0, 'Янв 26'),
            ('ИПН исчисленный', 13789.0, 'Янв 26'),
            ('ОПВ исчисленные', 30429.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 6216.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000000674', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 391920.0, 'total_deductions': 71752.0, 'net_pay': 320168.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 350393.0, 'position': 'Заведующий складом', 'department': 'Служба учета ТМЦ',
        'accruals': [
            ('Оклад по дням', 350393.0, 'Фев 26', 20, 160.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
            ('Доплата за выслугу лет (по дням)', 35039.0, 'Фев 26', 20, 160.0),
        ],
        'deductions': [
            ('Питание', 937.0, 'Фев 26'),
            ('Профсоюзный сбор', 3504.0, 'Фев 26'),
            ('ИПН исчисленный', 20930.0, 'Фев 26'),
            ('ОПВ исчисленные', 38543.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 7838.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000000674', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 498333.0, 'total_deductions': 94147.0, 'net_pay': 404186.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 350393.0, 'position': 'Заведующий складом', 'department': 'Служба учета ТМЦ',
        'accruals': [
            ('Оклад по дням', 369859.0, 'Мар 26', 19, 152.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
            ('Доплата за выслугу лет (по дням)', 36986.0, 'Мар 26', 19, 152.0),
            ('Премия разовая', 85000.0, 'Мар 26', None, None),
        ],
        'deductions': [
            ('Питание', 309.0, 'Мар 26'),
            ('Профсоюзный сбор', 3699.0, 'Мар 26'),
            ('ИПН исчисленный', 30588.0, 'Мар 26'),
            ('ОПВ исчисленные', 49518.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 10033.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000000674', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 391920.0, 'total_deductions': 73412.0, 'net_pay': 318508.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 350393.0, 'position': 'Заведующий складом', 'department': 'Служба учета ТМЦ',
        'accruals': [
            ('Оклад по дням', 350393.0, 'Апр 26', 22, 176.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
            ('Доплата за выслугу лет (по дням)', 35039.0, 'Апр 26', 22, 176.0),
        ],
        'deductions': [
            ('Питание', 2597.0, 'Апр 26'),
            ('Профсоюзный сбор', 3504.0, 'Апр 26'),
            ('ИПН исчисленный', 20930.0, 'Апр 26'),
            ('ОПВ исчисленные', 38543.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 7838.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000000726', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 425070.0, 'total_deductions': 85790.0, 'net_pay': 339280.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 349395.0, 'position': 'Бухгалтер', 'department': 'Отдел бухгалтерского и налогового учета',
        'accruals': [
            ('Доплата', 10345.0, 'Янв 26', None, None),
            ('Оклад по дням', 358590.0, 'Янв 26', 19, 156.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Янв 26', None, None),
            ('Доплата за выслугу лет (по дням)', 35859.0, 'Янв 26', 19, 156.0),
            ('Доплата за сверхурочные часы', 13788.0, '15-30 Янв 26', 12, 12.0),
        ],
        'deductions': [
            ('Питание', 7998.0, 'Янв 26'),
            ('Профсоюзный сбор', 3586.0, 'Янв 26'),
            ('ИПН исчисленный', 23847.0, 'Янв 26'),
            ('ОПВ исчисленные', 41858.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 8501.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000000726', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 438866.0, 'total_deductions': 92571.0, 'net_pay': 346295.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 349395.0, 'position': 'Бухгалтер', 'department': 'Отдел бухгалтерского и налогового учета',
        'accruals': [
            ('Оклад по дням', 382151.0, 'Фев 26', 21, 175.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
            ('Доплата за выслугу лет (по дням)', 38215.0, 'Фев 26', 21, 175.0),
            ('Доплата за сверхурочные часы', 12012.0, '6-27 Фев 26', 11, 11.0),
        ],
        'deductions': [
            ('Питание', 11673.0, 'Фев 26'),
            ('Профсоюзный сбор', 3822.0, 'Фев 26'),
            ('ИПН исчисленный', 25061.0, 'Фев 26'),
            ('ОПВ исчисленные', 43238.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 8777.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000000726', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 519973.0, 'total_deductions': 97323.0, 'net_pay': 422650.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 349395.0, 'position': 'Бухгалтер', 'department': 'Отдел бухгалтерского и налогового учета',
        'accruals': [
            ('Оклад по дням', 327558.0, 'Мар 26', 17, 135.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
            ('Доплата за выслугу лет (по дням)', 32756.0, 'Мар 26', 17, 135.0),
            ('Доплата за сверхурочные часы', 3639.0, '3-17 Мар 26', 3, 3.0),
            ('Оплата отпуска', 64532.0, '18-20 Мар 26', 3, 24.0),
            ('Премия разовая', 85000.0, 'Мар 26', None, None),
        ],
        'deductions': [
            ('Питание', 9459.0, 'Мар 26'),
            ('Профсоюзный сбор', 3276.0, 'Мар 26'),
            ('ИПН исчисленный', 33239.0, 'Мар 26'),
            ('ОПВ исчисленные', 51349.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000000726', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 419413.0, 'total_deductions': 85444.0, 'net_pay': 333969.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 349395.0, 'position': 'Бухгалтер', 'department': 'Отдел бухгалтерского и налогового учета',
        'accruals': [
            ('Оклад по дням', 367262.0, 'Апр 26', 22, 185.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
            ('Доплата за выслугу лет (по дням)', 36726.0, 'Апр 26', 22, 185.0),
            ('Доплата за сверхурочные часы', 8937.0, '20-30 Апр 26', 9, 9.0),
        ],
        'deductions': [
            ('Питание', 16290.0, 'Апр 26'),
            ('Профсоюзный сбор', 3673.0, 'Апр 26'),
            ('ИПН исчисленный', 24188.0, 'Апр 26'),
            ('ОПВ исчисленные', 41293.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000000910', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 518661.0, 'total_deductions': 169595.0, 'net_pay': 349066.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 589775.0, 'position': 'Начальник отдела', 'department': 'Отдел технического контроля',
        'accruals': [
            ('Оклад по дням', 465612.0, 'Янв 26', 15, 120.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Янв 26', None, None),
            ('Доплата за выслугу лет (по дням)', 46561.0, 'Янв 26', 15, 120.0),
        ],
        'deductions': [
            ('Вознаграждение по займу', 8833.0, 'Янв 26'),
            ('Займ', 57143.0, 'Янв 26'),
            ('Питание', 5290.0, 'Янв 26'),
            ('Профсоюзный сбор', 4656.0, 'Янв 26'),
            ('ИПН исчисленный', 32083.0, 'Янв 26'),
            ('ОПВ исчисленные', 51217.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 10373.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000000910', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 655241.0, 'total_deductions': 217957.0, 'net_pay': 437284.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 589775.0, 'position': 'Начальник отдела', 'department': 'Отдел технического контроля',
        'accruals': [
            ('Оклад по дням', 589775.0, 'Фев 26', 20, 160.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
            ('Доплата за выслугу лет (по дням)', 58978.0, 'Фев 26', 20, 160.0),
        ],
        'deductions': [
            ('Вознаграждение по займу', 8667.0, 'Фев 26'),
            ('Займ', 57143.0, 'Фев 26'),
            ('Питание', 6695.0, 'Фев 26'),
            ('Профсоюзный сбор', 5898.0, 'Фев 26'),
            ('ИПН исчисленный', 51494.0, 'Фев 26'),
            ('ОПВ исчисленные', 73275.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 14785.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000000910', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 734532.0, 'total_deductions': 218958.0, 'net_pay': 515574.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 589775.0, 'position': 'Начальник отдела', 'department': 'Отдел технического контроля',
        'accruals': [
            ('Доплата', 43250.0, 'Мар 26', None, None),
            ('Оклад по дням', 622540.0, 'Мар 26', 19, 152.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
            ('Доплата за выслугу лет (по дням)', 62254.0, 'Мар 26', 19, 152.0),
        ],
        'deductions': [
            ('Вознаграждение по займу', 8500.0, 'Мар 26'),
            ('Займ', 57143.0, 'Мар 26'),
            ('Питание', 7822.0, 'Мар 26'),
            ('Профсоюзный сбор', 6225.0, 'Мар 26'),
            ('ИПН исчисленный', 51373.0, 'Мар 26'),
            ('ОПВ исчисленные', 73138.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 14757.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000000910', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 742400.0, 'total_deductions': 154191.0, 'net_pay': 588209.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 589775.0, 'position': 'Начальник отдела', 'department': 'Отдел технического контроля',
        'accruals': [
            ('Оклад по дням', 375311.0, 'Апр 26', 14, 112.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
            ('Доплата за выслугу лет (по дням)', 37531.0, 'Апр 26', 14, 112.0),
            ('Оплата отпуска экологического', 121151.0, '21-23 Апр 26', 3, 24.0),
            ('Оплата отпуска экологического', 201919.0, '24-30 Апр 26', 5, 40.0),
        ],
        'deductions': [
            ('Вознаграждение по займу', 8333.0, 'Апр 26'),
            ('Займ', 57143.0, 'Апр 26'),
            ('Питание', 6134.0, 'Апр 26'),
            ('Профсоюзный сбор', 3753.0, 'Апр 26'),
            ('ИПН исчисленный', 22696.0, 'Апр 26'),
            ('ОПВ исчисленные', 41284.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 14848.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000001093', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 403611.0, 'total_deductions': 120407.0, 'net_pay': 283204.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 413578.0, 'position': 'Контрольный мастер', 'department': 'Отдел технического контроля',
        'accruals': [
            ('Оклад по дням', 152371.0, 'Янв 26', 7, 56.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Янв 26', None, None),
            ('Доплата за выслугу лет (по дням)', 15237.0, 'Янв 26', 7, 56.0),
            ('Оплата отпуска экологического', 229515.0, '12-21 Янв 26', 8, 64.0),
        ],
        'deductions': [
            ('Профсоюзный сбор', 1524.0, 'Янв 26'),
            ('Удержание по исп. листу процентом (Жумадилова Ирина Анатольевна)', 92747.0, 'Янв 26'),
            ('ИПН исчисленный', 1303.0, 'Янв 26'),
            ('ОПВ исчисленные', 16761.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 8072.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000001093', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 461424.0, 'total_deductions': 208883.0, 'net_pay': 252541.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 413578.0, 'position': 'Контрольный мастер', 'department': 'Отдел технического контроля',
        'accruals': [
            ('Оклад по дням', 413578.0, 'Фев 26', 20, 160.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
            ('Доплата за выслугу лет (по дням)', 41358.0, 'Фев 26', 20, 160.0),
        ],
        'deductions': [
            ('Профсоюзный сбор', 4136.0, 'Фев 26'),
            ('Удержание по исп. листу процентом (Жумадилова Ирина Анатольевна)', 83396.0, 'Фев 26'),
            ('ИПН исчисленный', 43793.0, 'Фев 26'),
            ('ОПВ исчисленные', 64524.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 13034.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000001093', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 486698.0, 'total_deductions': 303128.0, 'net_pay': 183570.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 413578.0, 'position': 'Контрольный мастер', 'department': 'Отдел технического контроля',
        'accruals': [
            ('Оклад по дням', 436555.0, 'Мар 26', 19, 152.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
            ('Доплата за выслугу лет (по дням)', 43655.0, 'Мар 26', 19, 152.0),
        ],
        'deductions': [
            ('Профсоюзный сбор', 4366.0, 'Мар 26'),
            ('Удержание по исп. листу процентом (Жумадилова Ирина Анатольевна)', 91099.0, 'Мар 26'),
            ('Удержание подотчетной суммы', 91850.0, 'Мар 26'),
            ('ИПН исчисленный', 41450.0, 'Мар 26'),
            ('ОПВ исчисленные', 61861.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 12502.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000001093', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 1536098.0, 'total_deductions': 625933.0, 'net_pay': 910165.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 413578.0, 'position': 'Контрольный мастер', 'department': 'Отдел технического контроля',
        'accruals': [
            ('Оклад по дням', 375980.0, 'Апр 26', 20, 160.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
            ('Доплата за выслугу лет (по дням)', 37598.0, 'Апр 26', 20, 160.0),
            ('Материальная помощь', 827156.0, 'Апр 26', None, None),
            ('Оплата отпуска', 57775.0, '29-30 Апр 26', 2, 16.0),
            ('Оплата отпуска', 231101.0, '1-16 Май 26', 8, 64.0),
        ],
        'deductions': [
            ('Профсоюзный сбор', 3760.0, 'Апр 26'),
            ('Удержание по исп. листу процентом (Жумадилова Ирина Анатольевна)', 302479.0, 'Апр 26'),
            ('ИПН исчисленный', 127707.0, 'Апр 26'),
            ('ОПВ исчисленные', 159881.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 32106.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000001236', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 623431.0, 'total_deductions': 118127.0, 'net_pay': 505304.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 456331.0, 'position': 'Заместитель главного бухгалтера', 'department': 'Отдел бухгалтерского и налогового учета',
        'accruals': [
            ('Доплата', 54036.0, 'Янв 26', None, None),
            ('Оклад по дням', 495359.0, 'Янв 26', 20, 165.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Янв 26', None, None),
            ('Доплата за выслугу лет (по дням)', 49536.0, 'Янв 26', 20, 165.0),
            ('Доплата за сверхурочные часы', 18012.0, '12-27 Янв 26', 12, 12.0),
        ],
        'deductions': [
            ('Питание', 2661.0, 'Янв 26'),
            ('ИПН исчисленный', 41303.0, 'Янв 26'),
            ('ОПВ исчисленные', 61694.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 12469.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000001236', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 448875.0, 'total_deductions': 83166.0, 'net_pay': 365709.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 456331.0, 'position': 'Заместитель главного бухгалтера', 'department': 'Отдел бухгалтерского и налогового учета',
        'accruals': [
            ('Оклад по дням', 290911.0, 'Фев 26', 12, 102.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
            ('Доплата за выслугу лет (по дням)', 29091.0, 'Фев 26', 12, 102.0),
            ('Доплата за сверхурочные часы', 14260.0, '16-27 Фев 26', 10, 10.0),
            ('Оплата больничных листов', 108125.0, '3-13 Фев 26', 9, 72.0),
        ],
        'deductions': [
            ('Питание', 1098.0, 'Фев 26'),
            ('Профсоюзный сбор', 2909.0, 'Фев 26'),
            ('ИПН исчисленный', 25942.0, 'Фев 26'),
            ('ОПВ исчисленные', 44239.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 8978.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000001236', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 682177.0, 'total_deductions': 135198.0, 'net_pay': 546979.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 456331.0, 'position': 'Заместитель главного бухгалтера', 'department': 'Отдел бухгалтерского и налогового учета',
        'accruals': [
            ('Оклад по дням', 519710.0, 'Мар 26', 19, 164.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
            ('Доплата за выслугу лет (по дням)', 51971.0, 'Мар 26', 19, 164.0),
            ('Доплата за сверхурочные часы', 19008.0, '2-31 Мар 26', 12, 12.0),
            ('Премия разовая', 85000.0, 'Мар 26', None, None),
        ],
        'deductions': [
            ('Питание', 1623.0, 'Мар 26'),
            ('Профсоюзный сбор', 5197.0, 'Мар 26'),
            ('ИПН исчисленный', 46766.0, 'Мар 26'),
            ('ОПВ исчисленные', 67902.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 13710.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000001236', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 558228.0, 'total_deductions': 114085.0, 'net_pay': 444143.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 456331.0, 'position': 'Заместитель главного бухгалтера', 'department': 'Отдел бухгалтерского и налогового учета',
        'accruals': [
            ('Оклад по дням', 487444.0, 'Апр 26', 22, 188.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
            ('Доплата за выслугу лет (по дням)', 48744.0, 'Апр 26', 22, 188.0),
            ('Доплата за сверхурочные часы', 15552.0, '1-23 Апр 26', 12, 12.0),
        ],
        'deductions': [
            ('Питание', 7307.0, 'Апр 26'),
            ('Профсоюзный сбор', 4874.0, 'Апр 26'),
            ('ИПН исчисленный', 35565.0, 'Апр 26'),
            ('ОПВ исчисленные', 55174.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 11165.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000001295', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 401418.0, 'total_deductions': 84179.0, 'net_pay': 317239.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 454768.0, 'position': 'Главный менеджер', 'department': 'Планово-экономический отдел',
        'accruals': [
            ('Оклад по дням', 359027.0, 'Янв 26', 15, 120.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Янв 26', None, None),
            ('Доплата за выслугу лет (по дням)', 35903.0, 'Янв 26', 15, 120.0),
        ],
        'deductions': [
            ('Питание', 11302.0, 'Янв 26'),
            ('Профсоюзный сбор', 3590.0, 'Янв 26'),
            ('ИПН исчисленный', 21766.0, 'Янв 26'),
            ('ОПВ исчисленные', 39493.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 8028.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000001295', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 506733.0, 'total_deductions': 111917.0, 'net_pay': 394816.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 454768.0, 'position': 'Главный менеджер', 'department': 'Планово-экономический отдел',
        'accruals': [
            ('Оклад по дням', 454768.0, 'Фев 26', 20, 160.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
            ('Доплата за выслугу лет (по дням)', 45477.0, 'Фев 26', 20, 160.0),
        ],
        'deductions': [
            ('Питание', 16175.0, 'Фев 26'),
            ('Профсоюзный сбор', 4548.0, 'Фев 26'),
            ('ИПН исчисленный', 31034.0, 'Фев 26'),
            ('ОПВ исчисленные', 50025.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 10135.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000001295', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 1405706.0, 'total_deductions': 289614.0, 'net_pay': 1116092.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 454768.0, 'position': 'Главный менеджер', 'department': 'Планово-экономический отдел',
        'accruals': [
            ('Доплата', 786182.0, 'Мар 26', None, None),
            ('Оклад по дням', 480033.0, 'Мар 26', 19, 152.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
            ('Доплата за выслугу лет (по дням)', 48003.0, 'Мар 26', 19, 152.0),
            ('Премия разовая', 85000.0, 'Мар 26', None, None),
        ],
        'deductions': [
            ('Питание', 5941.0, 'Мар 26'),
            ('Профсоюзный сбор', 4800.0, 'Мар 26'),
            ('ИПН исчисленный', 110437.0, 'Мар 26'),
            ('ОПВ исчисленные', 140255.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 28181.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000001295', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 1789596.0, 'total_deductions': 367631.0, 'net_pay': 1421965.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 454768.0, 'position': 'Главный менеджер', 'department': 'Планово-экономический отдел',
        'accruals': [
            ('Доплата', 1249789.0, 'Апр 26', None, None),
            ('Оклад по дням', 475439.0, 'Апр 26', 22, 184.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
            ('Доплата за выслугу лет (по дням)', 47544.0, 'Апр 26', 22, 184.0),
            ('Доплата за сверхурочные часы', 10336.0, '21-30 Апр 26', 8, 8.0),
        ],
        'deductions': [
            ('Питание', 6461.0, 'Апр 26'),
            ('Профсоюзный сбор', 4754.0, 'Апр 26'),
            ('ИПН исчисленный', 144105.0, 'Апр 26'),
            ('ОПВ исчисленные', 178311.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 34000.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000001296', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 390042.0, 'total_deductions': 67927.0, 'net_pay': 322115.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 407399.0, 'position': 'Главный менеджер', 'department': 'Отдел правового и административного обеспечения',
        'accruals': [
            ('Оклад по дням', 321631.0, '12-31 Янв 26', 15, 120.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, '12-31 Янв 26', None, None),
            ('Доплата за выслугу лет (по дням)', 32163.0, '12-31 Янв 26', 15, 120.0),
            ('Оплата за совмещение', 29760.0, '12-31 Янв 26', 15, 120.0),
        ],
        'deductions': [
            ('Питание', 1006.0, 'Янв 26'),
            ('ИПН исчисленный', 20765.0, 'Янв 26'),
            ('ОПВ исчисленные', 38355.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 7801.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000001296', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 454627.0, 'total_deductions': 88273.0, 'net_pay': 366354.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 407399.0, 'position': 'Главный менеджер', 'department': 'Отдел правового и административного обеспечения',
        'accruals': [
            ('Оклад по дням', 407399.0, 'Фев 26', 20, 160.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
            ('Доплата за выслугу лет (по дням)', 40740.0, 'Фев 26', 20, 160.0),
        ],
        'deductions': [
            ('Питание', 3593.0, 'Фев 26'),
            ('Профсоюзный сбор', 4325.0, 'Фев 26'),
            ('ИПН исчисленный', 26448.0, 'Фев 26'),
            ('ОПВ исчисленные', 44814.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 9093.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000001296', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 564524.0, 'total_deductions': 104223.0, 'net_pay': 460301.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 407399.0, 'position': 'Главный менеджер', 'department': 'Административный отдел',
        'accruals': [
            ('Оклад по дням', 430033.0, 'Мар 26', 19, 152.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, '1-9 Мар 26', None, None),
            ('Доплата за выслугу лет (по дням)', 43003.0, 'Мар 26', 19, 152.0),
            ('Премия разовая', 85000.0, 'Мар 26', None, None),
        ],
        'deductions': [
            ('Питание', 316.0, 'Мар 26'),
            ('ИПН исчисленный', 36413.0, 'Мар 26'),
            ('ОПВ исчисленные', 56137.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 11357.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000001296', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 454627.0, 'total_deductions': 81666.0, 'net_pay': 372961.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 407399.0, 'position': 'Главный менеджер', 'department': 'Административный отдел',
        'accruals': [
            ('Оклад по дням', 407399.0, 'Апр 26', 22, 176.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
            ('Доплата за выслугу лет (по дням)', 40740.0, 'Апр 26', 22, 176.0),
        ],
        'deductions': [
            ('Питание', 1311.0, 'Апр 26'),
            ('ИПН исчисленный', 26448.0, 'Апр 26'),
            ('ОПВ исчисленные', 44814.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 9093.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000001445', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 322862.0, 'total_deductions': 53425.0, 'net_pay': 269437.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 368995.0, 'position': 'Менеджер', 'department': 'Планово-экономический отдел',
        'accruals': [
            ('Оклад по дням', 287613.0, 'Янв 26', 15, 120.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, '16-31 Янв 26', None, None),
            ('Доплата за выслугу лет (по дням)', 28761.0, 'Янв 26', 15, 120.0),
        ],
        'deductions': [
            ('Питание', 478.0, 'Янв 26'),
            ('ИПН исчисленный', 14853.0, 'Янв 26'),
            ('ОПВ исчисленные', 31637.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 6457.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000001445', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 412383.0, 'total_deductions': 76654.0, 'net_pay': 335729.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 368995.0, 'position': 'Менеджер', 'department': 'Планово-экономический отдел',
        'accruals': [
            ('Оклад по дням', 368995.0, 'Фев 26', 20, 160.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
            ('Доплата за выслугу лет (по дням)', 36900.0, 'Фев 26', 20, 160.0),
        ],
        'deductions': [
            ('Питание', 1395.0, 'Фев 26'),
            ('Профсоюзный сбор', 3690.0, 'Фев 26'),
            ('ИПН исчисленный', 22731.0, 'Фев 26'),
            ('ОПВ исчисленные', 40590.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 8248.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000001445', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 497383.0, 'total_deductions': 96110.0, 'net_pay': 401273.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 368995.0, 'position': 'Менеджер', 'department': 'Планово-экономический отдел',
        'accruals': [
            ('Оклад по дням', 368995.0, 'Мар 26', 18, 144.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
            ('Доплата за выслугу лет (по дням)', 36900.0, 'Мар 26', 18, 144.0),
            ('Премия разовая', 85000.0, 'Мар 26', None, None),
        ],
        'deductions': [
            ('Питание', 2479.0, 'Мар 26'),
            ('Профсоюзный сбор', 3690.0, 'Мар 26'),
            ('ИПН исчисленный', 30504.0, 'Мар 26'),
            ('ОПВ исчисленные', 49423.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 10014.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000001445', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 439216.0, 'total_deductions': 86225.0, 'net_pay': 352991.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 368995.0, 'position': 'Менеджер', 'department': 'Планово-экономический отдел',
        'accruals': [
            ('Оклад по дням', 385767.0, 'Апр 26', 22, 184.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
            ('Доплата за выслугу лет (по дням)', 38577.0, 'Апр 26', 22, 184.0),
            ('Доплата за сверхурочные часы', 8384.0, '21-30 Апр 26', 8, 8.0),
        ],
        'deductions': [
            ('Питание', 5218.0, 'Апр 26'),
            ('Профсоюзный сбор', 3858.0, 'Апр 26'),
            ('ИПН исчисленный', 25092.0, 'Апр 26'),
            ('ОПВ исчисленные', 43273.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 8784.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000001579', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 222815.0, 'total_deductions': 34878.0, 'net_pay': 187937.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 260966.0, 'position': 'Кладовщик', 'department': 'Служба учета ТМЦ',
        'accruals': [
            ('Оклад по дням', 206026.0, 'Янв 26', 15, 120.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Янв 26', None, None),
            ('Доплата за выслугу лет (по дням)', 10301.0, 'Янв 26', 15, 120.0),
        ],
        'deductions': [
            ('Питание', 2740.0, 'Янв 26'),
            ('ИПН исчисленный', 6049.0, 'Янв 26'),
            ('ОПВ исчисленные', 21633.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 4456.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000001579', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 280502.0, 'total_deductions': 46140.0, 'net_pay': 234362.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 260966.0, 'position': 'Кладовщик', 'department': 'Служба учета ТМЦ',
        'accruals': [
            ('Оклад по дням', 260966.0, 'Фев 26', 20, 160.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
            ('Доплата за выслугу лет (по дням)', 13048.0, 'Фев 26', 20, 160.0),
        ],
        'deductions': [
            ('Питание', 2004.0, 'Фев 26'),
            ('ИПН исчисленный', 11125.0, 'Фев 26'),
            ('ОПВ исчисленные', 27401.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 5610.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000001579', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 365502.0, 'total_deductions': 68076.0, 'net_pay': 297426.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 260966.0, 'position': 'Кладовщик', 'department': 'Служба учета ТМЦ',
        'accruals': [
            ('Оклад по дням', 260966.0, 'Мар 26', 18, 144.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
            ('Доплата за выслугу лет (по дням)', 13048.0, 'Мар 26', 18, 144.0),
            ('Премия разовая', 85000.0, 'Мар 26', None, None),
        ],
        'deductions': [
            ('Питание', 1240.0, 'Мар 26'),
            ('Профсоюзный сбор', 4325.0, 'Мар 26'),
            ('ИПН исчисленный', 18899.0, 'Мар 26'),
            ('ОПВ исчисленные', 36235.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 7377.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000001579', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 268047.0, 'total_deductions': 46065.0, 'net_pay': 221982.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 260966.0, 'position': 'Кладовщик', 'department': 'Служба учета ТМЦ',
        'accruals': [
            ('Оклад по дням', 249104.0, 'Апр 26', 21, 168.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
            ('Доплата за выслугу лет (по дням)', 12455.0, 'Апр 26', 21, 168.0),
        ],
        'deductions': [
            ('Питание', 4519.0, 'Апр 26'),
            ('ИПН исчисленный', 10029.0, 'Апр 26'),
            ('ОПВ исчисленные', 26156.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 5361.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000001668', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 384762.0, 'total_deductions': 69425.0, 'net_pay': 315337.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 456331.0, 'position': 'Заместитель начальника', 'department': 'Отдел информационных технологий и связи',
        'accruals': [
            ('Оклад по дням', 360261.0, 'Янв 26', 15, 120.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Янв 26', None, None),
            ('Доплата за выслугу лет (по дням)', 18013.0, 'Янв 26', 15, 120.0),
        ],
        'deductions': [
            ('Профсоюзный сбор', 3603.0, 'Янв 26'),
            ('ИПН исчисленный', 20300.0, 'Янв 26'),
            ('ОПВ исчисленные', 37827.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 7695.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000001668', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 485636.0, 'total_deductions': 92158.0, 'net_pay': 393478.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 456331.0, 'position': 'Заместитель начальника', 'department': 'Отдел информационных технологий и связи',
        'accruals': [
            ('Оклад по дням', 456331.0, 'Фев 26', 20, 160.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
            ('Доплата за выслугу лет (по дням)', 22817.0, 'Фев 26', 20, 160.0),
        ],
        'deductions': [
            ('Питание', 790.0, 'Фев 26'),
            ('Профсоюзный сбор', 4563.0, 'Фев 26'),
            ('ИПН исчисленный', 29177.0, 'Фев 26'),
            ('ОПВ исчисленные', 47915.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 9713.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000001668', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 512255.0, 'total_deductions': 97852.0, 'net_pay': 414403.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 456331.0, 'position': 'Заместитель начальника', 'department': 'Отдел информационных технологий и связи',
        'accruals': [
            ('Оклад по дням', 481683.0, 'Мар 26', 19, 152.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
            ('Доплата за выслугу лет (по дням)', 24084.0, 'Мар 26', 19, 152.0),
        ],
        'deductions': [
            ('Профсоюзный сбор', 4817.0, 'Мар 26'),
            ('ИПН исчисленный', 31813.0, 'Мар 26'),
            ('ОПВ исчисленные', 50910.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 10312.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000001668', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 485636.0, 'total_deductions': 92255.0, 'net_pay': 393381.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 456331.0, 'position': 'Заместитель начальника', 'department': 'Отдел информационных технологий и связи',
        'accruals': [
            ('Оклад по дням', 456331.0, 'Апр 26', 22, 176.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
            ('Доплата за выслугу лет (по дням)', 22817.0, 'Апр 26', 22, 176.0),
        ],
        'deductions': [
            ('Питание', 887.0, 'Апр 26'),
            ('Профсоюзный сбор', 4563.0, 'Апр 26'),
            ('ИПН исчисленный', 29177.0, 'Апр 26'),
            ('ОПВ исчисленные', 47915.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 9713.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000001681', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 396976.0, 'total_deductions': 26380.0, 'net_pay': 370596.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 413578.0, 'position': 'Контрольный мастер', 'department': 'Отдел технического контроля',
        'accruals': [
            ('Оклад по дням', 108836.0, 'Янв 26', 5, 40.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Янв 26', None, None),
            ('Доплата за выслугу лет (по дням)', 5442.0, 'Янв 26', 5, 40.0),
            ('Оплата отпуска', 55242.0, '29-30 Янв 26', 2, 16.0),
            ('Оплата отпуска экологического', 138105.0, '19-24 Янв 26', 5, 40.0),
            ('Оплата отпуска экологического', 82863.0, '25-28 Янв 26', 3, 24.0),
        ],
        'deductions': [
            ('ИПН исчисленный', 1488.0, 'Янв 26'),
            ('ОПВ исчисленные', 16952.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 7940.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000001681', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 440745.0, 'total_deductions': 136768.0, 'net_pay': 303977.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 413578.0, 'position': 'Контрольный мастер', 'department': 'Отдел технического контроля',
        'accruals': [
            ('Оклад по дням', 413578.0, 'Фев 26', 20, 160.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
            ('Доплата за выслугу лет (по дням)', 20679.0, 'Фев 26', 20, 160.0),
        ],
        'deductions': [
            ('Профсоюзный сбор', 4136.0, 'Фев 26'),
            ('Удержание подотчетной суммы', 4787.0, 'Фев 26'),
            ('ИПН исчисленный', 46540.0, 'Фев 26'),
            ('ОПВ исчисленные', 67646.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 13659.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000001681', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 464871.0, 'total_deductions': 87545.0, 'net_pay': 377326.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 413578.0, 'position': 'Контрольный мастер', 'department': 'Отдел технического контроля',
        'accruals': [
            ('Оклад по дням', 436555.0, 'Мар 26', 19, 152.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
            ('Доплата за выслугу лет (по дням)', 21828.0, 'Мар 26', 19, 152.0),
        ],
        'deductions': [
            ('Профсоюзный сбор', 4366.0, 'Мар 26'),
            ('ИПН исчисленный', 27643.0, 'Мар 26'),
            ('ОПВ исчисленные', 46172.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 9364.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000001681', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 440745.0, 'total_deductions': 92399.0, 'net_pay': 348346.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 413578.0, 'position': 'Контрольный мастер', 'department': 'Отдел технического контроля',
        'accruals': [
            ('Оклад по дням', 413578.0, 'Апр 26', 22, 176.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
            ('Доплата за выслугу лет (по дням)', 20679.0, 'Апр 26', 22, 176.0),
        ],
        'deductions': [
            ('Профсоюзный сбор', 4136.0, 'Апр 26'),
            ('ИПН исчисленный', 29794.0, 'Апр 26'),
            ('ОПВ исчисленные', 48616.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 9853.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000001864', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 278379.0, 'total_deductions': 54606.0, 'net_pay': 223773.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 368995.0, 'position': 'Менеджер', 'department': 'Планово-экономический отдел',
        'accruals': [
            ('Оклад по дням', 271891.0, 'Янв 26', 14, 112.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Янв 26', None, None),
        ],
        'deductions': [
            ('Питание', 8192.0, 'Янв 26'),
            ('Профсоюзный сбор', 2719.0, 'Янв 26'),
            ('ИПН исчисленный', 10938.0, 'Янв 26'),
            ('ОПВ исчисленные', 27189.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 5568.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000001864', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 375483.0, 'total_deductions': 76748.0, 'net_pay': 298735.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 368995.0, 'position': 'Менеджер', 'department': 'Планово-экономический отдел',
        'accruals': [
            ('Оклад по дням', 368995.0, 'Фев 26', 20, 160.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
        ],
        'deductions': [
            ('Питание', 9164.0, 'Фев 26'),
            ('Профсоюзный сбор', 3690.0, 'Фев 26'),
            ('ИПН исчисленный', 19484.0, 'Фев 26'),
            ('ОПВ исчисленные', 36900.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 7510.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000001864', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 524233.0, 'total_deductions': 103410.0, 'net_pay': 420823.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 368995.0, 'position': 'Менеджер', 'department': 'Планово-экономический отдел',
        'accruals': [
            ('Доплата', 43250.0, 'Мар 26', None, None),
            ('Оклад по дням', 389495.0, 'Мар 26', 19, 152.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
            ('Премия разовая', 85000.0, 'Мар 26', None, None),
        ],
        'deductions': [
            ('Питание', 3989.0, 'Мар 26'),
            ('Профсоюзный сбор', 3895.0, 'Мар 26'),
            ('ИПН исчисленный', 32867.0, 'Мар 26'),
            ('ОПВ исчисленные', 52108.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 10551.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000001864', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 424902.0, 'total_deductions': 90728.0, 'net_pay': 334174.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 368995.0, 'position': 'Менеджер', 'department': 'Планово-экономический отдел',
        'accruals': [
            ('Оклад по дням', 301905.0, 'Апр 26', 17, 144.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
            ('Доплата за сверхурочные часы', 8384.0, '21-30 Апр 26', 8, 8.0),
            ('Оплата больничных листов', 108125.0, '13-17 Апр 26', 5, 40.0),
        ],
        'deductions': [
            ('Питание', 13537.0, 'Апр 26'),
            ('Профсоюзный сбор', 3019.0, 'Апр 26'),
            ('ИПН исчисленный', 23833.0, 'Апр 26'),
            ('ОПВ исчисленные', 41841.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 8498.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000001874', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 659514.0, 'total_deductions': 128140.0, 'net_pay': 531374.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 334464.0, 'position': 'Специалист по кадрам', 'department': 'Отдел правового и административного обеспечения',
        'accruals': [
            ('Материальная помощь', 334464.0, 'Янв 26', None, None),
            ('Оплата больничных листов', 108125.0, '26-30 Янв 26', 5, 40.0),
            ('Оплата отпуска', 216925.0, '12-25 Янв 26', 10, 80.0),
        ],
        'deductions': [
            ('Питание', 3937.0, 'Янв 26'),
            ('ИПН исчисленный', 45062.0, 'Янв 26'),
            ('ОПВ исчисленные', 65951.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 13190.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000001874', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 340952.0, 'total_deductions': 68948.0, 'net_pay': 272004.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 334464.0, 'position': 'Специалист по кадрам', 'department': 'Отдел правового и административного обеспечения',
        'accruals': [
            ('Оклад по дням', 334464.0, 'Фев 26', 20, 160.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
        ],
        'deductions': [
            ('Питание', 7913.0, 'Фев 26'),
            ('Профсоюзный сбор', 4325.0, 'Фев 26'),
            ('ИПН исчисленный', 16445.0, 'Фев 26'),
            ('ОПВ исчисленные', 33446.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 6819.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000001874', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 444533.0, 'total_deductions': 89125.0, 'net_pay': 355408.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 334464.0, 'position': 'Специалист по кадрам', 'department': 'Административный отдел',
        'accruals': [
            ('Оклад по дням', 353045.0, 'Мар 26', 19, 152.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, '1-9 Мар 26', None, None),
            ('Премия разовая', 85000.0, 'Мар 26', None, None),
        ],
        'deductions': [
            ('Питание', 10869.0, 'Мар 26'),
            ('ИПН исчисленный', 25560.0, 'Мар 26'),
            ('ОПВ исчисленные', 43805.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 8891.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000001874', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 355640.0, 'total_deductions': 72822.0, 'net_pay': 282818.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 334464.0, 'position': 'Специалист по кадрам', 'department': 'Административный отдел',
        'accruals': [
            ('Оклад по дням', 334464.0, 'Апр 26', 22, 176.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, '28-30 Апр 26', None, None),
            ('Оплата за совмещение', 14688.0, '28-30 Апр 26', 3, 24.0),
        ],
        'deductions': [
            ('Питание', 13057.0, 'Апр 26'),
            ('ИПН исчисленный', 17737.0, 'Апр 26'),
            ('ОПВ исчисленные', 34915.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 7113.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000001965', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 469574.0, 'total_deductions': 32669.0, 'net_pay': 436905.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 425229.0, 'position': 'инженер-программист', 'department': 'Отдел информационных технологий и связи',
        'accruals': [
            ('Оклад по дням', 156663.0, 'Янв 26', 7, 56.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Янв 26', None, None),
            ('Оплата больничных листов', 83570.0, '19-21 Янв 26', 3, 24.0),
            ('Оплата отпуска экологического', 55713.0, '26-27 Янв 26', 2, 16.0),
            ('Оплата отпуска экологического', 83570.0, '28-31 Янв 26', 3, 24.0),
            ('Оплата отпуска экологического', 83570.0, '1-4 Фев 26', 3, 24.0),
        ],
        'deductions': [
            ('ИПН исчисленный', 8646.0, 'Янв 26'),
            ('ОПВ исчисленные', 24023.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000001965', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 346671.0, 'total_deductions': 52242.0, 'net_pay': 294429.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 425229.0, 'position': 'инженер-программист', 'department': 'Отдел информационных технологий и связи',
        'accruals': [
            ('Оклад по дням', 340183.0, 'Фев 26', 16, 128.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
        ],
        'deductions': [
            ('Питание', 582.0, 'Фев 26'),
            ('ИПН исчисленный', 17642.0, 'Фев 26'),
            ('ОПВ исчисленные', 34018.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000001965', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 474712.0, 'total_deductions': 76621.0, 'net_pay': 398091.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 425229.0, 'position': 'инженер-программист', 'department': 'Отдел информационных технологий и связи',
        'accruals': [
            ('Оклад по дням', 354358.0, 'Мар 26', 15, 120.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
            ('Оплата отпуска', 113866.0, '3-6 Мар 26', 4, 32.0),
        ],
        'deductions': [
            ('ИПН исчисленный', 29465.0, 'Мар 26'),
            ('ОПВ исчисленные', 47156.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000001965', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 431717.0, 'total_deductions': 71154.0, 'net_pay': 360563.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 425229.0, 'position': 'инженер-программист', 'department': 'Отдел информационных технологий и связи',
        'accruals': [
            ('Оклад по дням', 425229.0, 'Апр 26', 22, 176.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
        ],
        'deductions': [
            ('Питание', 3335.0, 'Апр 26'),
            ('ИПН исчисленный', 25296.0, 'Апр 26'),
            ('ОПВ исчисленные', 42523.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000001978', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 1421582.0, 'total_deductions': 283377.0, 'net_pay': 1138205.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 413578.0, 'position': 'Мастер СУ', 'department': 'Строительный участок',
        'accruals': [
            ('Материальная помощь', 413578.0, 'Янв 26', None, None),
            ('Материальная помощь', 413578.0, 'Янв 26', None, None),
            ('Оплата отпуска', 405290.0, '12-31 Янв 26', 15, 120.0),
            ('Оплата отпуска', 189136.0, '1-10 Фев 26', 7, 56.0),
        ],
        'deductions': [
            ('Питание', 663.0, 'Янв 26'),
            ('ИПН исчисленный', 112124.0, 'Янв 26'),
            ('ОПВ исчисленные', 142158.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 28432.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000001978', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 275314.0, 'total_deductions': 48007.0, 'net_pay': 227307.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 413578.0, 'position': 'Мастер СУ', 'department': 'Строительный участок',
        'accruals': [
            ('Оклад по дням', 268826.0, 'Фев 26', 13, 104.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
        ],
        'deductions': [
            ('Питание', 2261.0, 'Фев 26'),
            ('Профсоюзный сбор', 2688.0, 'Фев 26'),
            ('ИПН исчисленный', 10669.0, 'Фев 26'),
            ('ОПВ исчисленные', 26883.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 5506.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000001978', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 443043.0, 'total_deductions': 83649.0, 'net_pay': 359394.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 413578.0, 'position': 'Мастер СУ', 'department': 'Строительный участок',
        'accruals': [
            ('Оклад по дням', 436555.0, 'Мар 26', 19, 152.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
        ],
        'deductions': [
            ('Питание', 644.0, 'Мар 26'),
            ('Профсоюзный сбор', 4366.0, 'Мар 26'),
            ('ИПН исчисленный', 25722.0, 'Мар 26'),
            ('ОПВ исчисленные', 43989.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 8928.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000001978', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 420066.0, 'total_deductions': 86641.0, 'net_pay': 333425.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 413578.0, 'position': 'Мастер СУ', 'department': 'Строительный участок',
        'accruals': [
            ('Оклад по дням', 413578.0, 'Апр 26', 22, 176.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
        ],
        'deductions': [
            ('Питание', 9339.0, 'Апр 26'),
            ('Профсоюзный сбор', 4136.0, 'Апр 26'),
            ('ИПН исчисленный', 23407.0, 'Апр 26'),
            ('ОПВ исчисленные', 41358.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 8401.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000002005', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 321401.0, 'total_deductions': 57917.0, 'net_pay': 263484.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 349395.0, 'position': 'Бухгалтер', 'department': 'Отдел бухгалтерского и налогового учета',
        'accruals': [
            ('Оклад по дням', 308019.0, 'Янв 26', 16, 134.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Янв 26', None, None),
            ('Доплата за сверхурочные часы', 6894.0, '20-30 Янв 26', 6, 6.0),
        ],
        'deductions': [
            ('Питание', 7979.0, 'Янв 26'),
            ('Профсоюзный сбор', 3080.0, 'Янв 26'),
            ('ИПН исчисленный', 15367.0, 'Янв 26'),
            ('ОПВ исчисленные', 31491.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000002005', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 369986.0, 'total_deductions': 72743.0, 'net_pay': 297243.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 349395.0, 'position': 'Бухгалтер', 'department': 'Отдел бухгалтерского и налогового учета',
        'accruals': [
            ('Оклад по дням', 359130.0, 'Фев 26', 20, 164.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
            ('Доплата за сверхурочные часы', 4368.0, '16-26 Фев 26', 4, 4.0),
        ],
        'deductions': [
            ('Питание', 13062.0, 'Фев 26'),
            ('Профсоюзный сбор', 3591.0, 'Фев 26'),
            ('ИПН исчисленный', 19740.0, 'Фев 26'),
            ('ОПВ исчисленные', 36350.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000002005', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 467573.0, 'total_deductions': 88976.0, 'net_pay': 378597.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 349395.0, 'position': 'Бухгалтер', 'department': 'Отдел бухгалтерского и налогового учета',
        'accruals': [
            ('Оклад по дням', 373659.0, 'Мар 26', 19, 154.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Мар 26', None, None),
            ('Доплата за сверхурочные часы', 2426.0, '19-20 Мар 26', 2, 2.0),
            ('Премия разовая', 85000.0, 'Мар 26', None, None),
        ],
        'deductions': [
            ('Питание', 9984.0, 'Мар 26'),
            ('Профсоюзный сбор', 3737.0, 'Мар 26'),
            ('ИПН исчисленный', 28818.0, 'Мар 26'),
            ('ОПВ исчисленные', 46437.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000002005', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 385665.0, 'total_deductions': 76736.0, 'net_pay': 308929.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 349395.0, 'position': 'Бухгалтер', 'department': 'Отдел бухгалтерского и налогового учета',
        'accruals': [
            ('Оклад по дням', 369247.0, 'Апр 26', 22, 186.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
            ('Доплата за сверхурочные часы', 9930.0, '2-30 Апр 26', 10, 10.0),
        ],
        'deductions': [
            ('Питание', 13975.0, 'Апр 26'),
            ('Профсоюзный сбор', 3692.0, 'Апр 26'),
            ('ИПН исчисленный', 21151.0, 'Апр 26'),
            ('ОПВ исчисленные', 37918.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000002063', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 236048.0, 'total_deductions': 42372.0, 'net_pay': 193676.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 278720.0, 'position': 'Офис менеджер', 'department': 'Отдел правового и административного обеспечения',
        'accruals': [
            ('Оклад по дням', 117355.0, 'Янв 26', 8, 64.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, '28-31 Янв 26', None, None),
            ('Оплата больничных листов', 17789.0, '13 Янв 26', 1, 8.0),
            ('Оплата больничных листов', 90336.0, '14-21 Янв 26', 6, 48.0),
            ('Оплата за совмещение', 4080.0, '28-31 Янв 26', 3, 24.0),
        ],
        'deductions': [
            ('Питание', 6308.0, 'Янв 26'),
            ('Профсоюзный сбор', 1174.0, 'Янв 26'),
            ('ИПН исчисленный', 7213.0, 'Янв 26'),
            ('ОПВ исчисленные', 22956.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 4721.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000002063', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 299096.0, 'total_deductions': 58062.0, 'net_pay': 241034.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 278720.0, 'position': 'Офис менеджер', 'department': 'Отдел правового и административного обеспечения',
        'accruals': [
            ('Оклад по дням', 278720.0, 'Фев 26', 20, 160.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, '9-28 Фев 26', None, None),
            ('Оплата за совмещение', 1360.0, '1-2 Фев 26', 1, 8.0),
            ('Оплата за совмещение', 2784.0, '5-6 Фев 26', 2, 16.0),
            ('Оплата за совмещение', 9744.0, '9-17 Фев 26', 7, 56.0),
        ],
        'deductions': [
            ('Питание', 7270.0, 'Фев 26'),
            ('Профсоюзный сбор', 2787.0, 'Фев 26'),
            ('ИПН исчисленный', 12762.0, 'Фев 26'),
            ('ОПВ исчисленные', 29261.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 5982.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000002063', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 968261.0, 'total_deductions': 188429.0, 'net_pay': 779832.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 278720.0, 'position': 'Офис менеджер', 'department': 'Административный отдел',
        'accruals': [
            ('Оклад по дням', 123876.0, 'Мар 26', 8, 64.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, '1-9 Мар 26', None, None),
            ('Материальная помощь', 557440.0, 'Мар 26', None, None),
            ('Оплата отпуска', 195457.0, '10-27 Мар 26', 11, 88.0),
            ('Премия разовая', 85000.0, 'Мар 26', None, None),
        ],
        'deductions': [
            ('Профсоюзный сбор', 1239.0, 'Мар 26'),
            ('ИПН исчисленный', 71648.0, 'Мар 26'),
            ('ОПВ исчисленные', 96177.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 19365.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000002063', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 297848.0, 'total_deductions': 66642.0, 'net_pay': 231206.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 278720.0, 'position': 'Офис менеджер', 'department': 'Административный отдел',
        'accruals': [
            ('Оклад по дням', 278720.0, 'Апр 26', 22, 176.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, '17-30 Апр 26', None, None),
            ('Оплата за совмещение', 12640.0, '17-30 Апр 26', 10, 80.0),
        ],
        'deductions': [
            ('Питание', 16110.0, 'Апр 26'),
            ('Профсоюзный сбор', 2787.0, 'Апр 26'),
            ('ИПН исчисленный', 12652.0, 'Апр 26'),
            ('ОПВ исчисленные', 29136.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 5957.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000002148', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 164132.0, 'total_deductions': 19932.0, 'net_pay': 144200.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 199682.0, 'position': 'Повар', 'department': 'Столовая',
        'accruals': [
            ('Оклад по дням', 157644.0, 'Янв 26', 15, 120.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Янв 26', None, None),
        ],
        'deductions': [
            ('ИПН исчисленный', 885.0, 'Янв 26'),
            ('ОПВ исчисленные', 15764.0, 'Янв 26'),
            ('Взносы ОСМС исчисленные', 3283.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000002148', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 224890.0, 'total_deductions': 35462.0, 'net_pay': 189428.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 199682.0, 'position': 'Повар', 'department': 'Столовая',
        'accruals': [
            ('Доплата', 18720.0, 'Фев 26', None, None),
            ('Оклад по дням', 199682.0, 'Фев 26', 20, 160.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
        ],
        'deductions': [
            ('Питание', 896.0, 'Фев 26'),
            ('Профсоюзный сбор', 1997.0, 'Фев 26'),
            ('ИПН исчисленный', 6231.0, 'Фев 26'),
            ('ОПВ исчисленные', 21840.0, 'Фев 26'),
            ('Взносы ОСМС исчисленные', 4498.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000002148', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 343037.0, 'total_deductions': 59945.0, 'net_pay': 283092.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 199682.0, 'position': 'Повар', 'department': 'Столовая',
        'accruals': [
            ('Доплата', 20805.0, 'Мар 26', None, None),
            ('Оклад по дням', 210776.0, 'Мар 26', 19, 152.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, '30-31 Мар 26', None, None),
            ('Оплата за совмещение', 19968.0, '17-29 Мар 26', 6, 48.0),
            ('Премия разовая', 85000.0, 'Мар 26', None, None),
        ],
        'deductions': [
            ('Профсоюзный сбор', 2108.0, 'Мар 26'),
            ('ИПН исчисленный', 16922.0, 'Мар 26'),
            ('ОПВ исчисленные', 33988.0, 'Мар 26'),
            ('Взносы ОСМС исчисленные', 6927.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000002148', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 206170.0, 'total_deductions': 31508.0, 'net_pay': 174662.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 199682.0, 'position': 'Повар', 'department': 'Столовая',
        'accruals': [
            ('Оклад по дням', 199682.0, 'Апр 26', 22, 176.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
        ],
        'deductions': [
            ('Питание', 836.0, 'Апр 26'),
            ('Профсоюзный сбор', 1997.0, 'Апр 26'),
            ('ИПН исчисленный', 4584.0, 'Апр 26'),
            ('ОПВ исчисленные', 19968.0, 'Апр 26'),
            ('Взносы ОСМС исчисленные', 4123.0, 'Апр 26'),
        ],
    },
    {
        'employee_id': '0000002162', 'month': 1, 'year': 2026,
        'display': 'Январь 2026',
        'total_accruals': 283930.0, 'total_deductions': 19190.0, 'net_pay': 264740.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 351426.0, 'position': 'Менеджер', 'department': 'Управление материально-технического обеспечения',
        'accruals': [
            ('Оклад по дням', 277442.0, '12-31 Янв 26', 15, 120.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, '12-31 Янв 26', None, None),
        ],
        'deductions': [
            ('Питание', 4421.0, 'Янв 26'),
            ('ИПН исчисленный', 14769.0, 'Янв 26'),
        ],
    },
    {
        'employee_id': '0000002162', 'month': 2, 'year': 2026,
        'display': 'Февраль 2026',
        'total_accruals': 436980.0, 'total_deductions': 34867.0, 'net_pay': 402113.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 351426.0, 'position': 'Менеджер', 'department': 'Управление материально-технического обеспечения',
        'accruals': [
            ('Доплата', 13176.0, 'Фев 26', None, None),
            ('Оклад по дням', 404140.0, 'Фев 26', 23, 184.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Фев 26', None, None),
            ('Доплата за сверхурочные часы', 13176.0, '2-20 Фев 26', 12, 12.0),
        ],
        'deductions': [
            ('Питание', 752.0, 'Фев 26'),
            ('Профсоюзный сбор', 4041.0, 'Фев 26'),
            ('ИПН исчисленный', 30074.0, 'Фев 26'),
        ],
    },
    {
        'employee_id': '0000002162', 'month': 3, 'year': 2026,
        'display': 'Март 2026',
        'total_accruals': 395741.0, 'total_deductions': 30831.0, 'net_pay': 364910.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 351426.0, 'position': 'Менеджер', 'department': 'Департамент материально-технического обеспечения',
        'accruals': [
            ('Оклад по дням', 388033.0, 'Мар 26', 20, 159.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, '1-9 Мар 26', None, None),
            ('Доплата за сверхурочные часы', 1220.0, '16 Мар 26', 1, 1.0),
        ],
        'deductions': [
            ('Питание', 667.0, 'Мар 26'),
            ('Профсоюзный сбор', 3880.0, 'Мар 26'),
            ('ИПН исчисленный', 26284.0, 'Мар 26'),
        ],
    },
    {
        'employee_id': '0000002162', 'month': 4, 'year': 2026,
        'display': 'Апрель 2026',
        'total_accruals': 357914.0, 'total_deductions': 32119.0, 'net_pay': 325795.0,
        'total_paid': 0.0, 'debt_start': 0.0, 'debt_end': 0.0,
        'salary_rate': 351426.0, 'position': 'Менеджер', 'department': 'Департамент материально-технического обеспечения',
        'accruals': [
            ('Оклад по дням', 351426.0, 'Апр 26', 22, 176.0),
            ('Выплаты вследствии экологического бедствия', 6488.0, 'Апр 26', None, None),
        ],
        'deductions': [
            ('Питание', 6437.0, 'Апр 26'),
            ('Профсоюзный сбор', 3514.0, 'Апр 26'),
            ('ИПН исчисленный', 22168.0, 'Апр 26'),
        ],
    },
]


def _seed_docx_employees_2026():
    """Seed 22 docx employees + their Jan–Apr 2026 payslips with full line items.

    Idempotent: creates missing employees/payslips and backfills accrual/deduction
    line items for any payslip that has none yet.
    """
    for eid, name, job in _DOCX_EMPLOYEES:
        if not Employee.query.filter_by(employee_id=eid).first():
            db.session.add(Employee(employee_id=eid, full_name=name, job_title=job))
    db.session.flush()

    for slip in _DOCX_PAYSLIPS:
        ps = Payslip.query.filter_by(
            employee_id=slip['employee_id'], period_year=slip['year'],
            period_month=slip['month']).first()
        if not ps:
            ps = Payslip(
                employee_id=slip['employee_id'], period_month=slip['month'],
                period_year=slip['year'], period_display=slip['display'],
                total_accruals=slip['total_accruals'], total_deductions=slip['total_deductions'],
                net_pay=slip['net_pay'], total_paid=slip['total_paid'],
                debt_start=slip['debt_start'], debt_end=slip['debt_end'],
                salary_rate=slip['salary_rate'], position=slip['position'],
                department=slip['department'])
            db.session.add(ps)
            db.session.flush()

        if not PayslipAccrual.query.filter_by(payslip_id=ps.id).first():
            for name, amount, period, days, hours in slip['accruals']:
                db.session.add(PayslipAccrual(
                    payslip_id=ps.id, name=name, amount=amount, period=period,
                    working_days=days, working_hours=hours))

        if not PayslipDeduction.query.filter_by(payslip_id=ps.id).first():
            for name, amount, period in slip['deductions']:
                db.session.add(PayslipDeduction(
                    payslip_id=ps.id, name=name, amount=amount, period=period))

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

    # Staff absent from the directory still belong to a team: fall back to the
    # department printed on their payslip, mapped onto the directory's naming
    # (payslips omit the abbreviation, e.g. "Отдел технического контроля" vs
    # "Отдел технического контроля (ОТК)").
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

    db.session.commit()



_OTK_DEPARTMENT = 'Отдел технического контроля (ОТК)'


def _seed_otk_july_2026():
    """Sample July 2026 turnstile traffic for the ОТК team.

    The department had no access records, so their employee report was empty.
    Times are derived from a hash of employee id + date: varied per person and
    day, yet identical on every run, so re-seeding never shifts the data.
    Employees who already have July 2026 records are left untouched.
    """
    import hashlib
    from datetime import date as _date, timedelta

    staff = Employee.query.filter_by(department=_OTK_DEPARTMENT).all()
    if not staff:
        return

    first, last = _date(2026, 7, 1), _date(2026, 7, 31)
    added = 0

    for emp in staff:
        already = AccessRecord.query.filter(
            AccessRecord.employee_id == emp.employee_id,
            AccessRecord.access_date >= first,
            AccessRecord.access_date <= last,
        ).first()
        if already:
            continue

        day = first
        while day <= last:
            if day.weekday() >= 5:            # Saturday/Sunday
                day += timedelta(days=1)
                continue

            seed = int(hashlib.md5(
                f'{emp.employee_id}:{day.isoformat()}'.encode()).hexdigest(), 16)

            # Roughly one absence per working month (leave, sick, off-site).
            if seed % 25 == 0:
                day += timedelta(days=1)
                continue

            punches = []
            arrive_m = 7 * 60 + 35 + (seed % 31)          # 07:35–08:05
            leave_m = 16 * 60 + 55 + ((seed >> 5) % 51)   # 16:55–17:45
            punches.append((arrive_m, 'Вход'))

            # About a third of days include a lunch run outside.
            if (seed >> 11) % 3 == 0:
                out_m = 11 * 60 + 55 + ((seed >> 17) % 11)
                back_m = 13 * 60 + 10 + ((seed >> 23) % 26)
                punches.append((out_m, 'Выход'))
                punches.append((back_m, 'Вход'))

            punches.append((leave_m, 'Выход'))

            for minutes, event in punches:
                db.session.add(AccessRecord(
                    employee_id=emp.employee_id,
                    access_date=day,
                    access_time=f'{minutes // 60:02d}:{minutes % 60:02d}',
                    event_type=event,
                    door_location='Турникет 1',
                ))
                added += 1

            day += timedelta(days=1)

    if added:
        db.session.commit()
        logging.info(f'Seeded {added} July 2026 access records for {_OTK_DEPARTMENT}')



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
    """Сотрудник 1465 (Даурембекова): листки за июнь-июль и проходы турникета.

    В справочнике она была заведена под временным номером D013: табельного
    ещё не знали. Листки его принесли — 0000001465, — и справочник теперь
    ведёт на него, а строку D013 подбирает _merge_duplicate_employees.

    В листках напечатано «Начальник отдела» и «АУП», но АУП — категория
    персонала в расчёте зарплаты, а не отдел. Экран листка склеивает
    должность с подразделением через точку, и получалось «Начальник отдела ·
    АУП» — читается как будто она начальник АУП, тогда как она начальник
    ОИТиС. Поэтому и в карточке, и на листках стоит настоящее: у остальных
    листков в подразделении тоже живой отдел, а не категория.
    """
    if not Employee.query.filter_by(employee_id=_DAUREMBEKOVA_ID).first():
        db.session.add(Employee(
            employee_id=_DAUREMBEKOVA_ID,
            full_name='Даурембекова Умут Ергазыевна',
            job_title=_DAUREMBEKOVA_POSITION,
            department=_DAUREMBEKOVA_DEPARTMENT,
        ))
        db.session.flush()

    # ── Июнь 2026 ────────────────────────────────────────────────────────────
    if not Payslip.query.filter_by(
            employee_id=_DAUREMBEKOVA_ID, period_year=2026, period_month=6).first():
        ps = Payslip(
            employee_id=_DAUREMBEKOVA_ID,
            period_month=6,
            period_year=2026,
            period_display='Июнь 2026',
            total_accruals=1_070_208.0,
            total_deductions=215_710.0,
            net_pay=854_498.0,
            total_paid=761_039.0,
            position=_DAUREMBEKOVA_POSITION,
            department=_DAUREMBEKOVA_DEPARTMENT,
            salary_rate=731_498.0,
            debt_start=761_039.0,
            debt_end=854_498.0,
        )
        db.session.add(ps)
        db.session.flush()

        p = '06.2026'
        for name, amt, days, hours in [
            ('Оклад по дням',                                 731_498.0, 22, 176.0),
            ('Выплаты вследствии экологического бедствия',      6_488.0, None, None),
            ('Доплата за выслугу лет (по дням)',               73_150.0, 22, 176.0),
            ('Доплата за допуск к ГС',                         23_584.0, 22, 176.0),
            ('Оплата за совмещение пост.',                    235_488.0, 22, 176.0),
        ]:
            db.session.add(PayslipAccrual(
                payslip_id=ps.id, name=name, amount=amt, period=p,
                working_days=days, working_hours=hours))

        for name, amt in [
            ('Профсоюзный сбор',          7_315.0),
            ('ИПН исчисленный',          80_619.0),
            ('ОПВ исчисленные',         106_372.0),
            ('Взносы ОСМС исчисленные',  21_404.0),
        ]:
            db.session.add(PayslipDeduction(payslip_id=ps.id, name=name, amount=amt, period=p))

        db.session.add(PayslipPaid(
            payslip_id=ps.id, payment_type='Перечислено в банк',
            period=p, amount=761_039.0))

        for name, amt in [
            ('Вычет ОПВ',    106_372.0),
            ('Вычет ВОСМС',   21_404.0),
            ('Базовый вычет', 129_750.0),
        ]:
            db.session.add(PayslipBenefit(payslip_id=ps.id, name=name, amount=amt))

        for name, amt in [
            ('ООСМС с начала года',  219_636.0),
            ('ООСМС за месяц',        32_106.0),
            ('ВОСМС с начала года',  131_932.0),
        ]:
            db.session.add(PayslipReference(payslip_id=ps.id, name=name, amount=amt))

    # ── Июль 2026 ────────────────────────────────────────────────────────────
    if not Payslip.query.filter_by(
            employee_id=_DAUREMBEKOVA_ID, period_year=2026, period_month=7).first():
        ps = Payslip(
            employee_id=_DAUREMBEKOVA_ID,
            period_month=7,
            period_year=2026,
            period_display='Июль 2026',
            total_accruals=1_801_706.0,
            total_deductions=313_405.0,
            net_pay=1_488_301.0,
            total_paid=1_924_806.0,
            position=_DAUREMBEKOVA_POSITION,
            department=_DAUREMBEKOVA_DEPARTMENT,
            salary_rate=731_498.0,
            debt_start=854_498.0,
            debt_end=417_993.0,
        )
        db.session.add(ps)
        db.session.flush()

        p = '07.2026'
        for name, amt, days, hours in [
            ('Оклад по дням',                                 731_498.0, 22, 176.0),
            ('Выплаты вследствии экологического бедствия',      6_488.0, None, None),
            ('Доплата за выслугу лет (по дням)',               73_150.0, 22, 176.0),
            ('Доплата за допуск к ГС',                         23_584.0, 22, 176.0),
            ('Оплата за совмещение пост.',                    235_488.0, 22, 176.0),
            ('Премия постоянная для ср',                      731_498.0, None, None),
        ]:
            db.session.add(PayslipAccrual(
                payslip_id=ps.id, name=name, amount=amt, period=p,
                working_days=days, working_hours=hours))

        # Подотчётная сумма стоит со знаком минус и в листке: удержали больше,
        # чем следовало, и в этом месяце вернули. Сумма раздела считана с ней.
        for name, amt in [
            ('Профсоюзный сбор',            7_315.0),
            ('Удержание подотчетной суммы', -52_914.0),
            ('ИПН исчисленный',           145_331.0),
            ('ОПВ исчисленные',           179_673.0),
            ('Взносы ОСМС исчисленные',    34_000.0),
        ]:
            db.session.add(PayslipDeduction(payslip_id=ps.id, name=name, amount=amt, period=p))

        db.session.add(PayslipPaid(
            payslip_id=ps.id, payment_type='Перечислено в банк',
            period=p, amount=1_924_806.0))

        for name, amt in [
            ('Вычет ОПВ',    179_673.0),
            ('Вычет ВОСМС',   34_000.0),
            ('Базовый вычет', 129_750.0),
        ]:
            db.session.add(PayslipBenefit(payslip_id=ps.id, name=name, amount=amt))

        # Натуральный доход идёт отдельным разделом и в «Всего начислено» не
        # входит — держим его справочно, чтобы не разошлась сумма начислений.
        for name, amt in [
            ('ООСМС с начала года',                                   273_733.0),
            ('ООСМС за месяц',                                         54_097.0),
            ('ВОСМС с начала года',                                   165_932.0),
            ('Натуральный доход: дополнительный доход от работодателя', 1_516.0),
        ]:
            db.session.add(PayslipReference(payslip_id=ps.id, name=name, amount=amt))

    # ── Учётная запись ───────────────────────────────────────────────────────
    #
    # Пароль — табельный номер, как у всех при заведении, но, в отличие от
    # перенесённых из _CREDENTIALS, со сменой при первом входе: экран смены
    # в сборке уже есть. Сам этот пароль оставить нельзя — он короче шести
    # знаков и совпадает с логином, обе проверки его отклонят.
    # Листки, уже попавшие в базу, тоже приводим к этим значениям: первая
    # версия сидера переносила их с листка как есть, и экран, склеивающий
    # должность с подразделением через точку, показывал «Начальник отдела ·
    # АУП» — читается как будто она начальник АУП.
    for slip in Payslip.query.filter_by(employee_id=_DAUREMBEKOVA_ID).all():
        slip.position = _DAUREMBEKOVA_POSITION
        slip.department = _DAUREMBEKOVA_DEPARTMENT

    # ── Проходы турникета, июль-август 2026 ──────────────────────────────────
    #
    # В выгрузке СКУД на каждый проход по две строки — «Доступ предоставлен» и
    # «Проход» секундой позже, — а направления в ней нет вовсе. Поэтому здесь
    # оставлен только сам проход, а вход и выход расставлены чередованием:
    # первый проход за день — вход, следующий — выход. По временам это сходится
    # везде: приходит в 7:40-8:07, уходит после 12.
    #
    # 21 июля турникет сработал дважды за шесть секунд (07:57:13 и 07:57:19) —
    # это один проход, а не два, и второй отброшен. 6 августа выхода в выгрузке
    # нет: так в источнике, дописывать его нечем.
    _PASSES = [
        ((2026, 7, 1),  ['07:55', '17:06']),
        ((2026, 7, 2),  ['07:43', '14:31']),
        ((2026, 7, 3),  ['07:54', '15:35']),
        ((2026, 7, 7),  ['07:49', '17:07']),
        ((2026, 7, 8),  ['07:50', '14:45']),
        ((2026, 7, 9),  ['10:35', '17:08']),
        ((2026, 7, 10), ['07:51', '15:24']),
        ((2026, 7, 13), ['07:51', '17:07']),
        ((2026, 7, 14), ['08:07', '14:36']),
        ((2026, 7, 20), ['07:51', '17:07']),
        ((2026, 7, 21), ['07:57', '14:40']),
        ((2026, 7, 22), ['08:00', '17:06']),
        ((2026, 7, 23), ['07:50', '17:08']),
        ((2026, 7, 24), ['07:48', '15:31']),
        ((2026, 7, 27), ['07:45', '17:06']),
        ((2026, 7, 28), ['07:48', '17:07']),
        ((2026, 7, 29), ['07:49', '17:06']),
        ((2026, 7, 30), ['07:46', '17:06']),
        ((2026, 7, 31), ['07:41', '14:03']),
        ((2026, 8, 3),  ['07:47', '17:06']),
        ((2026, 8, 5),  ['07:48', '17:06']),
        ((2026, 8, 6),  ['07:50']),
        ((2026, 8, 13), ['07:47', '15:07']),
        ((2026, 8, 17), ['07:52', '17:08']),
        ((2026, 8, 18), ['07:40', '12:14']),
    ]
    # Проверяем по дню, а не по всему диапазону: если за какое-то число записи
    # уже есть — от переноса с D013 или из будущей выгрузки турникета, — этот
    # день пропускается, а остальные всё равно заводятся.
    for (year, month, day), times in _PASSES:
        moment_date = date(year, month, day)
        if AccessRecord.query.filter_by(
                employee_id=_DAUREMBEKOVA_ID, access_date=moment_date).first():
            continue
        for index, moment in enumerate(times):
            db.session.add(AccessRecord(
                employee_id=_DAUREMBEKOVA_ID,
                access_date=moment_date,
                access_time=moment,
                event_type='Вход' if index % 2 == 0 else 'Выход',
                door_location='Турникет 1',
            ))

    if db.session.get(UserAccount, '1465') is None:
        db.session.add(UserAccount(
            login='1465',
            employee_id=_DAUREMBEKOVA_ID,
            password_hash=generate_password_hash('1465'),
            must_change_password=True,
        ))

    db.session.commit()
    logging.info('Seeded employee %s (Даурембекова): payslips and turnstile records',
                 _DAUREMBEKOVA_ID)


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
    """Сотрудник 83 (Бейсекина) и её расчётные листки за июнь-июль 2026.

    Как и Даурембекова, в справочнике она стояла под временным номером —
    D005; листки принесли настоящий, 0000000083.

    В листках напечатана другая должность, «Представитель руководства по
    СМК»: это роль по системе менеджмента качества, её держат вдобавок к
    основной. В карточке оставлена должность из справочника, как и
    подразделение, — «АУП» на листке снова категория персонала, а не отдел.

    В отпускных строках период — диапазон дней, а не месяц: в июле вторая
    строка уходит в август, отпуск оплачен вперёд.
    """
    if not Employee.query.filter_by(employee_id=_BEISEKINA_ID).first():
        db.session.add(Employee(
            employee_id=_BEISEKINA_ID,
            full_name='Бейсекина Айман Муратовна',
            job_title=_BEISEKINA_POSITION,
            department=_BEISEKINA_DEPARTMENT,
        ))
        db.session.flush()

    # ── Июнь 2026 ────────────────────────────────────────────────────────────
    if not Payslip.query.filter_by(
            employee_id=_BEISEKINA_ID, period_year=2026, period_month=6).first():
        ps = Payslip(
            employee_id=_BEISEKINA_ID,
            period_month=6,
            period_year=2026,
            period_display='Июнь 2026',
            total_accruals=1_620_323.0,
            total_deductions=327_135.0,
            net_pay=1_293_188.0,
            total_paid=1_489_022.0,
            position=_BEISEKINA_POSITION,
            department=_BEISEKINA_DEPARTMENT,
            salary_rate=436_706.0,
            debt_start=485_028.0,
            debt_end=289_194.0,
        )
        db.session.add(ps)
        db.session.flush()

        p = '06.2026'
        for name, amt, days, hours, period in [
            ('Оклад по дням',                              238_203.0, 12, 96.0, p),
            ('Выплаты вследствии экологического бедствия',   6_488.0, None, None, p),
            ('Доплата за выслугу лет (по дням)',            47_641.0, 12, 96.0, p),
            ('Материальная помощь',                        873_412.0, None, None, p),
            ('Оплата за совмещение пост.',                  76_704.0, 12, 96.0, p),
            ('Оплата отпуска',                              75_575.0,  2, 16.0, '15-16.06.2026'),
            ('Оплата отпуска',                             302_300.0,  8, 64.0, '17-28.06.2026'),
        ]:
            db.session.add(PayslipAccrual(
                payslip_id=ps.id, name=name, amount=amt, period=period,
                working_days=days, working_hours=hours))

        for name, amt in [
            ('Питание',                    1_933.0),
            ('Профсоюзный сбор',           2_382.0),
            ('ИПН исчисленный',          129_030.0),
            ('ОПВ исчисленные',          161_384.0),
            ('Взносы ОСМС исчисленные',   32_406.0),
        ]:
            db.session.add(PayslipDeduction(payslip_id=ps.id, name=name, amount=amt, period=p))

        db.session.add(PayslipPaid(
            payslip_id=ps.id, payment_type='Перечислено в банк',
            period=p, amount=1_489_022.0))

        for name, amt in [
            ('Вычет ОПВ',     161_384.0),
            ('Вычет ВОСМС',    32_406.0),
            ('Базовый вычет', 129_750.0),
        ]:
            db.session.add(PayslipBenefit(payslip_id=ps.id, name=name, amount=amt))

        for name, amt in [
            ('ОПВР с начала года',    159_970.0),
            ('ОПВР за месяц',          56_484.0),
            ('ООСМС с начала года',   138_286.0),
            ('ООСМС за месяц',         48_610.0),
            ('ВОСМС с начала года',    92_189.0),
        ]:
            db.session.add(PayslipReference(payslip_id=ps.id, name=name, amount=amt))

    # ── Июль 2026 ────────────────────────────────────────────────────────────
    if not Payslip.query.filter_by(
            employee_id=_BEISEKINA_ID, period_year=2026, period_month=7).first():
        ps = Payslip(
            employee_id=_BEISEKINA_ID,
            period_month=7,
            period_year=2026,
            period_display='Июль 2026',
            total_accruals=1_262_613.0,
            total_deductions=251_113.0,
            net_pay=1_011_500.0,
            total_paid=1_009_567.0,
            position=_BEISEKINA_POSITION,
            department=_BEISEKINA_DEPARTMENT,
            salary_rate=436_706.0,
            debt_start=289_194.0,
            debt_end=291_127.0,
        )
        db.session.add(ps)
        db.session.flush()

        p = '07.2026'
        for name, amt, days, hours, period in [
            ('Оклад по дням',                              238_203.0, 12, 96.0, p),
            ('Выплаты вследствии экологического бедствия',   6_488.0, None, None, p),
            ('Доплата за выслугу лет (по дням)',            47_641.0, 12, 96.0, p),
            ('Оплата за совмещение пост.',                  76_704.0, 12, 96.0, p),
            ('Оплата отпуска',                             380_726.0, 10, 80.0, '20-31.07.2026'),
            ('Оплата отпуска',                              76_145.0,  2, 16.0, '01-04.08.2026'),
            ('Премия постоянная для ср',                   436_706.0, None, None, p),
        ]:
            db.session.add(PayslipAccrual(
                payslip_id=ps.id, name=name, amount=amt, period=period,
                working_days=days, working_hours=hours))

        for name, amt in [
            ('Профсоюзный сбор',           2_382.0),
            ('ИПН исчисленный',           97_684.0),
            ('ОПВ исчисленные',          125_764.0),
            ('Взносы ОСМС исчисленные',   25_283.0),
        ]:
            db.session.add(PayslipDeduction(payslip_id=ps.id, name=name, amount=amt, period=p))

        db.session.add(PayslipPaid(
            payslip_id=ps.id, payment_type='Перечислено в банк',
            period=p, amount=1_009_567.0))

        for name, amt in [
            ('Вычет ОПВ',     125_764.0),
            ('Вычет ВОСМС',    25_283.0),
            ('Базовый вычет', 129_750.0),
        ]:
            db.session.add(PayslipBenefit(payslip_id=ps.id, name=name, amount=amt))

        # Натуральный доход в «Всего начислено» не входит — держим справочно,
        # чтобы не разошлась сумма начислений.
        for name, amt in [
            ('ОПВР с начала года',                                    203_987.0),
            ('ОПВР за месяц',                                          44_017.0),
            ('ООСМС с начала года',                                   176_210.0),
            ('ООСМС за месяц',                                         37_924.0),
            ('ВОСМС с начала года',                                   117_472.0),
            ('Натуральный доход: дополнительный доход от работодателя', 1_516.0),
        ]:
            db.session.add(PayslipReference(payslip_id=ps.id, name=name, amount=amt))

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
    logging.info('Seeded employee %s (Бейсекина) with Jun/Jul 2026 payslips',
                 _BEISEKINA_ID)


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
