"""«Где моя закупка»: заявка на закупку и её этап — принята, ищут
поставщика, договор на согласовании, в пути, на складе.

Сейчас инициатор узнаёт, где его закупка, звонком в ДМТО, а менеджер ДМТО
полдня отвечает на «ну что там?». Здесь у заявки есть ответственный
менеджер и этап, который он двигает; инициатор видит этап, ожидаемую дату
поставки и всё, что менеджер написал, и получает оповещение на каждом шаге.

Новую заявку видят руководитель ДМТО и заместитель (они распределяют) и
все менеджеры ДМТО (берут сами). PURCHASE_STAFF — сверх подразделения.
Этапы идут только вперёд: вернуть «в пути» к «поиску поставщика» значит
начать заново, а это — отказ и новая заявка.
"""

import logging
import os
from datetime import date, datetime, timedelta

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db


# Этапы по порядку. new — ещё никто не взял.
STAGES = ('new', 'accepted', 'sourcing', 'contract', 'in_transit', 'delivered')
CLOSED = ('delivered', 'rejected', 'cancelled')
STAGE_TITLES = {
    'new': 'новая', 'accepted': 'принята', 'sourcing': 'поиск поставщика',
    'contract': 'договор на согласовании', 'in_transit': 'в пути',
    'delivered': 'на складе',
}

UNITS = ('шт', 'кг', 'г', 'л', 'м', 'м²', 'м³', 'пар', 'упак', 'компл', 'рул', 'т')

_MAX_LINES = 30
_MAX_NAME = 200
_MAX_TEXT = 500
_MAX_COMMENT = 1000
_MAX_OPEN_PER_AUTHOR = 30
# Столько без движения — и заявка в очереди помечается «давно стоит».
STALE_AFTER = timedelta(days=7)
_QUEUE_CLOSED_FOR = timedelta(days=30)


def is_supply_head(employee):
    """Руководитель ДМТО и его заместитель: распределяют заявки."""
    dept = _norm(employee.department)
    return ('материально-технического' in dept or 'дмто' in dept) \
        and 'руководител' in _norm(employee.job_title)


def _quantity(raw):
    """«2,5» и «2.5» — одно и то же; ноль и меньше — не количество."""
    if isinstance(raw, (int, float)) and not isinstance(raw, bool):
        value = float(raw)
    elif isinstance(raw, str):
        try:
            value = float(raw.strip().replace(',', '.'))
        except ValueError:
            return None
    else:
        return None
    if not (0 < value < 1_000_000):
        return None
    return value


def _number(value):
    """5.0 → «5», 2.5 → «2,5» — в тексте оповещения."""
    return (f'{value:g}').replace('.', ',')


class Purchase(db.Model):
    __tablename__ = 'purchases'
    __table_args__ = (
        db.Index('ix_purchases_author', 'employee_id', 'created_at'),
        db.Index('ix_purchases_status', 'status', 'updated_at'),
    )
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False)
    # Для чего: «ремонт пресса К-2130», «участок 3, заказ 112».
    purpose = db.Column(db.String(_MAX_TEXT), nullable=False)
    needed_by = db.Column(db.Date)
    urgent = db.Column(db.Boolean, nullable=False, default=False)
    status = db.Column(db.String(12), nullable=False, default='new')
    assignee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    supplier = db.Column(db.String(_MAX_NAME))
    # Когда обещают привезти — менеджер ставит на «в пути».
    eta = db.Column(db.Date)
    reason = db.Column(db.Text)
    stage_since = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    closed_at = db.Column(db.DateTime)


class PurchaseLine(db.Model):
    __tablename__ = 'purchase_lines'
    id = db.Column(db.Integer, primary_key=True)
    purchase_id = db.Column(db.Integer,
                            db.ForeignKey('purchases.id', ondelete='CASCADE'),
                            nullable=False, index=True)
    position = db.Column(db.Integer, nullable=False)
    name = db.Column(db.String(_MAX_NAME), nullable=False)
    quantity = db.Column(db.Float, nullable=False)
    unit = db.Column(db.String(10), nullable=False, default='шт')


class PurchaseEvent(db.Model):
    __tablename__ = 'purchase_events'
    id = db.Column(db.Integer, primary_key=True)
    purchase_id = db.Column(db.Integer,
                            db.ForeignKey('purchases.id', ondelete='CASCADE'),
                            nullable=False, index=True)
    actor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # created, take, assign, stage, reject, cancel, comment
    action = db.Column(db.String(10), nullable=False)
    # Для stage — на какой этап перешли.
    stage = db.Column(db.String(12))
    comment = db.Column(db.Text)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_purchase_staff(employee):
    if employee is None:
        return False
    dept = _norm(employee.department)
    return ('материально-технического' in dept or 'дмто' in dept
            or employee.employee_id in _env_ids('PURCHASE_STAFF'))


def register(app, core):
    from models import Employee

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _roles(viewer):
        admin = core._is_system_admin(viewer.job_title)
        staff = admin or is_purchase_staff(viewer)
        return {'staff': staff,
                'head': admin or (staff and is_supply_head(viewer))}

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
        return viewer.employee_id == item.employee_id or roles['staff']

    def _lines(item):
        return (PurchaseLine.query.filter_by(purchase_id=item.id)
                .order_by(PurchaseLine.position).all())

    def _json(item, lines, people, viewer, roles, events=None):
        now = datetime.utcnow()
        data = {
            'id': item.id,
            'purpose': item.purpose,
            'needed_by': item.needed_by.isoformat() if item.needed_by else None,
            'urgent': bool(item.urgent),
            'status': item.status,
            'author': _person(people.get(item.employee_id), item.employee_id),
            'assignee': _person(people.get(item.assignee_id), item.assignee_id),
            'supplier': item.supplier or '',
            'eta': item.eta.isoformat() if item.eta else None,
            'reason': item.reason or '',
            'stage_since': _utc(item.stage_since),
            'stale': bool(item.status not in CLOSED
                          and now - item.stage_since >= STALE_AFTER),
            'created_at': _utc(item.created_at),
            'closed_at': _utc(item.closed_at),
            'lines': [{'name': l.name, 'quantity': l.quantity, 'unit': l.unit}
                      for l in lines],
            'is_author': viewer.employee_id == item.employee_id,
            'can_act': bool(roles['staff'] and item.status not in CLOSED),
            'can_assign': bool(roles['head'] and item.status not in CLOSED),
        }
        if events is not None:
            data['events'] = [{
                'action': e.action,
                'stage': e.stage or '',
                'comment': e.comment or '',
                'at': _utc(e.at),
                'actor': _person(people.get(e.actor_id), e.actor_id),
            } for e in events]
        return data

    def _list_json(items, viewer, roles):
        lines_of = {}
        for l in (PurchaseLine.query
                  .filter(PurchaseLine.purchase_id.in_([i.id for i in items] or [-1]))
                  .order_by(PurchaseLine.position)):
            lines_of.setdefault(l.purchase_id, []).append(l)
        people = _names([i.employee_id for i in items]
                        + [i.assignee_id for i in items])
        return [_json(i, lines_of.get(i.id, []), people, viewer, roles)
                for i in items]

    def _detail(item, viewer, roles):
        events = (PurchaseEvent.query.filter_by(purchase_id=item.id)
                  .order_by(PurchaseEvent.at, PurchaseEvent.id).all())
        people = _names([item.employee_id, item.assignee_id]
                        + [e.actor_id for e in events])
        return _json(item, _lines(item), people, viewer, roles, events)

    def _notify(employee_ids, title, body, item_id, actor_id=None):
        ids = sorted({e for e in employee_ids if e and e != actor_id})
        if ids:
            core._record_notice('purchase', title, body, employee_ids=ids,
                                ref=item_id, repeat=True)

    def _what(lines):
        return '; '.join(f'{l.name} — {_number(l.quantity)} {l.unit}'
                         for l in lines)

    @app.route('/api/purchases', methods=['GET'])
    @core.require_auth
    def purchases_list():
        """Мои заявки или очередь ДМТО: `?scope=queue`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        roles = _roles(viewer)
        if request.args.get('scope') == 'queue':
            if not roles['staff']:
                return core._deny()
            since = datetime.utcnow() - _QUEUE_CLOSED_FOR
            items = (Purchase.query
                     .filter(db.or_(Purchase.status.notin_(CLOSED),
                                    Purchase.updated_at >= since))
                     .order_by(Purchase.created_at).limit(300).all())
            # Несрочное и закрытое — вниз; среди открытых — давно ждущее выше.
            items.sort(key=lambda i: (i.status in CLOSED, not i.urgent,
                                      i.status != 'new'))
        else:
            items = (Purchase.query.filter_by(employee_id=viewer.employee_id)
                     .order_by(Purchase.created_at.desc()).limit(100).all())
        body = {'message': 'Success', 'staff': roles['staff'],
                'head': roles['head'], 'units': list(UNITS),
                'items': _list_json(items, viewer, roles)}
        if roles['staff']:
            counts = dict(db.session.query(Purchase.status,
                                           db.func.count(Purchase.id))
                          .filter(Purchase.status.notin_(CLOSED))
                          .group_by(Purchase.status))
            body['open'] = {s: counts.get(s, 0) for s in STAGES[:-1]}
            body['mine_open'] = Purchase.query.filter(
                Purchase.assignee_id == viewer.employee_id,
                Purchase.status.notin_(CLOSED)).count()
        return jsonify(body)

    @app.route('/api/purchases/staff', methods=['GET'])
    @core.require_auth
    def purchases_staff():
        """Кому руководитель ДМТО может отдать заявку."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not _roles(viewer)['head']:
            return core._deny()
        people = [e for e in Employee.query.order_by(Employee.full_name)
                  if is_purchase_staff(e)]
        return jsonify({'message': 'Success',
                        'people': [_person(e, e.employee_id) for e in people]})

    @app.route('/api/purchases', methods=['POST'])
    @core.require_auth
    def purchases_create():
        """`{"purpose", "needed_by", "urgent",
        "lines": [{"name", "quantity", "unit"}]}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        data = core._json_body()
        purpose = core._text(data, 'purpose')[:_MAX_TEXT]
        if not purpose:
            return _fail('purpose_required', 400)
        needed_by = None
        raw_date = core._text(data, 'needed_by')
        if raw_date:
            try:
                needed_by = date.fromisoformat(raw_date)
            except ValueError:
                return _fail('bad_date', 400)
            if needed_by < core._plant_today():
                return _fail('bad_date', 400)
        urgent = data.get('urgent') in (True, 1, '1', 'true')

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

        if Purchase.query.filter(Purchase.employee_id == viewer.employee_id,
                                 Purchase.status.notin_(CLOSED)).count() \
                >= _MAX_OPEN_PER_AUTHOR:
            return _fail('too_many_open', 429)

        now = datetime.utcnow()
        item = Purchase(employee_id=viewer.employee_id, purpose=purpose,
                        needed_by=needed_by, urgent=urgent, status='new',
                        stage_since=now, created_at=now, updated_at=now)
        db.session.add(item)
        db.session.flush()
        for position, (name, quantity, unit) in enumerate(lines):
            db.session.add(PurchaseLine(purchase_id=item.id, position=position,
                                        name=name, quantity=quantity, unit=unit))
        db.session.add(PurchaseEvent(purchase_id=item.id,
                                     actor_id=viewer.employee_id,
                                     action='created', stage='new', at=now))
        db.session.commit()
        logging.info('Закупка №%s от %s, позиций %s', item.id,
                     viewer.employee_id, len(lines))
        # Срочное — всем менеджерам, обычное — тем, кто распределяет.
        targets = _ids(is_purchase_staff) if urgent else \
            _ids(lambda e: is_purchase_staff(e) and is_supply_head(e))
        when = f', нужно к {needed_by:%d.%m}' if needed_by else ''
        _notify(targets,
                f'{"Срочная закупка" if urgent else "Закупка"} №{item.id}: {purpose}'[:200],
                f'{viewer.full_name}{when}. {_what(_lines(item))}'[:500],
                item.id, viewer.employee_id)
        return jsonify({'message': 'Success',
                        'item': _detail(item, viewer, _roles(viewer))}), 201

    @app.route('/api/purchases/<int:item_id>', methods=['GET'])
    @core.require_auth
    def purchase_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(Purchase, item_id)
        roles = _roles(viewer)
        if item is None or not _may_see(viewer, item, roles):
            return _fail('not_found', 404)
        return jsonify({'message': 'Success',
                        'item': _detail(item, viewer, roles)})

    @app.route('/api/purchases/<int:item_id>', methods=['POST'])
    @core.require_auth
    def purchase_action(item_id):
        """`{"action", "comment", "stage", "assignee_id", "supplier", "eta"}`.

        ДМТО: take, assign (руководитель), stage (вперёд), reject (с
        причиной). Автор: cancel. Всем, кто видит: comment.
        """
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(Purchase, item_id)
        roles = _roles(viewer)
        if item is None or not _may_see(viewer, item, roles):
            return _fail('not_found', 404)
        data = core._json_body()
        action = core._text(data, 'action')
        comment = core._text(data, 'comment')[:_MAX_COMMENT]
        is_author = viewer.employee_id == item.employee_id
        now = datetime.utcnow()
        before = item.status
        stage = None
        assignee = None

        if action in ('take', 'assign', 'stage', 'reject'):
            if not roles['staff']:
                return core._deny()
            if item.status in CLOSED:
                return _fail('closed', 409)

        if action == 'take':
            if item.assignee_id == viewer.employee_id:
                return _fail('already_yours', 409)
            item.assignee_id = viewer.employee_id
            if item.status == 'new':
                item.status = stage = 'accepted'
                item.stage_since = now
        elif action == 'assign':
            if not roles['head']:
                return core._deny()
            assignee = db.session.get(Employee, core._text(data, 'assignee_id'))
            if assignee is None or not is_purchase_staff(assignee):
                return _fail('bad_assignee', 400)
            item.assignee_id = assignee.employee_id
            if item.status == 'new':
                item.status = stage = 'accepted'
                item.stage_since = now
        elif action == 'stage':
            stage = core._text(data, 'stage')
            if stage not in STAGES[2:]:
                return _fail('bad_stage', 400)
            if STAGES.index(stage) <= STAGES.index(item.status):
                return _fail('stage_back', 409)
            supplier = core._text(data, 'supplier')[:_MAX_NAME]
            if supplier:
                item.supplier = supplier
            raw_eta = core._text(data, 'eta')
            if raw_eta:
                try:
                    item.eta = date.fromisoformat(raw_eta)
                except ValueError:
                    return _fail('bad_date', 400)
            if item.assignee_id is None:
                item.assignee_id = viewer.employee_id
            item.status = stage
            item.stage_since = now
            if stage == 'delivered':
                item.closed_at = now
        elif action == 'reject':
            if not comment:
                return _fail('comment_required', 400)
            item.status = 'rejected'
            item.reason = comment
            item.closed_at = now
        elif action == 'cancel':
            if not is_author:
                return core._deny()
            if item.status in CLOSED:
                return _fail('closed', 409)
            item.status = 'cancelled'
            item.closed_at = now
        elif action == 'comment':
            if not comment:
                return _fail('comment_required', 400)
        else:
            return _fail('bad_action', 400)

        item.updated_at = now
        db.session.add(PurchaseEvent(purchase_id=item.id,
                                     actor_id=viewer.employee_id,
                                     action=action, stage=stage,
                                     comment=comment or None, at=now))
        db.session.commit()

        number = f'Закупка №{item.id}'
        who = viewer.full_name
        if stage is not None:
            extra = []
            if stage == 'in_transit' and item.eta:
                extra.append(f'ожидается {item.eta:%d.%m}')
            if item.supplier and stage in ('contract', 'in_transit'):
                extra.append(item.supplier)
            if comment:
                extra.append(comment[:200])
            _notify([item.employee_id], f'{number}: {STAGE_TITLES[stage]}',
                    '; '.join(extra) or who, item.id, viewer.employee_id)
        if action == 'assign':
            _notify([assignee.employee_id], f'Вам передана {number.lower()}',
                    item.purpose[:200], item.id, viewer.employee_id)
        elif action == 'reject':
            _notify([item.employee_id], f'{number}: отказ',
                    f'{who}: {comment[:200]}', item.id, viewer.employee_id)
        elif action == 'cancel' and item.assignee_id:
            _notify([item.assignee_id], f'{number} отменена инициатором',
                    item.purpose[:200], item.id, viewer.employee_id)
        elif action == 'comment':
            targets = {item.employee_id, item.assignee_id} - {None}
            if item.assignee_id is None:
                # Ещё никто не взял — пусть увидят те, кто распределяет.
                targets |= set(_ids(lambda e: is_purchase_staff(e)
                                    and is_supply_head(e)))
            _notify(targets, f'{number}: сообщение', f'{who}: {comment[:200]}',
                    item.id, viewer.employee_id)
        logging.info('Закупка №%s: %s → %s (%s, %s)', item.id, before,
                     item.status, action, viewer.employee_id)
        return jsonify({'message': 'Success',
                        'item': _detail(item, viewer, roles)})
