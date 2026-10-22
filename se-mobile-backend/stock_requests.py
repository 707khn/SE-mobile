"""Заявки на ТМЦ со склада: «на участок 3 — электроды МР-3, 5 кг; перчатки,
10 пар».

Сейчас мастер или оператор по учёту ТМЦ звонит на склад, кладовщик ищет,
перезванивает, что чего-то нет, а мастер приходит и узнаёт это у окошка.
Здесь заявка — это список позиций. Кладовщик берёт её, собирает и отмечает,
чего нет; автор видит «собрано, можно забирать» и идёт уже за готовым.
Чего не нашлось, сразу уходит руководству ДМТО как потребность: «нет на
складе» перестаёт теряться между складом и снабжением.

Разбирает Служба учёта ТМЦ. Склад (№1, №2, №3) автор выбирает, если знает;
тогда о новой заявке узнают те, у кого в должности этот склад, а остальные
службы — нет. Не знает — узнают все.

Устроено как заявки в ОИТиС и на ремонт: отдельный модуль, общее — через
`core`.
"""

import logging
import os
import re
from datetime import datetime, timedelta

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db


WAREHOUSES = (1, 2, 3)

# new → in_progress (кладовщик взял) → ready (собрано, можно забирать) →
# issued (выдано). Отказ — rejected, автор передумал — cancelled.
STATUSES = ('new', 'in_progress', 'ready', 'issued', 'rejected', 'cancelled')
OPEN_STATUSES = ('new', 'in_progress', 'ready')

UNITS = ('шт', 'кг', 'г', 'л', 'м', 'м²', 'м³', 'пар', 'упак', 'компл', 'рул', 'т')

_MAX_LINES = 30
_MAX_NAME = 200
_MAX_PURPOSE = 300
_MAX_COMMENT = 1000
_MAX_OPEN_PER_AUTHOR = 15
_MAX_PER_AUTHOR_PER_DAY = 30
_QUEUE_CLOSED_FOR = timedelta(days=14)


class StockRequest(db.Model):
    __tablename__ = 'stock_requests'
    __table_args__ = (
        db.Index('ix_stock_requests_author', 'employee_id', 'created_at'),
        db.Index('ix_stock_requests_status', 'status', 'updated_at'),
    )
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False)
    # Номер склада; пусто — «не знаю, где лежит».
    warehouse = db.Column(db.Integer)
    # Куда и зачем: «участок 3, заказ 112». Кладовщику это и есть адрес.
    purpose = db.Column(db.String(_MAX_PURPOSE), nullable=False)
    status = db.Column(db.String(20), nullable=False, default='new')
    assignee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    resolution = db.Column(db.Text)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    closed_at = db.Column(db.DateTime)


class StockRequestLine(db.Model):
    __tablename__ = 'stock_request_lines'
    id = db.Column(db.Integer, primary_key=True)
    request_id = db.Column(db.Integer,
                           db.ForeignKey('stock_requests.id', ondelete='CASCADE'),
                           nullable=False, index=True)
    position = db.Column(db.Integer, nullable=False, default=0)
    name = db.Column(db.String(_MAX_NAME), nullable=False)
    quantity = db.Column(db.Float, nullable=False)
    unit = db.Column(db.String(10), nullable=False, default='шт')
    # Кладовщик отметил, что этого нет (или нет столько).
    missing = db.Column(db.Boolean, nullable=False, default=False)


class StockRequestEvent(db.Model):
    __tablename__ = 'stock_request_events'
    id = db.Column(db.Integer, primary_key=True)
    request_id = db.Column(db.Integer,
                           db.ForeignKey('stock_requests.id', ondelete='CASCADE'),
                           nullable=False, index=True)
    actor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # created, take, ready, issued, reject, cancel, comment
    action = db.Column(db.String(20), nullable=False)
    comment = db.Column(db.Text)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _extra_staff():
    """STOCK_STAFF: табельные номера кладовщиков сверх Службы учёта ТМЦ."""
    return {p.strip() for p in os.environ.get('STOCK_STAFF', '').split(',')
            if p.strip()}


def is_stock_department(department):
    return 'учета тмц' in _norm(department).replace('учёта', 'учета')


def is_stock_staff(employee):
    if employee is None:
        return False
    return (is_stock_department(employee.department)
            or employee.employee_id in _extra_staff())


def warehouse_of(job_title):
    """«Зав. Складом №2», «Кладовщик склада №2» → 2; общей должности — None."""
    match = re.search(r'склад\w*\s*№\s*(\d+)', _norm(job_title))
    return int(match.group(1)) if match else None


def is_supply_head(employee):
    """Руководитель ДМТО и его заместитель: им — что не нашлось на складе."""
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


def register(app, core):
    from models import Employee

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _staff(viewer):
        return is_stock_staff(viewer) or core._is_system_admin(viewer.job_title)

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

    def _staff_ids(warehouse):
        extra = _extra_staff()
        staff = [e for e in Employee.query.all()
                 if is_stock_department(e.department) or e.employee_id in extra]
        if warehouse:
            own = [e for e in staff if warehouse_of(e.job_title) == warehouse]
            if own:
                return sorted(e.employee_id for e in own)
        return sorted(e.employee_id for e in staff)

    def _supply_ids():
        return sorted(e.employee_id for e in Employee.query.all()
                      if is_supply_head(e))

    def _lines(item_ids):
        if not item_ids:
            return {}
        out = {}
        for line in (StockRequestLine.query
                     .filter(StockRequestLine.request_id.in_(item_ids))
                     .order_by(StockRequestLine.position, StockRequestLine.id)):
            out.setdefault(line.request_id, []).append(line)
        return out

    def _json(item, people, lines, events=None):
        data = {
            'id': item.id,
            'warehouse': item.warehouse,
            'purpose': item.purpose,
            'status': item.status,
            'author': _person(people.get(item.employee_id), item.employee_id),
            'assignee': _person(people.get(item.assignee_id), item.assignee_id),
            'resolution': item.resolution or '',
            'created_at': _utc(item.created_at),
            'updated_at': _utc(item.updated_at),
            'closed_at': _utc(item.closed_at),
            'lines': [{'id': l.id, 'name': l.name, 'quantity': l.quantity,
                       'unit': l.unit, 'missing': bool(l.missing)}
                      for l in lines],
        }
        if events is not None:
            data['events'] = [{
                'action': e.action,
                'comment': e.comment or '',
                'at': _utc(e.at),
                'actor': _person(people.get(e.actor_id), e.actor_id),
            } for e in events]
        return data

    def _list_json(items):
        people = _names([i.employee_id for i in items]
                        + [i.assignee_id for i in items])
        lines = _lines([i.id for i in items])
        return [_json(i, people, lines.get(i.id, [])) for i in items]

    def _detail(item):
        events = (StockRequestEvent.query.filter_by(request_id=item.id)
                  .order_by(StockRequestEvent.at, StockRequestEvent.id).all())
        people = _names([item.employee_id, item.assignee_id]
                        + [e.actor_id for e in events])
        return _json(item, people, _lines([item.id]).get(item.id, []), events)

    def _may_see(viewer, item):
        # Руководству ДМТО приходит «нет на складе» со ссылкой на заявку —
        # открыть её оно должно, хотя ничего в ней не делает.
        return (viewer.employee_id == item.employee_id or _staff(viewer)
                or is_supply_head(viewer))

    def _notify(employee_ids, title, body, item_id, actor_id=None):
        ids = sorted({e for e in employee_ids if e and e != actor_id})
        if ids:
            core._record_notice('stock', title, body, employee_ids=ids,
                                ref=item_id)

    def _summary(lines, limit=3):
        parts = [f'{l.name} — {_number(l.quantity)} {l.unit}' for l in lines[:limit]]
        if len(lines) > limit:
            parts.append(f'ещё {len(lines) - limit}')
        return '; '.join(parts)

    @app.route('/api/stock-requests', methods=['GET'])
    @core.require_auth
    def stock_requests_list():
        """Мои заявки или, для склада, очередь: `?scope=queue`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        staff = _staff(viewer)
        if request.args.get('scope') == 'queue':
            if not staff:
                return core._deny()
            since = datetime.utcnow() - _QUEUE_CLOSED_FOR
            items = (StockRequest.query
                     .filter(db.or_(StockRequest.status.in_(OPEN_STATUSES),
                                    StockRequest.updated_at >= since))
                     .order_by(StockRequest.created_at.desc())
                     .limit(300).all())
        else:
            items = (StockRequest.query
                     .filter_by(employee_id=viewer.employee_id)
                     .order_by(StockRequest.created_at.desc())
                     .limit(100).all())
        # Есть ли кнопка «Остатки на складах» — её видят не все.
        import stock_balances
        body = {'message': 'Success', 'staff': staff,
                'balances': stock_balances.may_view(viewer, core),
                'my_warehouse': warehouse_of(viewer.job_title) if staff else None,
                'units': list(UNITS), 'items': _list_json(items)}
        if staff:
            counts = dict(db.session.query(StockRequest.status,
                                           db.func.count(StockRequest.id))
                          .filter(StockRequest.status.in_(OPEN_STATUSES))
                          .group_by(StockRequest.status))
            body['open'] = {s: counts.get(s, 0) for s in OPEN_STATUSES}
        return jsonify(body)

    @app.route('/api/stock-requests', methods=['POST'])
    @core.require_auth
    def stock_requests_create():
        """`{"warehouse": 2|null, "purpose": "...", "lines": [{"name",
        "quantity", "unit"}]}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        data = core._json_body()
        purpose = core._text(data, 'purpose')
        if not purpose:
            return _fail('purpose_required', 400)
        warehouse = data.get('warehouse')
        if warehouse in ('', None):
            warehouse = None
        else:
            try:
                warehouse = int(warehouse)
            except (TypeError, ValueError):
                return _fail('bad_warehouse', 400)
            if warehouse not in WAREHOUSES:
                return _fail('bad_warehouse', 400)

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
            quantity = _quantity(raw.get('quantity'))
            unit = str(raw.get('unit') or 'шт').strip()
            if not name:
                return _fail('line_name_required', 400)
            if quantity is None:
                return _fail('bad_quantity', 400)
            if unit not in UNITS:
                return _fail('bad_unit', 400)
            lines.append((name, quantity, unit))

        now = datetime.utcnow()
        mine = StockRequest.query.filter_by(employee_id=viewer.employee_id)
        if mine.filter(StockRequest.status.in_(OPEN_STATUSES)).count() >= _MAX_OPEN_PER_AUTHOR:
            return _fail('too_many_open', 429)
        if mine.filter(StockRequest.created_at >= now - timedelta(days=1)).count() >= _MAX_PER_AUTHOR_PER_DAY:
            return _fail('too_many_today', 429)

        item = StockRequest(employee_id=viewer.employee_id, warehouse=warehouse,
                            purpose=purpose[:_MAX_PURPOSE], status='new',
                            created_at=now, updated_at=now)
        db.session.add(item)
        db.session.flush()
        rows = [StockRequestLine(request_id=item.id, position=i, name=n,
                                 quantity=q, unit=u)
                for i, (n, q, u) in enumerate(lines)]
        db.session.add_all(rows)
        db.session.add(StockRequestEvent(request_id=item.id,
                                         actor_id=viewer.employee_id,
                                         action='created', at=now))
        db.session.commit()
        logging.info('Заявка на ТМЦ №%s от %s: склад %s, позиций %d', item.id,
                     viewer.employee_id, warehouse or '—', len(rows))

        where = f'склад №{warehouse}' if warehouse else 'склад не указан'
        _notify(_staff_ids(warehouse), f'ТМЦ №{item.id}: {item.purpose} ({where})',
                f'{viewer.full_name}: {_summary(rows)}', item.id,
                actor_id=viewer.employee_id)
        return jsonify({'message': 'Success', 'item': _detail(item)}), 201

    @app.route('/api/stock-requests/<int:item_id>', methods=['GET'])
    @core.require_auth
    def stock_request_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(StockRequest, item_id)
        if item is None or not _may_see(viewer, item):
            return _fail('not_found', 404)
        body = _detail(item)
        body['can_act'] = _staff(viewer)
        return jsonify({'message': 'Success', 'item': body})

    @app.route('/api/stock-requests/<int:item_id>', methods=['POST'])
    @core.require_auth
    def stock_request_action(item_id):
        """`{"action", "comment", "missing": [id строк]}`.

        Склад: take, ready (с отметкой, чего нет), issued, reject (с
        причиной). Автор: cancel. Обоим: comment.
        """
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(StockRequest, item_id)
        if item is None or not _may_see(viewer, item):
            return _fail('not_found', 404)
        data = core._json_body()
        action = core._text(data, 'action')
        comment = core._text(data, 'comment')[:_MAX_COMMENT]
        staff = _staff(viewer)
        is_author = viewer.employee_id == item.employee_id
        now = datetime.utcnow()
        lines = _lines([item.id]).get(item.id, [])
        newly_missing = []

        if action == 'take':
            if not staff:
                return core._deny()
            if item.status not in ('new', 'in_progress'):
                return _fail('closed', 409)
            item.status = 'in_progress'
            item.assignee_id = viewer.employee_id
        elif action == 'ready':
            if not staff:
                return core._deny()
            if item.status not in ('new', 'in_progress'):
                return _fail('closed', 409)
            raw = data.get('missing') or []
            if not isinstance(raw, list):
                return _fail('bad_missing', 400)
            wanted = {int(i) for i in raw if isinstance(i, int)
                      or (isinstance(i, str) and i.isdigit())}
            known = {l.id for l in lines}
            if wanted - known:
                return _fail('bad_missing', 400)
            if wanted == known:
                # Нет ничего — это не «собрано», это отказ с причиной.
                return _fail('nothing_ready', 409)
            for line in lines:
                if line.id in wanted and not line.missing:
                    newly_missing.append(line)
                line.missing = line.id in wanted
            item.status = 'ready'
            item.assignee_id = item.assignee_id or viewer.employee_id
            item.resolution = comment or None
        elif action == 'issued':
            if not staff:
                return core._deny()
            if item.status not in OPEN_STATUSES:
                return _fail('closed', 409)
            item.status = 'issued'
            item.assignee_id = item.assignee_id or viewer.employee_id
            item.closed_at = now
        elif action == 'reject':
            if not staff:
                return core._deny()
            if item.status not in OPEN_STATUSES:
                return _fail('closed', 409)
            if not comment:
                return _fail('comment_required', 400)
            item.status = 'rejected'
            item.assignee_id = item.assignee_id or viewer.employee_id
            item.resolution = comment
            item.closed_at = now
        elif action == 'cancel':
            if not is_author:
                return core._deny()
            if item.status not in OPEN_STATUSES:
                return _fail('closed', 409)
            item.status = 'cancelled'
            item.closed_at = now
        elif action == 'comment':
            if not comment:
                return _fail('comment_required', 400)
            if not (is_author or staff):
                return core._deny()
        else:
            return _fail('bad_action', 400)

        item.updated_at = now
        db.session.add(StockRequestEvent(request_id=item.id,
                                         actor_id=viewer.employee_id,
                                         action=action, comment=comment or None,
                                         at=now))
        db.session.commit()

        number = f'ТМЦ №{item.id}'
        who = viewer.full_name
        if action == 'take':
            _notify([item.employee_id], f'{number} собирают', f'Кладовщик: {who}',
                    item.id, viewer.employee_id)
        elif action == 'ready':
            missing = [l for l in lines if l.missing]
            body = 'Можно забирать'
            if item.warehouse:
                body = f'Можно забирать, склад №{item.warehouse}'
            if missing:
                body += f'. Нет: {_summary(missing)}'
            _notify([item.employee_id], f'{number} собрана', body, item.id,
                    viewer.employee_id)
            if newly_missing:
                author = db.session.get(Employee, item.employee_id)
                _notify(_supply_ids(), f'Нет на складе: {number}',
                        f'{_summary(newly_missing, limit=5)}. Для: '
                        f'{author.full_name if author else item.employee_id}, '
                        f'{item.purpose}', item.id, viewer.employee_id)
        elif action == 'issued':
            _notify([item.employee_id], f'{number} выдана', who, item.id,
                    viewer.employee_id)
        elif action == 'reject':
            _notify([item.employee_id], f'{number} отклонена', comment, item.id,
                    viewer.employee_id)
        elif action == 'comment':
            if is_author:
                targets = ([item.assignee_id] if item.assignee_id
                           else _staff_ids(item.warehouse))
            else:
                targets = [item.employee_id]
            _notify(targets, f'{number}: сообщение', f'{who}: {comment[:200]}',
                    item.id, viewer.employee_id)
        body = _detail(item)
        body['can_act'] = staff
        return jsonify({'message': 'Success', 'item': body})
