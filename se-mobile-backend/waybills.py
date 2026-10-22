"""Путевой лист в телефоне: водитель открывает его после медосмотра и
выпуска машины, записывает поездки, на возврате — пробег и топливо;
механик или заведующий ХО закрывает.

Сейчас путевой лист — бланк, который водитель заполняет в конце дня по
памяти, а расход топлива считают по нему же через неделю. Здесь поездка
записывается, когда она есть: откуда, куда, зачем и для кого. Пробег и
расход по листу считаются сами.

Открыть лист можно, только если сегодня водитель допущен медпунктом и
машина выпущена механиком (pre_trip): госномер и пробег на выезде
подставляются из отметки механика.

Видят: водитель — свои листы; механик, заведующий ХО, руководство ДМТО и
администратор — все.
"""

import logging
from datetime import date, datetime, timedelta

from flask import g, jsonify, request

from it_requests import _utc
from models import db
from pre_trip import (PreTripExam, VehicleCheck, is_driver, is_fleet_manager,
                      is_mechanic)

STATUSES = ('open', 'returned', 'closed')

_MAX_TRIPS = 40
_MAX_PLACE = 200
_MAX_ODOMETER = 9_999_999
_MAX_DAY_RUN = 2000
_MAX_FUEL = 500
_HISTORY = timedelta(days=31)


class Waybill(db.Model):
    __tablename__ = 'waybills'
    __table_args__ = (db.Index('ix_waybills_day', 'day', 'driver_id'),)
    id = db.Column(db.Integer, primary_key=True)
    driver_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                          nullable=False, index=True)
    day = db.Column(db.Date, nullable=False)
    plate = db.Column(db.String(20), nullable=False)
    exam_id = db.Column(db.Integer, db.ForeignKey('pre_trip_exams.id'))
    check_id = db.Column(db.Integer, db.ForeignKey('vehicle_checks.id'))
    odometer_out = db.Column(db.Integer, nullable=False)
    odometer_in = db.Column(db.Integer)
    # Литры: в баке на выезде, заправлено за день, в баке на возврате.
    fuel_out = db.Column(db.Float, nullable=False)
    fuel_added = db.Column(db.Float)
    fuel_in = db.Column(db.Float)
    status = db.Column(db.String(10), nullable=False, default='open')
    reviewer_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    note = db.Column(db.Text)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    returned_at = db.Column(db.DateTime)
    closed_at = db.Column(db.DateTime)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class WaybillTrip(db.Model):
    __tablename__ = 'waybill_trips'
    id = db.Column(db.Integer, primary_key=True)
    waybill_id = db.Column(db.Integer,
                           db.ForeignKey('waybills.id', ondelete='CASCADE'),
                           nullable=False, index=True)
    origin = db.Column(db.String(_MAX_PLACE), nullable=False)
    destination = db.Column(db.String(_MAX_PLACE), nullable=False)
    purpose = db.Column(db.String(_MAX_PLACE))
    # Для кого: «ДМТО, Мусин А.» — как говорят, а не табельный.
    customer = db.Column(db.String(_MAX_PLACE))
    # «08:40» — время предприятия.
    departed = db.Column(db.String(5))
    arrived = db.Column(db.String(5))
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _clock(raw):
    """«8:40» → «08:40»; пусто — None; не время — False."""
    if raw is None or raw == '':
        return None
    try:
        moment = datetime.strptime(str(raw).strip(), '%H:%M')
    except ValueError:
        return False
    return moment.strftime('%H:%M')


def _number(raw, low, high, kind=float):
    if raw is None or raw == '' or isinstance(raw, bool):
        return None
    try:
        value = kind(str(raw).replace(',', '.')) if kind is float else int(raw)
    except (TypeError, ValueError):
        return None
    return value if low <= value <= high else None


def register(app, core):
    from models import Employee

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _staff(viewer):
        return (core._is_system_admin(viewer.job_title) or is_mechanic(viewer)
                or is_fleet_manager(viewer))

    def _person(emp, employee_id):
        if not employee_id:
            return None
        return {'id': employee_id,
                'name': emp.full_name if emp else employee_id,
                'department': (emp.department or '') if emp else ''}

    def _names(ids):
        ids = {i for i in ids if i}
        if not ids:
            return {}
        return {e.employee_id: e for e in
                Employee.query.filter(Employee.employee_id.in_(ids))}

    def _totals(item):
        distance = (item.odometer_in - item.odometer_out
                    if item.odometer_in is not None else None)
        used = None
        if item.fuel_in is not None:
            used = round(item.fuel_out + (item.fuel_added or 0) - item.fuel_in, 2)
        return distance, used

    def _json(item, people, viewer, trips=None):
        staff = _staff(viewer)
        mine = viewer.employee_id == item.driver_id
        distance, used = _totals(item)
        data = {
            'id': item.id,
            'date': item.day.isoformat(),
            'plate': item.plate,
            'status': item.status,
            'odometer_out': item.odometer_out,
            'odometer_in': item.odometer_in,
            'fuel_out': item.fuel_out,
            'fuel_added': item.fuel_added,
            'fuel_in': item.fuel_in,
            'distance': distance,
            'fuel_used': used,
            'note': item.note or '',
            'driver': _person(people.get(item.driver_id), item.driver_id),
            'reviewer': _person(people.get(item.reviewer_id), item.reviewer_id),
            'returned_at': _utc(item.returned_at),
            'closed_at': _utc(item.closed_at),
            'can_edit': mine and item.status == 'open',
            'can_review': staff and item.status == 'returned',
        }
        if trips is not None:
            data['trips'] = [{
                'id': t.id, 'origin': t.origin, 'destination': t.destination,
                'purpose': t.purpose or '', 'customer': t.customer or '',
                'departed': t.departed or '', 'arrived': t.arrived or '',
            } for t in trips]
        return data

    def _trips(item):
        return (WaybillTrip.query.filter_by(waybill_id=item.id)
                .order_by(WaybillTrip.departed, WaybillTrip.id).all())

    def _detail(item, viewer):
        people = _names([item.driver_id, item.reviewer_id])
        return _json(item, people, viewer, _trips(item))

    def _readiness(viewer):
        """Можно ли сегодня открыть лист: допуск медпункта и выпуск машины."""
        today = core._plant_today()
        exam = (PreTripExam.query
                .filter_by(employee_id=viewer.employee_id, exam_date=today, kind='pre')
                .order_by(PreTripExam.at.desc(), PreTripExam.id.desc()).first())
        check = (VehicleCheck.query
                 .filter_by(employee_id=viewer.employee_id, check_date=today)
                 .order_by(VehicleCheck.at.desc(), VehicleCheck.id.desc()).first())
        return exam, check

    def _staff_ids():
        return [e.employee_id for e in Employee.query.all()
                if is_mechanic(e) or is_fleet_manager(e)]

    def _notify(ids, title, body, ref, actor_id=None):
        ids = sorted({i for i in ids if i and i != actor_id})
        if ids:
            core._record_notice('waybill', title[:200], body[:500],
                                employee_ids=ids, ref=ref)

    @app.route('/api/waybills', methods=['GET'])
    @core.require_auth
    def waybills_list():
        """Водителю — свои за месяц и готовность на сегодня; механику и
        руководству — все за день (`?date=`) с итогами."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        staff, driver = _staff(viewer), is_driver(viewer)
        if not (staff or driver):
            return core._deny()
        body = {'message': 'Success', 'staff': staff, 'driver': driver}
        if driver:
            exam, check = _readiness(viewer)
            since = core._plant_today() - _HISTORY
            mine = (Waybill.query.filter_by(driver_id=viewer.employee_id)
                    .filter(Waybill.day >= since)
                    .order_by(Waybill.day.desc(), Waybill.id.desc()).all())
            body['ready'] = {
                'admitted': bool(exam and exam.admitted),
                'examined': exam is not None,
                'released': bool(check and check.ok),
                'checked': check is not None,
                'plate': check.plate if check else '',
                'odometer': check.odometer if check else None,
                # Вчерашний остаток в баке — подсказка к сегодняшнему.
                'fuel': next((w.fuel_in for w in mine if w.fuel_in is not None), None),
                'open_id': next((w.id for w in mine if w.status == 'open'), None),
            }
            people = _names([viewer.employee_id] + [w.reviewer_id for w in mine])
            body['mine'] = [_json(w, people, viewer) for w in mine]
        if staff:
            raw = request.args.get('date', '')
            try:
                day = date.fromisoformat(raw) if raw else core._plant_today()
            except ValueError:
                return _fail('bad_date', 400)
            items = (Waybill.query.filter_by(day=day)
                     .order_by(Waybill.created_at).all())
            people = _names([w.driver_id for w in items]
                            + [w.reviewer_id for w in items])
            rows = [_json(w, people, viewer) for w in items]
            body['date'] = day.isoformat()
            body['items'] = rows
            body['totals'] = {
                'count': len(rows),
                'open': sum(1 for r in rows if r['status'] == 'open'),
                'returned': sum(1 for r in rows if r['status'] == 'returned'),
                'distance': sum(r['distance'] or 0 for r in rows),
                'fuel_used': round(sum(r['fuel_used'] or 0 for r in rows), 2),
            }
        return jsonify(body)

    @app.route('/api/waybills', methods=['POST'])
    @core.require_auth
    def waybills_create():
        """`{"odometer_out", "fuel_out"}` — госномер берётся из выпуска."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not is_driver(viewer):
            return core._deny()
        exam, check = _readiness(viewer)
        if exam is None or not exam.admitted:
            return _fail('not_admitted', 409)
        if check is None or not check.ok:
            return _fail('not_released', 409)
        if Waybill.query.filter_by(driver_id=viewer.employee_id,
                                   status='open').first():
            return _fail('already_open', 409)
        data = core._json_body()
        odometer = _number(data.get('odometer_out'), 0, _MAX_ODOMETER, int)
        if odometer is None:
            odometer = check.odometer
        if odometer is None:
            return _fail('bad_odometer', 400)
        fuel = _number(data.get('fuel_out'), 0, _MAX_FUEL)
        if fuel is None:
            return _fail('bad_fuel', 400)
        now = datetime.utcnow()
        item = Waybill(driver_id=viewer.employee_id, day=core._plant_today(),
                       plate=check.plate, exam_id=exam.id, check_id=check.id,
                       odometer_out=odometer, fuel_out=fuel, status='open',
                       created_at=now, updated_at=now)
        db.session.add(item)
        db.session.commit()
        logging.info('Путевой лист №%s: %s, %s', item.id, viewer.employee_id,
                     item.plate)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer)}), 201

    def _load(item_id, viewer):
        item = db.session.get(Waybill, item_id)
        if item is None or not (item.driver_id == viewer.employee_id
                                or _staff(viewer)):
            return None
        return item

    @app.route('/api/waybills/<int:item_id>', methods=['GET'])
    @core.require_auth
    def waybill_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = _load(item_id, viewer)
        if item is None:
            return _fail('not_found', 404)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer)})

    @app.route('/api/waybills/<int:item_id>', methods=['POST'])
    @core.require_auth
    def waybill_action(item_id):
        """Водитель: trip, trip_remove, return. Механик и руководство:
        close, reopen (с причиной — обратно водителю)."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = _load(item_id, viewer)
        if item is None:
            return _fail('not_found', 404)
        data = core._json_body()
        action = core._text(data, 'action')
        state = _json(item, {}, viewer)
        if action in ('trip', 'trip_remove', 'return') and not state['can_edit']:
            return core._deny() if item.driver_id != viewer.employee_id \
                else _fail('not_open', 409)
        if action in ('close', 'reopen') and not state['can_review']:
            return core._deny() if not _staff(viewer) else _fail('not_returned', 409)

        now = datetime.utcnow()
        label = f'Путевой лист №{item.id} ({item.plate})'
        notify = None
        if action == 'trip':
            origin = ' '.join(core._text(data, 'origin').split())[:_MAX_PLACE]
            destination = ' '.join(core._text(data, 'destination').split())[:_MAX_PLACE]
            if not origin or not destination:
                return _fail('place_required', 400)
            departed, arrived = _clock(data.get('departed')), _clock(data.get('arrived'))
            if departed is False or arrived is False:
                return _fail('bad_time', 400)
            if WaybillTrip.query.filter_by(waybill_id=item.id).count() >= _MAX_TRIPS:
                return _fail('too_many_trips', 400)
            db.session.add(WaybillTrip(
                waybill_id=item.id, origin=origin, destination=destination,
                purpose=core._text(data, 'purpose')[:_MAX_PLACE] or None,
                customer=core._text(data, 'customer')[:_MAX_PLACE] or None,
                departed=departed, arrived=arrived, at=now))
        elif action == 'trip_remove':
            trip_id = _number(data.get('trip_id'), 1, 2**31, int)
            trip = db.session.get(WaybillTrip, trip_id) if trip_id else None
            if trip is None or trip.waybill_id != item.id:
                return _fail('not_found', 404)
            db.session.delete(trip)
        elif action == 'return':
            if not WaybillTrip.query.filter_by(waybill_id=item.id).count():
                return _fail('no_trips', 400)
            odometer = _number(data.get('odometer_in'), item.odometer_out,
                               item.odometer_out + _MAX_DAY_RUN, int)
            if odometer is None:
                return _fail('bad_odometer', 400)
            added = _number(data.get('fuel_added') or 0, 0, _MAX_FUEL)
            fuel = _number(data.get('fuel_in'), 0, _MAX_FUEL)
            if added is None or fuel is None or fuel > item.fuel_out + added:
                return _fail('bad_fuel', 400)
            item.odometer_in, item.fuel_added, item.fuel_in = odometer, added, fuel
            item.status = 'returned'
            item.returned_at = now
            item.note = None
            distance, used = _totals(item)
            notify = (_staff_ids(), f'{label}: машина вернулась',
                      f'{viewer.full_name}: {distance} км, расход {used:g} л')
        elif action == 'close':
            item.status = 'closed'
            item.closed_at = now
            item.reviewer_id = viewer.employee_id
        elif action == 'reopen':
            text = core._text(data, 'text')[:1000]
            if not text:
                return _fail('text_required', 400)
            item.status = 'open'
            item.note = text
            item.reviewer_id = viewer.employee_id
            notify = ([item.driver_id], f'{label}: исправьте', text)
        else:
            return _fail('bad_action', 400)

        item.updated_at = now
        db.session.commit()
        logging.info('Путевой лист №%s: %s (%s)', item.id, action, viewer.employee_id)
        if notify:
            _notify(notify[0], notify[1], notify[2], item.id, viewer.employee_id)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer)})
