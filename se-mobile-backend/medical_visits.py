"""Медосмотры и запись в медпункт: когда пора на периодический осмотр,
флюорографию или прививку, и свободное время в медпункте.

Сейчас о периодическом медосмотре человек узнаёт от мастера накануне, а в
медпункт идёт наугад и ждёт под дверью. Здесь медпункт назначает срок
(одному человеку или всему подразделению сразу), человек видит его у себя
и получает напоминание, а записаться можно на свободное время, которое
медпункт открыл.

Хранятся только виды и даты — когда пройти и когда пройдено. Ни
результатов, ни заключений, ни жалоб: их место — в медицинской карте, а не
в приложении. Медпункт — подразделение «медицинск…» и MED_STAFF, как у
предрейсовых осмотров.
"""

import calendar
import logging
import os
from datetime import date, datetime, time, timedelta

from flask import g, jsonify, request

import demo
from it_requests import _norm, _utc
from models import db

EXAM_KINDS = ('periodic', 'fluorography', 'vaccination')
EXAM_TITLES = {'periodic': 'периодический медосмотр',
               'fluorography': 'флюорография', 'vaccination': 'прививка'}
# Через сколько месяцев следующий, если медпункт не назначил дату сам.
EXAM_EVERY = {'periodic': 12, 'fluorography': 12, 'vaccination': 12}
SLOT_KINDS = ('exam', 'vaccination', 'consult')
SLOT_TITLES = {'exam': 'осмотр', 'vaccination': 'прививка', 'consult': 'приём'}

_DUE_SOON = timedelta(days=30)
_REMIND_SOON = timedelta(days=14)
_REMIND_EVERY = timedelta(days=7)
_SLOTS_AHEAD = 14
_MAX_SLOTS_PER_CALL = 40
_MAX_BOOKINGS = 2


class MedicalExam(db.Model):
    """Срок следующего осмотра человека по виду — одна строка на вид."""
    __tablename__ = 'medical_exams'
    __table_args__ = (db.UniqueConstraint('employee_id', 'kind',
                                          name='uq_medical_exams_employee_kind'),)
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    kind = db.Column(db.String(15), nullable=False)
    due_on = db.Column(db.Date, nullable=False, index=True)
    last_done_on = db.Column(db.Date)
    set_by = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    reminded_at = db.Column(db.DateTime)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class MedicalSlot(db.Model):
    """Время приёма в медпункте; занято, если есть `employee_id`."""
    __tablename__ = 'medical_slots'
    id = db.Column(db.Integer, primary_key=True)
    # Время предприятия, без пояса — как отметки проходной.
    starts_at = db.Column(db.DateTime, nullable=False, index=True)
    kind = db.Column(db.String(15), nullable=False)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            index=True)
    booked_at = db.Column(db.DateTime)
    created_by = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_medic(employee):
    return employee is not None and (
        'медицинск' in _norm(employee.department)
        or employee.employee_id in _env_ids('MED_STAFF'))


def add_months(day, months):
    """31 января + месяц — последний день февраля, а не ошибка."""
    month = day.month - 1 + months
    year, month = day.year + month // 12, month % 12 + 1
    return date(year, month, min(day.day, calendar.monthrange(year, month)[1]))


def exam_state(exam, today):
    if exam.due_on < today:
        return 'overdue'
    if exam.due_on - today <= _DUE_SOON:
        return 'soon'
    return 'ok'


def _parse_hm(raw):
    try:
        return datetime.strptime((raw or '').strip(), '%H:%M').time()
    except ValueError:
        return None


def register(app, core):
    from models import Employee

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

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

    def _exam_json(exam, today, people=None):
        data = {'id': exam.id, 'kind': exam.kind,
                'due_on': exam.due_on.isoformat(),
                'last_done_on': exam.last_done_on.isoformat()
                if exam.last_done_on else None,
                'state': exam_state(exam, today)}
        if people is not None:
            data['employee'] = _person(people.get(exam.employee_id), exam.employee_id)
        return data

    def _slot_json(slot, viewer, people=None):
        data = {'id': slot.id, 'kind': slot.kind,
                'starts_at': slot.starts_at.strftime('%Y-%m-%dT%H:%M'),
                'booked': slot.employee_id is not None,
                'mine': slot.employee_id == viewer.employee_id}
        if people is not None:
            data['employee'] = _person(people.get(slot.employee_id), slot.employee_id)
        return data

    def _notify(ids, title, body, ref=None):
        ids = sorted({i for i in ids if i})
        if ids:
            core._record_notice('medical', title[:200], body[:500],
                                employee_ids=ids, ref=ref, repeat=True)

    def _medic_only():
        viewer = _viewer()
        if viewer is None:
            return None, _fail('unauthorized', 401)
        if not is_medic(viewer):
            return None, core._deny()
        return viewer, None

    def _day_arg():
        raw = request.args.get('date', '')
        if not raw:
            return core._plant_today()
        try:
            return date.fromisoformat(raw)
        except ValueError:
            return None

    @app.route('/api/medical', methods=['GET'])
    @core.require_auth
    def medical_mine():
        """Мои сроки, мои записи и свободное время медпункта на две недели."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        today = core._plant_today()
        now = core._plant_now()
        exams = (MedicalExam.query.filter_by(employee_id=viewer.employee_id)
                 .order_by(MedicalExam.due_on, MedicalExam.id).all())
        mine = (MedicalSlot.query.filter_by(employee_id=viewer.employee_id)
                .filter(MedicalSlot.starts_at >= now)
                .order_by(MedicalSlot.starts_at, MedicalSlot.kind, MedicalSlot.id).all())
        free = (MedicalSlot.query.filter(MedicalSlot.employee_id.is_(None),
                                         MedicalSlot.starts_at >= now,
                                         MedicalSlot.starts_at < datetime.combine(
                                             today + timedelta(days=_SLOTS_AHEAD),
                                             time()))
                .order_by(MedicalSlot.starts_at, MedicalSlot.kind, MedicalSlot.id).limit(300).all())
        return jsonify({
            'message': 'Success',
            'medic': is_medic(viewer),
            'exams': [_exam_json(e, today) for e in exams],
            'bookings': [_slot_json(s, viewer) for s in mine],
            'free': [_slot_json(s, viewer) for s in free],
        })

    @app.route('/api/medical/slots/<int:slot_id>/book', methods=['POST'])
    @core.require_auth
    def medical_book(slot_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        slot = db.session.get(MedicalSlot, slot_id)
        if slot is None:
            return _fail('not_found', 404)
        if slot.starts_at < core._plant_now():
            return _fail('past', 409)
        if slot.employee_id is not None:
            return _fail('taken', 409)
        upcoming = MedicalSlot.query.filter(
            MedicalSlot.employee_id == viewer.employee_id,
            MedicalSlot.starts_at >= core._plant_now()).count()
        if upcoming >= _MAX_BOOKINGS:
            return _fail('too_many', 409)
        # Занять, только если никто не успел раньше — двое жмут одновременно.
        taken = (MedicalSlot.query.filter_by(id=slot.id, employee_id=None)
                 .update({'employee_id': viewer.employee_id,
                          'booked_at': datetime.utcnow()},
                         synchronize_session=False))
        db.session.commit()
        if not taken:
            return _fail('taken', 409)
        db.session.refresh(slot)
        logging.info('Медпункт: запись %s на %s', viewer.employee_id, slot.starts_at)
        return jsonify({'message': 'Success', 'slot': _slot_json(slot, viewer)})

    @app.route('/api/medical/slots/<int:slot_id>/cancel', methods=['POST'])
    @core.require_auth
    def medical_cancel(slot_id):
        """Отменить запись: свою — сам человек, любую — медпункт."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        slot = db.session.get(MedicalSlot, slot_id)
        if slot is None:
            return _fail('not_found', 404)
        medic = is_medic(viewer)
        if slot.employee_id is None:
            return _fail('not_booked', 409)
        if slot.employee_id != viewer.employee_id and not medic:
            return core._deny()
        if slot.starts_at < core._plant_now():
            return _fail('past', 409)
        who = slot.employee_id
        slot.employee_id = None
        slot.booked_at = None
        db.session.commit()
        if who != viewer.employee_id:
            _notify([who], 'Запись в медпункт отменена',
                    slot.starts_at.strftime('%d.%m.%Y %H:%M'))
        return jsonify({'message': 'Success', 'slot': _slot_json(slot, viewer)})

    @app.route('/api/medical/desk', methods=['GET'])
    @core.require_auth
    def medical_desk():
        """Медпункту: приёмы дня (`?date=`) с записавшимися и сроки на месяц."""
        viewer, denied = _medic_only()
        if denied:
            return denied
        day = _day_arg()
        if day is None:
            return _fail('bad_date', 400)
        today = core._plant_today()
        slots = (MedicalSlot.query
                 .filter(MedicalSlot.starts_at >= datetime.combine(day, time()),
                         MedicalSlot.starts_at < datetime.combine(
                             day + timedelta(days=1), time()))
                 .order_by(MedicalSlot.starts_at, MedicalSlot.kind, MedicalSlot.id).all())
        # Сроки гостевого мира (demo.py) медпункту не видны — и наоборот.
        due = (MedicalExam.query.filter(MedicalExam.due_on <= today + _DUE_SOON,
                                        demo.world(MedicalExam.employee_id, viewer))
               .order_by(MedicalExam.due_on, MedicalExam.id).limit(300).all())
        people = _names([s.employee_id for s in slots] + [e.employee_id for e in due])
        return jsonify({
            'message': 'Success',
            'date': day.isoformat(),
            'slots': [_slot_json(s, viewer, people) for s in slots],
            'due': [_exam_json(e, today, people) for e in due],
        })

    @app.route('/api/medical/slots', methods=['POST'])
    @core.require_auth
    def medical_slots_create():
        """`{"date", "from": "09:00", "to": "11:00", "step": 15, "kind"}` —
        открыть время приёма; уже открытое в то же время не дублируется."""
        viewer, denied = _medic_only()
        if denied:
            return denied
        data = core._json_body()
        kind = core._text(data, 'kind') or 'exam'
        if kind not in SLOT_KINDS:
            return _fail('bad_kind', 400)
        try:
            day = date.fromisoformat(core._text(data, 'date'))
        except ValueError:
            return _fail('bad_date', 400)
        today = core._plant_today()
        if not today <= day <= today + timedelta(days=60):
            return _fail('bad_date', 400)
        start, end = _parse_hm(core._text(data, 'from')), _parse_hm(core._text(data, 'to'))
        step = data.get('step', 15)
        if isinstance(step, str) and step.strip().isdigit():
            step = int(step)
        if start is None or end is None or start >= end:
            return _fail('bad_time', 400)
        if isinstance(step, bool) or not isinstance(step, int) or not 5 <= step <= 120:
            return _fail('bad_step', 400)
        moment = datetime.combine(day, start)
        stop = datetime.combine(day, end)
        wanted = []
        while moment < stop:
            wanted.append(moment)
            moment += timedelta(minutes=step)
        if len(wanted) > _MAX_SLOTS_PER_CALL:
            return _fail('too_many', 400)
        have = {s.starts_at for s in MedicalSlot.query.filter(
            MedicalSlot.kind == kind, MedicalSlot.starts_at.in_(wanted))}
        now = core._plant_now()
        added = 0
        for moment in wanted:
            if moment in have or moment < now:
                continue
            db.session.add(MedicalSlot(starts_at=moment, kind=kind,
                                       created_by=viewer.employee_id))
            added += 1
        db.session.commit()
        logging.info('Медпункт: открыто %d приёмов на %s (%s)', added, day,
                     viewer.employee_id)
        return jsonify({'message': 'Success', 'added': added}), 201

    @app.route('/api/medical/slots/<int:slot_id>', methods=['DELETE'])
    @core.require_auth
    def medical_slot_delete(slot_id):
        viewer, denied = _medic_only()
        if denied:
            return denied
        slot = db.session.get(MedicalSlot, slot_id)
        if slot is None:
            return _fail('not_found', 404)
        who = slot.employee_id
        when = slot.starts_at
        db.session.delete(slot)
        db.session.commit()
        if who and when >= core._plant_now():
            _notify([who], 'Запись в медпункт отменена', when.strftime('%d.%m.%Y %H:%M'))
        return jsonify({'message': 'Success'})

    @app.route('/api/medical/people', methods=['GET'])
    @core.require_auth
    def medical_people():
        viewer, denied = _medic_only()
        if denied:
            return denied
        q = _norm(request.args.get('q', ''))
        people = []
        for e in (Employee.query.filter(demo.world(Employee.employee_id, viewer))
                  .order_by(Employee.full_name)):
            if not e.full_name:
                continue
            if q and q not in _norm(e.full_name) and q not in _norm(e.job_title):
                continue
            people.append(_person(e, e.employee_id))
            if len(people) >= 50:
                break
        return jsonify({'message': 'Success', 'people': people})

    @app.route('/api/medical/departments', methods=['GET'])
    @core.require_auth
    def medical_departments():
        viewer, denied = _medic_only()
        if denied:
            return denied
        counts = {}
        for e in Employee.query.filter(Employee.department.isnot(None),
                                       demo.world(Employee.employee_id, viewer)):
            if e.department.strip():
                counts[e.department] = counts.get(e.department, 0) + 1
        return jsonify({'message': 'Success', 'departments': [
            {'name': name, 'count': n} for name, n in sorted(counts.items())]})

    @app.route('/api/medical/exams', methods=['POST'])
    @core.require_auth
    def medical_exams_set():
        """`{"kind", "due_on", "employee_ids": [...]}` или `"department"` —
        назначить срок (заменяет прежний срок того же вида)."""
        viewer, denied = _medic_only()
        if denied:
            return denied
        data = core._json_body()
        kind = core._text(data, 'kind')
        if kind not in EXAM_KINDS:
            return _fail('bad_kind', 400)
        try:
            due = date.fromisoformat(core._text(data, 'due_on'))
        except ValueError:
            return _fail('bad_date', 400)
        today = core._plant_today()
        if not today <= due <= today + timedelta(days=366):
            return _fail('bad_date', 400)
        department = core._text(data, 'department')
        if department:
            ids = [e.employee_id for e in Employee.query.filter_by(department=department)]
        else:
            raw = data.get('employee_ids')
            ids = [i for i in raw if isinstance(i, str)] if isinstance(raw, list) else []
            ids = [e.employee_id for e in Employee.query.filter(
                Employee.employee_id.in_(ids or ['-']))]
        if not ids:
            return _fail('no_people', 400)
        existing = {e.employee_id: e for e in MedicalExam.query.filter(
            MedicalExam.kind == kind, MedicalExam.employee_id.in_(ids))}
        now = datetime.utcnow()
        for employee_id in ids:
            exam = existing.get(employee_id)
            if exam is None:
                exam = MedicalExam(employee_id=employee_id, kind=kind)
                db.session.add(exam)
            exam.due_on = due
            exam.set_by = viewer.employee_id
            exam.reminded_at = None
            exam.updated_at = now
        db.session.commit()
        logging.info('Медпункт: %s до %s назначено %d сотрудникам (%s)', kind, due,
                     len(ids), viewer.employee_id)
        _notify(ids, f'Медпункт: {EXAM_TITLES[kind]}',
                f'Пройти до {due.strftime("%d.%m.%Y")}. Записаться можно в приложении')
        return jsonify({'message': 'Success', 'count': len(ids)}), 201

    @app.route('/api/medical/exams/<int:exam_id>', methods=['POST'])
    @core.require_auth
    def medical_exam_done(exam_id):
        """`{"action": "done", "next_due_on"}` — пройдено; следующий срок
        назначенный или через год."""
        viewer, denied = _medic_only()
        if denied:
            return denied
        exam = db.session.get(MedicalExam, exam_id)
        if exam is None:
            return _fail('not_found', 404)
        data = core._json_body()
        if core._text(data, 'action') != 'done':
            return _fail('bad_action', 400)
        today = core._plant_today()
        raw = core._text(data, 'next_due_on')
        try:
            next_due = date.fromisoformat(raw) if raw else add_months(
                today, EXAM_EVERY[exam.kind])
        except ValueError:
            return _fail('bad_date', 400)
        if next_due <= today:
            return _fail('bad_date', 400)
        exam.last_done_on = today
        exam.due_on = next_due
        exam.set_by = viewer.employee_id
        exam.reminded_at = None
        exam.updated_at = datetime.utcnow()
        db.session.commit()
        people = _names([exam.employee_id])
        return jsonify({'message': 'Success', 'exam': _exam_json(exam, today, people)})

    @app.route('/api/medical/remind-due', methods=['POST'])
    @core.require_auth
    def medical_remind_due():
        """Напомнить тем, у кого срок вышел или выходит в две недели — не
        чаще раза в неделю одному и тому же."""
        viewer, denied = _medic_only()
        if denied:
            return denied
        today = core._plant_today()
        now = datetime.utcnow()
        due = MedicalExam.query.filter(MedicalExam.due_on <= today + _REMIND_SOON,
                                       demo.world(MedicalExam.employee_id, viewer)).all()
        reminded = 0
        for exam in due:
            if exam.reminded_at and now - exam.reminded_at < _REMIND_EVERY:
                continue
            late = exam.due_on < today
            _notify([exam.employee_id], f'Медпункт: {EXAM_TITLES[exam.kind]}',
                    ('Срок прошёл ' if late else 'Пройти до ')
                    + exam.due_on.strftime('%d.%m.%Y'))
            exam.reminded_at = now
            reminded += 1
        db.session.commit()
        return jsonify({'message': 'Success', 'reminded': reminded})
