"""График планово-предупредительных ремонтов (ППР): какое оборудование и
когда останавливают на обслуживание, с напоминанием за неделю.

Сейчас график ППР — таблица у главного инженера, и мастер участка узнаёт о
плановой остановке станка в тот же день, когда у него на нём план. Здесь у
оборудования есть мастер участка и ответственный (энергетик, механик), у
каждого вида работ — периодичность и дата следующей остановки. За неделю до
неё оба получают напоминание; после работ ответственный отмечает
«выполнено», и следующая дата считается сама. Перенос — с причиной, и он
остаётся в истории.

Ведёт график Служба главного инженера (как в заявках на ремонт) и
MAINTENANCE_STAFF. Мастер и ответственный видят своё оборудование,
руководители — весь график.
"""

import logging
import os
import threading
from datetime import date, datetime, timedelta

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db
from repair_requests import ENGINEER, staff_groups
from workwear import add_months

KINDS = ('service', 'current', 'overhaul', 'inspection')
KIND_TITLES = {'service': 'техобслуживание', 'current': 'текущий ремонт',
               'overhaul': 'капитальный ремонт', 'inspection': 'осмотр'}

_REMIND_BEFORE = timedelta(days=7)
_REMIND_CHECK_EVERY = timedelta(hours=1)
_MAX_TEXT = 200
_MAX_NOTE = 500
_MAX_EVERY = 120
_HISTORY = 10


class Equipment(db.Model):
    __tablename__ = 'equipment'
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(_MAX_TEXT), nullable=False)
    inventory_no = db.Column(db.String(40))
    location = db.Column(db.String(_MAX_TEXT))
    master_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                          index=True)
    engineer_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            index=True)
    active = db.Column(db.Boolean, nullable=False, default=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class MaintenancePlan(db.Model):
    __tablename__ = 'maintenance_plans'
    id = db.Column(db.Integer, primary_key=True)
    equipment_id = db.Column(db.Integer,
                             db.ForeignKey('equipment.id', ondelete='CASCADE'),
                             nullable=False, index=True)
    kind = db.Column(db.String(12), nullable=False)
    every_months = db.Column(db.Integer, nullable=False)
    next_on = db.Column(db.Date, nullable=False, index=True)
    hours = db.Column(db.Integer)
    note = db.Column(db.String(_MAX_NOTE))
    # На какую дату уже напомнили: перенос — новая дата, новое напоминание.
    reminded_for = db.Column(db.Date)
    active = db.Column(db.Boolean, nullable=False, default=True)


class MaintenanceRecord(db.Model):
    __tablename__ = 'maintenance_records'
    id = db.Column(db.Integer, primary_key=True)
    plan_id = db.Column(db.Integer,
                        db.ForeignKey('maintenance_plans.id', ondelete='CASCADE'),
                        nullable=False, index=True)
    # done, postponed
    action = db.Column(db.String(10), nullable=False)
    planned_on = db.Column(db.Date, nullable=False)
    done_on = db.Column(db.Date)
    new_on = db.Column(db.Date)
    actor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    note = db.Column(db.String(_MAX_NOTE))
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_planner(employee, core):
    if employee is None:
        return False
    return (ENGINEER in staff_groups(employee)
            or core._is_system_admin(employee.job_title)
            or employee.employee_id in _env_ids('MAINTENANCE_STAFF'))


def sees_all(employee, core):
    return is_planner(employee, core) or (
        employee is not None and core._is_admin_role(employee.job_title))


def _state(plan, today):
    if plan.next_on < today:
        return 'overdue'
    if plan.next_on - today <= _REMIND_BEFORE:
        return 'week'
    return 'later'


def remind_due(core):
    """Напомнить мастеру и ответственному о остановках в ближайшую неделю.

    Один раз на дату: `reminded_for` помнит, о какой уже сказали.
    """
    from models import Employee
    today = core._plant_today()
    plans = (MaintenancePlan.query.filter(
        MaintenancePlan.active.is_(True),
        MaintenancePlan.next_on >= today,
        MaintenancePlan.next_on <= today + _REMIND_BEFORE).all())
    sent = 0
    for plan in plans:
        if plan.reminded_for == plan.next_on:
            continue
        equipment = db.session.get(Equipment, plan.equipment_id)
        if equipment is None or not equipment.active:
            continue
        ids = [i for i in (equipment.master_id, equipment.engineer_id) if i]
        ids = [e.employee_id for e in Employee.query.filter(
            Employee.employee_id.in_(ids or ['-']))]
        plan.reminded_for = plan.next_on
        if not ids:
            continue
        when = plan.next_on.strftime('%d.%m.%Y')
        hours = f', около {plan.hours} ч' if plan.hours else ''
        core._record_notice(
            'maintenance', f'ППР {when}: {equipment.name}'[:200],
            f'{KIND_TITLES[plan.kind].capitalize()}{hours}. '
            f'{equipment.location or ""}'.strip()[:500],
            employee_ids=ids, ref=equipment.id)
        sent += 1
    db.session.commit()
    return sent


_remind_lock = threading.Lock()
_reminded_at = None


def register(app, core):
    from models import Employee

    @app.before_request
    def _maintenance_reminders():
        """Раз в час, с первым же запросом, — напоминания о ППР.

        Отдельного планировщика у сервера нет; запросы идут весь рабочий
        день, и «за неделю» с точностью до часа здесь достаточно.
        """
        global _reminded_at
        now = datetime.utcnow()
        if _reminded_at is not None and now - _reminded_at < _REMIND_CHECK_EVERY:
            return
        if not _remind_lock.acquire(blocking=False):
            return
        try:
            _reminded_at = now
            remind_due(core)
        except Exception as e:
            db.session.rollback()
            logging.warning('Напоминания о ППР не отправлены: %s', e)
        finally:
            _remind_lock.release()

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

    def _own(equipment, viewer):
        return viewer.employee_id in (equipment.master_id, equipment.engineer_id)

    def _may_see(equipment, viewer):
        return sees_all(viewer, core) or _own(equipment, viewer)

    def _may_mark(equipment, viewer):
        return is_planner(viewer, core) or viewer.employee_id == equipment.engineer_id

    def _equipment_json(item, people):
        return {'id': item.id, 'name': item.name,
                'inventory_no': item.inventory_no or '',
                'location': item.location or '',
                'master': _person(people.get(item.master_id), item.master_id),
                'engineer': _person(people.get(item.engineer_id), item.engineer_id),
                'active': item.active}

    def _plan_json(plan, today, equipment=None, people=None, viewer=None,
                   history=None):
        data = {'id': plan.id, 'equipment_id': plan.equipment_id,
                'kind': plan.kind, 'every_months': plan.every_months,
                'next_on': plan.next_on.isoformat(), 'hours': plan.hours,
                'note': plan.note or '', 'state': _state(plan, today)}
        if equipment is not None:
            data['equipment'] = _equipment_json(equipment, people or {})
            data['can_mark'] = bool(viewer and plan.active
                                    and _may_mark(equipment, viewer))
        if history is not None:
            data['history'] = [{
                'action': r.action, 'planned_on': r.planned_on.isoformat(),
                'done_on': r.done_on.isoformat() if r.done_on else None,
                'new_on': r.new_on.isoformat() if r.new_on else None,
                'note': r.note or '', 'at': _utc(r.at),
                'actor': _person((people or {}).get(r.actor_id), r.actor_id),
            } for r in history]
        return data

    def _visible_equipment(viewer):
        query = Equipment.query.filter(Equipment.active.is_(True))
        if not sees_all(viewer, core):
            query = query.filter(db.or_(Equipment.master_id == viewer.employee_id,
                                        Equipment.engineer_id == viewer.employee_id))
        return query.order_by(Equipment.name).all()

    @app.route('/api/maintenance', methods=['GET'])
    @core.require_auth
    def maintenance_schedule():
        """Ближайшие остановки (`?days=`, по умолчанию 60) и просроченные."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        try:
            days = max(1, min(366, int(request.args.get('days', 60))))
        except ValueError:
            days = 60
        today = core._plant_today()
        equipment = {e.id: e for e in _visible_equipment(viewer)}
        plans = (MaintenancePlan.query.filter(
            MaintenancePlan.active.is_(True),
            MaintenancePlan.equipment_id.in_(list(equipment) or [-1]),
            MaintenancePlan.next_on <= today + timedelta(days=days))
            .order_by(MaintenancePlan.next_on).limit(500).all())
        people = _names([i for e in equipment.values()
                         for i in (e.master_id, e.engineer_id)])
        return jsonify({
            'message': 'Success',
            'planner': is_planner(viewer, core),
            'items': [_plan_json(p, today, equipment[p.equipment_id], people, viewer)
                      for p in plans],
        })

    @app.route('/api/maintenance/equipment', methods=['GET'])
    @core.require_auth
    def maintenance_equipment_list():
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        today = core._plant_today()
        items = _visible_equipment(viewer)
        plans = {}
        for plan in MaintenancePlan.query.filter(
                MaintenancePlan.active.is_(True),
                MaintenancePlan.equipment_id.in_([e.id for e in items] or [-1])
        ).order_by(MaintenancePlan.next_on):
            plans.setdefault(plan.equipment_id, []).append(plan)
        people = _names([i for e in items for i in (e.master_id, e.engineer_id)])
        rows = []
        for item in items:
            data = _equipment_json(item, people)
            data['plans'] = [_plan_json(p, today) for p in plans.get(item.id, [])]
            rows.append(data)
        return jsonify({'message': 'Success', 'planner': is_planner(viewer, core),
                        'items': rows})

    @app.route('/api/maintenance/equipment/<int:item_id>', methods=['GET'])
    @core.require_auth
    def maintenance_equipment_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(Equipment, item_id)
        if item is None or not item.active or not _may_see(item, viewer):
            return _fail('not_found', 404)
        today = core._plant_today()
        plans = (MaintenancePlan.query.filter_by(equipment_id=item.id, active=True)
                 .order_by(MaintenancePlan.next_on).all())
        histories = {p.id: (MaintenanceRecord.query.filter_by(plan_id=p.id)
                            .order_by(MaintenanceRecord.at.desc())
                            .limit(_HISTORY).all()) for p in plans}
        people = _names([item.master_id, item.engineer_id]
                        + [r.actor_id for h in histories.values() for r in h])
        data = _equipment_json(item, people)
        data['plans'] = [_plan_json(p, today, item, people, viewer, histories[p.id])
                         for p in plans]
        return jsonify({'message': 'Success', 'planner': is_planner(viewer, core),
                        'item': data})

    def _person_field(data, key):
        raw = core._text(data, key)
        if not raw:
            return None, None
        if db.session.get(Employee, raw) is None:
            return None, f'no_{key.replace("_id", "")}'
        return raw, None

    @app.route('/api/maintenance/equipment', methods=['POST'])
    @core.require_auth
    def maintenance_equipment_create():
        """`{"name", "inventory_no", "location", "master_id", "engineer_id"}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not is_planner(viewer, core):
            return core._deny()
        data = core._json_body()
        name = core._text(data, 'name')[:_MAX_TEXT]
        if not name:
            return _fail('name_required', 400)
        master_id, error = _person_field(data, 'master_id')
        if error:
            return _fail(error, 400)
        engineer_id, error = _person_field(data, 'engineer_id')
        if error:
            return _fail(error, 400)
        item = Equipment(name=name,
                         inventory_no=core._text(data, 'inventory_no')[:40] or None,
                         location=core._text(data, 'location')[:_MAX_TEXT] or None,
                         master_id=master_id, engineer_id=engineer_id)
        db.session.add(item)
        db.session.commit()
        logging.info('ППР: оборудование №%s «%s» (%s)', item.id, name,
                     viewer.employee_id)
        people = _names([master_id, engineer_id])
        return jsonify({'message': 'Success',
                        'item': _equipment_json(item, people)}), 201

    @app.route('/api/maintenance/equipment/<int:item_id>', methods=['POST'])
    @core.require_auth
    def maintenance_equipment_update(item_id):
        """Поправить поля (как при заведении) или `{"active": false}` — снять
        с учёта вместе с графиком."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not is_planner(viewer, core):
            return core._deny()
        item = db.session.get(Equipment, item_id)
        if item is None or not item.active:
            return _fail('not_found', 404)
        data = core._json_body()
        if data.get('active') is False:
            item.active = False
            MaintenancePlan.query.filter_by(equipment_id=item.id).update(
                {'active': False}, synchronize_session=False)
            db.session.commit()
            return jsonify({'message': 'Success'})
        if 'name' in data:
            name = core._text(data, 'name')[:_MAX_TEXT]
            if not name:
                return _fail('name_required', 400)
            item.name = name
        for key, width in (('inventory_no', 40), ('location', _MAX_TEXT)):
            if key in data:
                setattr(item, key, core._text(data, key)[:width] or None)
        for key in ('master_id', 'engineer_id'):
            if key in data:
                value, error = _person_field(data, key)
                if error:
                    return _fail(error, 400)
                setattr(item, key, value)
        db.session.commit()
        people = _names([item.master_id, item.engineer_id])
        return jsonify({'message': 'Success', 'item': _equipment_json(item, people)})

    def _int(data, key, low, high, required=True):
        raw = data.get(key)
        if raw in (None, '') and not required:
            return None, None
        if isinstance(raw, str) and raw.strip().isdigit():
            raw = int(raw)
        if isinstance(raw, bool) or not isinstance(raw, int) or not low <= raw <= high:
            return None, f'bad_{key}'
        return raw, None

    @app.route('/api/maintenance/plans', methods=['POST'])
    @core.require_auth
    def maintenance_plan_create():
        """`{"equipment_id", "kind", "every_months", "next_on", "hours", "note"}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not is_planner(viewer, core):
            return core._deny()
        data = core._json_body()
        item = db.session.get(Equipment, data.get('equipment_id'))
        if item is None or not item.active:
            return _fail('no_equipment', 400)
        kind = core._text(data, 'kind')
        if kind not in KINDS:
            return _fail('bad_kind', 400)
        every, error = _int(data, 'every_months', 1, _MAX_EVERY)
        if error:
            return _fail(error, 400)
        hours, error = _int(data, 'hours', 1, 2000, required=False)
        if error:
            return _fail(error, 400)
        try:
            next_on = date.fromisoformat(core._text(data, 'next_on'))
        except ValueError:
            return _fail('bad_date', 400)
        today = core._plant_today()
        if not today - timedelta(days=366) <= next_on <= today + timedelta(days=5 * 366):
            return _fail('bad_date', 400)
        plan = MaintenancePlan(equipment_id=item.id, kind=kind, every_months=every,
                               next_on=next_on, hours=hours,
                               note=core._text(data, 'note')[:_MAX_NOTE] or None)
        db.session.add(plan)
        db.session.commit()
        return jsonify({'message': 'Success', 'plan': _plan_json(plan, today)}), 201

    @app.route('/api/maintenance/plans/<int:plan_id>', methods=['POST'])
    @core.require_auth
    def maintenance_plan_action(plan_id):
        """`done` (`{"note", "done_on"}`) — ответственному и службе;
        `postpone` (`{"next_on", "note"}`, причина обязательна) и `remove` —
        службе главного инженера."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        plan = db.session.get(MaintenancePlan, plan_id)
        item = db.session.get(Equipment, plan.equipment_id) if plan else None
        if plan is None or not plan.active or item is None or not _may_see(item, viewer):
            return _fail('not_found', 404)
        data = core._json_body()
        action = core._text(data, 'action')
        note = core._text(data, 'note')[:_MAX_NOTE] or None
        today = core._plant_today()
        planner = is_planner(viewer, core)
        if action == 'done':
            if not _may_mark(item, viewer):
                return core._deny()
            raw = core._text(data, 'done_on')
            try:
                done_on = date.fromisoformat(raw) if raw else today
            except ValueError:
                return _fail('bad_date', 400)
            if done_on > today or done_on < today - timedelta(days=60):
                return _fail('bad_date', 400)
            new_on = add_months(done_on, plan.every_months)
            db.session.add(MaintenanceRecord(
                plan_id=plan.id, action='done', planned_on=plan.next_on,
                done_on=done_on, new_on=new_on, actor_id=viewer.employee_id,
                note=note))
            plan.next_on = new_on
        elif action == 'postpone':
            if not planner:
                return core._deny()
            if not note:
                return _fail('note_required', 400)
            try:
                new_on = date.fromisoformat(core._text(data, 'next_on'))
            except ValueError:
                return _fail('bad_date', 400)
            if new_on < today or new_on == plan.next_on:
                return _fail('bad_date', 400)
            db.session.add(MaintenanceRecord(
                plan_id=plan.id, action='postponed', planned_on=plan.next_on,
                new_on=new_on, actor_id=viewer.employee_id, note=note))
            old = plan.next_on
            plan.next_on = new_on
            ids = [i for i in (item.master_id, item.engineer_id)
                   if i and i != viewer.employee_id]
            if ids:
                core._record_notice(
                    'maintenance', f'ППР перенесён: {item.name}'[:200],
                    f'{old.strftime("%d.%m.%Y")} → {new_on.strftime("%d.%m.%Y")}. '
                    f'{note}'[:500], employee_ids=ids, ref=item.id)
        elif action == 'remove':
            if not planner:
                return core._deny()
            plan.active = False
        else:
            return _fail('bad_action', 400)
        db.session.commit()
        logging.info('ППР: план №%s %s (%s)', plan.id, action, viewer.employee_id)
        people = _names([item.master_id, item.engineer_id])
        return jsonify({'message': 'Success',
                        'plan': _plan_json(plan, today, item, people, viewer)})

    @app.route('/api/maintenance/people', methods=['GET'])
    @core.require_auth
    def maintenance_people():
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not is_planner(viewer, core):
            return core._deny()
        q = _norm(request.args.get('q', ''))
        people = []
        for e in Employee.query.order_by(Employee.full_name):
            if not e.full_name:
                continue
            if q and q not in _norm(e.full_name) and q not in _norm(e.job_title):
                continue
            people.append(_person(e, e.employee_id))
            if len(people) >= 50:
                break
        return jsonify({'message': 'Success', 'people': people})
