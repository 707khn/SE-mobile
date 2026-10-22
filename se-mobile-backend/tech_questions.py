"""Вопрос технологу или конструктору: мастер нашёл несоответствие чертежу
или техпроцессу — пишет в ТО, инженер отвечает решением, и решение
остаётся в истории изделия.

Сейчас такой вопрос решают по телефону, и через полгода на тот же вопрос
по тому же изделию никто не помнит ответа. Здесь у вопроса есть изделие,
документ (чертёж, техпроцесс) и операция; по изделию можно найти все
прежние решения.

О чертеже узнают конструкторы, о техпроцессе — технологи, о замене
материала и прочем — весь ТО; начальник ТО и заместитель — обо всём.
«Стоит работа» — всему ТО сразу. Историю по изделию видят ТО, производство
и ОТК. Фото и файлы не хранятся: чертежи — режимные.

ТО — подразделение «Технический отдел» или TECH_STAFF.
"""

import logging
import os
from datetime import datetime, timedelta

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db

KINDS = ('drawing', 'process', 'material', 'other')
KIND_TITLES = {'drawing': 'по чертежу', 'process': 'по техпроцессу',
               'material': 'замена материала', 'other': 'вопрос'}
OPEN = ('new', 'in_work')
CLOSED = ('closed',)

_MAX_PRODUCT = 200
_MAX_DOC = 100
_MAX_TEXT = 4000
_SHOW_CLOSED_FOR = timedelta(days=30)


class TechQuestion(db.Model):
    __tablename__ = 'tech_questions'
    __table_args__ = (db.Index('ix_tech_questions_status', 'status', 'created_at'),)
    id = db.Column(db.Integer, primary_key=True)
    author_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                          nullable=False, index=True)
    kind = db.Column(db.String(10), nullable=False)
    # Изделие — как его называют на участке: «Корпус 7.312», «ДСЕ 45-01».
    product = db.Column(db.String(_MAX_PRODUCT), nullable=False)
    # Для поиска по изделию — без регистра и лишних пробелов.
    product_key = db.Column(db.String(_MAX_PRODUCT), nullable=False, index=True)
    document = db.Column(db.String(_MAX_DOC))
    operation = db.Column(db.String(_MAX_DOC))
    text = db.Column(db.Text, nullable=False)
    urgent = db.Column(db.Boolean, nullable=False, default=False)
    # new — ждёт ТО, in_work — инженер взял или автор уточнил, answered —
    # есть решение, closed — автор принял решение.
    status = db.Column(db.String(10), nullable=False, default='new')
    assignee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    decision = db.Column(db.Text)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    answered_at = db.Column(db.DateTime)


class TechQuestionEvent(db.Model):
    __tablename__ = 'tech_question_events'
    id = db.Column(db.Integer, primary_key=True)
    question_id = db.Column(db.Integer,
                            db.ForeignKey('tech_questions.id', ondelete='CASCADE'),
                            nullable=False, index=True)
    actor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # created, take, answer, clarify, close, comment
    action = db.Column(db.String(10), nullable=False)
    comment = db.Column(db.Text)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def _key(product):
    return ' '.join(_norm(product).split())


def is_tech_staff(employee):
    if employee is None:
        return False
    dept = _norm(employee.department)
    return 'технический отдел' in dept or employee.employee_id in _env_ids('TECH_STAFF')


def is_tech_head(employee):
    title = _norm(employee.job_title)
    return is_tech_staff(employee) and title.startswith(('начальник', 'заместитель'))


def reads_history(employee):
    """Историю решений по изделию видят ТО, производство и ОТК."""
    dept = _norm(employee.department)
    return (is_tech_staff(employee) or 'основное производство' in dept
            or 'технического контроля' in dept)


def register(app, core):
    from models import Employee

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _staff(viewer):
        return core._is_system_admin(viewer.job_title) or is_tech_staff(viewer)

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

    def _may_see(viewer, item):
        return (viewer.employee_id == item.author_id or _staff(viewer)
                or reads_history(viewer))

    def _json(item, people, viewer, staff, events=None):
        data = {
            'id': item.id,
            'kind': item.kind,
            'product': item.product,
            'document': item.document or '',
            'operation': item.operation or '',
            'text': item.text,
            'urgent': bool(item.urgent),
            'status': item.status,
            'decision': item.decision or '',
            'author': _person(people.get(item.author_id), item.author_id),
            'assignee': _person(people.get(item.assignee_id), item.assignee_id),
            'created_at': _utc(item.created_at),
            'updated_at': _utc(item.updated_at),
            'answered_at': _utc(item.answered_at),
            'is_author': viewer.employee_id == item.author_id,
            'can_answer': bool(staff and item.status not in CLOSED),
        }
        if events is not None:
            data['events'] = [{
                'action': e.action,
                'comment': e.comment or '',
                'at': _utc(e.at),
                'actor': _person(people.get(e.actor_id), e.actor_id),
            } for e in events]
        return data

    def _list_json(items, viewer, staff):
        people = _names([i.author_id for i in items] + [i.assignee_id for i in items])
        return [_json(i, people, viewer, staff) for i in items]

    def _detail(item, viewer, staff):
        events = (TechQuestionEvent.query.filter_by(question_id=item.id)
                  .order_by(TechQuestionEvent.at, TechQuestionEvent.id).all())
        people = _names([item.author_id, item.assignee_id]
                        + [e.actor_id for e in events])
        return _json(item, people, viewer, staff, events)

    def _targets(kind, urgent):
        """Кому о новом вопросе."""
        out = []
        for e in Employee.query.all():
            if not is_tech_staff(e):
                continue
            title = _norm(e.job_title)
            if urgent or kind in ('material', 'other') or is_tech_head(e) \
                    or (kind == 'drawing' and 'конструктор' in title) \
                    or (kind == 'process' and 'технолог' in title):
                out.append(e.employee_id)
        return out

    def _notify(ids, title, body, ref, actor_id=None):
        ids = sorted({i for i in ids if i and i != actor_id})
        if ids:
            core._record_notice('techq', title[:200], body[:500],
                                employee_ids=ids, ref=ref)

    @app.route('/api/tech-questions', methods=['GET'])
    @core.require_auth
    def tech_questions_list():
        """Мои; ТО — `?scope=queue`; история по изделию — `?product=`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        staff = _staff(viewer)
        product = request.args.get('product', '')
        scope = request.args.get('scope')
        if product:
            if not (staff or reads_history(viewer)):
                return core._deny()
            key = _key(product)
            items = (TechQuestion.query
                     .filter(TechQuestion.product_key.contains(key, autoescape=True))
                     .order_by(TechQuestion.created_at.desc()).limit(100).all())
        elif scope == 'queue':
            if not staff:
                return core._deny()
            since = datetime.utcnow() - _SHOW_CLOSED_FOR
            items = (TechQuestion.query
                     .filter(db.or_(TechQuestion.status.notin_(CLOSED),
                                    TechQuestion.updated_at >= since))
                     .order_by(TechQuestion.created_at).limit(300).all())
            # Ждёт ТО — сверху, «стоит работа» — первым; решённое — вниз.
            items.sort(key=lambda i: (i.status not in OPEN, not i.urgent,
                                      i.status != 'new'))
        else:
            items = (TechQuestion.query.filter_by(author_id=viewer.employee_id)
                     .order_by(TechQuestion.created_at.desc()).limit(100).all())
        body = {'message': 'Success', 'staff': staff,
                'history': staff or reads_history(viewer),
                'items': _list_json(items, viewer, staff)}
        if staff:
            body['waiting'] = TechQuestion.query.filter(
                TechQuestion.status.in_(OPEN)).count()
        return jsonify(body)

    @app.route('/api/tech-questions/products', methods=['GET'])
    @core.require_auth
    def tech_question_products():
        """Изделия, по которым уже спрашивали, — подсказка при вводе."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        key = _key(request.args.get('q', ''))
        query = db.session.query(TechQuestion.product, TechQuestion.product_key)
        if key:
            query = query.filter(TechQuestion.product_key.contains(key, autoescape=True))
        seen, names = set(), []
        for product, product_key in query.order_by(TechQuestion.created_at.desc()):
            if product_key not in seen:
                seen.add(product_key)
                names.append(product)
            if len(names) >= 20:
                break
        return jsonify({'message': 'Success', 'products': names})

    @app.route('/api/tech-questions', methods=['POST'])
    @core.require_auth
    def tech_questions_create():
        """`{"kind", "product", "document", "operation", "text", "urgent"}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        data = core._json_body()
        kind = core._text(data, 'kind')
        if kind not in KINDS:
            return _fail('bad_kind', 400)
        product = ' '.join(core._text(data, 'product').split())[:_MAX_PRODUCT]
        if not product:
            return _fail('product_required', 400)
        text = core._text(data, 'text')[:_MAX_TEXT]
        if not text:
            return _fail('text_required', 400)
        urgent = data.get('urgent') in (True, 1, '1', 'true')
        now = datetime.utcnow()
        item = TechQuestion(author_id=viewer.employee_id, kind=kind,
                            product=product, product_key=_key(product),
                            document=core._text(data, 'document')[:_MAX_DOC] or None,
                            operation=core._text(data, 'operation')[:_MAX_DOC] or None,
                            text=text, urgent=urgent, status='new',
                            created_at=now, updated_at=now)
        db.session.add(item)
        db.session.flush()
        db.session.add(TechQuestionEvent(question_id=item.id,
                                         actor_id=viewer.employee_id,
                                         action='created', at=now))
        db.session.commit()
        logging.info('Вопрос в ТО №%s (%s) от %s', item.id, kind, viewer.employee_id)
        where = ', '.join(p for p in (item.document, item.operation) if p)
        _notify(_targets(kind, urgent),
                f'{"Стоит работа: " if urgent else ""}Вопрос {KIND_TITLES[kind]} '
                f'№{item.id}: {product}',
                f'{viewer.full_name}{f" ({where})" if where else ""}: {text}',
                item.id, viewer.employee_id)
        return jsonify({'message': 'Success',
                        'item': _detail(item, viewer, _staff(viewer))}), 201

    @app.route('/api/tech-questions/<int:item_id>', methods=['GET'])
    @core.require_auth
    def tech_question_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(TechQuestion, item_id)
        if item is None or not _may_see(viewer, item):
            return _fail('not_found', 404)
        return jsonify({'message': 'Success',
                        'item': _detail(item, viewer, _staff(viewer))})

    @app.route('/api/tech-questions/<int:item_id>', methods=['POST'])
    @core.require_auth
    def tech_question_action(item_id):
        """ТО: take, answer (решение). Автор: clarify (не понятно — снова в
        ТО), close (решение принято). Обоим: comment."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(TechQuestion, item_id)
        staff = _staff(viewer)
        is_author = item is not None and item.author_id == viewer.employee_id
        if item is None or not (staff or is_author):
            return _fail('not_found', 404)
        data = core._json_body()
        action = core._text(data, 'action')
        text = core._text(data, 'text')[:_MAX_TEXT]
        now = datetime.utcnow()
        label = f'№{item.id} ({item.product})'
        if item.status in CLOSED:
            return _fail('closed', 409)
        notify = None

        if action in ('take', 'answer') and not staff:
            return core._deny()
        if action in ('clarify', 'close') and not is_author:
            return core._deny()

        if action == 'take':
            if item.assignee_id == viewer.employee_id:
                return _fail('already_yours', 409)
            item.assignee_id = viewer.employee_id
            item.status = 'in_work'
            notify = ([item.author_id], f'Вопрос {label} взят в ТО', viewer.full_name)
        elif action == 'answer':
            if not text:
                return _fail('text_required', 400)
            item.decision = text
            item.status = 'answered'
            item.answered_at = now
            if item.assignee_id is None:
                item.assignee_id = viewer.employee_id
            notify = ([item.author_id], f'Решение ТО по вопросу {label}',
                      f'{viewer.full_name}: {text}')
        elif action == 'clarify':
            if item.status != 'answered':
                return _fail('bad_state', 409)
            if not text:
                return _fail('text_required', 400)
            item.status = 'in_work'
            notify = ([item.assignee_id] if item.assignee_id
                      else _targets(item.kind, item.urgent),
                      f'Уточнение по вопросу {label}', f'{viewer.full_name}: {text}')
        elif action == 'close':
            if item.status != 'answered':
                return _fail('bad_state', 409)
            item.status = 'closed'
        elif action == 'comment':
            if not text:
                return _fail('text_required', 400)
            other = item.author_id if staff and not is_author else item.assignee_id
            notify = ([other] if other else _targets(item.kind, item.urgent),
                      f'Комментарий к вопросу {label}', f'{viewer.full_name}: {text}')
        else:
            return _fail('bad_action', 400)

        item.updated_at = now
        db.session.add(TechQuestionEvent(question_id=item.id,
                                         actor_id=viewer.employee_id,
                                         action=action, comment=text or None, at=now))
        db.session.commit()
        logging.info('Вопрос в ТО №%s: %s (%s)', item.id, action, viewer.employee_id)
        if notify:
            _notify(notify[0], notify[1], notify[2], item.id, viewer.employee_id)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer, staff)})
