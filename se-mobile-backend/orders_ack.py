"""Ознакомление с приказами под отметку: делопроизводитель рассылает приказ
нужным отделам, сотрудник нажимает «Ознакомлен», АО видит, кто ещё нет.

Сейчас это лист ознакомления на бумаге, который носят по участкам, и к
проверке половины подписей нет. Здесь у приказа есть адресаты (всё
предприятие или выбранные подразделения) и срок, у каждого адресата —
отметка с датой и временем, у издающего — отчёт «кто ещё не ознакомлен»
и кнопка напомнить. Начальник видит то же по своему отделу.

Издают делопроизводитель, кадры, начальник АО (или ORDERS_PUBLISHERS).
Текст приказа — тот, что вставили при рассылке; файл не хранится, но
можно дать ссылку на него во внутренней системе.
"""

import json
import logging
import os
from datetime import date, datetime, timedelta

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db

KINDS = ('order', 'policy', 'instruction')

_MAX_TITLE = 300
_MAX_TEXT = 20000
_MAX_DEPARTMENTS = 40
# Напоминать неознакомленным — не чаще раза в сутки.
REMIND_EVERY = timedelta(hours=20)


class OrderDoc(db.Model):
    __tablename__ = 'order_docs'
    id = db.Column(db.Integer, primary_key=True)
    kind = db.Column(db.String(12), nullable=False, default='order')
    # Номер и дата приказа — как в журнале регистрации.
    number = db.Column(db.String(50))
    doc_date = db.Column(db.Date)
    title = db.Column(db.String(_MAX_TITLE), nullable=False)
    text = db.Column(db.Text, nullable=False)
    link = db.Column(db.String(500))
    # JSON-список подразделений; пусто — всё предприятие.
    departments = db.Column(db.Text)
    due_date = db.Column(db.Date)
    published_by = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                             nullable=False)
    published_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    reminded_at = db.Column(db.DateTime)
    withdrawn_at = db.Column(db.DateTime)


class OrderAck(db.Model):
    __tablename__ = 'order_acks'
    __table_args__ = (db.UniqueConstraint('order_id', 'employee_id'),)
    id = db.Column(db.Integer, primary_key=True)
    order_id = db.Column(db.Integer,
                         db.ForeignKey('order_docs.id', ondelete='CASCADE'),
                         nullable=False, index=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_publisher(employee):
    if employee is None:
        return False
    title = _norm(employee.job_title)
    dept = _norm(employee.department)
    return ('делопроизвод' in title or 'кадр' in title
            or ('административн' in dept and title.startswith('начальник'))
            or employee.employee_id in _env_ids('ORDERS_PUBLISHERS'))


def _departments(order):
    try:
        value = json.loads(order.departments) if order.departments else []
    except ValueError:
        value = []
    return [d for d in value if isinstance(d, str)]


def addressed_to(order, employee):
    wanted = _departments(order)
    if not wanted:
        return True
    return (employee.department or '') in wanted


def register(app, core):
    from models import Employee

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _publisher(viewer):
        return core._is_system_admin(viewer.job_title) or is_publisher(viewer)

    def _audience(order):
        return [e for e in Employee.query.order_by(Employee.full_name)
                if e.full_name and addressed_to(order, e)]

    def _acks(order):
        return {a.employee_id: a for a in OrderAck.query.filter_by(order_id=order.id)}

    def _json(order, viewer, ack=None, stats=None):
        data = {
            'id': order.id,
            'kind': order.kind,
            'number': order.number or '',
            'doc_date': order.doc_date.isoformat() if order.doc_date else None,
            'title': order.title,
            'link': order.link or '',
            'departments': _departments(order),
            'due_date': order.due_date.isoformat() if order.due_date else None,
            'published_at': _utc(order.published_at),
            'acked_at': _utc(ack.at) if ack else None,
            'withdrawn': order.withdrawn_at is not None,
        }
        if stats is not None:
            data.update(stats)
        return data

    def _stats(order, acks=None):
        audience = _audience(order)
        acks = _acks(order) if acks is None else acks
        done = sum(1 for e in audience if e.employee_id in acks)
        return {'total': len(audience), 'acked': done}

    def _notify(employee_ids, title, body, order_id, actor_id=None):
        ids = sorted({e for e in employee_ids if e and e != actor_id})
        if ids:
            core._record_notice('order', title, body, employee_ids=ids,
                                ref=order_id)

    def _label(order):
        kind = {'order': 'Приказ', 'policy': 'Положение',
                'instruction': 'Инструкция'}[order.kind]
        number = f' №{order.number}' if order.number else ''
        return f'{kind}{number}: {order.title}'

    @app.route('/api/orders', methods=['GET'])
    @core.require_auth
    def orders_list():
        """Мне к ознакомлению и уже прочитанное; издающему —
        `?scope=published` со счётчиками."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        publisher = _publisher(viewer)
        manager = core._is_manager()
        if request.args.get('scope') == 'published':
            if not publisher:
                return core._deny()
            orders = (OrderDoc.query.order_by(OrderDoc.published_at.desc())
                      .limit(100).all())
            items = [_json(o, viewer, stats=_stats(o)) for o in orders]
            return jsonify({'message': 'Success', 'publisher': True,
                            'manager': manager, 'items': items})
        mine = {a.order_id: a for a in OrderAck.query.filter_by(
            employee_id=viewer.employee_id)}
        orders = (OrderDoc.query.filter(OrderDoc.withdrawn_at.is_(None))
                  .order_by(OrderDoc.published_at.desc()).limit(300).all())
        items = [_json(o, viewer, ack=mine.get(o.id)) for o in orders
                 if addressed_to(o, viewer)]
        return jsonify({'message': 'Success', 'publisher': publisher,
                        'manager': manager, 'items': items,
                        'pending': sum(1 for i in items if not i['acked_at'])})

    @app.route('/api/orders/departments', methods=['GET'])
    @core.require_auth
    def orders_departments():
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not _publisher(viewer):
            return core._deny()
        rows = (db.session.query(Employee.department, db.func.count())
                .filter(Employee.department.isnot(None))
                .group_by(Employee.department).order_by(Employee.department))
        return jsonify({'message': 'Success',
                        'departments': [{'name': d, 'count': n} for d, n in rows if d]})

    @app.route('/api/orders', methods=['POST'])
    @core.require_auth
    def orders_publish():
        """`{"kind", "number", "doc_date", "title", "text", "link",
        "departments": [...], "due_date"}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not _publisher(viewer):
            return core._deny()
        data = core._json_body()
        kind = core._text(data, 'kind') or 'order'
        if kind not in KINDS:
            return _fail('bad_kind', 400)
        title = ' '.join(core._text(data, 'title').split())[:_MAX_TITLE]
        if not title:
            return _fail('title_required', 400)
        text = core._text(data, 'text')[:_MAX_TEXT]
        if not text:
            return _fail('text_required', 400)
        link = core._text(data, 'link')[:500]
        if link and not link.startswith(('https://', 'http://')):
            return _fail('bad_link', 400)
        today = core._plant_today()

        def _date(name, future=False):
            raw = core._text(data, name)
            if not raw:
                return None, None
            try:
                value = date.fromisoformat(raw)
            except ValueError:
                return None, 'bad_date'
            if future and value < today:
                return None, 'bad_date'
            return value, None

        doc_date, error = _date('doc_date')
        if error:
            return _fail(error, 400)
        due_date, error = _date('due_date', future=True)
        if error:
            return _fail(error, 400)

        raw_departments = data.get('departments') or []
        if not isinstance(raw_departments, list) \
                or len(raw_departments) > _MAX_DEPARTMENTS:
            return _fail('bad_departments', 400)
        known = {d for (d,) in db.session.query(Employee.department).distinct() if d}
        departments = sorted({str(d) for d in raw_departments})
        if any(d not in known for d in departments):
            return _fail('bad_departments', 400)

        order = OrderDoc(kind=kind, number=core._text(data, 'number')[:50] or None,
                         doc_date=doc_date, title=title, text=text,
                         link=link or None,
                         departments=json.dumps(departments, ensure_ascii=False)
                         if departments else None,
                         due_date=due_date, published_by=viewer.employee_id,
                         published_at=datetime.utcnow())
        db.session.add(order)
        db.session.commit()
        audience = _audience(order)
        logging.info('Приказ №%s разослан %s адресатам (%s)', order.id,
                     len(audience), viewer.employee_id)
        due = f' до {due_date:%d.%m}' if due_date else ''
        _notify([e.employee_id for e in audience], 'Ознакомьтесь' + due,
                _label(order)[:300], order.id)
        return jsonify({'message': 'Success',
                        'item': _json(order, viewer, stats=_stats(order))}), 201

    @app.route('/api/orders/<int:order_id>', methods=['GET'])
    @core.require_auth
    def order_detail(order_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        order = db.session.get(OrderDoc, order_id)
        publisher = _publisher(viewer)
        if order is None or not (publisher or addressed_to(order, viewer)):
            return _fail('not_found', 404)
        if order.withdrawn_at is not None and not publisher:
            return _fail('not_found', 404)
        ack = OrderAck.query.filter_by(order_id=order.id,
                                       employee_id=viewer.employee_id).first()
        data = _json(order, viewer, ack=ack)
        data['text'] = order.text
        data['addressed'] = addressed_to(order, viewer)
        data['can_report'] = publisher or core._is_manager()
        data['can_withdraw'] = publisher and order.withdrawn_at is None
        if publisher:
            data.update(_stats(order))
        data['can_remind'] = bool(
            publisher and order.withdrawn_at is None
            and (order.reminded_at is None
                 or datetime.utcnow() - order.reminded_at >= REMIND_EVERY))
        return jsonify({'message': 'Success', 'item': data})

    @app.route('/api/orders/<int:order_id>/report', methods=['GET'])
    @core.require_auth
    def order_report(order_id):
        """Кто ознакомлен и кто нет. Издающему — все, начальнику — свои."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        order = db.session.get(OrderDoc, order_id)
        publisher = _publisher(viewer)
        if order is None or not (publisher or core._is_manager()):
            return _fail('not_found', 404)
        audience = _audience(order)
        if not publisher:
            visible = core._visible_employee_ids()
            if visible is not None:
                audience = [e for e in audience if e.employee_id in visible]
        acks = _acks(order)
        people = [{
            'id': e.employee_id,
            'name': e.full_name,
            'department': e.department or '',
            'acked_at': _utc(acks[e.employee_id].at) if e.employee_id in acks else None,
        } for e in audience]
        # Неознакомленные — первыми, по отделам: им и звонить.
        people.sort(key=lambda p: (p['acked_at'] is not None, p['department'],
                                   p['name']))
        return jsonify({'message': 'Success', 'people': people,
                        'total': len(people),
                        'acked': sum(1 for p in people if p['acked_at'])})

    @app.route('/api/orders/<int:order_id>', methods=['POST'])
    @core.require_auth
    def order_action(order_id):
        """`{"action": "ack" | "remind" | "withdraw"}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        order = db.session.get(OrderDoc, order_id)
        publisher = _publisher(viewer)
        if order is None or not (publisher or addressed_to(order, viewer)):
            return _fail('not_found', 404)
        action = core._text(core._json_body(), 'action')
        now = datetime.utcnow()
        if order.withdrawn_at is not None:
            return _fail('withdrawn', 409)

        if action == 'ack':
            if not addressed_to(order, viewer):
                return _fail('not_addressed', 409)
            if OrderAck.query.filter_by(order_id=order.id,
                                        employee_id=viewer.employee_id).first():
                return _fail('already_acked', 409)
            db.session.add(OrderAck(order_id=order.id,
                                    employee_id=viewer.employee_id, at=now))
            db.session.commit()
            logging.info('Приказ №%s: ознакомлен %s', order.id, viewer.employee_id)
        elif action == 'remind':
            if not publisher:
                return core._deny()
            if order.reminded_at and now - order.reminded_at < REMIND_EVERY:
                return _fail('too_soon', 429)
            acks = _acks(order)
            left = [e.employee_id for e in _audience(order)
                    if e.employee_id not in acks]
            order.reminded_at = now
            db.session.commit()
            due = f' до {order.due_date:%d.%m}' if order.due_date else ''
            _notify(left, 'Напоминание: ознакомьтесь' + due,
                    _label(order)[:300], order.id)
            return jsonify({'message': 'Success', 'reminded': len(left)})
        elif action == 'withdraw':
            if not publisher:
                return core._deny()
            order.withdrawn_at = now
            db.session.commit()
        else:
            return _fail('bad_action', 400)
        return order_detail(order_id)
