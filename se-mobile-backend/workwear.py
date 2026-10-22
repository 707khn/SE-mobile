"""Спецодежда и СИЗ: что кому выдано и когда положена замена, стирка и
ремонт с отметкой «готово, заберите».

Сейчас карточки выдачи ведутся в журнале у хозотдела, и о сроке замены
человек узнаёт, когда костюм уже расползся. Здесь хозотдел записывает
выдачу со сроком носки, сотрудник видит свои вещи и сколько им осталось, а
хозотдел — у кого срок выходит, и может разом напомнить. Сданное в стирку
или ремонт записывается при приёме; когда готово, человеку приходит
«заберите».

Записывает выдачу и принимает вещи хозотдел: заведующий, специалист,
машинист по стирке и ремонту спецодежды, кладовщик — и WORKWEAR_STAFF.
Бухгалтерскую карточку учёта это не заменяет: здесь нет цен и номенклатуры.
"""

import calendar
import logging
import os
from datetime import date, datetime, timedelta

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db

LAUNDRY_KINDS = ('wash', 'repair')
LAUNDRY_OPEN = ('accepted', 'ready')

_MAX_ITEM = 120
_MAX_NOTE = 300
_MAX_QUANTITY = 20
_MAX_WEAR_MONTHS = 120
_DUE_SOON = timedelta(days=30)
_SHOW_COLLECTED_FOR = timedelta(days=14)
_STAFF_TITLES = ('заведующ', 'начальник', 'специалист', 'машинист по стирке',
                 'кладовщик')


class WorkwearIssue(db.Model):
    __tablename__ = 'workwear_issues'
    __table_args__ = (db.Index('ix_workwear_issues_due', 'returned_on', 'due_on'),)
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    item = db.Column(db.String(_MAX_ITEM), nullable=False)
    size = db.Column(db.String(20))
    quantity = db.Column(db.Integer, nullable=False, default=1)
    issued_on = db.Column(db.Date, nullable=False)
    # Срок носки в месяцах; пусто — «до износа», без даты замены.
    wear_months = db.Column(db.Integer)
    due_on = db.Column(db.Date)
    # Сдано или списано: вещь больше за человеком не числится.
    returned_on = db.Column(db.Date)
    issued_by = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    note = db.Column(db.String(_MAX_NOTE))
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class WorkwearLaundry(db.Model):
    __tablename__ = 'workwear_laundry'
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    kind = db.Column(db.String(10), nullable=False)
    items = db.Column(db.String(_MAX_NOTE), nullable=False)
    note = db.Column(db.String(_MAX_NOTE))
    # accepted, ready, collected
    status = db.Column(db.String(10), nullable=False, default='accepted', index=True)
    accepted_by = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    accepted_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    ready_at = db.Column(db.DateTime)
    collected_at = db.Column(db.DateTime)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_workwear_staff(employee):
    if employee is None:
        return False
    return (('хозяйствен' in _norm(employee.department)
             and _norm(employee.job_title).startswith(_STAFF_TITLES))
            or employee.employee_id in _env_ids('WORKWEAR_STAFF'))


def add_months(day, months):
    """31 января + месяц — последний день февраля, а не ошибка."""
    month = day.month - 1 + months
    year, month = day.year + month // 12, month % 12 + 1
    return date(year, month, min(day.day, calendar.monthrange(year, month)[1]))


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
                'job_title': (emp.job_title or '') if emp else '',
                'department': (emp.department or '') if emp else ''}

    def _due_state(item, today):
        if item.returned_on is not None or item.due_on is None:
            return 'none'
        if item.due_on <= today:
            return 'overdue'
        if item.due_on - today <= _DUE_SOON:
            return 'soon'
        return 'ok'

    def _issue_json(item, today, people=None):
        data = {
            'id': item.id,
            'item': item.item,
            'size': item.size or '',
            'quantity': item.quantity,
            'issued_on': item.issued_on.isoformat(),
            'wear_months': item.wear_months,
            'due_on': item.due_on.isoformat() if item.due_on else None,
            'returned_on': item.returned_on.isoformat() if item.returned_on else None,
            'due': _due_state(item, today),
            'note': item.note or '',
        }
        if people is not None:
            data['employee'] = _person(people.get(item.employee_id), item.employee_id)
        return data

    def _laundry_json(row, people=None):
        data = {
            'id': row.id,
            'kind': row.kind,
            'items': row.items,
            'note': row.note or '',
            'status': row.status,
            'accepted_at': _utc(row.accepted_at),
            'ready_at': _utc(row.ready_at),
            'collected_at': _utc(row.collected_at),
        }
        if people is not None:
            data['employee'] = _person(people.get(row.employee_id), row.employee_id)
        return data

    def _cards(employee_id, today):
        issues = (WorkwearIssue.query.filter_by(employee_id=employee_id)
                  .filter(WorkwearIssue.returned_on.is_(None))
                  .order_by(WorkwearIssue.due_on.is_(None), WorkwearIssue.due_on,
                            WorkwearIssue.item).all())
        since = datetime.utcnow() - _SHOW_COLLECTED_FOR
        laundry = (WorkwearLaundry.query.filter_by(employee_id=employee_id)
                   .filter(db.or_(WorkwearLaundry.status.in_(LAUNDRY_OPEN),
                                  WorkwearLaundry.collected_at >= since))
                   .order_by(WorkwearLaundry.accepted_at.desc()).all())
        return ([_issue_json(i, today) for i in issues],
                [_laundry_json(r) for r in laundry])

    def _notify(ids, title, body, ref=None):
        ids = sorted({i for i in ids if i})
        if ids:
            core._record_notice('workwear', title[:200], body[:500],
                                employee_ids=ids, ref=ref)

    def _staff_only():
        viewer = _viewer()
        if viewer is None:
            return None, _fail('unauthorized', 401)
        if not is_workwear_staff(viewer):
            return None, core._deny()
        return viewer, None

    @app.route('/api/workwear', methods=['GET'])
    @core.require_auth
    def workwear_mine():
        """Мои вещи с датами замены и мои вещи в стирке или ремонте."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        issues, laundry = _cards(viewer.employee_id, core._plant_today())
        return jsonify({'message': 'Success', 'staff': is_workwear_staff(viewer),
                        'issues': issues, 'laundry': laundry})

    @app.route('/api/workwear/staff', methods=['GET'])
    @core.require_auth
    def workwear_staff():
        """Хозотделу: что лежит в стирке и ремонте и у кого выходит срок."""
        viewer, denied = _staff_only()
        if denied:
            return denied
        today = core._plant_today()
        laundry = (WorkwearLaundry.query
                   .filter(WorkwearLaundry.status.in_(LAUNDRY_OPEN))
                   .order_by(WorkwearLaundry.status, WorkwearLaundry.accepted_at)
                   .limit(300).all())
        due = (WorkwearIssue.query.filter(WorkwearIssue.returned_on.is_(None),
                                          WorkwearIssue.due_on.isnot(None),
                                          WorkwearIssue.due_on <= today + _DUE_SOON)
               .order_by(WorkwearIssue.due_on).limit(300).all())
        people = _names([r.employee_id for r in laundry] + [i.employee_id for i in due])
        return jsonify({
            'message': 'Success',
            'laundry': [_laundry_json(r, people) for r in laundry],
            'due': [_issue_json(i, today, people) for i in due],
        })

    @app.route('/api/workwear/people', methods=['GET'])
    @core.require_auth
    def workwear_people():
        viewer, denied = _staff_only()
        if denied:
            return denied
        q = _norm(request.args.get('q', ''))
        people = []
        for e in Employee.query.order_by(Employee.full_name):
            if not e.full_name:
                continue
            if q and q not in _norm(e.full_name) and q not in _norm(e.job_title) \
                    and q not in _norm(e.department):
                continue
            people.append(_person(e, e.employee_id))
            if len(people) >= 50:
                break
        return jsonify({'message': 'Success', 'people': people})

    @app.route('/api/workwear/employees/<employee_id>', methods=['GET'])
    @core.require_auth
    def workwear_employee(employee_id):
        """Хозотделу: карточка человека — что за ним числится."""
        viewer, denied = _staff_only()
        if denied:
            return denied
        employee = db.session.get(Employee, employee_id)
        if employee is None:
            return _fail('not_found', 404)
        issues, laundry = _cards(employee_id, core._plant_today())
        return jsonify({'message': 'Success',
                        'employee': _person(employee, employee_id),
                        'issues': issues, 'laundry': laundry})

    def _new_issue(data, employee_id, viewer, today):
        item = core._text(data, 'item')[:_MAX_ITEM]
        if not item:
            return None, 'item_required'
        quantity = data.get('quantity', 1)
        if isinstance(quantity, str) and quantity.strip().isdigit():
            quantity = int(quantity)
        if isinstance(quantity, bool) or not isinstance(quantity, int) \
                or not 1 <= quantity <= _MAX_QUANTITY:
            return None, 'bad_quantity'
        months = data.get('wear_months')
        if isinstance(months, str):
            months = int(months) if months.strip().isdigit() else (
                None if not months.strip() else 'bad')
        if months is not None and (isinstance(months, bool)
                                   or not isinstance(months, int)
                                   or not 1 <= months <= _MAX_WEAR_MONTHS):
            return None, 'bad_months'
        raw = core._text(data, 'issued_on')
        try:
            issued = date.fromisoformat(raw) if raw else today
        except ValueError:
            return None, 'bad_date'
        if issued > today or issued < today - timedelta(days=5 * 366):
            return None, 'bad_date'
        return WorkwearIssue(
            employee_id=employee_id, item=item,
            size=core._text(data, 'size')[:20] or None, quantity=quantity,
            issued_on=issued, wear_months=months,
            due_on=add_months(issued, months) if months else None,
            issued_by=viewer.employee_id,
            note=core._text(data, 'note')[:_MAX_NOTE] or None), None

    @app.route('/api/workwear/issues', methods=['POST'])
    @core.require_auth
    def workwear_issue():
        """`{"employee_id", "item", "size", "quantity", "issued_on",
        "wear_months", "note"}` — записать выдачу."""
        viewer, denied = _staff_only()
        if denied:
            return denied
        data = core._json_body()
        employee = db.session.get(Employee, core._text(data, 'employee_id'))
        if employee is None:
            return _fail('no_employee', 400)
        today = core._plant_today()
        issue, error = _new_issue(data, employee.employee_id, viewer, today)
        if error:
            return _fail(error, 400)
        db.session.add(issue)
        db.session.commit()
        logging.info('Спецодежда: %s выдано %s (%s)', issue.item,
                     employee.employee_id, viewer.employee_id)
        body = (f'Замена — {issue.due_on.strftime("%d.%m.%Y")}' if issue.due_on
                else 'Без срока замены')
        _notify([employee.employee_id], f'Выдано: {issue.item}', body)
        return jsonify({'message': 'Success', 'issue': _issue_json(issue, today)}), 201

    @app.route('/api/workwear/issues/<int:issue_id>', methods=['POST'])
    @core.require_auth
    def workwear_issue_action(issue_id):
        """`replace` — сдал старое, выдали такое же новое сегодня;
        `return` — сдал или списано, больше не числится."""
        viewer, denied = _staff_only()
        if denied:
            return denied
        issue = db.session.get(WorkwearIssue, issue_id)
        if issue is None:
            return _fail('not_found', 404)
        if issue.returned_on is not None:
            return _fail('returned', 409)
        action = core._text(core._json_body(), 'action')
        today = core._plant_today()
        if action not in ('replace', 'return'):
            return _fail('bad_action', 400)
        issue.returned_on = today
        fresh = None
        if action == 'replace':
            fresh = WorkwearIssue(
                employee_id=issue.employee_id, item=issue.item, size=issue.size,
                quantity=issue.quantity, issued_on=today,
                wear_months=issue.wear_months,
                due_on=add_months(today, issue.wear_months) if issue.wear_months else None,
                issued_by=viewer.employee_id)
            db.session.add(fresh)
        db.session.commit()
        if fresh is not None:
            body = (f'Замена — {fresh.due_on.strftime("%d.%m.%Y")}' if fresh.due_on
                    else 'Без срока замены')
            _notify([issue.employee_id], f'Заменено: {issue.item}', body)
        return jsonify({'message': 'Success',
                        'issue': _issue_json(fresh or issue, today)})

    @app.route('/api/workwear/remind-due', methods=['POST'])
    @core.require_auth
    def workwear_remind_due():
        """Разом напомнить всем, у кого срок замены вышел или выходит в месяц."""
        viewer, denied = _staff_only()
        if denied:
            return denied
        today = core._plant_today()
        due = WorkwearIssue.query.filter(WorkwearIssue.returned_on.is_(None),
                                         WorkwearIssue.due_on.isnot(None),
                                         WorkwearIssue.due_on <= today + _DUE_SOON).all()
        by_person = {}
        for item in due:
            by_person.setdefault(item.employee_id, []).append(item.item)
        for employee_id, items in by_person.items():
            _notify([employee_id], 'Подходит срок замены спецодежды',
                    'Подойдите в хозотдел: ' + ', '.join(sorted(set(items))))
        logging.info('Спецодежда: напоминание о замене %d сотрудникам (%s)',
                     len(by_person), viewer.employee_id)
        return jsonify({'message': 'Success', 'reminded': len(by_person)})

    @app.route('/api/workwear/laundry', methods=['POST'])
    @core.require_auth
    def workwear_laundry_accept():
        """`{"employee_id", "kind": "wash"|"repair", "items", "note"}` —
        принять вещи в стирку или ремонт."""
        viewer, denied = _staff_only()
        if denied:
            return denied
        data = core._json_body()
        employee = db.session.get(Employee, core._text(data, 'employee_id'))
        if employee is None:
            return _fail('no_employee', 400)
        kind = core._text(data, 'kind')
        if kind not in LAUNDRY_KINDS:
            return _fail('bad_kind', 400)
        items = core._text(data, 'items')[:_MAX_NOTE]
        if not items:
            return _fail('items_required', 400)
        row = WorkwearLaundry(employee_id=employee.employee_id, kind=kind,
                              items=items,
                              note=core._text(data, 'note')[:_MAX_NOTE] or None,
                              status='accepted', accepted_by=viewer.employee_id,
                              accepted_at=datetime.utcnow())
        db.session.add(row)
        db.session.commit()
        return jsonify({'message': 'Success', 'laundry': _laundry_json(row)}), 201

    @app.route('/api/workwear/laundry/<int:row_id>', methods=['POST'])
    @core.require_auth
    def workwear_laundry_action(row_id):
        """`ready` — готово, человеку «заберите»; `collected` — забрал."""
        viewer, denied = _staff_only()
        if denied:
            return denied
        row = db.session.get(WorkwearLaundry, row_id)
        if row is None:
            return _fail('not_found', 404)
        action = core._text(core._json_body(), 'action')
        now = datetime.utcnow()
        if action == 'ready':
            if row.status != 'accepted':
                return _fail('bad_state', 409)
            row.status = 'ready'
            row.ready_at = now
        elif action == 'collected':
            if row.status not in LAUNDRY_OPEN:
                return _fail('bad_state', 409)
            row.status = 'collected'
            row.collected_at = now
        else:
            return _fail('bad_action', 400)
        db.session.commit()
        if action == 'ready':
            what = 'из стирки' if row.kind == 'wash' else 'из ремонта'
            _notify([row.employee_id], f'Готово {what}, заберите в хозотделе',
                    row.items)
        people = _names([row.employee_id])
        return jsonify({'message': 'Success', 'laundry': _laundry_json(row, people)})
