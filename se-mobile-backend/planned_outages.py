"""Плановые отключения: сеть, телефон, 1С, свет — заранее и тем, кого касается.

Сейчас о том, что в субботу отключат свет во втором корпусе или вечером
перезагрузят сервер 1С, узнают по телефону — или не узнают и теряют
несохранённую работу. Здесь ОИТиС и служба главного инженера объявляют
отключение: что, когда и каким подразделениям. Оповещение приходит сразу,
ещё раз — за пару часов до начала, и при отмене.

Объявляют: ОИТиС, служба главного инженера (энергетики), системный
администратор и OUTAGE_STAFF. Видят все — свои отключения отмечены.
"""

import os
import threading
from datetime import datetime, timedelta

from flask import g, jsonify

from it_requests import _norm, is_it_staff
from models import db

KINDS = ('power', 'network', 'phone', 'service', 'water', 'heat', 'other')
KIND_TITLES = {
    'power': 'электроэнергии', 'network': 'сети и интернета',
    'phone': 'телефонной связи', 'service': 'сервиса', 'water': 'воды',
    'heat': 'отопления', 'other': '',
}

_REMIND_BEFORE = timedelta(hours=2)
_REMIND_CHECK_EVERY = timedelta(minutes=10)
_MAX_AHEAD = timedelta(days=90)
_MAX_LENGTH = timedelta(days=14)
_SHOW_PAST = timedelta(days=7)


class Outage(db.Model):
    __tablename__ = 'outages'
    id = db.Column(db.Integer, primary_key=True)
    kind = db.Column(db.String(10), nullable=False)
    note = db.Column(db.String(500))
    # Время завода, как в расписании медпункта.
    starts_at = db.Column(db.DateTime, nullable=False, index=True)
    ends_at = db.Column(db.DateTime, nullable=False)
    # Подразделения строками; пусто — всё предприятие.
    departments = db.Column(db.Text, nullable=False, default='')
    author_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    cancelled_at = db.Column(db.DateTime)
    reminded = db.Column(db.Boolean, nullable=False, default=False)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def may_announce(employee, core):
    if employee is None:
        return False
    return (is_it_staff(employee)
            or 'главного инженера' in _norm(employee.department)
            or core._is_system_admin(employee.job_title)
            or employee.employee_id in _env_ids('OUTAGE_STAFF'))


def _key(name):
    return ' '.join(_norm(name).split())


def departments_of(outage):
    return [d for d in (outage.departments or '').split('\n') if d]


def concerns(outage, employee):
    wanted = {_key(d) for d in departments_of(outage)}
    return not wanted or _key(employee.department) in wanted


def _when(outage):
    start, end = outage.starts_at, outage.ends_at
    if start.date() == end.date():
        return f"{start:%d.%m} с {start:%H:%M} до {end:%H:%M}"
    return f"с {start:%d.%m %H:%M} до {end:%d.%m %H:%M}"


def _title(outage, prefix='Отключение'):
    what = KIND_TITLES.get(outage.kind, '')
    return ' '.join(p for p in (prefix, what, _when(outage)) if p)


def _audience(outage):
    from models import Employee
    return sorted(e.employee_id for e in Employee.query.all()
                  if concerns(outage, e))


def _body(outage):
    where = ', '.join(departments_of(outage)) or 'всё предприятие'
    return ((outage.note + '. ') if outage.note else '') + f'Касается: {where}'


def remind_soon(core):
    """За пару часов до начала — ещё раз тем, кого касается."""
    now = core._plant_now()
    due = (Outage.query.filter(Outage.cancelled_at.is_(None),
                               Outage.reminded.is_(False),
                               Outage.starts_at > now,
                               Outage.starts_at <= now + _REMIND_BEFORE)
           .order_by(Outage.starts_at, Outage.id).all())
    for outage in due:
        outage.reminded = True
        db.session.commit()
        ids = _audience(outage)
        if ids:
            core._record_notice('outage', _title(outage, 'Скоро отключение')[:200],
                                _body(outage)[:500], employee_ids=ids,
                                ref=str(outage.id))
    return len(due)


_remind_lock = threading.Lock()
_reminded_at = None


def register(app, core):
    from models import Employee

    @app.before_request
    def _outage_reminders():
        """Раз в десять минут, с первым же запросом, — «скоро отключение»."""
        global _reminded_at
        now = datetime.utcnow()
        if _reminded_at is not None and now - _reminded_at < _REMIND_CHECK_EVERY:
            return
        if not _remind_lock.acquire(blocking=False):
            return
        try:
            _reminded_at = now
            remind_soon(core)
        except Exception:
            db.session.rollback()
        finally:
            _remind_lock.release()

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _json(outage, viewer, now):
        author = db.session.get(Employee, outage.author_id) if outage.author_id else None
        if outage.cancelled_at:
            state = 'cancelled'
        elif outage.ends_at <= now:
            state = 'past'
        elif outage.starts_at <= now:
            state = 'now'
        else:
            state = 'planned'
        return {
            'id': outage.id,
            'kind': outage.kind,
            'note': outage.note or '',
            'starts_at': outage.starts_at.strftime('%Y-%m-%dT%H:%M'),
            'ends_at': outage.ends_at.strftime('%Y-%m-%dT%H:%M'),
            'departments': departments_of(outage),
            'mine': concerns(outage, viewer),
            'state': state,
            'author': {'id': author.employee_id, 'name': author.full_name,
                       'job_title': author.job_title or ''} if author else None,
        }

    def _time(raw):
        try:
            return datetime.strptime(str(raw or '').strip().replace('T', ' ')[:16],
                                     '%Y-%m-%d %H:%M')
        except ValueError:
            return None

    @app.route('/api/outages', methods=['GET'])
    @core.require_auth
    def outages_list():
        viewer = getattr(g, 'employee', None)
        if viewer is None:
            return _fail('unauthorized', 401)
        now = core._plant_now()
        rows = (Outage.query.filter(Outage.ends_at >= now - _SHOW_PAST)
                .order_by(Outage.starts_at, Outage.id).all())
        items = [_json(o, viewer, now) for o in rows]
        return jsonify({'message': 'Success',
                        'staff': may_announce(viewer, core),
                        'items': items})

    @app.route('/api/outages/departments', methods=['GET'])
    @core.require_auth
    def outages_departments():
        viewer = getattr(g, 'employee', None)
        if not may_announce(viewer, core):
            return core._deny()
        names = sorted({d for (d,) in db.session.query(Employee.department)
                        .distinct() if d})
        return jsonify({'message': 'Success', 'departments': names})

    @app.route('/api/outages', methods=['POST'])
    @core.require_auth
    def outages_create():
        """{kind, starts_at, ends_at, note, departments: [] — пусто, всем}."""
        viewer = getattr(g, 'employee', None)
        if not may_announce(viewer, core):
            return core._deny()
        data = core._json_body()
        kind = data.get('kind')
        if kind not in KINDS:
            return _fail('bad_kind', 400)
        start, end = _time(data.get('starts_at')), _time(data.get('ends_at'))
        if start is None or end is None:
            return _fail('bad_time', 400)
        now = core._plant_now()
        if end <= start:
            return _fail('ends_before', 400)
        if end <= now:
            return _fail('past', 400)
        if start - now > _MAX_AHEAD or end - start > _MAX_LENGTH:
            return _fail('too_long', 400)
        note = ' '.join(core._text(data, 'note').split())[:500]
        if kind == 'other' and not note:
            return _fail('note_required', 400)
        raw = data.get('departments') or []
        if not isinstance(raw, list):
            return _fail('bad_departments', 400)
        known = {_key(d): d for (d,) in db.session.query(Employee.department)
                 .distinct() if d}
        departments = []
        for name in raw:
            found = known.get(_key(name)) if isinstance(name, str) else None
            if found is None:
                return _fail('bad_departments', 400)
            if found not in departments:
                departments.append(found)

        outage = Outage(kind=kind, note=note or None, starts_at=start, ends_at=end,
                        departments='\n'.join(departments),
                        author_id=viewer.employee_id,
                        # Объявили за час до начала — сразу и есть «скоро».
                        reminded=start - now <= _REMIND_BEFORE)
        db.session.add(outage)
        db.session.commit()
        ids = [i for i in _audience(outage) if i != viewer.employee_id]
        if ids:
            core._record_notice('outage', _title(outage)[:200], _body(outage)[:500],
                                employee_ids=ids, ref=str(outage.id))
        return jsonify({'message': 'Success',
                        'outage': _json(outage, viewer, now),
                        'notified': len(ids)}), 201

    @app.route('/api/outages/<int:outage_id>', methods=['POST'])
    @core.require_auth
    def outages_action(outage_id):
        """{action: cancel} — отменить и сказать всем, кому объявляли."""
        viewer = getattr(g, 'employee', None)
        if not may_announce(viewer, core):
            return core._deny()
        outage = db.session.get(Outage, outage_id)
        if outage is None:
            return _fail('not_found', 404)
        if core._json_body().get('action') != 'cancel':
            return _fail('bad_action', 400)
        now = core._plant_now()
        if outage.cancelled_at is not None or outage.ends_at <= now:
            return _fail('closed', 409)
        outage.cancelled_at = datetime.utcnow()
        db.session.commit()
        ids = [i for i in _audience(outage) if i != viewer.employee_id]
        if ids:
            core._record_notice('outage', _title(outage, 'Отменено отключение')[:200],
                                'Работы перенесены или не понадобились',
                                employee_ids=ids, ref=str(outage.id))
        return jsonify({'message': 'Success', 'outage': _json(outage, viewer, now)})
