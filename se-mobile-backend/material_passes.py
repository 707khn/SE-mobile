"""Материальный пропуск на вывоз ТМЦ: оформил → руководитель согласовал →
охрана на КПП сверила и выпустила.

Сейчас пропуск — бумага с подписью, и на проходной не проверить, настоящая
ли подпись и не дописали ли позицию. Здесь пропуск живёт на сервере:
охранник открывает его по номеру, сверяет код, который назвал водитель, и
видит ровно тот список, что согласовал руководитель. Отметка «выпущено»
или «задержано» сразу приходит автору.

Согласуют руководство предприятия и руководство ДМТО (или PASS_APPROVERS).
Выпускает Служба безопасности (или PASS_GUARDS — охранники КПП, если у них
есть учётные записи). Пропуск действует один день — тот, что указан;
просроченный охрана не выпускает.
"""

import logging
import os
import secrets
from datetime import date, datetime, timedelta

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db
from stock_requests import UNITS, _number, _quantity, is_supply_head


# pending → approved → released. Отказ руководителя — rejected, охрана
# не выпустила — held, автор передумал — cancelled.
STATUSES = ('pending', 'approved', 'rejected', 'released', 'held', 'cancelled')
OPEN_STATUSES = ('pending', 'approved')
# Что охране показывать: согласованное и то, что уже прошло через КПП.
GATE_STATUSES = ('approved', 'released', 'held')

_MAX_LINES = 30
_MAX_NAME = 200
_MAX_TEXT = 300
_MAX_COMMENT = 1000
_MAX_OPEN_PER_AUTHOR = 20
# Дальше — уже не пропуск, а план.
_MAX_DAYS_AHEAD = 14
_LIST_CLOSED_FOR = timedelta(days=14)


class MaterialPass(db.Model):
    __tablename__ = 'material_passes'
    __table_args__ = (
        db.Index('ix_material_passes_author', 'employee_id', 'created_at'),
        db.Index('ix_material_passes_gate', 'status', 'exit_date'),
    )
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False)
    # Куда и на каком основании: «в ремонт ТОО „Сервис“, договор 12».
    purpose = db.Column(db.String(_MAX_TEXT), nullable=False)
    # Кто вывозит: ФИО водителя или организация.
    carrier = db.Column(db.String(_MAX_NAME), nullable=False)
    vehicle = db.Column(db.String(20))
    exit_date = db.Column(db.Date, nullable=False)
    # Четыре цифры: водитель называет, охранник сверяет — бумажку не подделать.
    code = db.Column(db.String(4), nullable=False)
    status = db.Column(db.String(10), nullable=False, default='pending')
    approver_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    decided_at = db.Column(db.DateTime)
    guard_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    released_at = db.Column(db.DateTime)
    # Причина отказа или почему охрана не выпустила.
    reason = db.Column(db.Text)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class MaterialPassLine(db.Model):
    __tablename__ = 'material_pass_lines'
    id = db.Column(db.Integer, primary_key=True)
    pass_id = db.Column(db.Integer,
                        db.ForeignKey('material_passes.id', ondelete='CASCADE'),
                        nullable=False, index=True)
    position = db.Column(db.Integer, nullable=False)
    name = db.Column(db.String(_MAX_NAME), nullable=False)
    quantity = db.Column(db.Float, nullable=False)
    unit = db.Column(db.String(10), nullable=False, default='шт')


class MaterialPassEvent(db.Model):
    __tablename__ = 'material_pass_events'
    id = db.Column(db.Integer, primary_key=True)
    pass_id = db.Column(db.Integer,
                        db.ForeignKey('material_passes.id', ondelete='CASCADE'),
                        nullable=False, index=True)
    actor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # created, approve, reject, release, hold, cancel, comment
    action = db.Column(db.String(10), nullable=False)
    comment = db.Column(db.Text)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_approver(employee):
    if employee is None:
        return False
    return (_norm(employee.department).startswith('руководство')
            or is_supply_head(employee)
            or employee.employee_id in _env_ids('PASS_APPROVERS'))


def is_guard(employee):
    if employee is None:
        return False
    dept = _norm(employee.department)
    return (('служба безопасности' in dept and 'охраны труда' not in dept)
            or employee.employee_id in _env_ids('PASS_GUARDS'))


def register(app, core):
    from models import Employee

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _roles(viewer):
        admin = core._is_system_admin(viewer.job_title)
        return {'approver': admin or is_approver(viewer),
                'guard': admin or is_guard(viewer)}

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

    def _ids(test):
        return sorted(e.employee_id for e in Employee.query.all() if test(e))

    def _may_see(viewer, item, roles):
        return (viewer.employee_id == item.employee_id or roles['approver']
                or (roles['guard'] and item.status in GATE_STATUSES))

    def _lines(item):
        return (MaterialPassLine.query.filter_by(pass_id=item.id)
                .order_by(MaterialPassLine.position).all())

    def _expired(item, today):
        return item.status in OPEN_STATUSES and item.exit_date < today

    def _json(item, lines, people, viewer, roles, events=None):
        today = core._plant_today()
        is_author = viewer.employee_id == item.employee_id
        data = {
            'id': item.id,
            'purpose': item.purpose,
            'carrier': item.carrier,
            'vehicle': item.vehicle or '',
            'exit_date': item.exit_date.isoformat(),
            'status': item.status,
            'expired': _expired(item, today),
            'author': _person(people.get(item.employee_id), item.employee_id),
            'approver': _person(people.get(item.approver_id), item.approver_id),
            'guard': _person(people.get(item.guard_id), item.guard_id),
            'reason': item.reason or '',
            'decided_at': _utc(item.decided_at),
            'released_at': _utc(item.released_at),
            'created_at': _utc(item.created_at),
            'lines': [{'name': l.name, 'quantity': l.quantity, 'unit': l.unit}
                      for l in lines],
            'is_author': is_author,
            'can_approve': bool(roles['approver'] and not is_author
                                and item.status == 'pending'
                                and not _expired(item, today)),
            'can_release': bool(roles['guard'] and item.status == 'approved'
                                and item.exit_date == today),
        }
        # Код — тем, кто его называет и кто сверяет; в общем списке не светим.
        if events is not None:
            data['code'] = item.code
            data['events'] = [{
                'action': e.action,
                'comment': e.comment or '',
                'at': _utc(e.at),
                'actor': _person(people.get(e.actor_id), e.actor_id),
            } for e in events]
        return data

    def _list_json(items, viewer, roles):
        lines_of = {}
        for l in (MaterialPassLine.query
                  .filter(MaterialPassLine.pass_id.in_([i.id for i in items] or [-1]))
                  .order_by(MaterialPassLine.position)):
            lines_of.setdefault(l.pass_id, []).append(l)
        people = _names([i.employee_id for i in items]
                        + [i.approver_id for i in items])
        return [_json(i, lines_of.get(i.id, []), people, viewer, roles)
                for i in items]

    def _detail(item, viewer, roles):
        events = (MaterialPassEvent.query.filter_by(pass_id=item.id)
                  .order_by(MaterialPassEvent.at, MaterialPassEvent.id).all())
        people = _names([item.employee_id, item.approver_id, item.guard_id]
                        + [e.actor_id for e in events])
        return _json(item, _lines(item), people, viewer, roles, events)

    def _notify(employee_ids, title, body, item_id, actor_id=None):
        ids = sorted({e for e in employee_ids if e and e != actor_id})
        if ids:
            core._record_notice('pass', title, body, employee_ids=ids,
                                ref=item_id)

    def _what(lines):
        return '; '.join(f'{l.name} — {_number(l.quantity)} {l.unit}'
                         for l in lines)

    @app.route('/api/material-passes', methods=['GET'])
    @core.require_auth
    def material_passes_list():
        """Мои пропуска; `?scope=approve` — руководителю, `?scope=gate` —
        охране: согласованные на сегодня и прошедшие сегодня КПП."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        roles = _roles(viewer)
        scope = request.args.get('scope', 'mine')
        today = core._plant_today()
        if scope == 'approve':
            if not roles['approver']:
                return core._deny()
            since = datetime.utcnow() - _LIST_CLOSED_FOR
            items = (MaterialPass.query
                     .filter(db.or_(MaterialPass.status == 'pending',
                                    MaterialPass.updated_at >= since))
                     .order_by(MaterialPass.created_at.desc()).limit(200).all())
            items.sort(key=lambda i: i.status != 'pending')
        elif scope == 'gate':
            if not roles['guard']:
                return core._deny()
            items = (MaterialPass.query
                     .filter(MaterialPass.status.in_(GATE_STATUSES),
                             MaterialPass.exit_date == today)
                     .order_by(MaterialPass.id).all())
            items.sort(key=lambda i: i.status != 'approved')
        else:
            items = (MaterialPass.query.filter_by(employee_id=viewer.employee_id)
                     .order_by(MaterialPass.created_at.desc()).limit(100).all())
        body = {'message': 'Success', 'roles': roles, 'units': list(UNITS),
                'items': _list_json(items, viewer, roles)}
        if roles['approver']:
            body['pending'] = MaterialPass.query.filter(
                MaterialPass.status == 'pending',
                MaterialPass.exit_date >= today).count()
        return jsonify(body)

    @app.route('/api/material-passes', methods=['POST'])
    @core.require_auth
    def material_passes_create():
        """`{"purpose", "carrier", "vehicle", "exit_date",
        "lines": [{"name", "quantity", "unit"}]}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        data = core._json_body()
        purpose = core._text(data, 'purpose')[:_MAX_TEXT]
        if not purpose:
            return _fail('purpose_required', 400)
        carrier = core._text(data, 'carrier')[:_MAX_NAME]
        if not carrier:
            return _fail('carrier_required', 400)
        vehicle = core._text(data, 'vehicle').upper()[:20]
        today = core._plant_today()
        try:
            exit_date = date.fromisoformat(core._text(data, 'exit_date'))
        except ValueError:
            return _fail('bad_date', 400)
        if not today <= exit_date <= today + timedelta(days=_MAX_DAYS_AHEAD):
            return _fail('bad_date', 400)

        raw_lines = data.get('lines')
        if not isinstance(raw_lines, list) or not raw_lines:
            return _fail('lines_required', 400)
        if len(raw_lines) > _MAX_LINES:
            return _fail('too_many_lines', 400)
        lines = []
        for raw in raw_lines:
            if not isinstance(raw, dict):
                return _fail('bad_line', 400)
            name = ' '.join(str(raw.get('name') or '').split())[:_MAX_NAME]
            if not name:
                return _fail('line_name_required', 400)
            quantity = _quantity(raw.get('quantity'))
            if quantity is None:
                return _fail('bad_quantity', 400)
            unit = str(raw.get('unit') or 'шт').strip()
            if unit not in UNITS:
                return _fail('bad_unit', 400)
            lines.append((name, quantity, unit))

        if MaterialPass.query.filter(MaterialPass.employee_id == viewer.employee_id,
                                     MaterialPass.status.in_(OPEN_STATUSES)).count() \
                >= _MAX_OPEN_PER_AUTHOR:
            return _fail('too_many_open', 429)

        now = datetime.utcnow()
        item = MaterialPass(employee_id=viewer.employee_id, purpose=purpose,
                            carrier=carrier, vehicle=vehicle or None,
                            exit_date=exit_date,
                            code=f'{secrets.randbelow(10000):04d}',
                            status='pending', created_at=now, updated_at=now)
        db.session.add(item)
        db.session.flush()
        for position, (name, quantity, unit) in enumerate(lines):
            db.session.add(MaterialPassLine(pass_id=item.id, position=position,
                                            name=name, quantity=quantity,
                                            unit=unit))
        db.session.add(MaterialPassEvent(pass_id=item.id,
                                         actor_id=viewer.employee_id,
                                         action='created', at=now))
        db.session.commit()
        logging.info('Материальный пропуск №%s от %s на %s, позиций %s',
                     item.id, viewer.employee_id, exit_date, len(lines))
        _notify(_ids(is_approver),
                f'Пропуск №{item.id} на {exit_date:%d.%m}: {purpose}',
                f'{viewer.full_name}. {_what(_lines(item))}'[:500], item.id,
                viewer.employee_id)
        return jsonify({'message': 'Success',
                        'item': _detail(item, viewer, _roles(viewer))}), 201

    @app.route('/api/material-passes/<int:item_id>', methods=['GET'])
    @core.require_auth
    def material_pass_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(MaterialPass, item_id)
        roles = _roles(viewer)
        if item is None or not _may_see(viewer, item, roles):
            return _fail('not_found', 404)
        return jsonify({'message': 'Success',
                        'item': _detail(item, viewer, roles)})

    @app.route('/api/material-passes/<int:item_id>', methods=['POST'])
    @core.require_auth
    def material_pass_action(item_id):
        """`{"action", "comment"}`.

        Руководитель: approve, reject (с причиной). Охрана: release, hold (с
        причиной). Автор: cancel. Всем, кто видит: comment.
        """
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(MaterialPass, item_id)
        roles = _roles(viewer)
        if item is None or not _may_see(viewer, item, roles):
            return _fail('not_found', 404)
        data = core._json_body()
        action = core._text(data, 'action')
        comment = core._text(data, 'comment')[:_MAX_COMMENT]
        is_author = viewer.employee_id == item.employee_id
        today = core._plant_today()
        now = datetime.utcnow()
        before = item.status

        if action in ('approve', 'reject'):
            if not roles['approver']:
                return core._deny()
            if is_author:
                # Свой пропуск себе не согласуют.
                return core._deny()
            if item.status != 'pending':
                return _fail('closed', 409)
            if _expired(item, today):
                return _fail('expired', 409)
            if action == 'reject' and not comment:
                return _fail('comment_required', 400)
            item.status = 'approved' if action == 'approve' else 'rejected'
            item.approver_id = viewer.employee_id
            item.decided_at = now
            item.reason = comment if action == 'reject' else None
        elif action in ('release', 'hold'):
            if not roles['guard']:
                return core._deny()
            if item.status != 'approved':
                return _fail('closed', 409)
            if item.exit_date < today:
                return _fail('expired', 409)
            if item.exit_date > today:
                return _fail('not_today', 409)
            if action == 'hold' and not comment:
                return _fail('comment_required', 400)
            item.status = 'released' if action == 'release' else 'held'
            item.guard_id = viewer.employee_id
            item.released_at = now
            if action == 'hold':
                item.reason = comment
        elif action == 'cancel':
            if not is_author:
                return core._deny()
            if item.status not in OPEN_STATUSES:
                return _fail('closed', 409)
            item.status = 'cancelled'
        elif action == 'comment':
            if not comment:
                return _fail('comment_required', 400)
        else:
            return _fail('bad_action', 400)

        item.updated_at = now
        db.session.add(MaterialPassEvent(pass_id=item.id,
                                         actor_id=viewer.employee_id,
                                         action=action, comment=comment or None,
                                         at=now))
        db.session.commit()

        number = f'Пропуск №{item.id}'
        who = viewer.full_name
        if action == 'approve':
            _notify([item.employee_id], f'{number} согласован',
                    f'{who}. Выезд {item.exit_date:%d.%m}, код {item.code}',
                    item.id, viewer.employee_id)
            if item.exit_date == today:
                _notify(_ids(is_guard), f'{number} на сегодня: {item.carrier}',
                        _what(_lines(item))[:500], item.id, viewer.employee_id)
        elif action == 'reject':
            _notify([item.employee_id], f'{number} не согласован',
                    f'{who}: {comment[:200]}', item.id, viewer.employee_id)
        elif action == 'release':
            _notify([item.employee_id], f'{number}: выпущено через КПП',
                    comment or item.carrier, item.id, viewer.employee_id)
        elif action == 'hold':
            _notify([item.employee_id, item.approver_id],
                    f'{number}: охрана не выпустила', comment[:200], item.id,
                    viewer.employee_id)
        elif action == 'comment':
            targets = {item.employee_id, item.approver_id, item.guard_id} - {None}
            _notify(targets, f'{number}: сообщение', f'{who}: {comment[:200]}',
                    item.id, viewer.employee_id)
        logging.info('Пропуск №%s: %s → %s (%s)', item.id, before, item.status,
                     viewer.employee_id)
        return jsonify({'message': 'Success',
                        'item': _detail(item, viewer, roles)})
