"""«Сообщить об опасности»: пролитое масло, открытый щиток, чуть не
случившаяся травма. Можно анонимно. Инженер БиОТ берёт сообщение и
закрывает его с отметкой, что сделано.

Сейчас о таком говорят мастеру, а до БиОТ доходит, когда уже случилось.
Здесь сообщение сразу у инженеров БиОТ; «опасно прямо сейчас» — первым в
очереди.

Анонимное сообщение хранится без автора вовсе: ни табельного, ни
подразделения. Вместо них автору один раз выдаётся ключ, по которому
телефон потом узнаёт, что стало с сообщением; на сервере лежит только хеш
ключа. Оповещений такому автору нет — некому.

БиОТ — инженеры и руководитель Службы БиОТ или SAFETY_STAFF.
"""

import hashlib
import logging
import os
import secrets
from datetime import datetime, timedelta

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db

CATEGORIES = ('spill', 'electrical', 'equipment', 'fire', 'height',
              'near_miss', 'other')
CATEGORY_TITLES = {
    'spill': 'разлив, скользко', 'electrical': 'электрика',
    'equipment': 'оборудование без защиты', 'fire': 'пожарная опасность',
    'height': 'высота, проёмы', 'near_miss': 'чуть не случилось',
    'other': 'другое',
}
OPEN = ('new', 'in_work')
CLOSED = ('resolved', 'rejected')

_MAX_PLACE = 200
_MAX_TEXT = 2000
_MAX_TRACK = 50
_SHOW_CLOSED_FOR = timedelta(days=30)


class Hazard(db.Model):
    __tablename__ = 'hazards'
    __table_args__ = (db.Index('ix_hazards_status', 'status', 'created_at'),)
    id = db.Column(db.Integer, primary_key=True)
    # Пусто у анонимного — его не знает и сервер.
    author_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                          index=True)
    track_hash = db.Column(db.String(64), unique=True)
    category = db.Column(db.String(12), nullable=False)
    place = db.Column(db.String(_MAX_PLACE), nullable=False)
    text = db.Column(db.Text, nullable=False)
    urgent = db.Column(db.Boolean, nullable=False, default=False)
    status = db.Column(db.String(10), nullable=False, default='new')
    assignee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # Что сделано или почему не опасность.
    outcome = db.Column(db.Text)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    closed_at = db.Column(db.DateTime)


class HazardEvent(db.Model):
    __tablename__ = 'hazard_events'
    id = db.Column(db.Integer, primary_key=True)
    hazard_id = db.Column(db.Integer, db.ForeignKey('hazards.id', ondelete='CASCADE'),
                          nullable=False, index=True)
    # Пусто — автор-аноним или сама система.
    actor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # created, take, resolve, reject, comment
    action = db.Column(db.String(10), nullable=False)
    comment = db.Column(db.Text)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_safety(employee):
    """Инженеры и руководитель БиОТ — не слаботочник из той же службы."""
    if employee is None:
        return False
    dept = _norm(employee.department)
    title = _norm(employee.job_title)
    return (('биот' in dept or 'охраны труда' in dept)
            and ('биот' in title or 'охран' in title or 'промышлен' in title)) \
        or employee.employee_id in _env_ids('SAFETY_STAFF')


def _hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def register(app, core):
    from models import Employee

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _staff(viewer):
        return core._is_system_admin(viewer.job_title) or is_safety(viewer)

    def _names(ids):
        ids = {i for i in ids if i}
        if not ids:
            return {}
        return {e.employee_id: e for e in
                Employee.query.filter(Employee.employee_id.in_(ids))}

    def _person(emp, employee_id):
        if not employee_id:
            return None
        return {'id': employee_id,
                'name': emp.full_name if emp else employee_id,
                'department': (emp.department or '') if emp else ''}

    def _json(item, people, viewer, staff, events=None):
        data = {
            'id': item.id,
            'category': item.category,
            'place': item.place,
            'text': item.text,
            'urgent': bool(item.urgent),
            'status': item.status,
            'anonymous': item.author_id is None,
            'author': _person(people.get(item.author_id), item.author_id),
            'assignee': _person(people.get(item.assignee_id), item.assignee_id),
            'outcome': item.outcome or '',
            'created_at': _utc(item.created_at),
            'updated_at': _utc(item.updated_at),
            'closed_at': _utc(item.closed_at),
            'is_author': viewer is not None and item.author_id == viewer.employee_id,
            'can_act': bool(staff and item.status in OPEN),
        }
        if events is not None:
            data['events'] = [{
                'action': e.action,
                'comment': e.comment or '',
                'at': _utc(e.at),
                # Автора-анонима в истории тоже нет.
                'actor': _person(people.get(e.actor_id), e.actor_id),
            } for e in events]
        return data

    def _with_events(items, viewer, staff):
        events = {}
        for e in (HazardEvent.query
                  .filter(HazardEvent.hazard_id.in_([i.id for i in items] or [-1]))
                  .order_by(HazardEvent.at, HazardEvent.id)):
            events.setdefault(e.hazard_id, []).append(e)
        people = _names([i.author_id for i in items] + [i.assignee_id for i in items]
                        + [e.actor_id for es in events.values() for e in es])
        return [_json(i, people, viewer, staff, events.get(i.id, [])) for i in items]

    def _safety_ids():
        return sorted(e.employee_id for e in Employee.query.all() if is_safety(e))

    def _notify(ids, title, body, ref, actor_id=None):
        ids = sorted({i for i in ids if i and i != actor_id})
        if ids:
            core._record_notice('hazard', title[:200], body[:500],
                                employee_ids=ids, ref=ref)

    @app.route('/api/hazards', methods=['GET'])
    @core.require_auth
    def hazards_list():
        """Мои сообщения; БиОТ — `?scope=queue`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        staff = _staff(viewer)
        if request.args.get('scope') == 'queue':
            if not staff:
                return core._deny()
            since = datetime.utcnow() - _SHOW_CLOSED_FOR
            items = (Hazard.query
                     .filter(db.or_(Hazard.status.in_(OPEN),
                                    Hazard.updated_at >= since))
                     .order_by(Hazard.created_at).limit(300).all())
            # Опасное сейчас и ещё не взятое — первым, закрытое — вниз.
            items.sort(key=lambda i: (i.status in CLOSED, not i.urgent,
                                      i.status != 'new'))
        else:
            items = (Hazard.query.filter_by(author_id=viewer.employee_id)
                     .order_by(Hazard.created_at.desc()).limit(100).all())
        body = {'message': 'Success', 'staff': staff,
                'categories': list(CATEGORIES),
                'items': _with_events(items, viewer, staff)}
        if staff:
            body['open'] = Hazard.query.filter(Hazard.status.in_(OPEN)).count()
            body['new'] = Hazard.query.filter_by(status='new').count()
        return jsonify(body)

    @app.route('/api/hazards', methods=['POST'])
    @core.require_auth
    def hazards_create():
        """`{"category", "place", "text", "urgent", "anonymous"}`. Анонимному
        в ответе — `track`: ключ, по которому потом смотреть, что сделано."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        data = core._json_body()
        category = core._text(data, 'category')
        if category not in CATEGORIES:
            return _fail('bad_category', 400)
        place = ' '.join(core._text(data, 'place').split())[:_MAX_PLACE]
        if not place:
            return _fail('place_required', 400)
        text = core._text(data, 'text')[:_MAX_TEXT]
        if not text:
            return _fail('text_required', 400)
        urgent = data.get('urgent') in (True, 1, '1', 'true')
        anonymous = data.get('anonymous') in (True, 1, '1', 'true')
        now = datetime.utcnow()
        token = secrets.token_urlsafe(24) if anonymous else None
        item = Hazard(author_id=None if anonymous else viewer.employee_id,
                      track_hash=_hash(token) if token else None,
                      category=category, place=place, text=text, urgent=urgent,
                      status='new', created_at=now, updated_at=now)
        db.session.add(item)
        db.session.flush()
        db.session.add(HazardEvent(hazard_id=item.id,
                                   actor_id=item.author_id, action='created', at=now))
        db.session.commit()
        # Кто прислал анонимное — в журнал сервера тоже не пишем.
        logging.info('Опасность №%s (%s)%s', item.id, category,
                     '' if anonymous else f' от {viewer.employee_id}')
        _notify(_safety_ids(),
                f'{"Опасно сейчас" if urgent else "Сообщение об опасности"} '
                f'№{item.id}: {CATEGORY_TITLES[category]}',
                f'{place}. {text}', item.id, item.author_id)
        body = {'message': 'Success',
                'item': _with_events([item], viewer, _staff(viewer))[0]}
        if token:
            body['track'] = token
        return jsonify(body), 201

    @app.route('/api/hazards/track', methods=['POST'])
    @core.require_auth
    def hazards_track():
        """Что стало с моими анонимными: `{"tokens": [...]}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        tokens = core._json_body().get('tokens')
        if not isinstance(tokens, list) or len(tokens) > _MAX_TRACK:
            return _fail('bad_tokens', 400)
        hashes = [_hash(t) for t in tokens if isinstance(t, str) and t]
        items = (Hazard.query.filter(Hazard.track_hash.in_(hashes or ['-']))
                 .order_by(Hazard.created_at.desc()).all())
        return jsonify({'message': 'Success',
                        'items': _with_events(items, None, False)})

    @app.route('/api/hazards/<int:item_id>', methods=['GET'])
    @core.require_auth
    def hazard_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(Hazard, item_id)
        staff = _staff(viewer)
        if item is None or not (staff or item.author_id == viewer.employee_id):
            return _fail('not_found', 404)
        return jsonify({'message': 'Success',
                        'item': _with_events([item], viewer, staff)[0]})

    @app.route('/api/hazards/<int:item_id>', methods=['POST'])
    @core.require_auth
    def hazard_action(item_id):
        """БиОТ: take, resolve (что сделано), reject (почему не опасность),
        comment. Автор (не аноним): comment."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(Hazard, item_id)
        staff = _staff(viewer)
        is_author = item is not None and item.author_id == viewer.employee_id
        if item is None or not (staff or is_author):
            return _fail('not_found', 404)
        data = core._json_body()
        action = core._text(data, 'action')
        comment = core._text(data, 'comment')[:_MAX_TEXT]
        now = datetime.utcnow()
        label = f'№{item.id} ({item.place})'
        tell_author = None

        if action in ('take', 'resolve', 'reject'):
            if not staff:
                return core._deny()
            if item.status in CLOSED:
                return _fail('closed', 409)
        if action == 'take':
            if item.assignee_id == viewer.employee_id:
                return _fail('already_yours', 409)
            item.assignee_id = viewer.employee_id
            item.status = 'in_work'
            tell_author = (f'Сообщение {label} взято в работу',
                           viewer.full_name)
        elif action in ('resolve', 'reject'):
            if not comment:
                return _fail('comment_required', 400)
            item.status = 'resolved' if action == 'resolve' else 'rejected'
            item.outcome = comment
            item.closed_at = now
            if item.assignee_id is None:
                item.assignee_id = viewer.employee_id
            tell_author = (f'Опасность устранена: {label}' if action == 'resolve'
                           else f'Сообщение {label} закрыто', comment)
        elif action == 'comment':
            if not comment:
                return _fail('comment_required', 400)
            if is_author and not staff:
                targets = [item.assignee_id] if item.assignee_id else _safety_ids()
                _notify(targets, f'Комментарий к сообщению {label}', comment,
                        item.id, viewer.employee_id)
            else:
                tell_author = (f'Комментарий БиОТ: {label}', comment)
        else:
            return _fail('bad_action', 400)

        item.updated_at = now
        db.session.add(HazardEvent(hazard_id=item.id, actor_id=viewer.employee_id,
                                   action=action, comment=comment or None, at=now))
        db.session.commit()
        logging.info('Опасность №%s: %s (%s)', item.id, action, viewer.employee_id)
        if tell_author and item.author_id:
            _notify([item.author_id], *tell_author, item.id, viewer.employee_id)
        return jsonify({'message': 'Success',
                        'item': _with_events([item], viewer, staff)[0]})
