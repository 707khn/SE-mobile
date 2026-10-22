"""Предъявление продукции: мастер предъявляет партию ОТК, ОТК принимает или
возвращает на доработку, принятое уходит военному представительству.

Сейчас это идёт ногами и звонками: мастер ищет контрольного мастера,
контрольный мастер — военпреда, и никто не видит, сколько партия уже
ждёт. Здесь у предъявления есть номер, изделие, количество и заказ, а у
каждого на экране — на каком оно шаге и сколько ждёт. Начальник ОП и
начальник ОТК видят всю очередь и то, что застряло.

Шаги: ждёт ОТК → ОТК проверяет → (если нужна приёмка ВП) ждёт ВП → ВП
проверяет → принято. С любого шага — возврат на доработку с причиной;
после доработки мастер предъявляет снова, и партия опять идёт в ОТК.

Военпреды — не штат предприятия. Учётные записи им заводятся отдельно, а
кто из заведённых военпред, говорит подразделение («Военное
представительство») или VP_STAFF.

Что именно хранить об изделиях, решает режим (ЗГС): здесь только то, что
мастер сам напишет, — наименование, количество, заказ.
"""

import logging
import os
from datetime import datetime, timedelta

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db


STATUSES = ('waiting_otk', 'checking_otk', 'waiting_vp', 'checking_vp',
            'accepted', 'returned', 'cancelled')
# Партия «в работе» у кого-то из проверяющих.
IN_FLIGHT = ('waiting_otk', 'checking_otk', 'waiting_vp', 'checking_vp')
# Автору ещё есть что делать: возвращённую доработать и предъявить снова.
OPEN_STATUSES = IN_FLIGHT + ('returned',)

OTK, VP = 'otk', 'vp'
_STAGE_OF = {'waiting_otk': OTK, 'checking_otk': OTK,
             'waiting_vp': VP, 'checking_vp': VP}

_MAX_TEXT = 200
_MAX_NOTE = 1000
_MAX_COMMENT = 1000
_MAX_OPEN_PER_AUTHOR = 40
_QUEUE_CLOSED_FOR = timedelta(days=14)


class Inspection(db.Model):
    __tablename__ = 'inspections'
    __table_args__ = (
        db.Index('ix_inspections_author', 'employee_id', 'created_at'),
        db.Index('ix_inspections_status', 'status', 'updated_at'),
    )
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False)
    product = db.Column(db.String(_MAX_TEXT), nullable=False)
    quantity = db.Column(db.Integer, nullable=False)
    # Заказ или партия — по нему ищут, когда спрашивают «где мой заказ».
    order_no = db.Column(db.String(100))
    place = db.Column(db.String(100), nullable=False)
    note = db.Column(db.Text)
    needs_vp = db.Column(db.Boolean, nullable=False, default=False)
    status = db.Column(db.String(20), nullable=False, default='waiting_otk')
    otk_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    vp_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # Причина последнего возврата — чтобы мастер видел её, не листая историю.
    return_reason = db.Column(db.Text)
    returns = db.Column(db.Integer, nullable=False, default=0)
    # С какого момента партия ждёт на текущем шаге: отсюда «ждёт 3 ч».
    stage_since = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    closed_at = db.Column(db.DateTime)


class InspectionEvent(db.Model):
    __tablename__ = 'inspection_events'
    id = db.Column(db.Integer, primary_key=True)
    inspection_id = db.Column(db.Integer,
                              db.ForeignKey('inspections.id', ondelete='CASCADE'),
                              nullable=False, index=True)
    actor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # created, take, accept, return, resubmit, cancel, comment
    action = db.Column(db.String(20), nullable=False)
    # На каком шаге: otk или vp — «принято ОТК» и «принято ВП» различаются.
    stage = db.Column(db.String(5))
    comment = db.Column(db.Text)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_otk(employee):
    if employee is None:
        return False
    return ('технического контроля' in _norm(employee.department)
            or employee.employee_id in _env_ids('OTK_STAFF'))


def is_vp(employee):
    if employee is None:
        return False
    return ('военное представительство' in _norm(employee.department)
            or employee.employee_id in _env_ids('VP_STAFF'))


def is_production_head(employee):
    """Начальник ОП и заместитель: видят всю очередь, ничего в ней не делают."""
    if employee is None:
        return False
    title = _norm(employee.job_title)
    return ('основное производство' in _norm(employee.department)
            and ('начальник' in title))


def register(app, core):
    from models import Employee

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _roles(viewer):
        admin = core._is_system_admin(viewer.job_title)
        return {
            OTK: admin or is_otk(viewer),
            VP: admin or is_vp(viewer),
            'watch': admin or is_production_head(viewer) or is_otk(viewer),
        }

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
        if viewer.employee_id == item.employee_id or roles['watch'] or roles[OTK]:
            return True
        # Военпреду — только то, что дошло до него.
        return roles[VP] and item.needs_vp and (
            item.status in ('waiting_vp', 'checking_vp')
            or item.vp_id is not None)

    def _json(item, people, events=None, roles=None):
        stage = _STAGE_OF.get(item.status)
        data = {
            'id': item.id,
            'product': item.product,
            'quantity': item.quantity,
            'order_no': item.order_no or '',
            'place': item.place,
            'note': item.note or '',
            'needs_vp': bool(item.needs_vp),
            'status': item.status,
            'stage': stage,
            'author': _person(people.get(item.employee_id), item.employee_id),
            'otk': _person(people.get(item.otk_id), item.otk_id),
            'vp': _person(people.get(item.vp_id), item.vp_id),
            'return_reason': item.return_reason or '',
            'returns': item.returns,
            'stage_since': _utc(item.stage_since),
            'created_at': _utc(item.created_at),
            'closed_at': _utc(item.closed_at),
        }
        if roles is not None:
            data['can_act'] = bool(stage and roles.get(stage))
        if events is not None:
            data['events'] = [{
                'action': e.action,
                'stage': e.stage or '',
                'comment': e.comment or '',
                'at': _utc(e.at),
                'actor': _person(people.get(e.actor_id), e.actor_id),
            } for e in events]
        return data

    def _list_json(items):
        people = _names([i.employee_id for i in items] + [i.otk_id for i in items]
                        + [i.vp_id for i in items])
        return [_json(i, people) for i in items]

    def _detail(item, roles):
        events = (InspectionEvent.query.filter_by(inspection_id=item.id)
                  .order_by(InspectionEvent.at, InspectionEvent.id).all())
        people = _names([item.employee_id, item.otk_id, item.vp_id]
                        + [e.actor_id for e in events])
        return _json(item, people, events, roles)

    def _notify(employee_ids, title, body, item_id, actor_id=None):
        ids = sorted({e for e in employee_ids if e and e != actor_id})
        if ids:
            core._record_notice('inspection', title, body, employee_ids=ids,
                                ref=item_id)

    def _what(item):
        order = f', заказ {item.order_no}' if item.order_no else ''
        return f'{item.product}, {item.quantity} шт{order}'

    @app.route('/api/inspections', methods=['GET'])
    @core.require_auth
    def inspections_list():
        """Мои предъявления или очередь: `?scope=queue`.

        ОТК — всё, что ждёт ОТК или у него на проверке; ВП — что дошло до
        ВП; начальник ОП — всё, что в пути.
        """
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        roles = _roles(viewer)
        staff = roles[OTK] or roles[VP] or roles['watch']
        if request.args.get('scope') == 'queue':
            if not staff:
                return core._deny()
            since = datetime.utcnow() - _QUEUE_CLOSED_FOR
            query = Inspection.query
            if not (roles[OTK] or roles['watch']):
                query = query.filter(Inspection.needs_vp.is_(True),
                                     db.or_(Inspection.status.in_(('waiting_vp', 'checking_vp')),
                                            Inspection.vp_id.isnot(None)))
            items = (query.filter(db.or_(Inspection.status.in_(OPEN_STATUSES),
                                         Inspection.updated_at >= since))
                     .order_by(Inspection.stage_since).limit(300).all())
            # Дольше всех ждущее — первым; закрытое — вниз.
            items.sort(key=lambda i: i.status not in IN_FLIGHT)
        else:
            items = (Inspection.query.filter_by(employee_id=viewer.employee_id)
                     .order_by(Inspection.created_at.desc()).limit(100).all())
        body = {'message': 'Success', 'staff': staff,
                'roles': {k: v for k, v in roles.items()},
                'items': _list_json(items)}
        if staff:
            counts = dict(db.session.query(Inspection.status,
                                           db.func.count(Inspection.id))
                          .filter(Inspection.status.in_(IN_FLIGHT))
                          .group_by(Inspection.status))
            body['open'] = {s: counts.get(s, 0) for s in IN_FLIGHT}
        return jsonify(body)

    @app.route('/api/inspections', methods=['POST'])
    @core.require_auth
    def inspections_create():
        """`{"product", "quantity", "order_no", "place", "note", "needs_vp"}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        data = core._json_body()
        product = ' '.join(core._text(data, 'product').split())[:_MAX_TEXT]
        if not product:
            return _fail('product_required', 400)
        raw_qty = data.get('quantity')
        try:
            quantity = int(str(raw_qty).strip())
        except (TypeError, ValueError):
            return _fail('bad_quantity', 400)
        if not 0 < quantity < 1_000_000:
            return _fail('bad_quantity', 400)
        place = core._text(data, 'place')[:100]
        if not place:
            return _fail('place_required', 400)
        needs_vp = data.get('needs_vp') in (True, 1, '1', 'true')

        if Inspection.query.filter(Inspection.employee_id == viewer.employee_id,
                                   Inspection.status.in_(OPEN_STATUSES)).count() \
                >= _MAX_OPEN_PER_AUTHOR:
            return _fail('too_many_open', 429)

        now = datetime.utcnow()
        item = Inspection(employee_id=viewer.employee_id, product=product,
                          quantity=quantity,
                          order_no=core._text(data, 'order_no')[:100] or None,
                          place=place,
                          note=core._text(data, 'note')[:_MAX_NOTE] or None,
                          needs_vp=needs_vp, status='waiting_otk',
                          stage_since=now, created_at=now, updated_at=now)
        db.session.add(item)
        db.session.flush()
        db.session.add(InspectionEvent(inspection_id=item.id,
                                       actor_id=viewer.employee_id,
                                       action='created', stage=OTK, at=now))
        db.session.commit()
        logging.info('Предъявление №%s от %s: %s', item.id, viewer.employee_id,
                     _what(item))
        _notify(_ids(is_otk), f'Предъявление №{item.id}: {_what(item)}',
                f'{viewer.full_name}, {item.place}', item.id, viewer.employee_id)
        return jsonify({'message': 'Success',
                        'item': _detail(item, _roles(viewer))}), 201

    @app.route('/api/inspections/<int:item_id>', methods=['GET'])
    @core.require_auth
    def inspection_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(Inspection, item_id)
        roles = _roles(viewer)
        if item is None or not _may_see(viewer, item, roles):
            return _fail('not_found', 404)
        return jsonify({'message': 'Success', 'item': _detail(item, roles)})

    @app.route('/api/inspections/<int:item_id>', methods=['POST'])
    @core.require_auth
    def inspection_action(item_id):
        """`{"action", "comment"}`.

        Проверяющий своего шага: take, accept, return (с причиной). Автор:
        resubmit (после возврата), cancel. Всем, кто видит: comment.
        """
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(Inspection, item_id)
        roles = _roles(viewer)
        if item is None or not _may_see(viewer, item, roles):
            return _fail('not_found', 404)
        data = core._json_body()
        action = core._text(data, 'action')
        comment = core._text(data, 'comment')[:_MAX_COMMENT]
        stage = _STAGE_OF.get(item.status)
        mine = bool(stage and roles.get(stage))
        is_author = viewer.employee_id == item.employee_id
        now = datetime.utcnow()
        before = item.status

        def _move(status):
            item.status = status
            item.stage_since = now

        if action == 'take':
            if not mine:
                return core._deny() if stage else _fail('closed', 409)
            if item.status.startswith('checking'):
                return _fail('already_taken', 409)
            item.status = f'checking_{stage}'
            setattr(item, f'{stage}_id', viewer.employee_id)
        elif action == 'accept':
            if not mine:
                return core._deny() if stage else _fail('closed', 409)
            setattr(item, f'{stage}_id', viewer.employee_id)
            if stage == OTK and item.needs_vp:
                _move('waiting_vp')
            else:
                _move('accepted')
                item.closed_at = now
            item.return_reason = None
        elif action == 'return':
            if not mine:
                return core._deny() if stage else _fail('closed', 409)
            if not comment:
                return _fail('comment_required', 400)
            setattr(item, f'{stage}_id', viewer.employee_id)
            _move('returned')
            item.return_reason = comment
            item.returns += 1
        elif action == 'resubmit':
            if not is_author:
                return core._deny()
            if item.status != 'returned':
                return _fail('not_returned', 409)
            # После доработки — снова с ОТК, даже если вернул ВП.
            _move('waiting_otk')
            stage = OTK
        elif action == 'cancel':
            if not is_author:
                return core._deny()
            if item.status not in OPEN_STATUSES:
                return _fail('closed', 409)
            _move('cancelled')
            item.closed_at = now
        elif action == 'comment':
            if not comment:
                return _fail('comment_required', 400)
        else:
            return _fail('bad_action', 400)

        item.updated_at = now
        db.session.add(InspectionEvent(inspection_id=item.id,
                                       actor_id=viewer.employee_id,
                                       action=action, stage=stage,
                                       comment=comment or None, at=now))
        db.session.commit()

        number = f'Предъявление №{item.id}'
        who = viewer.full_name
        if action == 'take':
            _notify([item.employee_id],
                    f'{number}: {"ОТК" if stage == OTK else "ВП"} проверяет',
                    who, item.id, viewer.employee_id)
        elif action == 'accept' and item.status == 'waiting_vp':
            _notify([item.employee_id], f'{number} принято ОТК',
                    'Передано военному представительству', item.id,
                    viewer.employee_id)
            _notify(_ids(is_vp), f'{number}: {_what(item)}',
                    f'Принято ОТК ({who}), {item.place}', item.id,
                    viewer.employee_id)
        elif action == 'accept':
            _notify([item.employee_id], f'{number} принято',
                    f'{"ВП" if stage == VP else "ОТК"}: {who}', item.id,
                    viewer.employee_id)
        elif action == 'return':
            _notify([item.employee_id], f'{number}: возврат на доработку',
                    comment, item.id, viewer.employee_id)
            if stage == VP and item.otk_id:
                _notify([item.otk_id], f'{number}: ВП вернул на доработку',
                        comment, item.id, viewer.employee_id)
        elif action == 'resubmit':
            _notify([item.otk_id] if item.otk_id else _ids(is_otk),
                    f'{number} предъявлено повторно', comment or _what(item),
                    item.id, viewer.employee_id)
        elif action == 'comment':
            targets = {item.employee_id, item.otk_id, item.vp_id} - {None}
            _notify(targets, f'{number}: сообщение', f'{who}: {comment[:200]}',
                    item.id, viewer.employee_id)
        logging.info('Предъявление №%s: %s → %s (%s)', item.id, before,
                     item.status, viewer.employee_id)
        return jsonify({'message': 'Success', 'item': _detail(item, roles)})
