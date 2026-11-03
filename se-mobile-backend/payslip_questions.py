"""Вопрос по расчётному листку: «почему удержали больше», «где доплата за
сверхурочные» — прямо из листка, расчётной группе.

После каждой зарплаты расчётную группу засыпают звонками и походами в
бухгалтерию, и половина вопросов одинаковая. Здесь вопрос привязан к
месяцу и, если человек выбрал, к строке листка; бухгалтер видит, о чём
речь, отвечает письменно, и ответ остаётся у человека.

Зарплата — тайна: вопрос видят только автор и расчётная группа (в
должности «расчетн», главный бухгалтер или PAYROLL_STAFF). Ни начальник,
ни администратор приложения его не видят. В оповещениях — ни сумм, ни
текста строки.
"""

import logging
import os
from datetime import datetime, timedelta

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db, PayrollGrant

STATUSES = ('open', 'answered', 'closed')

_MAX_TEXT = 2000
_MAX_LINE = 200
_MAX_OPEN_PER_AUTHOR = 10
_QUEUE_CLOSED_FOR = timedelta(days=30)


class PayslipQuestion(db.Model):
    __tablename__ = 'payslip_questions'
    __table_args__ = (
        db.Index('ix_payslip_questions_author', 'employee_id', 'created_at'),
        db.Index('ix_payslip_questions_status', 'status', 'updated_at'),
    )
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False)
    period_year = db.Column(db.Integer, nullable=False)
    period_month = db.Column(db.Integer, nullable=False)
    # Строка листка, о которой вопрос: «Удержания: ИПН — 12 345,00».
    line = db.Column(db.String(_MAX_LINE))
    # open — ждёт ответа бухгалтера, answered — ответили, closed — решено.
    status = db.Column(db.String(10), nullable=False, default='open')
    assignee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class PayslipQuestionMessage(db.Model):
    __tablename__ = 'payslip_question_messages'
    id = db.Column(db.Integer, primary_key=True)
    question_id = db.Column(db.Integer,
                            db.ForeignKey('payslip_questions.id', ondelete='CASCADE'),
                            nullable=False, index=True)
    author_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    text = db.Column(db.Text, nullable=False)
    # Служебная отметка «вопрос решён» — отдельной строкой в переписке.
    kind = db.Column(db.String(10), nullable=False, default='message')
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def payroll_by_title(employee):
    """Расчётная группа по должности — это не снять из админ-панели."""
    title = _norm(employee.job_title)
    return 'расчетн' in title or title.startswith('главный бухгалтер')


def payroll_grants():
    """Табельные номера, кому расчётную группу открыли вручную: списком
    PAYROLL_STAFF на сервере или из админ-панели."""
    return (_env_ids('PAYROLL_STAFF')
            | {row.employee_id for row in PayrollGrant.query.all()})


def is_payroll(employee):
    if employee is None:
        return False
    if payroll_by_title(employee):
        return True
    if employee.employee_id in _env_ids('PAYROLL_STAFF'):
        return True
    return db.session.get(PayrollGrant, employee.employee_id) is not None


_MONTHS = ('январь', 'февраль', 'март', 'апрель', 'май', 'июнь', 'июль',
           'август', 'сентябрь', 'октябрь', 'ноябрь', 'декабрь')


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

    def _person(emp, employee_id, with_department=True):
        if not employee_id:
            return None
        data = {'id': employee_id,
                'name': emp.full_name if emp else employee_id}
        if with_department:
            data['department'] = (emp.department or '') if emp else ''
        return data

    def _ids(test):
        return sorted(e.employee_id for e in Employee.query.all() if test(e))

    def _may_see(viewer, item):
        return viewer.employee_id == item.employee_id or is_payroll(viewer)

    def _period(item):
        return f'{_MONTHS[item.period_month - 1]} {item.period_year}'

    def _json(item, people, viewer, messages=None, first=None):
        data = {
            'id': item.id,
            'year': item.period_year,
            'month': item.period_month,
            'line': item.line or '',
            'status': item.status,
            'author': _person(people.get(item.employee_id), item.employee_id),
            'assignee': _person(people.get(item.assignee_id), item.assignee_id),
            'created_at': _utc(item.created_at),
            'updated_at': _utc(item.updated_at),
            'is_author': viewer.employee_id == item.employee_id,
            'can_answer': is_payroll(viewer) and item.status != 'closed',
        }
        if first is not None:
            data['preview'] = first.text[:200]
        if messages is not None:
            data['messages'] = [{
                'text': m.text,
                'kind': m.kind,
                'at': _utc(m.at),
                'author': _person(people.get(m.author_id), m.author_id,
                                  with_department=False),
                'from_payroll': m.author_id != item.employee_id,
            } for m in messages]
        return data

    def _messages(item):
        return (PayslipQuestionMessage.query.filter_by(question_id=item.id)
                .order_by(PayslipQuestionMessage.at,
                          PayslipQuestionMessage.id).all())

    def _detail(item, viewer):
        messages = _messages(item)
        people = _names([item.employee_id, item.assignee_id]
                        + [m.author_id for m in messages])
        return _json(item, people, viewer, messages)

    def _notify(employee_ids, title, body, item_id, actor_id=None):
        ids = sorted({e for e in employee_ids if e and e != actor_id})
        if ids:
            core._record_notice('payslip_q', title, body, employee_ids=ids,
                                ref=item_id, repeat=True)

    @app.route('/api/payslip-questions', methods=['GET'])
    @core.require_auth
    def payslip_questions_list():
        """Мои вопросы или очередь расчётной группы: `?scope=queue`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        staff = is_payroll(viewer)
        if request.args.get('scope') == 'queue':
            if not staff:
                return core._deny()
            since = datetime.utcnow() - _QUEUE_CLOSED_FOR
            items = (PayslipQuestion.query
                     .filter(db.or_(PayslipQuestion.status == 'open',
                                    PayslipQuestion.updated_at >= since))
                     .order_by(PayslipQuestion.updated_at).limit(300).all())
            # Ждущие ответа — наверх, дольше ждущие — первыми.
            items.sort(key=lambda i: i.status != 'open')
        else:
            items = (PayslipQuestion.query.filter_by(employee_id=viewer.employee_id)
                     .order_by(PayslipQuestion.updated_at.desc()).limit(100).all())
        firsts = {}
        for m in (PayslipQuestionMessage.query
                  .filter(PayslipQuestionMessage.question_id.in_(
                      [i.id for i in items] or [-1]))
                  .order_by(PayslipQuestionMessage.id)):
            firsts.setdefault(m.question_id, m)
        people = _names([i.employee_id for i in items]
                        + [i.assignee_id for i in items])
        body = {'message': 'Success', 'staff': staff,
                'items': [_json(i, people, viewer, first=firsts.get(i.id))
                          for i in items]}
        if staff:
            body['open'] = PayslipQuestion.query.filter_by(status='open').count()
        return jsonify(body)

    @app.route('/api/payslip-questions', methods=['POST'])
    @core.require_auth
    def payslip_questions_create():
        """`{"year", "month", "line", "text"}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        data = core._json_body()
        try:
            year = int(data.get('year'))
            month = int(data.get('month'))
        except (TypeError, ValueError):
            return _fail('bad_period', 400)
        today = core._plant_today()
        if not (1 <= month <= 12 and 2000 <= year <= today.year
                and (year, month) <= (today.year, today.month)):
            return _fail('bad_period', 400)
        text = core._text(data, 'text')[:_MAX_TEXT]
        if not text:
            return _fail('text_required', 400)
        if PayslipQuestion.query.filter(
                PayslipQuestion.employee_id == viewer.employee_id,
                PayslipQuestion.status != 'closed').count() >= _MAX_OPEN_PER_AUTHOR:
            return _fail('too_many_open', 429)

        now = datetime.utcnow()
        item = PayslipQuestion(employee_id=viewer.employee_id, period_year=year,
                               period_month=month,
                               line=core._text(data, 'line')[:_MAX_LINE] or None,
                               status='open', created_at=now, updated_at=now)
        db.session.add(item)
        db.session.flush()
        db.session.add(PayslipQuestionMessage(question_id=item.id,
                                              author_id=viewer.employee_id,
                                              text=text, at=now))
        db.session.commit()
        logging.info('Вопрос по листку №%s от %s', item.id, viewer.employee_id)
        _notify(_ids(is_payroll), f'Вопрос по листку №{item.id}',
                f'{viewer.full_name}, {_period(item)}', item.id,
                viewer.employee_id)
        return jsonify({'message': 'Success',
                        'item': _detail(item, viewer)}), 201

    @app.route('/api/payslip-questions/<int:item_id>', methods=['GET'])
    @core.require_auth
    def payslip_question_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(PayslipQuestion, item_id)
        if item is None or not _may_see(viewer, item):
            return _fail('not_found', 404)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer)})

    @app.route('/api/payslip-questions/<int:item_id>', methods=['POST'])
    @core.require_auth
    def payslip_question_action(item_id):
        """`{"action": "reply" | "close", "text"}`.

        Ответ бухгалтера переводит вопрос в «отвечено», ответ автора —
        снова в «ждёт ответа». Закрывает автор: «вопрос решён».
        """
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(PayslipQuestion, item_id)
        if item is None or not _may_see(viewer, item):
            return _fail('not_found', 404)
        data = core._json_body()
        action = core._text(data, 'action')
        text = core._text(data, 'text')[:_MAX_TEXT]
        is_author = viewer.employee_id == item.employee_id
        now = datetime.utcnow()

        if action == 'reply':
            if not text:
                return _fail('text_required', 400)
            if item.status == 'closed' and not is_author:
                return _fail('closed', 409)
            if is_author:
                item.status = 'open'
            else:
                item.status = 'answered'
                item.assignee_id = viewer.employee_id
            kind = 'message'
        elif action == 'close':
            if not is_author:
                return core._deny()
            if item.status == 'closed':
                return _fail('closed', 409)
            item.status = 'closed'
            kind = 'closed'
            text = text or '—'
        else:
            return _fail('bad_action', 400)

        item.updated_at = now
        db.session.add(PayslipQuestionMessage(question_id=item.id,
                                              author_id=viewer.employee_id,
                                              text=text, kind=kind, at=now))
        db.session.commit()

        number = f'Вопрос по листку №{item.id}'
        if action == 'reply' and not is_author:
            _notify([item.employee_id], f'{number}: ответ расчётной группы',
                    _period(item), item.id, viewer.employee_id)
        elif action == 'reply':
            targets = [item.assignee_id] if item.assignee_id else _ids(is_payroll)
            _notify(targets, f'{number}: уточнение',
                    f'{viewer.full_name}, {_period(item)}', item.id,
                    viewer.employee_id)
        logging.info('Вопрос по листку №%s: %s (%s)', item.id, action,
                     viewer.employee_id)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer)})
