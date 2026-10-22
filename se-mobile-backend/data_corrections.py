"""«Исправить мои данные»: сотрудник видит в приложении ошибку в ФИО,
должности или подразделении — и пишет в кадры прямо отсюда.

Сейчас с такой ошибкой идут в отдел кадров лично или не идут вовсе, и она
живёт годами: в приложении, в справочнике, в расчётном листке. Здесь у
просьбы есть что не так (с тем, что сейчас записано), как правильно и
ответ кадров: исправлено или почему нет.

Сами данные приложение не меняет: ФИО, должность и подразделение приходят
из учёта кадров при следующей загрузке, а от должности зависит, что человек
видит в приложении, — менять её одной кнопкой нельзя. Кадры исправляют у
себя и отмечают «Исправлено».

Видят просьбу только автор и кадры — ни руководитель, ни администратор
приложения. Кадры — «кадр» в должности, начальник административного
отдела или HR_STAFF.
"""

import logging
import os
from datetime import datetime, timedelta

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db

KINDS = ('name', 'job', 'department', 'contacts', 'documents', 'other')
KIND_TITLES = {'name': 'ФИО', 'job': 'должность', 'department': 'подразделение',
               'contacts': 'телефон или почта', 'documents': 'документы, адрес, семья',
               'other': 'другое'}
OPEN = ('new', 'in_work')

_MAX_TEXT = 1000
_MAX_OPEN_PER_AUTHOR = 5
_SHOW_CLOSED_FOR = timedelta(days=30)


class DataCorrection(db.Model):
    __tablename__ = 'data_corrections'
    __table_args__ = (db.Index('ix_data_corrections_status', 'status', 'created_at'),)
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    kind = db.Column(db.String(12), nullable=False)
    # Что записано сейчас — снимок на момент просьбы: после исправления
    # иначе не видно, что было не так.
    current = db.Column(db.String(300))
    requested = db.Column(db.Text, nullable=False)
    comment = db.Column(db.Text)
    # new → in_work (кадры взяли) → done | rejected; cancelled — автор передумал.
    status = db.Column(db.String(10), nullable=False, default='new')
    assignee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    resolution = db.Column(db.Text)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    closed_at = db.Column(db.DateTime)


class DataCorrectionEvent(db.Model):
    __tablename__ = 'data_correction_events'
    id = db.Column(db.Integer, primary_key=True)
    correction_id = db.Column(db.Integer,
                              db.ForeignKey('data_corrections.id', ondelete='CASCADE'),
                              nullable=False, index=True)
    actor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # created, take, done, reject, cancel, comment
    action = db.Column(db.String(10), nullable=False)
    comment = db.Column(db.Text)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_hr(employee):
    if employee is None:
        return False
    title = _norm(employee.job_title)
    return ('кадр' in title
            or ('административн' in _norm(employee.department)
                and title.startswith('начальник'))
            or employee.employee_id in _env_ids('HR_STAFF'))


def _current(employee, kind):
    return {'name': employee.full_name, 'job': employee.job_title,
            'department': employee.department}.get(kind) or ''


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
                'department': (emp.department or '') if emp else ''}

    def _json(item, people, viewer, hr, events=None):
        data = {
            'id': item.id,
            'kind': item.kind,
            'current': item.current or '',
            'requested': item.requested,
            'comment': item.comment or '',
            'status': item.status,
            'resolution': item.resolution or '',
            'author': _person(people.get(item.employee_id), item.employee_id),
            'assignee': _person(people.get(item.assignee_id), item.assignee_id),
            'created_at': _utc(item.created_at),
            'closed_at': _utc(item.closed_at),
            'is_author': viewer.employee_id == item.employee_id,
            'can_handle': bool(hr and item.status in OPEN),
        }
        if events is not None:
            data['events'] = [{
                'action': e.action,
                'comment': e.comment or '',
                'at': _utc(e.at),
                'actor': _person(people.get(e.actor_id), e.actor_id),
            } for e in events]
        return data

    def _list_json(items, viewer, hr):
        people = _names([i.employee_id for i in items] + [i.assignee_id for i in items])
        return [_json(i, people, viewer, hr) for i in items]

    def _detail(item, viewer, hr):
        events = (DataCorrectionEvent.query.filter_by(correction_id=item.id)
                  .order_by(DataCorrectionEvent.at, DataCorrectionEvent.id).all())
        people = _names([item.employee_id, item.assignee_id]
                        + [e.actor_id for e in events])
        return _json(item, people, viewer, hr, events)

    def _hr_ids():
        return [e.employee_id for e in Employee.query.all() if is_hr(e)]

    def _notify(ids, title, body, ref, actor_id=None):
        ids = sorted({i for i in ids if i and i != actor_id})
        if ids:
            core._record_notice('datafix', title[:200], body[:500],
                                employee_ids=ids, ref=ref)

    @app.route('/api/data-corrections', methods=['GET'])
    @core.require_auth
    def data_corrections_list():
        """Мои просьбы; кадрам — `?scope=queue`. С тем, что записано сейчас."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        hr = is_hr(viewer)
        if request.args.get('scope') == 'queue':
            if not hr:
                return core._deny()
            since = datetime.utcnow() - _SHOW_CLOSED_FOR
            items = (DataCorrection.query
                     .filter(db.or_(DataCorrection.status.in_(OPEN),
                                    DataCorrection.updated_at >= since))
                     .order_by(DataCorrection.created_at).limit(300).all())
            items.sort(key=lambda i: (i.status not in OPEN, i.status != 'new'))
        else:
            items = (DataCorrection.query.filter_by(employee_id=viewer.employee_id)
                     .order_by(DataCorrection.created_at.desc()).limit(50).all())
        body = {'message': 'Success', 'staff': hr,
                'profile': {'name': viewer.full_name, 'job': viewer.job_title,
                            'department': viewer.department or ''},
                'items': _list_json(items, viewer, hr)}
        if hr:
            body['waiting'] = DataCorrection.query.filter_by(status='new').count()
        return jsonify(body)

    @app.route('/api/data-corrections', methods=['POST'])
    @core.require_auth
    def data_corrections_create():
        """`{"kind", "requested": "как правильно", "comment"}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        data = core._json_body()
        kind = core._text(data, 'kind')
        if kind not in KINDS:
            return _fail('bad_kind', 400)
        requested = core._text(data, 'requested')[:_MAX_TEXT]
        if not requested:
            return _fail('requested_required', 400)
        current = _current(viewer, kind)
        if current and _norm(current) == _norm(requested):
            return _fail('same_as_current', 400)
        open_count = DataCorrection.query.filter(
            DataCorrection.employee_id == viewer.employee_id,
            DataCorrection.status.in_(OPEN)).count()
        if open_count >= _MAX_OPEN_PER_AUTHOR:
            return _fail('too_many_open', 429)
        now = datetime.utcnow()
        item = DataCorrection(employee_id=viewer.employee_id, kind=kind,
                              current=current[:300] or None, requested=requested,
                              comment=core._text(data, 'comment')[:_MAX_TEXT] or None,
                              status='new', created_at=now, updated_at=now)
        db.session.add(item)
        db.session.flush()
        db.session.add(DataCorrectionEvent(correction_id=item.id,
                                           actor_id=viewer.employee_id,
                                           action='created', at=now))
        db.session.commit()
        logging.info('Исправление данных №%s (%s) от %s', item.id, kind,
                     viewer.employee_id)
        # Что именно не так — только на экране просьбы, не в тексте
        # оповещения: там может быть номер удостоверения или адрес.
        _notify(_hr_ids(), f'Исправить данные: {KIND_TITLES[kind]}',
                viewer.full_name, item.id, viewer.employee_id)
        return jsonify({'message': 'Success',
                        'item': _detail(item, viewer, is_hr(viewer))}), 201

    def _load(item_id, viewer):
        item = db.session.get(DataCorrection, item_id)
        hr = is_hr(viewer)
        if item is None or not (hr or item.employee_id == viewer.employee_id):
            return None, hr
        return item, hr

    @app.route('/api/data-corrections/<int:item_id>', methods=['GET'])
    @core.require_auth
    def data_correction_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item, hr = _load(item_id, viewer)
        if item is None:
            return _fail('not_found', 404)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer, hr)})

    @app.route('/api/data-corrections/<int:item_id>', methods=['POST'])
    @core.require_auth
    def data_correction_action(item_id):
        """Кадры: take, done, reject (с причиной). Автор: cancel, пока не
        взяли. Обоим: comment."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item, hr = _load(item_id, viewer)
        if item is None:
            return _fail('not_found', 404)
        is_author = item.employee_id == viewer.employee_id
        data = core._json_body()
        action = core._text(data, 'action')
        text = core._text(data, 'text')[:_MAX_TEXT]
        if item.status not in OPEN:
            return _fail('closed', 409)
        if action in ('take', 'done', 'reject') and not hr:
            return core._deny()
        if action == 'cancel' and not is_author:
            return core._deny()

        now = datetime.utcnow()
        label = f'№{item.id} ({KIND_TITLES[item.kind]})'
        notify = None
        if action == 'take':
            if item.assignee_id == viewer.employee_id:
                return _fail('already_yours', 409)
            item.assignee_id = viewer.employee_id
            item.status = 'in_work'
            notify = ([item.employee_id], f'Кадры взяли просьбу {label}',
                      viewer.full_name)
        elif action == 'done':
            item.status = 'done'
            item.resolution = text or None
            item.closed_at = now
            item.assignee_id = item.assignee_id or viewer.employee_id
            notify = ([item.employee_id], f'Данные исправлены: {label}',
                      text or 'В приложении — после следующей загрузки из учёта кадров')
        elif action == 'reject':
            if not text:
                return _fail('text_required', 400)
            item.status = 'rejected'
            item.resolution = text
            item.closed_at = now
            item.assignee_id = item.assignee_id or viewer.employee_id
            notify = ([item.employee_id], f'Кадры не исправили {label}', text)
        elif action == 'cancel':
            if item.status != 'new':
                return _fail('bad_state', 409)
            item.status = 'cancelled'
            item.closed_at = now
        elif action == 'comment':
            if not text:
                return _fail('text_required', 400)
            if hr and not is_author:
                targets = [item.employee_id]
            else:
                targets = [item.assignee_id] if item.assignee_id else _hr_ids()
            notify = (targets, f'Комментарий к просьбе {label}', viewer.full_name)
        else:
            return _fail('bad_action', 400)

        item.updated_at = now
        db.session.add(DataCorrectionEvent(correction_id=item.id,
                                           actor_id=viewer.employee_id,
                                           action=action, comment=text or None, at=now))
        db.session.commit()
        logging.info('Исправление данных №%s: %s (%s)', item.id, action,
                     viewer.employee_id)
        if notify:
            _notify(notify[0], notify[1], notify[2], item.id, viewer.employee_id)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer, hr)})
