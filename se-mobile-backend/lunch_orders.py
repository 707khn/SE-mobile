"""Предзаказ обеда: сотрудник выбирает блюда из меню заранее, столовая
видит, сколько чего готовить и кому что отдать.

Сейчас столовая готовит на глаз: к концу обеда одно кончается в первые
полчаса, а другое остаётся. Здесь заказ на день можно сделать заранее или
сегодня до отсечки (LUNCH_ORDER_CUTOFF, по умолчанию 10:30); до неё же —
поправить или отменить. Столовая видит итог по блюдам и список заказов и
отмечает выданные.

Блюда в заказе — снимок меню на момент заказа: технолог при правке меню
пересоздаёт строки, и ссылка на строку меню потерялась бы. Оплата — как и
раньше, на кассе: приложение показывает сумму по ценам меню, но денег не
списывает.

Столовая — технолог столовой, подразделение «Столовая», администратор и
CANTEEN_STAFF.
"""

import logging
import os
from datetime import date, datetime, time, timedelta

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db

_MAX_DAYS_AHEAD = 7
_MAX_LINES = 10
_MAX_QUANTITY = 5
_MAX_NOTE = 200


class LunchOrder(db.Model):
    __tablename__ = 'lunch_orders'
    __table_args__ = (db.UniqueConstraint('employee_id', 'day',
                                          name='uq_lunch_orders_employee_day'),)
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    day = db.Column(db.Date, nullable=False, index=True)
    note = db.Column(db.String(_MAX_NOTE))
    served_at = db.Column(db.DateTime)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class LunchOrderLine(db.Model):
    __tablename__ = 'lunch_order_lines'
    id = db.Column(db.Integer, primary_key=True)
    order_id = db.Column(db.Integer,
                         db.ForeignKey('lunch_orders.id', ondelete='CASCADE'),
                         nullable=False, index=True)
    category = db.Column(db.String(50), nullable=False)
    name = db.Column(db.String(255), nullable=False)
    price = db.Column(db.Numeric(10, 2))
    quantity = db.Column(db.Integer, nullable=False, default=1)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def _cutoff():
    raw = os.environ.get('LUNCH_ORDER_CUTOFF', '10:30').strip()
    try:
        return datetime.strptime(raw, '%H:%M').time()
    except ValueError:
        return time(10, 30)


def is_canteen(employee, core):
    if employee is None:
        return False
    job = _norm(employee.job_title)
    return (('технолог' in job and 'столов' in job) or core._is_system_admin(job)
            or _norm(employee.department) == 'столовая'
            or employee.employee_id in _env_ids('CANTEEN_STAFF'))


def register(app, core):
    from models import Employee, MenuDate, MenuItem

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _open_for(day):
        """Можно ли ещё заказать или поправить заказ на этот день."""
        now = core._plant_now()
        if day < now.date() or day > now.date() + timedelta(days=_MAX_DAYS_AHEAD):
            return False
        return day > now.date() or now.time() < _cutoff()

    def _day():
        raw = request.args.get('date', '')
        if not raw:
            return core._plant_today()
        try:
            return date.fromisoformat(raw)
        except ValueError:
            return None

    def _money(value):
        return float(value) if value is not None else None

    def _lines(order):
        return (LunchOrderLine.query.filter_by(order_id=order.id)
                .order_by(LunchOrderLine.id).all())

    def _order_json(order, lines, people=None):
        total = sum((float(l.price) * l.quantity) for l in lines
                    if l.price is not None)
        data = {
            'id': order.id,
            'date': order.day.isoformat(),
            'note': order.note or '',
            'served': order.served_at is not None,
            'served_at': _utc(order.served_at),
            'lines': [{'category': l.category, 'name': l.name,
                       'price': _money(l.price), 'quantity': l.quantity}
                      for l in lines],
            'total': round(total, 2),
            'updated_at': _utc(order.updated_at),
        }
        if people is not None:
            emp = people.get(order.employee_id)
            data['employee'] = {'id': order.employee_id,
                                'name': emp.full_name if emp else order.employee_id,
                                'department': (emp.department or '') if emp else ''}
        return data

    def _menu(day):
        menu = MenuDate.query.filter_by(date=day).first()
        if menu is None:
            return []
        return MenuItem.query.filter_by(menu_date_id=menu.id) \
            .order_by(MenuItem.id).all()

    @app.route('/api/lunch-orders', methods=['GET'])
    @core.require_auth
    def lunch_order_get():
        """Мой заказ на день (`?date=`), меню этого дня и мои заказы вперёд."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        day = _day()
        if day is None:
            return _fail('bad_date', 400)
        order = LunchOrder.query.filter_by(employee_id=viewer.employee_id,
                                           day=day).first()
        today = core._plant_today()
        upcoming = (LunchOrder.query.filter_by(employee_id=viewer.employee_id)
                    .filter(LunchOrder.day >= today)
                    .order_by(LunchOrder.day).limit(_MAX_DAYS_AHEAD + 1).all())
        return jsonify({
            'message': 'Success',
            'date': day.isoformat(),
            'open': _open_for(day),
            'cutoff': _cutoff().strftime('%H:%M'),
            'canteen': is_canteen(viewer, core),
            'menu': [{'id': i.id, 'category': i.category, 'name': i.name,
                      'price': _money(i.price), 'portion': i.portion}
                     for i in _menu(day)],
            'order': _order_json(order, _lines(order)) if order else None,
            'upcoming': [{'date': o.day.isoformat(), 'id': o.id} for o in upcoming],
        })

    @app.route('/api/lunch-orders', methods=['PUT'])
    @core.require_auth
    def lunch_order_put():
        """`{"date", "items": [{"menu_item_id", "quantity"}], "note"}` —
        заказ на день целиком, заменяет прежний."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        data = core._json_body()
        try:
            day = date.fromisoformat(core._text(data, 'date'))
        except ValueError:
            return _fail('bad_date', 400)
        if not _open_for(day):
            return _fail('closed', 409)
        menu = {i.id: i for i in _menu(day)}
        if not menu:
            return _fail('no_menu', 409)
        raw = data.get('items')
        if not isinstance(raw, list) or not raw:
            return _fail('empty', 400)
        wanted = {}
        for entry in raw[:_MAX_LINES]:
            if not isinstance(entry, dict):
                return _fail('bad_items', 400)
            item = menu.get(entry.get('menu_item_id'))
            quantity = entry.get('quantity', 1)
            if item is None or isinstance(quantity, bool) \
                    or not isinstance(quantity, int) \
                    or not 1 <= quantity <= _MAX_QUANTITY:
                return _fail('bad_items', 400)
            wanted[item.id] = min(_MAX_QUANTITY, wanted.get(item.id, 0) + quantity)
        now = datetime.utcnow()
        order = LunchOrder.query.filter_by(employee_id=viewer.employee_id,
                                           day=day).first()
        created = order is None
        if created:
            order = LunchOrder(employee_id=viewer.employee_id, day=day, created_at=now)
            db.session.add(order)
            db.session.flush()
        else:
            if order.served_at is not None:
                return _fail('served', 409)
            LunchOrderLine.query.filter_by(order_id=order.id).delete()
        for item_id, quantity in wanted.items():
            item = menu[item_id]
            db.session.add(LunchOrderLine(order_id=order.id, category=item.category,
                                          name=item.name, price=item.price,
                                          quantity=quantity))
        order.note = core._text(data, 'note')[:_MAX_NOTE] or None
        order.updated_at = now
        db.session.commit()
        logging.info('Заказ обеда на %s: %s (%d блюд)', day, viewer.employee_id,
                     len(wanted))
        return jsonify({'message': 'Success',
                        'order': _order_json(order, _lines(order))}), \
            201 if created else 200

    @app.route('/api/lunch-orders', methods=['DELETE'])
    @core.require_auth
    def lunch_order_delete():
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        day = _day()
        if day is None:
            return _fail('bad_date', 400)
        order = LunchOrder.query.filter_by(employee_id=viewer.employee_id,
                                           day=day).first()
        if order is None:
            return _fail('not_found', 404)
        if not _open_for(day) or order.served_at is not None:
            return _fail('closed', 409)
        db.session.delete(order)
        db.session.commit()
        return jsonify({'message': 'Success'})

    @app.route('/api/lunch-orders/summary', methods=['GET'])
    @core.require_auth
    def lunch_orders_summary():
        """Столовой: сколько чего готовить на день и кому что отдать."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not is_canteen(viewer, core):
            return core._deny()
        day = _day()
        if day is None:
            return _fail('bad_date', 400)
        orders = LunchOrder.query.filter_by(day=day).all()
        ids = [o.id for o in orders]
        lines = (LunchOrderLine.query.filter(LunchOrderLine.order_id.in_(ids or [-1]))
                 .order_by(LunchOrderLine.id).all())
        by_order = {}
        dishes = {}
        for line in lines:
            by_order.setdefault(line.order_id, []).append(line)
            key = (line.category, line.name)
            dishes[key] = dishes.get(key, 0) + line.quantity
        people = {e.employee_id: e for e in Employee.query.filter(
            Employee.employee_id.in_([o.employee_id for o in orders] or ['-']))}
        rows = [_order_json(o, by_order.get(o.id, []), people) for o in orders]
        rows.sort(key=lambda r: (r['served'], r['employee']['name']))
        return jsonify({
            'message': 'Success',
            'date': day.isoformat(),
            'open': _open_for(day),
            'count': len(rows),
            'served': sum(1 for r in rows if r['served']),
            'dishes': [{'category': c, 'name': n, 'quantity': q}
                       for (c, n), q in sorted(dishes.items(),
                                               key=lambda d: (d[0][0], -d[1]))],
            'orders': rows,
        })

    @app.route('/api/lunch-orders/<int:order_id>/served', methods=['POST'])
    @core.require_auth
    def lunch_order_served(order_id):
        """`{"served": true|false}` — выдали заказ (или отметили по ошибке)."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not is_canteen(viewer, core):
            return core._deny()
        order = db.session.get(LunchOrder, order_id)
        if order is None:
            return _fail('not_found', 404)
        served = core._json_body().get('served', True) is not False
        order.served_at = datetime.utcnow() if served else None
        db.session.commit()
        people = {order.employee_id: db.session.get(Employee, order.employee_id)}
        return jsonify({'message': 'Success',
                        'order': _order_json(order, _lines(order), people)})
