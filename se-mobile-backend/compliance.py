"""Горячая линия комплаенса: сообщения о коррупции, конфликте интересов,
мошенничестве и давлении. Видит их только комплаенс-офицер.

Это не ящик предложений и не «Сообщить об опасности»: другой круг читающих
и другая тайна. Сообщение можно отправить анонимно — тогда на сервере нет
ни автора, ни подразделения, а время отправки хранится с точностью до дня:
по минутам его можно было бы сверить с проходами и журналом входов.
Анонимному автору один раз выдаётся ключ; по нему телефон показывает ответы
офицера, и по нему же автор может дописать. На сервере — только хеш ключа.

Оповещение офицеру о названном сообщении уходит сразу, об анонимном — с
ближайшей ежечасной сверкой и одним на все новые: оповещение в ту же минуту
выдало бы время отправки. По той же причине анонимное не пишется в журнал.

Офицер может задать уточняющий вопрос, взять сообщение в проверку и
закрыть с итогом. В оповещениях — ни слова из самого сообщения.

Комплаенс-офицер — должность со словом «комплаенс» и COMPLIANCE_OFFICERS
(например, внутренний аудит, если так решит руководство).
"""

import hashlib
import logging
import os
import secrets
import threading
from datetime import datetime, timedelta

from flask import g, jsonify

from it_requests import _norm, _utc
from models import db

KINDS = ('corruption', 'conflict', 'fraud', 'pressure', 'other')
KIND_TITLES = {'corruption': 'коррупция', 'conflict': 'конфликт интересов',
               'fraud': 'мошенничество', 'pressure': 'давление, принуждение',
               'other': 'другое'}
OPEN = ('new', 'review')

_MAX_TEXT = 4000
_MAX_TRACK = 30
_MAX_MESSAGES = 50
_SHOW_CLOSED_FOR = timedelta(days=90)
_SWEEP_EVERY = timedelta(hours=1)


class ComplianceReport(db.Model):
    __tablename__ = 'compliance_reports'
    id = db.Column(db.Integer, primary_key=True)
    # Пусто у анонимного — его не знает и сервер.
    author_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                          index=True)
    track_hash = db.Column(db.String(64), unique=True)
    kind = db.Column(db.String(12), nullable=False)
    text = db.Column(db.Text, nullable=False)
    # new, review, closed
    status = db.Column(db.String(10), nullable=False, default='new', index=True)
    resolution = db.Column(db.Text)
    # У анонимного — полночь дня отправки, см. описание модуля.
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    # Офицеры знают о нём — у анонимного это ставит ежечасная сверка.
    notified = db.Column(db.Boolean, nullable=False, default=True)


class ComplianceMessage(db.Model):
    __tablename__ = 'compliance_messages'
    id = db.Column(db.Integer, primary_key=True)
    report_id = db.Column(db.Integer,
                          db.ForeignKey('compliance_reports.id', ondelete='CASCADE'),
                          nullable=False, index=True)
    from_officer = db.Column(db.Boolean, nullable=False, default=False)
    text = db.Column(db.Text, nullable=False)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    notified = db.Column(db.Boolean, nullable=False, default=True)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_officer(employee):
    if employee is None:
        return False
    return ('комплаенс' in _norm(employee.job_title)
            or employee.employee_id in _env_ids('COMPLIANCE_OFFICERS'))


def _hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def notify_pending(core):
    """Сказать офицерам об анонимных сообщениях и дополнениях, о которых
    ещё не говорили, — одним оповещением на всё сразу."""
    from models import Employee
    reports = ComplianceReport.query.filter_by(notified=False).all()
    messages = ComplianceMessage.query.filter_by(notified=False).all()
    if not reports and not messages:
        return 0
    for item in reports + messages:
        item.notified = True
    db.session.commit()
    officers = [e.employee_id for e in Employee.query.all() if is_officer(e)]
    parts = []
    if reports:
        parts.append(f'новых сообщений: {len(reports)}')
    if messages:
        parts.append(f'дополнений: {len(messages)}')
    if officers:
        core._record_notice('compliance', 'Горячая линия: ' + ', '.join(parts), '',
                            employee_ids=officers)
    return len(reports) + len(messages)


_sweep_lock = threading.Lock()
_swept_at = None


def register(app, core):
    from models import Employee

    @app.before_request
    def _compliance_sweep():
        global _swept_at
        now = datetime.utcnow()
        if _swept_at is not None and now - _swept_at < _SWEEP_EVERY:
            return
        if not _sweep_lock.acquire(blocking=False):
            return
        try:
            _swept_at = now
            notify_pending(core)
        except Exception as e:
            db.session.rollback()
            logging.warning('Сверка горячей линии не удалась: %s', e)
        finally:
            _sweep_lock.release()

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _anon_time(moment):
        """Анонимному — без часов и минут, и для сообщений в переписке тоже."""
        return moment.replace(hour=0, minute=0, second=0, microsecond=0)

    def _json(item, viewer_is_officer, mine):
        anonymous = item.author_id is None
        messages = (ComplianceMessage.query.filter_by(report_id=item.id)
                    .order_by(ComplianceMessage.id).all())
        data = {
            'id': item.id,
            'kind': item.kind,
            'text': item.text,
            'status': item.status,
            'resolution': item.resolution or '',
            'anonymous': anonymous,
            'created_at': _utc(item.created_at),
            'messages': [{'from_officer': m.from_officer, 'text': m.text,
                          'at': _utc(m.at)} for m in messages],
            'is_mine': mine,
            'can_reply': item.status in OPEN,
            'can_handle': viewer_is_officer and item.status in OPEN,
        }
        if viewer_is_officer and not anonymous:
            emp = db.session.get(Employee, item.author_id)
            data['author'] = {'id': item.author_id,
                              'name': emp.full_name if emp else item.author_id,
                              'department': (emp.department or '') if emp else ''}
        return data

    def _officer_ids():
        return [e.employee_id for e in Employee.query.all() if is_officer(e)]

    def _notify(ids, title, ref):
        ids = sorted({i for i in ids if i})
        if ids:
            core._record_notice('compliance', title, '', employee_ids=ids, ref=ref)

    def _by_token(data):
        token = core._text(data, 'track')
        if not token:
            return None
        return ComplianceReport.query.filter_by(track_hash=_hash(token)).first()

    @app.route('/api/compliance', methods=['POST'])
    @core.require_auth
    def compliance_create():
        """`{"kind", "text", "anonymous"}`. Анонимному в ответе `track` —
        один раз, сохранить на телефоне."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        data = core._json_body()
        kind = core._text(data, 'kind')
        if kind not in KINDS:
            return _fail('bad_kind', 400)
        text = core._text(data, 'text')[:_MAX_TEXT]
        if len(text) < 10:
            return _fail('text_required', 400)
        anonymous = data.get('anonymous') in (True, 1, '1', 'true')
        token = secrets.token_urlsafe(24) if anonymous else None
        now = datetime.utcnow()
        stamp = _anon_time(now) if anonymous else now
        item = ComplianceReport(author_id=None if anonymous else viewer.employee_id,
                                track_hash=_hash(token) if token else None,
                                kind=kind, text=text, status='new',
                                created_at=stamp, updated_at=stamp,
                                notified=not anonymous)
        db.session.add(item)
        db.session.commit()
        if not anonymous:
            # Ни автора, ни текста в журнале: журнал читают не только офицеры.
            logging.info('Горячая линия: сообщение №%s', item.id)
            _notify(_officer_ids(), 'Новое сообщение на горячую линию', item.id)
        body = {'message': 'Success', 'item': _json(item, is_officer(viewer), True)}
        if token:
            body['track'] = token
        return jsonify(body), 201

    @app.route('/api/compliance', methods=['GET'])
    @core.require_auth
    def compliance_list():
        """Мои сообщения с именем; офицеру — все открытые и закрытые за 90 дней."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        officer = is_officer(viewer)
        mine = (ComplianceReport.query.filter_by(author_id=viewer.employee_id)
                .order_by(ComplianceReport.created_at.desc()).limit(50).all())
        body = {'message': 'Success', 'officer': officer,
                'mine': [_json(i, officer, True) for i in mine]}
        if officer:
            since = datetime.utcnow() - _SHOW_CLOSED_FOR
            queue = (ComplianceReport.query
                     .filter(db.or_(ComplianceReport.status.in_(OPEN),
                                    ComplianceReport.updated_at >= since))
                     .order_by(ComplianceReport.created_at.desc(),
                               ComplianceReport.id.desc()).limit(300).all())
            queue.sort(key=lambda i: i.status not in OPEN)
            body['queue'] = [_json(i, True, i.author_id == viewer.employee_id)
                             for i in queue]
        return jsonify(body)

    @app.route('/api/compliance/track', methods=['POST'])
    @core.require_auth
    def compliance_track():
        """Мои анонимные: `{"tracks": [...]}` — по ключам, без имени."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        tracks = core._json_body().get('tracks')
        if not isinstance(tracks, list) or len(tracks) > _MAX_TRACK:
            return _fail('bad_tracks', 400)
        index = {_hash(t): n for n, t in enumerate(tracks)
                 if isinstance(t, str) and t}
        items = (ComplianceReport.query
                 .filter(ComplianceReport.track_hash.in_(list(index) or ['-']))
                 .order_by(ComplianceReport.id.desc()).all())
        rows = []
        for item in items:
            # Какой из присланных ключей — чтобы телефон знал, чем дописывать.
            data = _json(item, False, True)
            data['track_index'] = index[item.track_hash]
            rows.append(data)
        return jsonify({'message': 'Success', 'items': rows})

    def _load(item_id, viewer, data):
        """Сообщение и кто смотрит: офицер, автор по имени или по ключу."""
        item = db.session.get(ComplianceReport, item_id)
        if item is None:
            return None, False, False
        officer = is_officer(viewer)
        mine = item.author_id is not None and item.author_id == viewer.employee_id
        if not mine and item.author_id is None:
            tracked = _by_token(data)
            mine = tracked is not None and tracked.id == item.id
        if not (officer or mine):
            return None, False, False
        return item, officer, mine

    @app.route('/api/compliance/<int:item_id>', methods=['POST'])
    @core.require_auth
    def compliance_action(item_id):
        """`message` (`{"text"}`, анонимному — с `track`) — автору и офицеру;
        `take` и `close` (`{"text"}` — итог) — офицеру."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        data = core._json_body()
        item, officer, mine = _load(item_id, viewer, data)
        if item is None:
            return _fail('not_found', 404)
        action = core._text(data, 'action')
        text = core._text(data, 'text')[:_MAX_TEXT]
        if item.status not in OPEN:
            return _fail('closed', 409)
        now = datetime.utcnow()
        anonymous = item.author_id is None
        if action == 'message':
            if not text:
                return _fail('text_required', 400)
            if ComplianceMessage.query.filter_by(report_id=item.id).count() >= _MAX_MESSAGES:
                return _fail('too_many', 429)
            # Офицер, пишущий в своё же сообщение, — автор, а не офицер.
            from_officer = officer and not mine
            stamp = _anon_time(now) if anonymous and not from_officer else now
            hidden = anonymous and not from_officer
            db.session.add(ComplianceMessage(report_id=item.id,
                                             from_officer=from_officer,
                                             text=text, at=stamp,
                                             notified=not hidden))
            item.updated_at = stamp if not from_officer else now
            db.session.commit()
            if from_officer:
                if not anonymous:
                    _notify([item.author_id], 'Ответ по вашему сообщению на горячую линию',
                            item.id)
            elif not hidden:
                _notify(_officer_ids(), f'Горячая линия: дополнение к №{item.id}',
                        item.id)
        elif action in ('take', 'close'):
            if not officer:
                return core._deny()
            if action == 'take':
                if item.status != 'new':
                    return _fail('bad_state', 409)
                item.status = 'review'
            else:
                if not text:
                    return _fail('text_required', 400)
                item.status = 'closed'
                item.resolution = text
            item.updated_at = now
            db.session.commit()
            if not anonymous:
                title = ('Ваше сообщение на горячую линию взято в проверку'
                         if action == 'take'
                         else 'Проверка по вашему сообщению закончена')
                _notify([item.author_id], title, item.id)
        else:
            return _fail('bad_action', 400)
        if officer or not anonymous:
            logging.info('Горячая линия: №%s %s', item.id, action)
        return jsonify({'message': 'Success', 'item': _json(item, officer, mine)})
