"""Вход на компьютере по QR-коду с телефона — как в WhatsApp и Telegram.

Программа на компьютере показывает QR-код. Человек открывает SE-mobile на
телефоне (в браузере или в приложении), где он уже вошёл, считывает код,
видит, на какой компьютер входит, и подтверждает. Компьютер получает свой
пропуск — такой же, как после входа паролем. Пароль на компьютере при этом
не нужен вовсе: у большинства его и нет, на телефоне входят кодом из
четырёх цифр.

Как устроено:

    компьютер  POST /api/qr-login/start    → секрет (только ему) и код для QR
    телефон    POST /api/qr-login/scan     → «на какой компьютер», код занят им
    телефон    POST /api/qr-login/confirm  → вход разрешён
       или     POST /api/qr-login/reject   → отказ
    компьютер  POST /api/qr-login/poll     → ждём… / пропуск (один раз)

Что держит это в безопасности:

- Код живёт две минуты и годится один раз. Компьютер, не дождавшись,
  просит новый.
- Пропуск отдаётся только тому, кто знает секрет компьютера (32 случайных
  байта, в QR его нет), и только один раз: строка тут же удаляется.
- Подтверждает только вошедший на телефоне, и только тот, кто код считал:
  второй телефон, считавший тот же код, получит отказ.
- В базе — хеши секрета и кода, а не они сами.
- Код сам по себе ничего не открывает: угадавший чужой код может разве что
  впустить чужой компьютер в свою собственную учётку.
- О каждом таком входе человеку приходит оповещение в колокольчик: если
  подтвердил не он (или его обманом уговорили считать код), он узнает.
- Ни зарплаты, ни других данных эти адреса не отдают: компьютер получает
  то же, что при обычном входе, — имя, должность и пропуск.
"""
import hashlib
import logging
import re
import secrets
from datetime import datetime, timedelta

from flask import g, jsonify

# Сколько живёт код. Хватает, чтобы достать телефон и навести камеру, и
# мало для того, чтобы код с экрана успели переслать кому-то ещё.
LIFETIME = timedelta(minutes=2)

# Больше стольких незаконченных входов разом не бывает и в понедельник
# утром: дальше — сорвавшийся скрипт, и новые не заводим.
_MAX_ACTIVE = 300

# Код — восемь знаков без похожих друг на друга (0/O, 1/I): его можно и
# набрать руками, если камера не открылась. 32^8 ≈ 10^12 вариантов на две
# минуты жизни.
_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
_CODE_LENGTH = 8
_CODE_RE = re.compile(f'^[{_ALPHABET}]{{{_CODE_LENGTH}}}$')

# Имя компьютера — для глаз человека, не для проверки: им можно назваться
# каким угодно. Поэтому только печатные знаки и коротко.
_DEVICE_MAX = 64


def _hash(raw):
    return hashlib.sha256(raw.encode()).hexdigest()


def normalize_code(raw):
    """Код из того, что прислал телефон: сам код или ссылка из QR.

    Набранный руками — с пробелами, дефисами и строчными буквами; в QR —
    ссылка вида …/web/?pc=ABCD2345. Не похоже на код — пустая строка.
    """
    raw = (raw or '').strip()
    match = re.search(r'[?&#]pc=([A-Za-z0-9-]+)', raw)
    if match:
        raw = match.group(1)
    code = re.sub(r'[\s-]', '', raw).upper()
    return code if _CODE_RE.match(code) else ''


def _clean_device(raw):
    text = ''.join(ch for ch in (raw or '') if ch.isprintable()).strip()
    return text[:_DEVICE_MAX]


def register(app, core):
    from models import db, Employee, QrLogin, UserAccount

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _purge(now):
        QrLogin.query.filter(QrLogin.expires_at <= now).delete(
            synchronize_session=False)

    def _active_account(employee_id):
        return UserAccount.query.filter_by(
            employee_id=employee_id, is_active=True).order_by(
            UserAccount.login).first()

    def _session_by_code(data, now):
        code = normalize_code(core._text(data, 'code'))
        if not code:
            return None
        row = QrLogin.query.filter_by(code_hash=_hash(code)).first()
        if row is None or row.expires_at <= now:
            return None
        return row

    def _viewer():
        """Кто подтверждает. Без пропуска — никто, даже пока проверка
        пропуска не обязательна (REQUIRE_AUTH): иначе «чей» вход
        разрешать, было бы не узнать."""
        viewer = getattr(g, 'employee', None)
        if viewer is None:
            return None
        if _active_account(viewer.employee_id) is None:
            return None
        return viewer

    @app.route('/api/qr-login/start', methods=['POST'])
    def qr_login_start():
        """Компьютер просит код для QR. Без пропуска: он ещё не вошёл."""
        data = core._json_body()
        now = datetime.utcnow()
        try:
            _purge(now)
            if QrLogin.query.count() >= _MAX_ACTIVE:
                db.session.commit()
                logging.warning('QR-вход: слишком много незаконченных входов')
                return _fail('busy', 429)
            secret = secrets.token_urlsafe(32)
            code = ''.join(secrets.choice(_ALPHABET)
                           for _ in range(_CODE_LENGTH))
            db.session.add(QrLogin(
                id=_hash(secret), code_hash=_hash(code),
                device=_clean_device(core._text(data, 'device')),
                status='waiting', created_at=now,
                expires_at=now + LIFETIME))
            db.session.commit()
        except Exception as e:
            db.session.rollback()
            logging.error('QR-вход: не удалось начать: %s', e, exc_info=True)
            return _fail('internal', 503)
        return jsonify({'message': 'Success', 'secret': secret, 'code': code,
                        'expires_in': int(LIFETIME.total_seconds())})

    @app.route('/api/qr-login/poll', methods=['POST'])
    def qr_login_poll():
        """Компьютер спрашивает, подтвердили ли вход.

        Подтвердили — отдаём пропуск и удаляем строку: второй раз по тому же
        секрету не дадут ничего.
        """
        secret = core._text(core._json_body(), 'secret')
        if not secret or len(secret) > 128:
            return _fail('bad_secret', 400)
        now = datetime.utcnow()
        key = _hash(secret)
        row = db.session.get(QrLogin, key)
        if row is None or row.expires_at <= now:
            return jsonify({'message': 'Success', 'status': 'expired'})
        if row.status == 'rejected':
            db.session.delete(row)
            db.session.commit()
            return jsonify({'message': 'Success', 'status': 'rejected'})
        if row.status != 'approved':
            return jsonify({'message': 'Success', 'status': row.status})

        employee_id = row.employee_id
        # Забрать пропуск можно один раз. Удаление с условием — одно
        # действие в базе: два одновременных опроса не получат по пропуску.
        taken = QrLogin.query.filter_by(id=key, status='approved').delete(
            synchronize_session=False)
        db.session.commit()
        if taken != 1:
            return jsonify({'message': 'Success', 'status': 'expired'})
        employee = db.session.get(Employee, employee_id)
        account = _active_account(employee_id)
        # Пока компьютер ждал, учётку могли отключить.
        if employee is None or account is None:
            return jsonify({'message': 'Success', 'status': 'rejected'})
        try:
            account.last_login_at = now
            db.session.commit()
        except Exception:
            db.session.rollback()
        return jsonify({
            'message': 'Success',
            'status': 'approved',
            'token': core._issue_token(employee_id),
            'login': account.login,
            'full_name': employee.full_name,
            'job': employee.job_title,
            'employee_id': employee.employee_id,
            'has_password': core._has_password(account),
        })

    @app.route('/api/qr-login/scan', methods=['POST'])
    @core.require_auth
    def qr_login_scan():
        """Телефон считал код: занимаем его и говорим, что за компьютер."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        now = datetime.utcnow()
        row = _session_by_code(core._json_body(), now)
        if row is None:
            return _fail('not_found', 404)
        if row.status == 'waiting':
            # С условием — чтобы из двух телефонов, считавших код разом,
            # код достался одному.
            QrLogin.query.filter_by(id=row.id, status='waiting').update(
                {'status': 'scanned', 'employee_id': viewer.employee_id},
                synchronize_session=False)
            db.session.commit()
            db.session.refresh(row)
        if row.status not in ('waiting', 'scanned') or (
                row.employee_id != viewer.employee_id):
            return _fail('taken', 409)
        return jsonify({'message': 'Success',
                        'device': row.device,
                        'expires_in': max(1, int(
                            (row.expires_at - now).total_seconds()))})

    def _answer(approve):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        now = datetime.utcnow()
        row = _session_by_code(core._json_body(), now)
        if row is None:
            return _fail('not_found', 404)
        if row.employee_id != viewer.employee_id:
            return _fail('taken', 409)
        done = QrLogin.query.filter_by(
            id=row.id, status='scanned',
            employee_id=viewer.employee_id).update(
            {'status': 'approved' if approve else 'rejected'},
            synchronize_session=False)
        db.session.commit()
        if done != 1:
            return _fail('taken', 409)
        if approve:
            logging.info('QR-вход на компьютер %r разрешён сотрудником %s',
                         row.device, viewer.employee_id)
            device = row.device or 'без имени'
            core._record_notice(
                'signin', 'Вход на компьютере',
                f'Вы подтвердили вход с телефона на компьютер «{device}». '
                'Если это были не вы — сразу сообщите в ОИТиС.',
                employee_ids=[viewer.employee_id], repeat=True)
        return jsonify({'message': 'Success'})

    @app.route('/api/qr-login/confirm', methods=['POST'])
    @core.require_auth
    def qr_login_confirm():
        """Человек на телефоне нажал «Войти»."""
        return _answer(True)

    @app.route('/api/qr-login/reject', methods=['POST'])
    @core.require_auth
    def qr_login_reject():
        """Человек на телефоне нажал «Отмена»: компьютер покажет отказ."""
        return _answer(False)
