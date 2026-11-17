"""Вход из Safari — значку на экране «Домой» (iPhone и iPad).

Беда: человек вошёл в SE-mobile в Safari, нажал «Поделиться» → «На экран
Домой», открыл значок — а там снова логин и пароль. iOS держит у значка
своё хранилище, отдельно от Safari, и пропуск из вкладки туда не попадает.

Одно iOS переносит: куки сайта копируются значку один раз, в ту минуту,
когда его ставят. На этом и держится передача:

    вкладка  POST /api/web-handoff         (с пропуском) → кука se_handoff
    значок   POST /api/web-handoff/claim   (с этой кукой) → свой пропуск

Вкладка заводит куку каждый раз, как в ней вошли или открыли её кодом.
Значок при первом запуске, ещё не войдя, предъявляет её — и получает
пропуск, такой же, как после входа паролем. Дальше значок живёт сам по
себе, как приложение на телефоне.

Что держит это в безопасности:

- Кука HttpOnly: скрипт страницы её не прочитает, а значит, и не утащит.
  Secure и SameSite=Strict, путь — только эти два адреса: с другими
  запросами она не ходит.
- В куке — 32 случайных байта, в базе — их хеш.
- Годится один раз: значок забрал пропуск — строки больше нет.
- Привязана к пропуску вкладки. Вышли из вкладки, сменили или сбросили
  пароль, отключили учётку — пропуск вкладки погас, и передать вход по
  куке уже нельзя.
- Живёт неделю. Значок обычно открывают сразу, как поставили.
- Отдаёт то же, что обычный вход: имя, должность, пропуск. Ни зарплаты,
  ни других данных.
"""
import hashlib
import logging
import secrets
from datetime import datetime, timedelta

from flask import g, jsonify, request

COOKIE = 'se_handoff'
COOKIE_PATH = '/api/web-handoff'

# Сколько живёт кука. Значок ставят и открывают в одну минуту; неделя —
# с запасом на того, кто поставил значок и открыл его через пару дней.
LIFETIME = timedelta(days=7)


def _hash(raw):
    return hashlib.sha256(raw.encode()).hexdigest()


def register(app, core):
    from models import db, AuthToken, Employee, UserAccount, WebHandoff

    def _active_account(employee_id):
        return UserAccount.query.filter_by(
            employee_id=employee_id, is_active=True).order_by(
            UserAccount.login).first()

    def _set_cookie(response, secret):
        response.set_cookie(
            COOKIE, secret, max_age=int(LIFETIME.total_seconds()),
            path=COOKIE_PATH, secure=True, httponly=True, samesite='Strict')
        return response

    def _drop_cookie(response):
        response.delete_cookie(COOKIE, path=COOKIE_PATH, secure=True,
                               httponly=True, samesite='Strict')
        return response

    def _nothing():
        """Передавать нечего: значок покажет обычный экран входа."""
        return _drop_cookie(jsonify({'message': 'Success', 'status': 'none'}))

    @app.route('/api/web-handoff', methods=['POST'])
    @core.require_auth
    def web_handoff_offer():
        """Вошедшая вкладка заводит куку для будущего значка."""
        viewer = getattr(g, 'employee', None)
        raw = core._bearer_token()
        if viewer is None or not raw or (
                _active_account(viewer.employee_id) is None):
            return jsonify({'message': 'Failure', 'error': 'unauthorized'}), 401
        source = core._token_key(raw)
        now = datetime.utcnow()
        try:
            WebHandoff.query.filter(WebHandoff.expires_at <= now).delete(
                synchronize_session=False)
            # Кука уже есть и от этого же пропуска — продлеваем её, а не
            # заводим новую: значок, поставленный минуту назад, унёс именно её.
            secret = request.cookies.get(COOKIE) or ''
            row = db.session.get(WebHandoff, _hash(secret)) if secret else None
            if row is not None and row.source_token == source:
                row.expires_at = now + LIFETIME
            else:
                # Прежние строки этой вкладки без куки уже не найти.
                WebHandoff.query.filter_by(source_token=source).delete(
                    synchronize_session=False)
                secret = secrets.token_urlsafe(32)
                db.session.add(WebHandoff(
                    id=_hash(secret), source_token=source,
                    created_at=now, expires_at=now + LIFETIME))
            db.session.commit()
        except Exception as e:
            db.session.rollback()
            logging.error('Передача входа значку: не удалось завести: %s', e,
                          exc_info=True)
            return jsonify({'message': 'Failure', 'error': 'internal'}), 503
        return _set_cookie(jsonify({'message': 'Success'}), secret)

    @app.route('/api/web-handoff/claim', methods=['POST'])
    def web_handoff_claim():
        """Значок при первом запуске забирает вход вкладки. Без пропуска:
        он ещё не вошёл, всё решает кука."""
        secret = request.cookies.get(COOKIE) or ''
        if not secret or len(secret) > 128:
            return _nothing()
        now = datetime.utcnow()
        key = _hash(secret)
        row = db.session.get(WebHandoff, key)
        if row is None:
            return _nothing()
        source, expires_at = row.source_token, row.expires_at
        # Забрать можно один раз. Удаление с условием — одно действие в
        # базе: два одновременных запроса не получат по пропуску.
        taken = WebHandoff.query.filter_by(id=key).delete(
            synchronize_session=False)
        db.session.commit()
        if taken != 1 or expires_at <= now:
            return _nothing()
        tab = db.session.get(AuthToken, source)
        if tab is None or tab.expires_at <= now:
            return _nothing()
        employee = db.session.get(Employee, tab.employee_id)
        account = _active_account(tab.employee_id)
        if employee is None or account is None:
            return _nothing()
        try:
            account.last_login_at = now
            db.session.commit()
        except Exception:
            db.session.rollback()
        logging.info('Вход передан значку на экране «Домой»: %s',
                     employee.employee_id)
        return _drop_cookie(jsonify({
            'message': 'Success',
            'status': 'approved',
            'token': core._issue_token(employee.employee_id),
            'login': account.login,
            'full_name': employee.full_name,
            'job': employee.job_title,
            'employee_id': employee.employee_id,
            'has_password': core._has_password(account),
            'must_change_password': bool(account.must_change_password),
        }))
