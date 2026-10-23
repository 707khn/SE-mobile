"""Командировка и авансовый отчёт: заявка — согласование руководителем —
аванс в бухгалтерии — отчёт о расходах — проверка.

Сейчас заявку на командировку пишут на бумаге и носят на подпись, аванс
выдают по звонку, а авансовый отчёт сдают через месяц, вспоминая, сколько
стоила гостиница. Здесь заявка согласуется с телефона, расходы вносятся по
ходу поездки, а остаток — «вернуть в кассу» или «к выплате» — считается сам.

Согласует руководитель отдела командируемого (руководитель, начальник,
заместитель, заведующий того же подразделения — кроме главных менеджеров),
руководство предприятия или TRAVEL_APPROVERS. Руководителю отдела — его
руководство. Аванс и отчёт ведёт бухгалтерия (подразделение бухгалтерского
учёта или TRAVEL_ACCOUNTANTS).

Чеки и билеты приложение не хранит: оригиналы сдаются в бухгалтерию, а в
строке отчёта — номер документа. Суммы видят командируемый, согласующие и
бухгалтерия; в тексте оповещений сумм нет.

TRAVEL_DAILY_ALLOWANCE — суточные в тенге за день: если задано, отчёт
подсказывает строку суточных по числу дней.
"""

import logging
import os
from datetime import date, datetime, timedelta

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db

TRANSPORTS = ('train', 'plane', 'bus', 'company_car', 'own_car', 'other')
CATEGORIES = ('travel', 'lodging', 'per_diem', 'other')
OPEN = ('pending', 'approved', 'advanced', 'reported')

_MAX_TEXT = 1000
_MAX_PLACE = 200
_MAX_AMOUNT = 10_000_000
_MAX_LINES = 50
_MAX_SPAN = 60
_BACKDATE = 30
_SHOW_CLOSED_FOR = timedelta(days=60)

_HEAD_TITLES = ('руководител', 'начальник', 'заместитель', 'заведующ', 'директор')


class BusinessTrip(db.Model):
    __tablename__ = 'business_trips'
    __table_args__ = (db.Index('ix_business_trips_status', 'status', 'date_from'),)
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    destination = db.Column(db.String(_MAX_PLACE), nullable=False)
    organization = db.Column(db.String(_MAX_PLACE))
    purpose = db.Column(db.Text, nullable=False)
    date_from = db.Column(db.Date, nullable=False)
    date_to = db.Column(db.Date, nullable=False)
    transport = db.Column(db.String(12), nullable=False, default='other')
    advance_requested = db.Column(db.Integer, nullable=False, default=0)
    advance_issued = db.Column(db.Integer)
    # pending → approved → advanced → reported → closed; rejected, cancelled.
    status = db.Column(db.String(10), nullable=False, default='pending')
    approver_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    accountant_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    note = db.Column(db.Text)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    reported_at = db.Column(db.DateTime)
    closed_at = db.Column(db.DateTime)


class TripExpense(db.Model):
    __tablename__ = 'trip_expenses'
    id = db.Column(db.Integer, primary_key=True)
    trip_id = db.Column(db.Integer,
                        db.ForeignKey('business_trips.id', ondelete='CASCADE'),
                        nullable=False, index=True)
    category = db.Column(db.String(10), nullable=False)
    amount = db.Column(db.Integer, nullable=False)
    # Номер билета, счёта гостиницы — оригинал у бухгалтерии.
    document = db.Column(db.String(_MAX_PLACE))


class BusinessTripEvent(db.Model):
    __tablename__ = 'business_trip_events'
    id = db.Column(db.Integer, primary_key=True)
    trip_id = db.Column(db.Integer,
                        db.ForeignKey('business_trips.id', ondelete='CASCADE'),
                        nullable=False, index=True)
    actor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # created, approve, reject, advance, report, accept, send_back, cancel, comment
    action = db.Column(db.String(10), nullable=False)
    comment = db.Column(db.Text)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_head(employee):
    title = _norm(employee.job_title)
    return title.startswith(_HEAD_TITLES) and not title.startswith('главный менеджер')


def is_top(employee):
    return _norm(employee.department) == 'руководство'


def is_accountant(employee):
    return employee is not None and (
        'бухгалтерск' in _norm(employee.department)
        or employee.employee_id in _env_ids('TRAVEL_ACCOUNTANTS'))


def may_approve(approver, traveller):
    if approver is None or approver.employee_id == traveller.employee_id:
        return False
    if is_top(approver) or approver.employee_id in _env_ids('TRAVEL_APPROVERS'):
        return True
    # Руководителю отдела командировку согласует руководство, а не зам.
    return (not is_head(traveller) and is_head(approver)
            and bool(traveller.department)
            and approver.department == traveller.department)


def _daily_allowance():
    try:
        return max(0, int(os.environ.get('TRAVEL_DAILY_ALLOWANCE', '0')))
    except ValueError:
        return 0


def _amount(raw, low=0):
    if raw is None or raw == '' or isinstance(raw, bool):
        return None
    try:
        value = int(round(float(str(raw).replace(' ', '').replace(',', '.'))))
    except (TypeError, ValueError):
        return None
    return value if low <= value <= _MAX_AMOUNT else None


def register(app, core):
    from models import Employee

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
                'department': (emp.department or '') if emp else '',
                'job_title': (emp.job_title or '') if emp else ''}

    def _lines(item):
        return (TripExpense.query.filter_by(trip_id=item.id)
                .order_by(TripExpense.id).all())

    def _json(item, people, viewer, lines=None, events=None):
        traveller = people.get(item.employee_id)
        mine = viewer.employee_id == item.employee_id
        # Свою командировку бухгалтер не ведёт: аванс себе и приём своего же
        # отчёта — то же, что согласовать себе поездку, а это запрещено
        # (may_approve). Её ведёт другой бухгалтер.
        accountant = is_accountant(viewer) and not mine
        approver = traveller is not None and may_approve(viewer, traveller)
        data = {
            'id': item.id,
            'destination': item.destination,
            'organization': item.organization or '',
            'purpose': item.purpose,
            'date_from': item.date_from.isoformat(),
            'date_to': item.date_to.isoformat(),
            'days': (item.date_to - item.date_from).days + 1,
            'transport': item.transport,
            'advance_requested': item.advance_requested,
            'advance_issued': item.advance_issued,
            'status': item.status,
            'note': item.note or '',
            'employee': _person(traveller, item.employee_id),
            'approver': _person(people.get(item.approver_id), item.approver_id),
            'accountant': _person(people.get(item.accountant_id), item.accountant_id),
            'created_at': _utc(item.created_at),
            'is_mine': mine,
            'can_approve': approver and item.status == 'pending',
            'can_advance': accountant and item.status == 'approved',
            'can_edit_report': mine and item.status in ('approved', 'advanced'),
            'can_check': accountant and item.status == 'reported',
            'can_cancel': mine and item.status in ('pending', 'approved'),
        }
        if lines is not None:
            spent = sum(line.amount for line in lines)
            data['expenses'] = [{'id': line.id, 'category': line.category,
                                 'amount': line.amount,
                                 'document': line.document or ''}
                                for line in lines]
            data['spent'] = spent
            # Плюс — вернуть в кассу, минус — доплатить командируемому.
            data['balance'] = (item.advance_issued or 0) - spent
        if events is not None:
            data['events'] = [{
                'action': e.action,
                'comment': e.comment or '',
                'at': _utc(e.at),
                'actor': _person(people.get(e.actor_id), e.actor_id),
            } for e in events]
        return data

    def _detail(item, viewer):
        events = (BusinessTripEvent.query.filter_by(trip_id=item.id)
                  .order_by(BusinessTripEvent.at, BusinessTripEvent.id).all())
        people = _names([item.employee_id, item.approver_id, item.accountant_id]
                        + [e.actor_id for e in events])
        return _json(item, people, viewer, _lines(item), events)

    def _list_json(items, viewer):
        people = _names([i.employee_id for i in items]
                        + [i.approver_id for i in items]
                        + [i.accountant_id for i in items])
        return [_json(i, people, viewer) for i in items]

    def _may_see(viewer, item, traveller):
        return (viewer.employee_id == item.employee_id or is_accountant(viewer)
                or may_approve(viewer, traveller)
                or core._is_system_admin(viewer.job_title))

    def _approvers(traveller):
        """Кому о заявке: руководитель отдела; руководителю — руководство,
        и ему же, если в отделе некому согласовать."""
        people = [e for e in Employee.query.all() if may_approve(e, traveller)]
        heads = [e.employee_id for e in people
                 if not is_head(traveller) and is_head(e)
                 and e.department == traveller.department]
        extra = [e.employee_id for e in people
                 if e.employee_id in _env_ids('TRAVEL_APPROVERS')]
        return heads + extra if heads else [e.employee_id for e in people
                                            if is_top(e)] + extra

    def _accountants():
        return [e.employee_id for e in Employee.query.all() if is_accountant(e)]

    def _notify(ids, title, body, ref, actor_id=None):
        ids = sorted({i for i in ids if i and i != actor_id})
        if ids:
            core._record_notice('trip', title[:200], body[:500],
                                employee_ids=ids, ref=ref, repeat=True)

    @app.route('/api/trips', methods=['GET'])
    @core.require_auth
    def trips_list():
        """Мои; `?scope=approve` — на согласование; `?scope=accounting` —
        бухгалтерии: выдать аванс и проверить отчёты."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        scope = request.args.get('scope')
        if scope == 'approve':
            pending = BusinessTrip.query.filter_by(status='pending') \
                .order_by(BusinessTrip.date_from).all()
            people = _names([i.employee_id for i in pending])
            items = [i for i in pending
                     if people.get(i.employee_id) is not None
                     and may_approve(viewer, people[i.employee_id])]
        elif scope == 'accounting':
            if not is_accountant(viewer):
                return core._deny()
            items = (BusinessTrip.query
                     .filter(BusinessTrip.status.in_(('approved', 'reported')))
                     .order_by(BusinessTrip.date_from).limit(300).all())
            items.sort(key=lambda i: i.status != 'reported')
        else:
            since = datetime.utcnow() - _SHOW_CLOSED_FOR
            items = (BusinessTrip.query.filter_by(employee_id=viewer.employee_id)
                     .filter(db.or_(BusinessTrip.status.in_(OPEN),
                                    BusinessTrip.updated_at >= since))
                     .order_by(BusinessTrip.date_from.desc()).limit(100).all())
        body = {'message': 'Success',
                'approver': is_head(viewer) or is_top(viewer)
                or viewer.employee_id in _env_ids('TRAVEL_APPROVERS'),
                'accountant': is_accountant(viewer),
                'daily_allowance': _daily_allowance(),
                'items': _list_json(items, viewer)}
        return jsonify(body)

    @app.route('/api/trips', methods=['POST'])
    @core.require_auth
    def trips_create():
        """`{"destination", "organization", "purpose", "date_from", "date_to",
        "transport", "advance"}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        data = core._json_body()
        destination = ' '.join(core._text(data, 'destination').split())[:_MAX_PLACE]
        if not destination:
            return _fail('destination_required', 400)
        purpose = core._text(data, 'purpose')[:_MAX_TEXT]
        if not purpose:
            return _fail('purpose_required', 400)
        try:
            start = date.fromisoformat(core._text(data, 'date_from'))
            end = date.fromisoformat(core._text(data, 'date_to'))
        except ValueError:
            return _fail('bad_dates', 400)
        today = core._plant_today()
        if end < start or (end - start).days >= _MAX_SPAN:
            return _fail('bad_dates', 400)
        if start < today - timedelta(days=_BACKDATE):
            return _fail('too_old', 400)
        transport = core._text(data, 'transport') or 'other'
        if transport not in TRANSPORTS:
            return _fail('bad_transport', 400)
        advance = _amount(data.get('advance') or 0)
        if advance is None:
            return _fail('bad_amount', 400)
        now = datetime.utcnow()
        item = BusinessTrip(employee_id=viewer.employee_id, destination=destination,
                            organization=core._text(data, 'organization')[:_MAX_PLACE]
                            or None,
                            purpose=purpose, date_from=start, date_to=end,
                            transport=transport, advance_requested=advance,
                            status='pending', created_at=now, updated_at=now)
        db.session.add(item)
        db.session.flush()
        db.session.add(BusinessTripEvent(trip_id=item.id, actor_id=viewer.employee_id,
                                         action='created', at=now))
        db.session.commit()
        logging.info('Командировка №%s: %s в %s', item.id, viewer.employee_id,
                     destination)
        _notify(_approvers(viewer), f'Командировка на согласование: {destination}',
                f'{viewer.full_name}, {start:%d.%m}–{end:%d.%m}', item.id,
                viewer.employee_id)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer)}), 201

    def _load(item_id, viewer):
        item = db.session.get(BusinessTrip, item_id)
        if item is None:
            return None, None
        traveller = db.session.get(Employee, item.employee_id)
        if traveller is None or not _may_see(viewer, item, traveller):
            return None, None
        return item, traveller

    @app.route('/api/trips/<int:item_id>', methods=['GET'])
    @core.require_auth
    def trip_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item, _ = _load(item_id, viewer)
        if item is None:
            return _fail('not_found', 404)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer)})

    @app.route('/api/trips/<int:item_id>', methods=['POST'])
    @core.require_auth
    def trip_action(item_id):
        """Согласующий: approve, reject. Бухгалтерия: advance (сумма), accept,
        send_back. Командируемый: expense_add, expense_remove, report, cancel.
        Всем, кто видит: comment."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item, traveller = _load(item_id, viewer)
        if item is None:
            return _fail('not_found', 404)
        data = core._json_body()
        action = core._text(data, 'action')
        text = core._text(data, 'text')[:_MAX_TEXT]
        state = _json(item, {item.employee_id: traveller}, viewer)
        need = {'approve': 'can_approve', 'reject': 'can_approve',
                'advance': 'can_advance', 'accept': 'can_check',
                'send_back': 'can_check', 'expense_add': 'can_edit_report',
                'expense_remove': 'can_edit_report', 'report': 'can_edit_report',
                'cancel': 'can_cancel'}
        if action != 'comment' and action not in need:
            return _fail('bad_action', 400)
        if action in need and not state[need[action]]:
            return _fail('bad_state', 409) if item.status not in OPEN \
                or _may_act(viewer, traveller, action) else core._deny()
        if action in ('reject', 'send_back', 'comment') and not text:
            return _fail('text_required', 400)
        if action == 'comment' and item.status not in OPEN:
            return _fail('closed', 409)

        now = datetime.utcnow()
        label = f'Командировка №{item.id} ({item.destination})'
        notify = None
        if action == 'approve':
            item.status = 'approved'
            item.approver_id = viewer.employee_id
            notify = ([item.employee_id] + (_accountants() if item.advance_requested
                                            else []),
                      f'{label} согласована', viewer.full_name)
        elif action == 'reject':
            item.status = 'rejected'
            item.approver_id = viewer.employee_id
            item.note = text
            item.closed_at = now
            notify = ([item.employee_id], f'{label} не согласована', text)
        elif action == 'advance':
            amount = _amount(data.get('amount'))
            if amount is None:
                return _fail('bad_amount', 400)
            item.advance_issued = amount
            item.status = 'advanced'
            item.accountant_id = viewer.employee_id
            notify = ([item.employee_id], f'{label}: аванс выдан',
                      'Сумма — в карточке командировки')
        elif action == 'expense_add':
            category = core._text(data, 'category')
            if category not in CATEGORIES:
                return _fail('bad_category', 400)
            amount = _amount(data.get('amount'), low=1)
            if amount is None:
                return _fail('bad_amount', 400)
            if TripExpense.query.filter_by(trip_id=item.id).count() >= _MAX_LINES:
                return _fail('too_many_lines', 400)
            db.session.add(TripExpense(
                trip_id=item.id, category=category, amount=amount,
                document=core._text(data, 'document')[:_MAX_PLACE] or None))
        elif action == 'expense_remove':
            line_id = _amount(data.get('expense_id'), low=1)
            line = db.session.get(TripExpense, line_id) if line_id else None
            if line is None or line.trip_id != item.id:
                return _fail('not_found', 404)
            db.session.delete(line)
        elif action == 'report':
            if core._plant_today() < item.date_from:
                return _fail('not_started', 409)
            if not TripExpense.query.filter_by(trip_id=item.id).count():
                return _fail('no_expenses', 400)
            item.status = 'reported'
            item.reported_at = now
            item.note = None
            notify = (_accountants(), f'Авансовый отчёт: {label}', viewer.full_name)
        elif action == 'accept':
            item.status = 'closed'
            item.accountant_id = viewer.employee_id
            item.closed_at = now
            notify = ([item.employee_id], f'{label}: отчёт принят', viewer.full_name)
        elif action == 'send_back':
            item.status = 'advanced' if item.advance_issued is not None else 'approved'
            item.accountant_id = viewer.employee_id
            item.note = text
            notify = ([item.employee_id], f'{label}: исправьте отчёт', text)
        elif action == 'cancel':
            item.status = 'cancelled'
            item.closed_at = now
            notify = ([item.approver_id] if item.approver_id else [],
                      f'{label} отменена', viewer.full_name)
        elif action == 'comment':
            others = {item.employee_id, item.approver_id, item.accountant_id}
            if viewer.employee_id == item.employee_id and not item.approver_id:
                others |= set(_approvers(traveller))
            notify = (others, f'Комментарий: {label}', f'{viewer.full_name}: {text}')

        item.updated_at = now
        if action not in ('expense_add', 'expense_remove'):
            db.session.add(BusinessTripEvent(trip_id=item.id,
                                             actor_id=viewer.employee_id,
                                             action=action, comment=text or None,
                                             at=now))
        db.session.commit()
        logging.info('Командировка №%s: %s (%s)', item.id, action, viewer.employee_id)
        if notify:
            _notify(notify[0], notify[1], notify[2], item.id, viewer.employee_id)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer)})

    def _may_act(viewer, traveller, action):
        """Есть ли у смотрящего вообще такая роль — тогда отказ из-за этапа."""
        if action in ('approve', 'reject'):
            return may_approve(viewer, traveller)
        if action in ('advance', 'accept', 'send_back'):
            return (is_accountant(viewer)
                    and viewer.employee_id != traveller.employee_id)
        return viewer.employee_id == traveller.employee_id
