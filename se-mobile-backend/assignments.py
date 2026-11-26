"""Задачи с контролем сроков (в интерфейсе — «Задачи», прежде «Поручения»): руководитель поручает, исполнитель
принимает, отчитывается или просит перенести срок, руководитель принимает
работу или возвращает.

Сейчас поручение дают на планёрке или в мессенджере, а через неделю никто
не помнит, кому и к какому числу. Здесь у поручения есть исполнитель, срок
и история: просроченные видны обоим, перенос срока — только с согласия
поручившего, и «сделано» — это отчёт, который поручивший принимает.

Поручать может начальник — своему отделу (как в табеле), руководство
предприятия и ASSIGNERS — кому угодно.
"""

import logging
import os
from datetime import date, datetime, timedelta

from flask import g, jsonify, request

import demo
from it_requests import _norm, _utc
from models import db

OPEN = ('new', 'in_progress')
CLOSED = ('closed', 'cancelled')

_MAX_TITLE = 300
_MAX_TEXT = 4000
_MAX_COMMENT = 2000
_MAX_ASSIGNEES = 30
_MAX_OPEN_PER_AUTHOR = 300
REMIND_EVERY = timedelta(hours=4)
# Закрытые показываем в списке ещё месяц.
_SHOW_CLOSED_FOR = timedelta(days=30)


class Assignment(db.Model):
    __tablename__ = 'assignments'
    __table_args__ = (
        db.Index('ix_assignments_assignee', 'assignee_id', 'status'),
        db.Index('ix_assignments_author', 'author_id', 'status'),
    )
    id = db.Column(db.Integer, primary_key=True)
    author_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                          nullable=False)
    assignee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False)
    title = db.Column(db.String(_MAX_TITLE), nullable=False)
    text = db.Column(db.Text)
    important = db.Column(db.Boolean, nullable=False, default=False)
    due_date = db.Column(db.Date, nullable=False)
    # new — поручено, in_progress — принял, done — отчитался, closed —
    # поручивший принял работу, cancelled — снято.
    status = db.Column(db.String(12), nullable=False, default='new')
    result = db.Column(db.Text)
    # Исполнитель просит перенести срок — до ответа поручившего.
    proposed_due = db.Column(db.Date)
    proposed_reason = db.Column(db.Text)
    reminded_at = db.Column(db.DateTime)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    closed_at = db.Column(db.DateTime)


class AssignmentEvent(db.Model):
    __tablename__ = 'assignment_events'
    id = db.Column(db.Integer, primary_key=True)
    assignment_id = db.Column(db.Integer,
                              db.ForeignKey('assignments.id', ondelete='CASCADE'),
                              nullable=False, index=True)
    actor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # created, accept, done, close, return, extend, extend_ok, extend_no,
    # cancel, remind, comment
    action = db.Column(db.String(10), nullable=False)
    comment = db.Column(db.Text)
    # Для extend и extend_ok — о каком сроке речь.
    due = db.Column(db.Date)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_top(employee):
    """Руководство предприятия — поручает кому угодно."""
    if employee is None:
        return False
    return ('руководств' in _norm(employee.department)
            or employee.employee_id in _env_ids('ASSIGNERS'))


def register(app, core):
    from models import Employee

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _assignable(viewer):
        """Кому этот человек может поручать: None — всем, иначе набор id."""
        if core._is_system_admin(viewer.job_title) or is_top(viewer):
            return None
        if not core._is_admin_role(viewer.job_title or ''):
            return set()
        visible = core._visible_employee_ids()
        if visible is None:
            return None
        return visible - {viewer.employee_id}

    def _can_assign(viewer):
        allowed = _assignable(viewer)
        return allowed is None or bool(allowed)

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

    def _may_see(viewer, item):
        return (viewer.employee_id in (item.author_id, item.assignee_id)
                or core._is_system_admin(viewer.job_title))

    def _overdue(item, today):
        return item.status in OPEN and item.due_date < today

    def _json(item, people, viewer, today, events=None):
        is_author = viewer.employee_id == item.author_id
        is_assignee = viewer.employee_id == item.assignee_id
        data = {
            'id': item.id,
            'title': item.title,
            'text': item.text or '',
            'important': bool(item.important),
            'due_date': item.due_date.isoformat(),
            'status': item.status,
            'overdue': _overdue(item, today),
            'result': item.result or '',
            'proposed_due': item.proposed_due.isoformat() if item.proposed_due else None,
            'proposed_reason': item.proposed_reason or '',
            'author': _person(people.get(item.author_id), item.author_id),
            'assignee': _person(people.get(item.assignee_id), item.assignee_id),
            'created_at': _utc(item.created_at),
            'updated_at': _utc(item.updated_at),
            'closed_at': _utc(item.closed_at),
            'is_author': is_author,
            'is_assignee': is_assignee,
            'can_remind': bool(
                is_author and item.status in OPEN
                and (item.reminded_at is None
                     or datetime.utcnow() - item.reminded_at >= REMIND_EVERY)),
        }
        if events is not None:
            data['events'] = [{
                'action': e.action,
                'comment': e.comment or '',
                'due': e.due.isoformat() if e.due else None,
                'at': _utc(e.at),
                'actor': _person(people.get(e.actor_id), e.actor_id),
            } for e in events]
        return data

    def _list_json(items, viewer, today):
        people = _names([i.author_id for i in items]
                        + [i.assignee_id for i in items])
        return [_json(i, people, viewer, today) for i in items]

    def _detail(item, viewer):
        events = (AssignmentEvent.query.filter_by(assignment_id=item.id)
                  .order_by(AssignmentEvent.at, AssignmentEvent.id).all())
        people = _names([item.author_id, item.assignee_id]
                        + [e.actor_id for e in events])
        return _json(item, people, viewer, core._plant_today(), events)

    def _notify(employee_ids, title, body, item_id, actor_id=None):
        ids = sorted({e for e in employee_ids if e and e != actor_id})
        if ids:
            core._record_notice('assignment', title[:200], body[:500],
                                employee_ids=ids, ref=item_id, repeat=True)

    def _date(raw):
        try:
            return date.fromisoformat(raw) if raw else None
        except ValueError:
            return None

    @app.route('/api/assignments', methods=['GET'])
    @core.require_auth
    def assignments_list():
        """Мне поручено или `?scope=given` — я поручил."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        today = core._plant_today()
        since = datetime.utcnow() - _SHOW_CLOSED_FOR
        given_scope = request.args.get('scope') == 'given'
        column = Assignment.author_id if given_scope else Assignment.assignee_id
        items = (Assignment.query
                 .filter(column == viewer.employee_id,
                         db.or_(Assignment.status.notin_(CLOSED),
                                Assignment.updated_at >= since))
                 .order_by(Assignment.due_date, Assignment.id).limit(300).all())
        # Сверху — то, что ждёт этого человека: поручившего — отчёты,
        # исполнителя — просроченное; дальше по сроку, закрытое — вниз.
        items.sort(key=lambda i: (i.status in CLOSED,
                                  (i.status != 'done') if given_scope
                                  else (i.status == 'done'),
                                  not _overdue(i, today), i.due_date))
        mine = Assignment.query.filter(Assignment.assignee_id == viewer.employee_id,
                                       Assignment.status.in_(OPEN)).all()
        given = Assignment.query.filter(Assignment.author_id == viewer.employee_id,
                                        Assignment.status.notin_(CLOSED)).all()
        return jsonify({
            'message': 'Success',
            'can_assign': _can_assign(viewer),
            'items': _list_json(items, viewer, today),
            'counts': {
                'mine_open': len(mine),
                'mine_overdue': sum(1 for i in mine if _overdue(i, today)),
                'given_open': len(given),
                'given_overdue': sum(1 for i in given if _overdue(i, today)),
                # Отчитались — ждут, когда поручивший примет.
                'given_done': sum(1 for i in given if i.status == 'done'),
            },
        })

    @app.route('/api/assignments/people', methods=['GET'])
    @core.require_auth
    def assignments_people():
        """Кому можно поручить: `?q=` — часть ФИО или должности."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        allowed = _assignable(viewer)
        if allowed is not None and not allowed:
            return core._deny()
        q = _norm(request.args.get('q', ''))
        people = []
        # Только свой мир: гостю (demo.py) — его вымышленные люди, руководству
        # и администратору — без них.
        for e in (Employee.query.filter(demo.world(Employee.employee_id, viewer))
                  .order_by(Employee.full_name)):
            if not e.full_name or e.employee_id == viewer.employee_id:
                continue
            if allowed is not None and e.employee_id not in allowed:
                continue
            if q and q not in _norm(e.full_name) and q not in _norm(e.job_title):
                continue
            people.append(_person(e, e.employee_id))
            if len(people) >= 50:
                break
        return jsonify({'message': 'Success', 'people': people})

    @app.route('/api/assignments', methods=['POST'])
    @core.require_auth
    def assignments_create():
        """`{"title", "text", "due_date", "important", "assignee_ids": [...]}` —
        на каждого исполнителя своё поручение."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        allowed = _assignable(viewer)
        if allowed is not None and not allowed:
            return core._deny()
        data = core._json_body()
        title = ' '.join(core._text(data, 'title').split())[:_MAX_TITLE]
        if not title:
            return _fail('title_required', 400)
        text = core._text(data, 'text')[:_MAX_TEXT]
        due = _date(core._text(data, 'due_date'))
        if due is None or due < core._plant_today():
            return _fail('bad_date', 400)
        important = data.get('important') in (True, 1, '1', 'true')
        raw_ids = data.get('assignee_ids')
        if not isinstance(raw_ids, list) or not raw_ids:
            return _fail('assignee_required', 400)
        if len(raw_ids) > _MAX_ASSIGNEES:
            return _fail('too_many_assignees', 400)
        ids = sorted({str(i) for i in raw_ids})
        people = _names(ids)
        for employee_id in ids:
            if employee_id not in people or employee_id == viewer.employee_id:
                return _fail('bad_assignee', 400)
            if allowed is not None and employee_id not in allowed:
                return _fail('bad_assignee', 403)
        if Assignment.query.filter(Assignment.author_id == viewer.employee_id,
                                   Assignment.status.notin_(CLOSED)).count() \
                + len(ids) > _MAX_OPEN_PER_AUTHOR:
            return _fail('too_many_open', 429)

        now = datetime.utcnow()
        created = []
        for employee_id in ids:
            item = Assignment(author_id=viewer.employee_id, assignee_id=employee_id,
                              title=title, text=text or None, important=important,
                              due_date=due, status='new', created_at=now,
                              updated_at=now)
            db.session.add(item)
            db.session.flush()
            db.session.add(AssignmentEvent(assignment_id=item.id,
                                           actor_id=viewer.employee_id,
                                           action='created', due=due, at=now))
            created.append(item)
        db.session.commit()
        logging.info('Поручение «%s» от %s: %s исполнителей', title,
                     viewer.employee_id, len(created))
        for item in created:
            _notify([item.assignee_id],
                    f'{"Важная задача" if important else "Новая задача"}: {title}',
                    f'{viewer.full_name}, срок {due:%d.%m}', item.id)
        today = core._plant_today()
        return jsonify({'message': 'Success',
                        'items': _list_json(created, viewer, today)}), 201

    @app.route('/api/assignments/<int:item_id>', methods=['GET'])
    @core.require_auth
    def assignment_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(Assignment, item_id)
        if item is None or not _may_see(viewer, item):
            return _fail('not_found', 404)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer)})

    @app.route('/api/assignments/<int:item_id>', methods=['POST'])
    @core.require_auth
    def assignment_action(item_id):
        """`{"action", "comment", "due_date"}`.

        Исполнитель: accept, done (отчёт обязателен), extend (новый срок и
        причина). Поручивший: close, return (с замечанием), extend_ok,
        extend_no, cancel, remind. Обоим: comment.
        """
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(Assignment, item_id)
        if item is None or not _may_see(viewer, item):
            return _fail('not_found', 404)
        data = core._json_body()
        action = core._text(data, 'action')
        comment = core._text(data, 'comment')[:_MAX_COMMENT]
        is_author = viewer.employee_id == item.author_id
        is_assignee = viewer.employee_id == item.assignee_id
        now = datetime.utcnow()
        due = None
        label = f'«{item.title}»'

        if action in ('accept', 'done', 'extend') and not is_assignee:
            return core._deny()
        if action in ('close', 'return', 'extend_ok', 'extend_no', 'cancel',
                      'remind') and not is_author:
            return core._deny()
        if item.status in CLOSED and action != 'comment':
            return _fail('closed', 409)

        notify_to, title, body = None, None, None
        if action == 'accept':
            if item.status != 'new':
                return _fail('bad_state', 409)
            item.status = 'in_progress'
            notify_to, title = item.author_id, f'Задача принята: {label}'
            body = viewer.full_name
        elif action == 'done':
            if item.status not in OPEN:
                return _fail('bad_state', 409)
            if not comment:
                return _fail('comment_required', 400)
            item.status = 'done'
            item.result = comment
            item.proposed_due = item.proposed_reason = None
            notify_to, title = item.author_id, f'Выполнено: {label}'
            body = f'{viewer.full_name}: {comment}'
        elif action == 'extend':
            if item.status not in OPEN:
                return _fail('bad_state', 409)
            due = _date(core._text(data, 'due_date'))
            if due is None or due <= item.due_date:
                return _fail('bad_date', 400)
            if not comment:
                return _fail('comment_required', 400)
            item.proposed_due = due
            item.proposed_reason = comment
            notify_to, title = item.author_id, f'Просит перенести срок: {label}'
            body = f'{viewer.full_name}: на {due:%d.%m} — {comment}'
        elif action == 'close':
            if item.status != 'done':
                return _fail('bad_state', 409)
            item.status = 'closed'
            item.closed_at = now
            notify_to, title = item.assignee_id, f'Работа принята: {label}'
            body = viewer.full_name
        elif action == 'return':
            if item.status != 'done':
                return _fail('bad_state', 409)
            if not comment:
                return _fail('comment_required', 400)
            item.status = 'in_progress'
            new_due = _date(core._text(data, 'due_date'))
            if new_due is not None:
                if new_due < core._plant_today():
                    return _fail('bad_date', 400)
                item.due_date = due = new_due
            notify_to, title = item.assignee_id, f'Задача возвращена: {label}'
            body = f'{viewer.full_name}: {comment}'
        elif action in ('extend_ok', 'extend_no'):
            if item.proposed_due is None:
                return _fail('no_request', 409)
            if action == 'extend_ok':
                item.due_date = due = item.proposed_due
                title = f'Срок перенесён на {due:%d.%m}: {label}'
            else:
                title = f'Срок не перенесён: {label}'
            item.proposed_due = item.proposed_reason = None
            notify_to = item.assignee_id
            body = f'{viewer.full_name}' + (f': {comment}' if comment else '')
        elif action == 'cancel':
            item.status = 'cancelled'
            item.closed_at = now
            notify_to, title = item.assignee_id, f'Задача снята: {label}'
            body = f'{viewer.full_name}' + (f': {comment}' if comment else '')
        elif action == 'remind':
            if item.status not in OPEN:
                return _fail('bad_state', 409)
            if item.reminded_at and now - item.reminded_at < REMIND_EVERY:
                return _fail('too_soon', 429)
            item.reminded_at = now
            notify_to, title = item.assignee_id, f'Напоминание: {label}'
            body = f'{viewer.full_name}, срок {item.due_date:%d.%m}'
        elif action == 'comment':
            if not comment:
                return _fail('comment_required', 400)
            notify_to = item.assignee_id if is_author else item.author_id
            title = f'Комментарий: {label}'
            body = f'{viewer.full_name}: {comment}'
        else:
            return _fail('bad_action', 400)

        item.updated_at = now
        db.session.add(AssignmentEvent(assignment_id=item.id,
                                       actor_id=viewer.employee_id,
                                       action=action, comment=comment or None,
                                       due=due, at=now))
        db.session.commit()
        logging.info('Поручение №%s: %s (%s)', item.id, action, viewer.employee_id)
        if notify_to:
            _notify([notify_to], title, body, item.id, viewer.employee_id)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer)})
