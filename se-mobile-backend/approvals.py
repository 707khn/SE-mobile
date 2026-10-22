"""Лист согласования: договор или служебная записка идёт по маршруту
согласующих, каждый согласует, согласует с замечаниями или возвращает.

Сейчас лист носят по кабинетам: ДМТО → юрист → ПЭО → бухгалтерия →
заместитель генерального, и никто, кроме носящего, не знает, у кого
документ лежит третий день. Здесь у листа есть номер и маршрут, у
согласующего — список «на подпись», а у автора — кнопка «Напомнить» тому,
у кого документ завис.

Маршрут последовательный. Автор собирает его сам; для договора приложение
предлагает обычный: руководитель ДМТО, начальник юридического отдела,
начальник ПЭО, главный бухгалтер, заместитель генерального по экономике и
финансам. Возврат останавливает маршрут; после доработки документ идёт
дальше с того, кто вернул, — уже согласовавшие второй раз не подписывают.

Сам документ здесь не хранится: только то, что автор напишет в листе, —
название, номер в СЭД или 1С, контрагент, сумма и суть. Файлы договоров —
коммерческая тайна, и где им лежать, решают СБ и юристы, а не телефон.
"""

import logging
from datetime import datetime, timedelta

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db


KINDS = ('contract', 'memo', 'other')
STATUSES = ('on_route', 'approved', 'returned', 'cancelled')
OPEN_STATUSES = ('on_route', 'returned')

_MAX_TITLE = 200
_MAX_SUMMARY = 4000
_MAX_COMMENT = 1000
_MAX_STEPS = 8
_MAX_OPEN_PER_AUTHOR = 50
# Напоминать чаще — уже не напоминание, а спам.
REMIND_EVERY = timedelta(hours=4)


class Approval(db.Model):
    __tablename__ = 'approvals'
    __table_args__ = (
        db.Index('ix_approvals_author', 'employee_id', 'created_at'),
    )
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False)
    kind = db.Column(db.String(10), nullable=False, default='contract')
    title = db.Column(db.String(_MAX_TITLE), nullable=False)
    # Номер в СЭД или 1С — по нему документ находят, а не по названию.
    doc_number = db.Column(db.String(100))
    counterparty = db.Column(db.String(_MAX_TITLE))
    # Строкой: «12 500 000 тг», «$4 300» — считать здесь нечего.
    amount = db.Column(db.String(50))
    summary = db.Column(db.Text, nullable=False)
    status = db.Column(db.String(10), nullable=False, default='on_route')
    # Чей сейчас шаг — позиция в маршруте.
    current_step = db.Column(db.Integer, nullable=False, default=0)
    # С какого момента документ лежит у текущего согласующего.
    step_since = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    reminded_at = db.Column(db.DateTime)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    closed_at = db.Column(db.DateTime)


class ApprovalStep(db.Model):
    __tablename__ = 'approval_steps'
    __table_args__ = (
        db.Index('ix_approval_steps_person', 'employee_id', 'approval_id'),
    )
    id = db.Column(db.Integer, primary_key=True)
    approval_id = db.Column(db.Integer,
                            db.ForeignKey('approvals.id', ondelete='CASCADE'),
                            nullable=False, index=True)
    position = db.Column(db.Integer, nullable=False)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False)
    # pending, approved, returned
    decision = db.Column(db.String(10), nullable=False, default='pending')
    # Замечания при согласовании или причина возврата.
    comment = db.Column(db.Text)
    decided_at = db.Column(db.DateTime)


class ApprovalEvent(db.Model):
    __tablename__ = 'approval_events'
    id = db.Column(db.Integer, primary_key=True)
    approval_id = db.Column(db.Integer,
                            db.ForeignKey('approvals.id', ondelete='CASCADE'),
                            nullable=False, index=True)
    actor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # created, approve, return, resubmit, cancel, comment, remind
    action = db.Column(db.String(10), nullable=False)
    comment = db.Column(db.Text)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


# Обычный маршрут договора: (подразделение содержит, должность начинается с).
_CONTRACT_ROUTE = (
    ('материально-технического', 'руководитель'),
    ('юридический', 'начальник'),
    ('планово-экономический', 'начальник'),
    ('бухгалтерск', 'главный бухгалтер'),
    ('руководство', 'заместитель генерального директора по экономике'),
)


def suggested_route(kind, author, employees):
    """Кого обычно ставят в лист: для договора — пять служб, для записки —
    начальник своего отдела и генеральный директор."""
    def find(dept_part, title_start):
        for e in employees:
            if (dept_part in _norm(e.department)
                    and _norm(e.job_title).startswith(title_start)
                    and e.employee_id != author.employee_id):
                return e
        return None

    if kind == 'contract':
        picked = [find(d, t) for d, t in _CONTRACT_ROUTE]
    elif kind == 'memo':
        own = _norm(author.department)
        head = None
        if own:
            head = next((e for e in employees
                         if _norm(e.department) == own
                         and e.employee_id != author.employee_id
                         and _norm(e.job_title).startswith(('начальник',
                                                            'руководитель'))),
                        None)
        picked = [head, find('руководство', 'генеральный директор')]
    else:
        picked = []
    seen, route = set(), []
    for e in picked:
        if e is not None and e.employee_id not in seen:
            seen.add(e.employee_id)
            route.append(e)
    return route


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
                'title': (emp.job_title or '') if emp else '',
                'department': (emp.department or '') if emp else ''}

    def _steps(item):
        return (ApprovalStep.query.filter_by(approval_id=item.id)
                .order_by(ApprovalStep.position).all())

    def _current(item, steps):
        if item.status not in OPEN_STATUSES:
            return None
        return next((s for s in steps if s.position == item.current_step), None)

    def _may_see(viewer, item, steps):
        return (viewer.employee_id == item.employee_id
                or any(s.employee_id == viewer.employee_id for s in steps)
                or core._is_system_admin(viewer.job_title))

    def _can_remind(item, now):
        return (item.status == 'on_route'
                and (item.reminded_at is None
                     or now - item.reminded_at >= REMIND_EVERY))

    def _json(item, steps, people, viewer, events=None):
        current = _current(item, steps)
        now = datetime.utcnow()
        is_author = viewer.employee_id == item.employee_id
        my_turn = bool(item.status == 'on_route' and current
                       and current.employee_id == viewer.employee_id)
        data = {
            'id': item.id,
            'kind': item.kind,
            'title': item.title,
            'doc_number': item.doc_number or '',
            'counterparty': item.counterparty or '',
            'amount': item.amount or '',
            'summary': item.summary,
            'status': item.status,
            'author': _person(people.get(item.employee_id), item.employee_id),
            'current': _person(people.get(current.employee_id),
                               current.employee_id) if current else None,
            'step': item.current_step,
            'step_since': _utc(item.step_since),
            'created_at': _utc(item.created_at),
            'closed_at': _utc(item.closed_at),
            'steps': [{
                'position': s.position,
                'person': _person(people.get(s.employee_id), s.employee_id),
                'decision': s.decision,
                'comment': s.comment or '',
                'decided_at': _utc(s.decided_at),
            } for s in steps],
            'my_turn': my_turn,
            'is_author': is_author,
            'can_remind': is_author and _can_remind(item, now),
        }
        if events is not None:
            data['events'] = [{
                'action': e.action,
                'comment': e.comment or '',
                'at': _utc(e.at),
                'actor': _person(people.get(e.actor_id), e.actor_id),
            } for e in events]
        return data

    def _detail(item, viewer):
        steps = _steps(item)
        events = (ApprovalEvent.query.filter_by(approval_id=item.id)
                  .order_by(ApprovalEvent.at, ApprovalEvent.id).all())
        people = _names([item.employee_id] + [s.employee_id for s in steps]
                        + [e.actor_id for e in events])
        return _json(item, steps, people, viewer, events)

    def _notify(employee_ids, title, body, item_id, actor_id=None):
        ids = sorted({e for e in employee_ids if e and e != actor_id})
        if ids:
            core._record_notice('approval', title, body, employee_ids=ids,
                                ref=item_id)

    def _what(item):
        number = f' ({item.doc_number})' if item.doc_number else ''
        return f'{item.title}{number}'

    @app.route('/api/approvals', methods=['GET'])
    @core.require_auth
    def approvals_list():
        """Листы, где я автор или согласующий. `todo` — сколько ждут меня."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        mine_ids = {a for (a,) in db.session.query(ApprovalStep.approval_id)
                    .filter(ApprovalStep.employee_id == viewer.employee_id)}
        items = (Approval.query
                 .filter(db.or_(Approval.employee_id == viewer.employee_id,
                                Approval.id.in_(list(mine_ids) or [-1])))
                 .order_by(Approval.updated_at.desc()).limit(200).all())
        steps_of = {}
        for s in (ApprovalStep.query
                  .filter(ApprovalStep.approval_id.in_([i.id for i in items] or [-1]))
                  .order_by(ApprovalStep.position)):
            steps_of.setdefault(s.approval_id, []).append(s)
        people = _names([i.employee_id for i in items]
                        + [s.employee_id for ss in steps_of.values() for s in ss])
        rows = [_json(i, steps_of.get(i.id, []), people, viewer) for i in items]
        return jsonify({'message': 'Success', 'items': rows,
                        'todo': sum(1 for r in rows if r['my_turn'])})

    @app.route('/api/approvals/route', methods=['GET'])
    @core.require_auth
    def approvals_route():
        """Обычный маршрут для вида документа — автор правит его как хочет."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        kind = request.args.get('kind', 'contract')
        if kind not in KINDS:
            return _fail('bad_kind', 400)
        route = suggested_route(kind, viewer, Employee.query.order_by(
            Employee.employee_id).all())
        return jsonify({'message': 'Success',
                        'steps': [_person(e, e.employee_id) for e in route]})

    @app.route('/api/approvals/people', methods=['GET'])
    @core.require_auth
    def approvals_people():
        """Найти согласующего по фамилии, должности или отделу."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        words = _norm(request.args.get('q', '')).split()
        if not words or len(''.join(words)) < 2:
            return jsonify({'message': 'Success', 'people': []})
        found = []
        for e in Employee.query.order_by(Employee.full_name):
            if not e.full_name or e.employee_id == viewer.employee_id:
                continue
            text = _norm(f'{e.full_name} {e.job_title} {e.department}')
            if all(w in text for w in words):
                found.append(_person(e, e.employee_id))
                if len(found) >= 20:
                    break
        return jsonify({'message': 'Success', 'people': found})

    @app.route('/api/approvals', methods=['POST'])
    @core.require_auth
    def approvals_create():
        """`{"kind", "title", "doc_number", "counterparty", "amount",
        "summary", "route": [employee_id, ...]}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        data = core._json_body()
        kind = core._text(data, 'kind') or 'contract'
        if kind not in KINDS:
            return _fail('bad_kind', 400)
        title = ' '.join(core._text(data, 'title').split())[:_MAX_TITLE]
        if not title:
            return _fail('title_required', 400)
        summary = core._text(data, 'summary')[:_MAX_SUMMARY]
        if not summary:
            return _fail('summary_required', 400)
        raw_route = data.get('route')
        if not isinstance(raw_route, list) or not raw_route:
            return _fail('route_required', 400)
        if len(raw_route) > _MAX_STEPS:
            return _fail('route_too_long', 400)
        route = [str(r).strip() for r in raw_route]
        if len(set(route)) != len(route):
            return _fail('route_repeats', 400)
        if viewer.employee_id in route:
            return _fail('route_self', 400)
        people = _names(route)
        if any(r not in people for r in route):
            return _fail('route_unknown', 400)

        if Approval.query.filter(Approval.employee_id == viewer.employee_id,
                                 Approval.status.in_(OPEN_STATUSES)).count() \
                >= _MAX_OPEN_PER_AUTHOR:
            return _fail('too_many_open', 429)

        now = datetime.utcnow()
        item = Approval(employee_id=viewer.employee_id, kind=kind, title=title,
                        doc_number=core._text(data, 'doc_number')[:100] or None,
                        counterparty=core._text(data, 'counterparty')[:_MAX_TITLE] or None,
                        amount=core._text(data, 'amount')[:50] or None,
                        summary=summary, status='on_route', current_step=0,
                        step_since=now, created_at=now, updated_at=now)
        db.session.add(item)
        db.session.flush()
        for position, employee_id in enumerate(route):
            db.session.add(ApprovalStep(approval_id=item.id, position=position,
                                        employee_id=employee_id))
        db.session.add(ApprovalEvent(approval_id=item.id,
                                     actor_id=viewer.employee_id,
                                     action='created', at=now))
        db.session.commit()
        logging.info('Лист согласования №%s от %s, шагов %s', item.id,
                     viewer.employee_id, len(route))
        _notify([route[0]], f'На согласование: {_what(item)}',
                f'{viewer.full_name}, лист №{item.id}', item.id)
        return jsonify({'message': 'Success',
                        'item': _detail(item, viewer)}), 201

    @app.route('/api/approvals/<int:item_id>', methods=['GET'])
    @core.require_auth
    def approval_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(Approval, item_id)
        if item is None or not _may_see(viewer, item, _steps(item)):
            return _fail('not_found', 404)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer)})

    @app.route('/api/approvals/<int:item_id>', methods=['POST'])
    @core.require_auth
    def approval_action(item_id):
        """`{"action", "comment"}`.

        Согласующий своего шага: approve (замечания — в comment), return
        (с причиной). Автор: resubmit, cancel, remind. Всем в листе: comment.
        """
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(Approval, item_id)
        steps = _steps(item) if item else []
        if item is None or not _may_see(viewer, item, steps):
            return _fail('not_found', 404)
        data = core._json_body()
        action = core._text(data, 'action')
        comment = core._text(data, 'comment')[:_MAX_COMMENT]
        current = _current(item, steps)
        my_turn = bool(item.status == 'on_route' and current
                       and current.employee_id == viewer.employee_id)
        is_author = viewer.employee_id == item.employee_id
        now = datetime.utcnow()
        before = item.status
        next_step = None

        if action in ('approve', 'return'):
            if not my_turn:
                if item.status not in OPEN_STATUSES:
                    return _fail('closed', 409)
                return core._deny()
            if action == 'return' and not comment:
                return _fail('comment_required', 400)
            current.decision = 'approved' if action == 'approve' else 'returned'
            current.comment = comment or None
            current.decided_at = now
            if action == 'return':
                item.status = 'returned'
            else:
                next_step = next((s for s in steps
                                  if s.position > current.position), None)
                if next_step is None:
                    item.status = 'approved'
                    item.closed_at = now
                else:
                    item.current_step = next_step.position
            item.step_since = now
        elif action == 'resubmit':
            if not is_author:
                return core._deny()
            if item.status != 'returned':
                return _fail('not_returned', 409)
            # С того, кто вернул: уже согласовавшие второй раз не подписывают.
            current.decision = 'pending'
            current.decided_at = None
            item.status = 'on_route'
            item.step_since = now
            item.reminded_at = None
        elif action == 'cancel':
            if not is_author:
                return core._deny()
            if item.status not in OPEN_STATUSES:
                return _fail('closed', 409)
            item.status = 'cancelled'
            item.closed_at = now
        elif action == 'remind':
            if not is_author:
                return core._deny()
            if item.status != 'on_route':
                return _fail('closed', 409)
            if not _can_remind(item, now):
                return _fail('too_soon', 429)
            item.reminded_at = now
        elif action == 'comment':
            if not comment:
                return _fail('comment_required', 400)
        else:
            return _fail('bad_action', 400)

        item.updated_at = now
        db.session.add(ApprovalEvent(approval_id=item.id,
                                     actor_id=viewer.employee_id,
                                     action=action, comment=comment or None,
                                     at=now))
        db.session.commit()

        number = f'Лист №{item.id}'
        who = viewer.full_name
        if action == 'approve' and next_step is not None:
            _notify([next_step.employee_id], f'На согласование: {_what(item)}',
                    f'{number}, согласовал {who}', item.id)
            if comment:
                _notify([item.employee_id], f'{number}: замечания',
                        f'{who}: {comment[:200]}', item.id, viewer.employee_id)
        elif action == 'approve':
            _notify([item.employee_id], f'{number} согласован',
                    _what(item), item.id, viewer.employee_id)
        elif action == 'return':
            _notify([item.employee_id], f'{number} возвращён',
                    f'{who}: {comment[:200]}', item.id, viewer.employee_id)
        elif action == 'resubmit':
            _notify([current.employee_id], f'Снова на согласовании: {_what(item)}',
                    comment or number, item.id, viewer.employee_id)
        elif action == 'remind':
            waited = now - (item.step_since or now)
            days = waited.days
            since = f' Лежит {days} дн.' if days else ''
            _notify([current.employee_id], f'Напоминание: {_what(item)}',
                    f'{number} ждёт вашего согласования.{since}', item.id,
                    viewer.employee_id)
        elif action == 'comment':
            targets = {item.employee_id}
            if current:
                targets.add(current.employee_id)
            _notify(targets, f'{number}: сообщение', f'{who}: {comment[:200]}',
                    item.id, viewer.employee_id)
        logging.info('Лист №%s: %s → %s (%s, %s)', item.id, before,
                     item.status, action, viewer.employee_id)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer)})
