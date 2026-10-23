"""Запись на приём к руководству: свободные окна, приёмная подтверждает.

Сейчас на приём к генеральному директору записываются звонком в приёмную:
офис-менеджер смотрит в тетрадь, перезванивает, когда окно найдётся, а
человек полдня ждёт звонка. Здесь приёмная открывает окна приёма — у
генерального директора и заместителей, — сотрудник выбирает свободное и
пишет, с каким вопросом; приёмная подтверждает или отказывает с причиной,
и человеку сразу приходит ответ.

Ведёт запись приёмная (офис-менеджер), системный администратор и
RECEPTION_STAFF. Руководитель видит свой день. Вопрос, с которым идут,
видят только приёмная и сам руководитель.
"""

import logging
import os
from datetime import date, datetime, time, timedelta

from flask import g, jsonify, request

from business_trips import is_top
from it_requests import _norm
from models import db

STATUSES = ('requested', 'confirmed')

_SLOTS_AHEAD = 30
_MAX_SLOTS_PER_CALL = 40
_MAX_TOPIC = 300


class ReceptionSlot(db.Model):
    """Окно приёма у руководителя; занято, если есть `employee_id`."""
    __tablename__ = 'reception_slots'
    __table_args__ = (db.UniqueConstraint('host_id', 'starts_at',
                                          name='uq_reception_slots_host_time'),)
    id = db.Column(db.Integer, primary_key=True)
    host_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                        nullable=False, index=True)
    # Время предприятия, без пояса — как в медпункте.
    starts_at = db.Column(db.DateTime, nullable=False, index=True)
    minutes = db.Column(db.Integer, nullable=False, default=15)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            index=True)
    topic = db.Column(db.String(_MAX_TOPIC))
    status = db.Column(db.String(10))
    booked_at = db.Column(db.DateTime)
    created_by = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_reception(employee, core):
    if employee is None:
        return False
    dept = _norm(employee.department).replace('ё', 'е')
    return ('приемная' in dept or 'офис-менеджер' in _norm(employee.job_title)
            or core._is_system_admin(employee.job_title)
            or employee.employee_id in _env_ids('RECEPTION_STAFF'))


def _parse_hm(raw):
    try:
        return datetime.strptime((raw or '').strip(), '%H:%M').time()
    except ValueError:
        return None


def _stamp(moment):
    return moment.strftime('%d.%m.%Y %H:%M')


def register(app, core):
    from models import Employee

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _hosts():
        """К кому записываются: руководство, генеральный — первым."""
        found = [e for e in Employee.query.order_by(Employee.full_name).all()
                 if is_top(e)]
        found.sort(key=lambda e: (not _norm(e.job_title).startswith('генеральный'),
                                  e.full_name))
        return found

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
                'job_title': (emp.job_title or '') if emp else '',
                'department': (emp.department or '') if emp else ''}

    def _slot_json(slot, viewer, people, full=False):
        data = {'id': slot.id,
                'host': _person(people.get(slot.host_id), slot.host_id),
                'starts_at': slot.starts_at.strftime('%Y-%m-%dT%H:%M'),
                'minutes': slot.minutes,
                'booked': slot.employee_id is not None,
                'mine': slot.employee_id == viewer.employee_id}
        if full or data['mine']:
            data['topic'] = slot.topic or ''
            data['status'] = slot.status
        if full:
            data['employee'] = _person(people.get(slot.employee_id), slot.employee_id)
        return data

    def _notify(ids, title, body, ref=None):
        ids = sorted({i for i in ids if i})
        if ids:
            core._record_notice('reception', title[:200], body[:500],
                                employee_ids=ids, ref=ref, repeat=True)

    def _reception_ids():
        return [e.employee_id for e in Employee.query.all()
                if is_reception(e, core)
                and not core._is_system_admin(e.job_title)]

    def _manager():
        viewer = _viewer()
        if viewer is None:
            return None, _fail('unauthorized', 401)
        if not is_reception(viewer, core):
            return None, core._deny()
        return viewer, None

    @app.route('/api/reception', methods=['GET'])
    @core.require_auth
    def reception_mine():
        """Мои записи, руководители и их свободные окна на месяц вперёд."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        now = core._plant_now()
        hosts = _hosts()
        mine = (ReceptionSlot.query.filter_by(employee_id=viewer.employee_id)
                .filter(ReceptionSlot.starts_at >= now - timedelta(days=1))
                .order_by(ReceptionSlot.starts_at, ReceptionSlot.id).all())
        free = (ReceptionSlot.query.filter(
                    ReceptionSlot.employee_id.is_(None),
                    ReceptionSlot.starts_at >= now,
                    ReceptionSlot.starts_at < datetime.combine(
                        core._plant_today() + timedelta(days=_SLOTS_AHEAD), time()))
                .order_by(ReceptionSlot.starts_at, ReceptionSlot.host_id,
                          ReceptionSlot.id).limit(300).all())
        people = {e.employee_id: e for e in hosts}
        return jsonify({
            'message': 'Success',
            'manager': is_reception(viewer, core),
            'host': is_top(viewer),
            'hosts': [_person(e, e.employee_id) for e in hosts],
            'bookings': [_slot_json(s, viewer, people) for s in mine],
            'free': [_slot_json(s, viewer, people) for s in free],
        })

    @app.route('/api/reception/slots/<int:slot_id>/book', methods=['POST'])
    @core.require_auth
    def reception_book(slot_id):
        """{topic} — с каким вопросом. Одна открытая запись к каждому."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        slot = db.session.get(ReceptionSlot, slot_id)
        if slot is None:
            return _fail('not_found', 404)
        now = core._plant_now()
        if slot.starts_at < now:
            return _fail('past', 409)
        if slot.employee_id is not None:
            return _fail('taken', 409)
        if slot.host_id == viewer.employee_id:
            return _fail('own', 409)
        topic = ' '.join(core._text(core._json_body(), 'topic').split())[:_MAX_TOPIC]
        if len(topic) < 3:
            return _fail('topic_required', 400)
        upcoming = ReceptionSlot.query.filter(
            ReceptionSlot.employee_id == viewer.employee_id,
            ReceptionSlot.host_id == slot.host_id,
            ReceptionSlot.starts_at >= now).count()
        if upcoming:
            return _fail('too_many', 409)
        # Занять, только если никто не успел раньше.
        taken = (ReceptionSlot.query.filter_by(id=slot.id, employee_id=None)
                 .update({'employee_id': viewer.employee_id, 'topic': topic,
                          'status': 'requested', 'booked_at': datetime.utcnow()},
                         synchronize_session=False))
        db.session.commit()
        if not taken:
            return _fail('taken', 409)
        db.session.refresh(slot)
        host = db.session.get(Employee, slot.host_id)
        _notify(_reception_ids(), 'Запись на приём: нужно подтвердить',
                f'{viewer.full_name} — к {host.full_name if host else ""}, '
                f'{_stamp(slot.starts_at)}', ref=str(slot.id))
        logging.info('Приёмная: запись %s на %s', viewer.employee_id, slot.starts_at)
        return jsonify({'message': 'Success',
                        'slot': _slot_json(slot, viewer, _names([slot.host_id]))})

    @app.route('/api/reception/slots/<int:slot_id>/cancel', methods=['POST'])
    @core.require_auth
    def reception_cancel(slot_id):
        """Отменить свою запись — окно снова свободно."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        slot = db.session.get(ReceptionSlot, slot_id)
        if slot is None:
            return _fail('not_found', 404)
        if slot.employee_id != viewer.employee_id:
            return core._deny()
        if slot.starts_at < core._plant_now():
            return _fail('past', 409)
        slot.employee_id = slot.topic = slot.status = slot.booked_at = None
        db.session.commit()
        _notify(_reception_ids(), 'Запись на приём отменена',
                f'{viewer.full_name}, {_stamp(slot.starts_at)}')
        return jsonify({'message': 'Success'})

    @app.route('/api/reception/desk', methods=['GET'])
    @core.require_auth
    def reception_desk():
        """День приёма (`?date=`, `?host=`): приёмной — любой, руководителю — свой."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        manager = is_reception(viewer, core)
        host_id = request.args.get('host') or ''
        if not manager:
            if not is_top(viewer):
                return core._deny()
            host_id = viewer.employee_id
        raw = request.args.get('date', '')
        try:
            day = date.fromisoformat(raw) if raw else core._plant_today()
        except ValueError:
            return _fail('bad_date', 400)
        query = ReceptionSlot.query.filter(
            ReceptionSlot.starts_at >= datetime.combine(day, time()),
            ReceptionSlot.starts_at < datetime.combine(day + timedelta(days=1), time()))
        if host_id:
            query = query.filter_by(host_id=host_id)
        slots = query.order_by(ReceptionSlot.starts_at, ReceptionSlot.host_id,
                               ReceptionSlot.id).all()
        people = _names([s.host_id for s in slots] + [s.employee_id for s in slots])
        return jsonify({'message': 'Success', 'date': day.isoformat(),
                        'slots': [_slot_json(s, viewer, people, full=True)
                                  for s in slots]})

    @app.route('/api/reception/slots', methods=['POST'])
    @core.require_auth
    def reception_slots_create():
        """{host_id, date, from: "14:00", to: "16:00", step: 15} — открыть окна."""
        viewer, denied = _manager()
        if denied:
            return denied
        data = core._json_body()
        host = db.session.get(Employee, core._text(data, 'host_id'))
        if host is None or not is_top(host):
            return _fail('bad_host', 400)
        try:
            day = date.fromisoformat(core._text(data, 'date'))
        except ValueError:
            return _fail('bad_date', 400)
        today = core._plant_today()
        if not today <= day <= today + timedelta(days=90):
            return _fail('bad_date', 400)
        start, end = _parse_hm(core._text(data, 'from')), _parse_hm(core._text(data, 'to'))
        step = data.get('step', 15)
        if isinstance(step, str) and step.strip().isdigit():
            step = int(step)
        if start is None or end is None or start >= end:
            return _fail('bad_time', 400)
        if isinstance(step, bool) or not isinstance(step, int) or not 5 <= step <= 120:
            return _fail('bad_step', 400)
        wanted = []
        moment, stop = datetime.combine(day, start), datetime.combine(day, end)
        while moment < stop:
            wanted.append(moment)
            moment += timedelta(minutes=step)
        if len(wanted) > _MAX_SLOTS_PER_CALL:
            return _fail('too_many', 400)
        have = {s.starts_at for s in ReceptionSlot.query.filter(
            ReceptionSlot.host_id == host.employee_id,
            ReceptionSlot.starts_at.in_(wanted))}
        now = core._plant_now()
        added = 0
        for moment in wanted:
            if moment in have or moment < now:
                continue
            db.session.add(ReceptionSlot(host_id=host.employee_id, starts_at=moment,
                                         minutes=step, created_by=viewer.employee_id))
            added += 1
        db.session.commit()
        return jsonify({'message': 'Success', 'added': added}), 201

    @app.route('/api/reception/slots/<int:slot_id>', methods=['POST'])
    @core.require_auth
    def reception_slot_action(slot_id):
        """{action: confirm | decline {reason}} — ответ записавшемуся."""
        viewer, denied = _manager()
        if denied:
            return denied
        slot = db.session.get(ReceptionSlot, slot_id)
        if slot is None:
            return _fail('not_found', 404)
        if slot.employee_id is None:
            return _fail('not_booked', 409)
        data = core._json_body()
        action = data.get('action')
        host = db.session.get(Employee, slot.host_id)
        whom = host.full_name if host else ''
        if action == 'confirm':
            slot.status = 'confirmed'
            db.session.commit()
            _notify([slot.employee_id], 'Приём подтверждён',
                    f'{_stamp(slot.starts_at)}, {whom}', ref=str(slot.id))
        elif action == 'decline':
            reason = ' '.join(core._text(data, 'reason').split())[:300]
            if not reason:
                return _fail('reason_required', 400)
            who = slot.employee_id
            slot.employee_id = slot.topic = slot.status = slot.booked_at = None
            db.session.commit()
            _notify([who], 'Приём не состоится',
                    f'{_stamp(slot.starts_at)}, {whom}. {reason}')
        else:
            return _fail('bad_action', 400)
        people = _names([slot.host_id, slot.employee_id])
        return jsonify({'message': 'Success',
                        'slot': _slot_json(slot, viewer, people, full=True)})

    @app.route('/api/reception/slots/<int:slot_id>', methods=['DELETE'])
    @core.require_auth
    def reception_slot_delete(slot_id):
        """Убрать окно; записавшемуся — что приёма не будет."""
        viewer, denied = _manager()
        if denied:
            return denied
        slot = db.session.get(ReceptionSlot, slot_id)
        if slot is None:
            return _fail('not_found', 404)
        who, when = slot.employee_id, slot.starts_at
        db.session.delete(slot)
        db.session.commit()
        if who and when >= core._plant_now():
            _notify([who], 'Приём не состоится',
                    f'{_stamp(when)}. Приёмная перенесла окно — запишитесь снова')
        return jsonify({'message': 'Success'})
