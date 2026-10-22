"""Инвентаризация склада: пересчёт с телефона и расхождения с 1С.

Сейчас кладовщик распечатывает ведомость остатков, ходит со стеллажа на
стеллаж с ручкой, а потом сверяет и перепечатывает цифры в Excel. Здесь
пересчёт начинается из последней выгрузки остатков 1С (см. stock_balances):
по каждой позиции склада запоминается, сколько её должно быть, а кладовщик
сканирует код — камерой телефона или ручным сканером, который печатает как
клавиатура, — и вводит, сколько насчитал. Расхождения видны сразу, а в
конце выгружаются в Excel для акта.

Код на этикетке не всегда совпадает с кодом 1С: на заводской упаковке
штрихкод производителя. Такой код один раз привязывают к позиции, и дальше
он находит её сам — на любом складе и в следующих пересчётах.

Считать могут Служба учёта ТМЦ, системный администратор и INVENTORY_STAFF.
Количество прибавляется атомарно: два кладовщика на одном складе не
затирают друг друга.
"""

import os
from datetime import datetime

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db
from stock_balances import StockBalance
from stock_requests import is_stock_staff

STATUSES = ('open', 'closed')

_MAX_QUANTITY = 1_000_000
_MAX_COUNTS = 30
_MAX_LINES = 3000


class InventoryCount(db.Model):
    __tablename__ = 'inventory_counts'
    id = db.Column(db.Integer, primary_key=True)
    warehouse = db.Column(db.String(100), nullable=False, default='')
    status = db.Column(db.String(10), nullable=False, default='open')
    # Остатки 1С — по состоянию на эту выгрузку.
    as_of = db.Column(db.DateTime)
    started_by = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    started_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    closed_by = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    closed_at = db.Column(db.DateTime)


class InventoryLine(db.Model):
    __tablename__ = 'inventory_lines'
    __table_args__ = (db.UniqueConstraint('count_id', 'item_key'),)
    id = db.Column(db.Integer, primary_key=True)
    count_id = db.Column(db.Integer, db.ForeignKey('inventory_counts.id'),
                         nullable=False, index=True)
    # Код 1С или наименование без регистра — и единица: как в остатках.
    item_key = db.Column(db.String(230), nullable=False)
    code = db.Column(db.String(50))
    name = db.Column(db.String(200), nullable=False)
    name_key = db.Column(db.String(200), nullable=False)
    unit = db.Column(db.String(20))
    expected = db.Column(db.Float, nullable=False, default=0)
    counted = db.Column(db.Float)
    # Нашлось на складе, а в 1С нет.
    extra = db.Column(db.Boolean, nullable=False, default=False)
    counted_by = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    counted_at = db.Column(db.DateTime)


class InventoryBarcode(db.Model):
    """Штрихкод производителя → позиция 1С. Привязывают один раз."""
    __tablename__ = 'inventory_barcodes'
    barcode = db.Column(db.String(64), primary_key=True)
    item_key = db.Column(db.String(230), nullable=False)
    set_by = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    set_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def may_count(employee, core):
    if employee is None:
        return False
    return (is_stock_staff(employee) or core._is_system_admin(employee.job_title)
            or employee.employee_id in _env_ids('INVENTORY_STAFF'))


def item_key(code, name, unit):
    return f"{code or _norm(name)[:200]}|{(unit or '').strip().lower()}"[:230]


def _quantity(raw):
    if isinstance(raw, bool):
        return None
    try:
        value = float(str(raw).replace(',', '.').replace(' ', ''))
    except (TypeError, ValueError):
        return None
    if value != value or value < 0 or value > _MAX_QUANTITY:
        return None
    return round(value, 3)


def _diff(line, closed):
    if line.counted is None:
        # Не посчитанное к концу пересчёта — не нашлось.
        return -line.expected if closed else None
    return round(line.counted - line.expected, 3)


def register(app, core):
    from models import Employee

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status, **extra):
        return jsonify({'message': 'Failure', 'error': error, **extra}), status

    def _person(employee_id):
        if not employee_id:
            return None
        emp = db.session.get(Employee, employee_id)
        return {'id': employee_id, 'name': emp.full_name if emp else employee_id}

    def _line_json(line, closed):
        return {
            'id': line.id,
            'code': line.code or '',
            'name': line.name,
            'unit': line.unit or '',
            'expected': line.expected,
            'counted': line.counted,
            'extra': line.extra,
            'diff': _diff(line, closed),
            'counted_at': _utc(line.counted_at),
        }

    def _count_json(count):
        closed = count.status == 'closed'
        lines = InventoryLine.query.filter_by(count_id=count.id).all()
        diffs = [_diff(line, closed) for line in lines]
        return {
            'id': count.id,
            'warehouse': count.warehouse,
            'status': count.status,
            'as_of': _utc(count.as_of),
            'started_at': _utc(count.started_at),
            'started_by': _person(count.started_by),
            'closed_at': _utc(count.closed_at),
            'closed_by': _person(count.closed_by),
            'lines': len(lines),
            'counted': sum(1 for line in lines if line.counted is not None),
            'differences': sum(1 for d in diffs if d),
        }

    def _counter():
        viewer = _viewer()
        if viewer is None:
            return None, _fail('unauthorized', 401)
        if not may_count(viewer, core):
            return None, core._deny()
        return viewer, None

    def _open_count(count_id):
        count = db.session.get(InventoryCount, count_id)
        if count is None:
            return None, _fail('not_found', 404)
        if count.status != 'open':
            return None, _fail('closed', 409)
        return count, None

    @app.route('/api/inventory', methods=['GET'])
    @core.require_auth
    def inventory_list():
        """Склады из выгрузки остатков и последние пересчёты."""
        viewer, denied = _counter()
        if denied:
            return denied
        warehouses = (db.session.query(StockBalance.warehouse,
                                       db.func.count(StockBalance.id),
                                       db.func.max(StockBalance.uploaded_at))
                      .group_by(StockBalance.warehouse)
                      .order_by(StockBalance.warehouse).all())
        counts = (InventoryCount.query
                  .order_by(InventoryCount.status.desc(),
                            InventoryCount.started_at.desc(),
                            InventoryCount.id.desc())
                  .limit(_MAX_COUNTS).all())
        return jsonify({
            'message': 'Success',
            'warehouses': [{'name': name, 'items': items, 'as_of': _utc(at)}
                           for name, items, at in warehouses],
            'counts': [_count_json(c) for c in counts],
        })

    @app.route('/api/inventory', methods=['POST'])
    @core.require_auth
    def inventory_start():
        """{warehouse} — пересчёт по последней выгрузке этого склада."""
        viewer, denied = _counter()
        if denied:
            return denied
        data = core._json_body()
        warehouse = core._text(data, 'warehouse')[:100]
        balances = (StockBalance.query.filter_by(warehouse=warehouse)
                    .order_by(StockBalance.name_key, StockBalance.id)
                    .limit(_MAX_LINES).all())
        if not balances:
            return _fail('no_warehouse', 400)
        busy = InventoryCount.query.filter_by(warehouse=warehouse,
                                              status='open').first()
        if busy is not None:
            return _fail('exists', 409, id=busy.id)

        count = InventoryCount(warehouse=warehouse, status='open',
                               as_of=max(b.uploaded_at for b in balances),
                               started_by=viewer.employee_id)
        db.session.add(count)
        db.session.flush()
        lines = {}
        for row in balances:
            key = item_key(row.code, row.name, row.unit)
            if key in lines:
                lines[key].expected += row.quantity
                continue
            lines[key] = InventoryLine(
                count_id=count.id, item_key=key, code=row.code, name=row.name,
                name_key=row.name_key, unit=row.unit, expected=row.quantity)
        db.session.add_all(lines.values())
        db.session.commit()
        return jsonify({'message': 'Success', 'count': _count_json(count)}), 201

    @app.route('/api/inventory/<int:count_id>', methods=['GET'])
    @core.require_auth
    def inventory_detail(count_id):
        viewer, denied = _counter()
        if denied:
            return denied
        count = db.session.get(InventoryCount, count_id)
        if count is None:
            return _fail('not_found', 404)
        lines = (InventoryLine.query.filter_by(count_id=count.id)
                 .order_by(InventoryLine.name_key, InventoryLine.id).all())
        closed = count.status == 'closed'
        return jsonify({'message': 'Success', 'count': _count_json(count),
                        'lines': [_line_json(line, closed) for line in lines]})

    def _find_line(count, barcode):
        line = (InventoryLine.query.filter_by(count_id=count.id, code=barcode)
                .order_by(InventoryLine.id).first())
        if line is not None:
            return line
        bound = db.session.get(InventoryBarcode, barcode)
        if bound is None:
            return None
        return InventoryLine.query.filter_by(count_id=count.id,
                                             item_key=bound.item_key).first()

    @app.route('/api/inventory/<int:count_id>/scan', methods=['POST'])
    @core.require_auth
    def inventory_scan(count_id):
        """{barcode | line_id, quantity, mode: add|set}.

        Без количества — только найти позицию: экран спросит, сколько.
        С line_id и barcode — заодно запомнить, что этот штрихкод — она.
        """
        viewer, denied = _counter()
        if denied:
            return denied
        count, failed = _open_count(count_id)
        if failed:
            return failed
        data = core._json_body()
        barcode = core._text(data, 'barcode')[:64]
        line_id = data.get('line_id')

        if line_id is not None:
            line = db.session.get(InventoryLine, line_id) \
                if isinstance(line_id, int) else None
            if line is None or line.count_id != count.id:
                return _fail('not_found', 404)
            if barcode and barcode != (line.code or ''):
                bound = db.session.get(InventoryBarcode, barcode)
                if bound is None:
                    db.session.add(InventoryBarcode(
                        barcode=barcode, item_key=line.item_key,
                        set_by=viewer.employee_id))
                else:
                    bound.item_key = line.item_key
                    bound.set_by = viewer.employee_id
                    bound.set_at = datetime.utcnow()
        elif barcode:
            line = _find_line(count, barcode)
            if line is None:
                return _fail('unknown_code', 404, barcode=barcode)
        else:
            return _fail('code_required', 400)

        if data.get('quantity') in (None, ''):
            db.session.commit()
            return jsonify({'message': 'Success',
                            'line': _line_json(line, False)})
        quantity = _quantity(data.get('quantity'))
        if quantity is None:
            db.session.rollback()
            return _fail('bad_quantity', 400)

        now = datetime.utcnow()
        if data.get('mode') == 'set':
            value = quantity
        else:
            # Прибавляем в самой базе: второй кладовщик мог посчитать ту же
            # позицию на соседнем стеллаже секундой раньше.
            value = db.func.coalesce(InventoryLine.counted, 0) + quantity
        InventoryLine.query.filter_by(id=line.id).update(
            {'counted': value, 'counted_by': viewer.employee_id,
             'counted_at': now}, synchronize_session=False)
        db.session.commit()
        db.session.refresh(line)
        return jsonify({'message': 'Success', 'line': _line_json(line, False)})

    @app.route('/api/inventory/<int:count_id>/extra', methods=['POST'])
    @core.require_auth
    def inventory_extra(count_id):
        """{name, unit, quantity, barcode?} — нашлось то, чего нет в 1С."""
        viewer, denied = _counter()
        if denied:
            return denied
        count, failed = _open_count(count_id)
        if failed:
            return failed
        data = core._json_body()
        name = ' '.join(core._text(data, 'name').split())[:200]
        unit = core._text(data, 'unit')[:20]
        barcode = core._text(data, 'barcode')[:64]
        if not name:
            return _fail('name_required', 400)
        quantity = _quantity(data.get('quantity'))
        if quantity is None:
            return _fail('bad_quantity', 400)
        key = item_key(None, name, unit)
        if InventoryLine.query.filter_by(count_id=count.id, item_key=key).first():
            return _fail('exists', 409)
        line = InventoryLine(
            count_id=count.id, item_key=key, name=name, name_key=_norm(name)[:200],
            unit=unit or None, expected=0, counted=quantity, extra=True,
            counted_by=viewer.employee_id, counted_at=datetime.utcnow())
        db.session.add(line)
        if barcode and db.session.get(InventoryBarcode, barcode) is None:
            db.session.add(InventoryBarcode(barcode=barcode, item_key=key,
                                            set_by=viewer.employee_id))
        db.session.commit()
        return jsonify({'message': 'Success', 'line': _line_json(line, False)}), 201

    @app.route('/api/inventory/<int:count_id>', methods=['POST'])
    @core.require_auth
    def inventory_action(count_id):
        """{action: close} — итог; {action: remove} — начатый по ошибке."""
        viewer, denied = _counter()
        if denied:
            return denied
        count, failed = _open_count(count_id)
        if failed:
            return failed
        action = core._json_body().get('action')
        if action == 'close':
            count.status = 'closed'
            count.closed_by = viewer.employee_id
            count.closed_at = datetime.utcnow()
            db.session.commit()
            return jsonify({'message': 'Success', 'count': _count_json(count)})
        if action == 'remove':
            if InventoryLine.query.filter(InventoryLine.count_id == count.id,
                                          InventoryLine.counted.isnot(None)).first():
                return _fail('has_counts', 409)
            InventoryLine.query.filter_by(count_id=count.id).delete()
            db.session.delete(count)
            db.session.commit()
            return jsonify({'message': 'Success'})
        return _fail('bad_action', 400)
