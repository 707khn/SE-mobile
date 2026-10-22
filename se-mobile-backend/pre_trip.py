"""Предрейсовый медосмотр и выпуск на линию: медпункт отмечает осмотр
водителя, механик — исправность машины, водитель и руководство видят
«допущен» или «не допущен» на сегодня.

Сейчас это два бумажных журнала, и чтобы узнать, выпущен ли водитель,
звонят в медпункт. Здесь журнал тот же, но в одном месте: медработник
вносит давление, пульс, температуру и пробу на алкоголь, механик — госномер,
пробег и исправность. С положительной пробой на алкоголь допустить нельзя.

Показатели осмотра — медицинские сведения: их видят медпункт и сам
водитель. Заведующему ХО, руководству ДМТО (и FLEET_MANAGERS) и механику —
только «допущен / не допущен», без причины по здоровью.

Медпункт — подразделение «Медицинский пункт» или MED_STAFF; механики —
должность «механик» или FLEET_MECHANICS; водители — подразделение «Гараж»,
должность «водитель» или FLEET_DRIVERS.
"""

import logging
import os
from datetime import date, datetime

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db
from stock_requests import is_supply_head

# Границы, за которыми медработнику подсвечивается показатель. Решает он.
SYSTOLIC_HIGH = 140
DIASTOLIC_HIGH = 90
PULSE_LOW, PULSE_HIGH = 50, 100
TEMPERATURE_HIGH = 37.0

_MAX_TEXT = 500
_HISTORY_DAYS = 30


class PreTripExam(db.Model):
    __tablename__ = 'pre_trip_exams'
    __table_args__ = (db.Index('ix_pre_trip_exams_day', 'exam_date', 'employee_id'),)
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    # pre — предрейсовый, post — послерейсовый.
    kind = db.Column(db.String(4), nullable=False, default='pre')
    exam_date = db.Column(db.Date, nullable=False)
    systolic = db.Column(db.Integer)
    diastolic = db.Column(db.Integer)
    pulse = db.Column(db.Integer)
    temperature = db.Column(db.Float)
    # мг/л в выдыхаемом воздухе; 0 — проба отрицательная.
    alcohol = db.Column(db.Float)
    complaints = db.Column(db.String(_MAX_TEXT))
    admitted = db.Column(db.Boolean, nullable=False)
    reason = db.Column(db.String(_MAX_TEXT))
    medic_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                         nullable=False)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class VehicleCheck(db.Model):
    __tablename__ = 'vehicle_checks'
    __table_args__ = (db.Index('ix_vehicle_checks_day', 'check_date', 'employee_id'),)
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    check_date = db.Column(db.Date, nullable=False)
    plate = db.Column(db.String(20), nullable=False)
    odometer = db.Column(db.Integer)
    ok = db.Column(db.Boolean, nullable=False)
    reason = db.Column(db.String(_MAX_TEXT))
    mechanic_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_medic(employee):
    return employee is not None and (
        'медицинск' in _norm(employee.department)
        or employee.employee_id in _env_ids('MED_STAFF'))


def is_mechanic(employee):
    return employee is not None and (
        'механик' in _norm(employee.job_title)
        or employee.employee_id in _env_ids('FLEET_MECHANICS'))


def is_driver(employee):
    return employee is not None and (
        _norm(employee.department) == 'гараж'
        or 'водител' in _norm(employee.job_title)
        or employee.employee_id in _env_ids('FLEET_DRIVERS'))


def is_fleet_manager(employee):
    """Заведующий ХО (гараж и механик — у него) и руководство ДМТО."""
    if employee is None:
        return False
    title = _norm(employee.job_title)
    return (is_supply_head(employee)
            or ('хозяйствен' in _norm(employee.department)
                and title.startswith(('заведующ', 'начальник')))
            or employee.employee_id in _env_ids('FLEET_MANAGERS'))


def warnings_for(systolic, diastolic, pulse, temperature, alcohol):
    """Что подсветить медработнику: давление, пульс, температура, алкоголь."""
    out = []
    if systolic is not None and systolic >= SYSTOLIC_HIGH \
            or diastolic is not None and diastolic >= DIASTOLIC_HIGH:
        out.append('pressure')
    if pulse is not None and not PULSE_LOW <= pulse <= PULSE_HIGH:
        out.append('pulse')
    if temperature is not None and temperature >= TEMPERATURE_HIGH:
        out.append('temperature')
    if alcohol is not None and alcohol > 0:
        out.append('alcohol')
    return out


def register(app, core):
    from models import Employee

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _roles(viewer):
        admin = core._is_system_admin(viewer.job_title)
        return {
            'medic': admin or is_medic(viewer),
            'mechanic': admin or is_mechanic(viewer),
            'manager': admin or is_fleet_manager(viewer),
            'driver': is_driver(viewer),
        }

    def _person(emp):
        return {'id': emp.employee_id, 'name': emp.full_name or emp.employee_id,
                'department': emp.department or ''}

    def _drivers():
        return [e for e in Employee.query.order_by(Employee.full_name)
                if e.full_name and is_driver(e)]

    def _exam_json(exam, medical):
        data = {
            'id': exam.id,
            'kind': exam.kind,
            'date': exam.exam_date.isoformat(),
            'admitted': bool(exam.admitted),
            'at': _utc(exam.at),
        }
        if medical:
            data.update({
                'systolic': exam.systolic,
                'diastolic': exam.diastolic,
                'pulse': exam.pulse,
                'temperature': exam.temperature,
                'alcohol': exam.alcohol,
                'complaints': exam.complaints or '',
                'reason': exam.reason or '',
                'warnings': warnings_for(exam.systolic, exam.diastolic, exam.pulse,
                                         exam.temperature, exam.alcohol),
                'medic_id': exam.medic_id,
            })
        return data

    def _check_json(check):
        return {
            'id': check.id,
            'date': check.check_date.isoformat(),
            'plate': check.plate,
            'odometer': check.odometer,
            'ok': bool(check.ok),
            'reason': check.reason or '',
            'at': _utc(check.at),
        }

    def _status(exam, check):
        """pending — не осмотрен, not_admitted — нет, med_ok — осмотрен,
        машину ещё не смотрели, admitted — всё."""
        if exam is None:
            return 'pending'
        if not exam.admitted or (check is not None and not check.ok):
            return 'not_admitted'
        return 'admitted' if check is not None else 'med_ok'

    def _latest(model, column, day, ids, extra=None):
        query = model.query.filter(column == day, model.employee_id.in_(ids or ['-']))
        if extra is not None:
            query = query.filter(extra)
        latest = {}
        for row in query.order_by(model.at, model.id):
            latest[row.employee_id] = row
        return latest

    def _day():
        raw = request.args.get('date', '')
        if not raw:
            return core._plant_today()
        try:
            return date.fromisoformat(raw)
        except ValueError:
            return None

    def _number(data, name, low, high, kind=int):
        """Пусто — None; не число или вне пределов — ошибка."""
        raw = data.get(name)
        if raw is None or raw == '':
            return None, None
        try:
            value = kind(str(raw).replace(',', '.')) if kind is float else int(raw)
        except (TypeError, ValueError):
            return None, f'bad_{name}'
        if isinstance(raw, bool) or not low <= value <= high:
            return None, f'bad_{name}'
        return value, None

    def _notify(ids, title, body, ref):
        ids = sorted({i for i in ids if i})
        if ids:
            core._record_notice('pretrip', title[:200], body[:500],
                                employee_ids=ids, ref=ref)

    def _managers():
        return [e.employee_id for e in Employee.query.all() if is_fleet_manager(e)]

    @app.route('/api/pretrip', methods=['GET'])
    @core.require_auth
    def pretrip_day():
        """Журнал на день (`?date=`) — медпункту, механику, руководству;
        водителю — свой допуск на сегодня и осмотры за месяц."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        roles = _roles(viewer)
        day = _day()
        if day is None:
            return _fail('bad_date', 400)
        body = {'message': 'Success', 'roles': roles, 'date': day.isoformat(),
                'limits': {'systolic': SYSTOLIC_HIGH, 'diastolic': DIASTOLIC_HIGH,
                           'pulse_low': PULSE_LOW, 'pulse_high': PULSE_HIGH,
                           'temperature': TEMPERATURE_HIGH}}
        if roles['driver']:
            today = core._plant_today()
            exams = (PreTripExam.query.filter_by(employee_id=viewer.employee_id)
                     .filter(PreTripExam.exam_date >= date.fromordinal(
                         today.toordinal() - _HISTORY_DAYS))
                     .order_by(PreTripExam.at.desc()).all())
            exam = next((e for e in exams
                         if e.exam_date == today and e.kind == 'pre'), None)
            check = _latest(VehicleCheck, VehicleCheck.check_date, today,
                            [viewer.employee_id]).get(viewer.employee_id)
            body['me'] = {
                'status': _status(exam, check),
                'exam': _exam_json(exam, True) if exam else None,
                'check': _check_json(check) if check else None,
                'history': [_exam_json(e, True) for e in exams],
            }
        if roles['medic'] or roles['mechanic'] or roles['manager']:
            drivers = _drivers()
            ids = [d.employee_id for d in drivers]
            exams = _latest(PreTripExam, PreTripExam.exam_date, day, ids,
                            PreTripExam.kind == 'pre')
            posts = _latest(PreTripExam, PreTripExam.exam_date, day, ids,
                            PreTripExam.kind == 'post')
            checks = _latest(VehicleCheck, VehicleCheck.check_date, day, ids)
            rows = []
            for d in drivers:
                exam, check = exams.get(d.employee_id), checks.get(d.employee_id)
                post = posts.get(d.employee_id)
                rows.append({
                    'driver': _person(d),
                    'status': _status(exam, check),
                    # Показатели — только медпункту.
                    'exam': _exam_json(exam, roles['medic']) if exam else None,
                    'post_exam': _exam_json(post, roles['medic']) if post else None,
                    'check': _check_json(check) if check else None,
                })
            body['drivers'] = rows
            body['counts'] = {s: sum(1 for r in rows if r['status'] == s)
                              for s in ('pending', 'med_ok', 'admitted',
                                        'not_admitted')}
        if not any(roles.values()):
            return core._deny()
        return jsonify(body)

    def _target(data):
        driver = db.session.get(Employee, core._text(data, 'employee_id'))
        return driver if driver is not None and is_driver(driver) else None

    @app.route('/api/pretrip/exams', methods=['POST'])
    @core.require_auth
    def pretrip_exam():
        """Медпункт: `{"employee_id", "kind", "systolic", "diastolic", "pulse",
        "temperature", "alcohol", "complaints", "admitted", "reason"}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not _roles(viewer)['medic']:
            return core._deny()
        data = core._json_body()
        driver = _target(data)
        if driver is None:
            return _fail('bad_driver', 400)
        kind = core._text(data, 'kind') or 'pre'
        if kind not in ('pre', 'post'):
            return _fail('bad_kind', 400)
        values = {}
        for name, low, high, typ in (('systolic', 60, 250, int),
                                     ('diastolic', 30, 160, int),
                                     ('pulse', 30, 200, int),
                                     ('temperature', 34.0, 42.0, float),
                                     ('alcohol', 0.0, 5.0, float)):
            values[name], error = _number(data, name, low, high, typ)
            if error:
                return _fail(error, 400)
        if values['systolic'] is None or values['diastolic'] is None:
            return _fail('pressure_required', 400)
        if values['alcohol'] is None:
            return _fail('alcohol_required', 400)
        admitted = data.get('admitted')
        if not isinstance(admitted, bool):
            return _fail('admitted_required', 400)
        reason = core._text(data, 'reason')[:_MAX_TEXT]
        if admitted and values['alcohol'] > 0:
            return _fail('alcohol_positive', 409)
        if not admitted and not reason:
            return _fail('reason_required', 400)
        exam = PreTripExam(employee_id=driver.employee_id, kind=kind,
                           exam_date=core._plant_today(),
                           complaints=core._text(data, 'complaints')[:_MAX_TEXT] or None,
                           admitted=admitted, reason=reason or None,
                           medic_id=viewer.employee_id, at=datetime.utcnow(),
                           **values)
        db.session.add(exam)
        db.session.commit()
        logging.info('Медосмотр %s: %s %s (%s)', driver.employee_id, kind,
                     'допущен' if admitted else 'не допущен', viewer.employee_id)
        if kind == 'pre':
            if admitted:
                _notify([driver.employee_id], 'Медосмотр пройден',
                        'Допущены к рейсу по медосмотру', exam.id)
            else:
                # Водителю — причина, руководству — только факт.
                _notify([driver.employee_id], 'Не допущены к рейсу',
                        reason, exam.id)
                _notify([m for m in _managers() if m != driver.employee_id],
                        f'Не допущен к рейсу: {driver.full_name}',
                        'По результатам предрейсового медосмотра', exam.id)
        return jsonify({'message': 'Success', 'item': _exam_json(exam, True)}), 201

    @app.route('/api/pretrip/checks', methods=['POST'])
    @core.require_auth
    def pretrip_check():
        """Механик: `{"employee_id", "plate", "odometer", "ok", "reason"}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not _roles(viewer)['mechanic']:
            return core._deny()
        data = core._json_body()
        driver = _target(data)
        if driver is None:
            return _fail('bad_driver', 400)
        plate = ''.join(core._text(data, 'plate').upper().split())[:20]
        if not plate:
            return _fail('plate_required', 400)
        odometer, error = _number(data, 'odometer', 0, 9_999_999)
        if error:
            return _fail(error, 400)
        ok = data.get('ok')
        if not isinstance(ok, bool):
            return _fail('ok_required', 400)
        reason = core._text(data, 'reason')[:_MAX_TEXT]
        if not ok and not reason:
            return _fail('reason_required', 400)
        check = VehicleCheck(employee_id=driver.employee_id,
                             check_date=core._plant_today(), plate=plate,
                             odometer=odometer, ok=ok, reason=reason or None,
                             mechanic_id=viewer.employee_id, at=datetime.utcnow())
        db.session.add(check)
        db.session.commit()
        logging.info('Выпуск %s на %s: %s (%s)', driver.employee_id, plate,
                     'исправна' if ok else 'не выпущена', viewer.employee_id)
        if not ok:
            _notify([driver.employee_id] + _managers(),
                    f'Машина {plate} не выпущена на линию',
                    f'{driver.full_name}: {reason}', check.id)
        return jsonify({'message': 'Success', 'item': _check_json(check)}), 201
