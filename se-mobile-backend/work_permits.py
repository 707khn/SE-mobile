"""Наряд-допуск на опасные работы: огневые, на высоте, в электроустановках,
газоопасные, в ёмкостях, земляные.

Сейчас наряд — бумажный бланк: его выписывают, несут на подпись в БиОТ,
допускающий расписывается на месте, а кто сейчас где варит, знает только
тот, у кого в руках бланк. Здесь у наряда есть место, время, люди и меры
безопасности; БиОТ согласует с телефона, допускающий отмечает, что меры
выполнены, и на доске «Сейчас идут» видно все открытые наряды предприятия.

Путь: выдающий выписывает (pending) → БиОТ согласует (approved) или
возвращает → допускающий проверяет меры и допускает (open) → производитель
работ или ответственный закрывает (closed). БиОТ может остановить работы
(stopped). Бумажный бланк с подписями это не отменяет — приложение
показывает, что происходит, а не заменяет журнал.

Бригада — просто список фамилий: у слесарей и сварщиков чаще всего нет
учётной записи в приложении.
"""

import json
import logging
import os
from datetime import datetime, timedelta

from flask import g, jsonify, request

from hazards import is_safety
from it_requests import _norm, _utc
from models import db

KINDS = ('fire', 'height', 'electrical', 'gas', 'confined', 'earth', 'other')
KIND_TITLES = {'fire': 'огневые работы', 'height': 'работы на высоте',
               'electrical': 'работы в электроустановках',
               'gas': 'газоопасные работы', 'confined': 'работы в ёмкости',
               'earth': 'земляные работы', 'other': 'опасные работы'}

# Что предложить в мерах безопасности по виду работ. Выдающий правит
# список сам — это подсказка, а не норматив.
DEFAULT_MEASURES = {
    'fire': ['Убрать горючие материалы из зоны работ',
             'Поставить первичные средства пожаротушения',
             'Закрыть сгораемые конструкции негорючими экранами',
             'После окончания проверить место работ на тление'],
    'height': ['Оградить место работ и опасную зону внизу',
               'Проверить страховочные системы',
               'Проверить леса, подмости и лестницы'],
    'electrical': ['Отключить и вывесить плакаты «Не включать»',
                   'Проверить отсутствие напряжения',
                   'Установить заземление',
                   'Оградить части, оставшиеся под напряжением'],
    'gas': ['Отключить и заглушить трубопроводы',
            'Проверить воздух на загазованность',
            'Выдать противогазы и спасательные пояса',
            'Назначить наблюдающего'],
    'confined': ['Проветрить и проверить воздух',
                 'Назначить наблюдающего у входа',
                 'Подготовить средства спасения',
                 'Безопасное освещение'],
    'earth': ['Согласовать с владельцами подземных коммуникаций',
              'Оградить котлован или траншею',
              'Укрепить стенки'],
    'other': [],
}

OPEN = ('pending', 'approved', 'open')
CLOSED = ('closed', 'rejected', 'cancelled', 'stopped')

_MAX_PLACE = 200
_MAX_TEXT = 2000
_MAX_MEMBERS = 20
_MAX_MEASURES = 20
_MAX_SPAN = timedelta(days=15)
_SHOW_CLOSED_FOR = timedelta(days=14)

_ISSUER_TITLES = ('мастер', 'начальник', 'заведующ', 'главный', 'энергетик',
                  'механик', 'руководител', 'инженер')


class WorkPermit(db.Model):
    __tablename__ = 'work_permits'
    __table_args__ = (db.Index('ix_work_permits_status', 'status', 'starts_at'),)
    id = db.Column(db.Integer, primary_key=True)
    kind = db.Column(db.String(12), nullable=False)
    place = db.Column(db.String(_MAX_PLACE), nullable=False)
    work = db.Column(db.Text, nullable=False)
    # Время предприятия, без пояса — как отметки проходной.
    starts_at = db.Column(db.DateTime, nullable=False)
    ends_at = db.Column(db.DateTime, nullable=False)
    issuer_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                          nullable=False, index=True)
    responsible_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                               nullable=False)
    performer_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                             nullable=False, index=True)
    admitter_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # Бригада — фамилии строками; меры — JSON-список строк.
    members = db.Column(db.Text)
    measures = db.Column(db.Text)
    status = db.Column(db.String(10), nullable=False, default='pending')
    approver_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    reason = db.Column(db.Text)
    opened_at = db.Column(db.DateTime)
    closed_at = db.Column(db.DateTime)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class WorkPermitEvent(db.Model):
    __tablename__ = 'work_permit_events'
    id = db.Column(db.Integer, primary_key=True)
    permit_id = db.Column(db.Integer,
                          db.ForeignKey('work_permits.id', ondelete='CASCADE'),
                          nullable=False, index=True)
    actor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # created, approve, reject, admit, close, stop, cancel, comment
    action = db.Column(db.String(10), nullable=False)
    comment = db.Column(db.Text)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_issuer(employee, core):
    if employee is None:
        return False
    title = _norm(employee.job_title)
    return (core._is_admin_role(employee.job_title)
            or any(key in title for key in _ISSUER_TITLES)
            or employee.employee_id in _env_ids('PERMIT_ISSUERS'))


def sees_board(employee, core):
    """Доска «Сейчас идут»: БиОТ, руководство, СБ, главный инженер."""
    if employee is None:
        return False
    dept = _norm(employee.department)
    return (is_safety(employee) or core._is_system_admin(employee.job_title)
            or dept == 'руководство' or '(сб)' in dept
            or _norm(employee.job_title) == 'главный инженер')


def _list(raw):
    try:
        value = json.loads(raw) if raw else []
    except ValueError:
        value = []
    return [v for v in value if isinstance(v, str)]


def _lines(value, limit, width):
    if isinstance(value, str):
        value = value.splitlines()
    if not isinstance(value, list):
        return []
    out = []
    for item in value:
        if isinstance(item, str) and ' '.join(item.split()):
            out.append(' '.join(item.split())[:width])
    return out[:limit]


def _local(raw):
    """«2030-01-15T08:00» — время предприятия."""
    if not isinstance(raw, str):
        return None
    try:
        moment = datetime.fromisoformat(raw.strip())
    except ValueError:
        return None
    return moment.replace(tzinfo=None, second=0, microsecond=0)


def _local_iso(moment):
    return moment.strftime('%Y-%m-%dT%H:%M') if moment else None


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

    def _participants(item):
        return {i for i in (item.issuer_id, item.responsible_id,
                            item.performer_id, item.admitter_id) if i}

    def _may_see(viewer, item):
        return (viewer.employee_id in _participants(item) or is_safety(viewer)
                or sees_board(viewer, core))

    def _admits(viewer, item):
        return viewer.employee_id == (item.admitter_id or item.responsible_id)

    def _json(item, people, viewer, now, events=None):
        me = viewer.employee_id
        safety = is_safety(viewer)
        data = {
            'id': item.id,
            'kind': item.kind,
            'place': item.place,
            'work': item.work,
            'starts_at': _local_iso(item.starts_at),
            'ends_at': _local_iso(item.ends_at),
            'members': _lines(item.members or '', _MAX_MEMBERS, 100),
            'measures': _list(item.measures),
            'status': item.status,
            'reason': item.reason or '',
            'overdue': item.status == 'open' and now > item.ends_at,
            'expired': item.status in ('pending', 'approved') and now > item.ends_at,
            'issuer': _person(people.get(item.issuer_id), item.issuer_id),
            'responsible': _person(people.get(item.responsible_id), item.responsible_id),
            'performer': _person(people.get(item.performer_id), item.performer_id),
            'admitter': _person(people.get(item.admitter_id), item.admitter_id),
            'approver': _person(people.get(item.approver_id), item.approver_id),
            'opened_at': _utc(item.opened_at),
            'closed_at': _utc(item.closed_at),
            'created_at': _utc(item.created_at),
            'can_approve': safety and item.status == 'pending',
            'can_admit': _admits(viewer, item) and item.status == 'approved',
            'can_close': item.status == 'open' and me in (item.performer_id,
                                                          item.responsible_id),
            'can_stop': safety and item.status == 'open',
            'can_cancel': me == item.issuer_id and item.status in ('pending', 'approved'),
            'can_comment': item.status in OPEN and (me in _participants(item) or safety),
        }
        if events is not None:
            data['events'] = [{
                'action': e.action,
                'comment': e.comment or '',
                'at': _utc(e.at),
                'actor': _person(people.get(e.actor_id), e.actor_id),
            } for e in events]
        return data

    def _people_of(items):
        ids = []
        for i in items:
            ids += [i.issuer_id, i.responsible_id, i.performer_id, i.admitter_id,
                    i.approver_id]
        return _names(ids)

    def _list_json(items, viewer):
        people = _people_of(items)
        now = core._plant_now()
        return [_json(i, people, viewer, now) for i in items]

    def _detail(item, viewer):
        events = (WorkPermitEvent.query.filter_by(permit_id=item.id)
                  .order_by(WorkPermitEvent.at, WorkPermitEvent.id).all())
        people = _people_of([item])
        people.update(_names([e.actor_id for e in events]))
        return _json(item, people, viewer, core._plant_now(), events)

    def _safety_ids():
        return [e.employee_id for e in Employee.query.all() if is_safety(e)]

    def _notify(ids, title, body, ref, actor_id=None):
        ids = sorted({i for i in ids if i and i != actor_id})
        if ids:
            core._record_notice('permit', title[:200], body[:500],
                                employee_ids=ids, ref=ref)

    @app.route('/api/permits', methods=['GET'])
    @core.require_auth
    def permits_list():
        """Мои (выписал, отвечаю, работаю, допускаю); `?scope=board` — что
        согласовано и идёт; `?scope=queue` — ждёт БиОТ."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        scope = request.args.get('scope')
        me = viewer.employee_id
        if scope == 'board':
            if not sees_board(viewer, core):
                return core._deny()
            items = (WorkPermit.query
                     .filter(WorkPermit.status.in_(('approved', 'open')))
                     .order_by(WorkPermit.starts_at).limit(200).all())
            items.sort(key=lambda i: i.status != 'open')
        elif scope == 'queue':
            if not is_safety(viewer):
                return core._deny()
            items = (WorkPermit.query.filter_by(status='pending')
                     .order_by(WorkPermit.starts_at).limit(200).all())
        else:
            since = datetime.utcnow() - _SHOW_CLOSED_FOR
            items = (WorkPermit.query
                     .filter(db.or_(WorkPermit.issuer_id == me,
                                    WorkPermit.responsible_id == me,
                                    WorkPermit.performer_id == me,
                                    WorkPermit.admitter_id == me))
                     .filter(db.or_(WorkPermit.status.in_(OPEN),
                                    WorkPermit.updated_at >= since))
                     .order_by(WorkPermit.starts_at.desc()).limit(100).all())
        body = {'message': 'Success',
                'can_issue': is_issuer(viewer, core),
                'safety': is_safety(viewer),
                'board': sees_board(viewer, core),
                'measures': DEFAULT_MEASURES,
                'items': _list_json(items, viewer)}
        if is_safety(viewer):
            body['waiting'] = WorkPermit.query.filter_by(status='pending').count()
        return jsonify(body)

    @app.route('/api/permits/people', methods=['GET'])
    @core.require_auth
    def permits_people():
        """Кого вписать в наряд: `?q=` — часть ФИО или должности."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not is_issuer(viewer, core):
            return core._deny()
        q = _norm(request.args.get('q', ''))
        people = []
        for e in Employee.query.order_by(Employee.full_name):
            if not e.full_name:
                continue
            if q and q not in _norm(e.full_name) and q not in _norm(e.job_title):
                continue
            people.append(_person(e, e.employee_id))
            if len(people) >= 50:
                break
        return jsonify({'message': 'Success', 'people': people})

    @app.route('/api/permits', methods=['POST'])
    @core.require_auth
    def permits_create():
        """`{"kind", "place", "work", "starts_at", "ends_at", "performer_id",
        "responsible_id", "admitter_id", "members": [...], "measures": [...]}`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not is_issuer(viewer, core):
            return core._deny()
        data = core._json_body()
        kind = core._text(data, 'kind')
        if kind not in KINDS:
            return _fail('bad_kind', 400)
        place = ' '.join(core._text(data, 'place').split())[:_MAX_PLACE]
        if not place:
            return _fail('place_required', 400)
        work = core._text(data, 'work')[:_MAX_TEXT]
        if not work:
            return _fail('work_required', 400)
        starts, ends = _local(data.get('starts_at')), _local(data.get('ends_at'))
        if starts is None or ends is None or ends <= starts:
            return _fail('bad_time', 400)
        if ends - starts > _MAX_SPAN:
            return _fail('too_long', 400)
        if ends <= core._plant_now():
            return _fail('in_past', 400)
        ids = {}
        for field in ('performer_id', 'responsible_id', 'admitter_id'):
            value = core._text(data, field)
            if value and db.session.get(Employee, value) is None:
                return _fail('unknown_person', 400)
            ids[field] = value or None
        if not ids['performer_id']:
            return _fail('performer_required', 400)
        measures = _lines(data.get('measures'), _MAX_MEASURES, 200)
        if not measures and DEFAULT_MEASURES[kind]:
            return _fail('measures_required', 400)
        now = datetime.utcnow()
        item = WorkPermit(kind=kind, place=place, work=work, starts_at=starts,
                          ends_at=ends, issuer_id=viewer.employee_id,
                          responsible_id=ids['responsible_id'] or viewer.employee_id,
                          performer_id=ids['performer_id'],
                          admitter_id=ids['admitter_id'],
                          members='\n'.join(_lines(data.get('members'),
                                                   _MAX_MEMBERS, 100)) or None,
                          measures=json.dumps(measures, ensure_ascii=False),
                          status='pending', created_at=now, updated_at=now)
        db.session.add(item)
        db.session.flush()
        db.session.add(WorkPermitEvent(permit_id=item.id, actor_id=viewer.employee_id,
                                       action='created', at=now))
        db.session.commit()
        logging.info('Наряд-допуск №%s (%s) от %s', item.id, kind, viewer.employee_id)
        when = item.starts_at.strftime('%d.%m %H:%M')
        _notify(_safety_ids(),
                f'Наряд №{item.id} на согласование: {KIND_TITLES[kind]}',
                f'{place}, с {when}. Выдал {viewer.full_name}', item.id,
                viewer.employee_id)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer)}), 201

    @app.route('/api/permits/<int:item_id>', methods=['GET'])
    @core.require_auth
    def permit_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(WorkPermit, item_id)
        if item is None or not _may_see(viewer, item):
            return _fail('not_found', 404)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer)})

    @app.route('/api/permits/<int:item_id>', methods=['POST'])
    @core.require_auth
    def permit_action(item_id):
        """БиОТ: approve, reject, stop. Допускающий: admit. Производитель или
        ответственный: close. Выдавший: cancel. Участникам и БиОТ: comment."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(WorkPermit, item_id)
        if item is None or not _may_see(viewer, item):
            return _fail('not_found', 404)
        data = core._json_body()
        action = core._text(data, 'action')
        text = core._text(data, 'text')[:_MAX_TEXT]
        if item.status in CLOSED:
            return _fail('closed', 409)
        state = _json(item, {}, viewer, core._plant_now())
        allowed = {'approve': state['can_approve'], 'reject': state['can_approve'],
                   'admit': state['can_admit'], 'close': state['can_close'],
                   'stop': state['can_stop'], 'cancel': state['can_cancel'],
                   'comment': state['can_comment']}
        if action not in allowed:
            return _fail('bad_action', 400)
        if not allowed[action]:
            return core._deny()
        if action in ('reject', 'stop', 'comment') and not text:
            return _fail('text_required', 400)
        if action == 'admit' and core._plant_now() > item.ends_at:
            return _fail('expired', 409)

        now = datetime.utcnow()
        label = f'Наряд №{item.id} ({item.place})'
        crew = _participants(item)
        notify = None
        if action == 'approve':
            item.status = 'approved'
            item.approver_id = viewer.employee_id
            notify = (crew, f'{label} согласован БиОТ',
                      text or viewer.full_name)
        elif action == 'reject':
            item.status = 'rejected'
            item.approver_id = viewer.employee_id
            item.reason = text
            item.closed_at = now
            notify = ([item.issuer_id], f'{label} не согласован', text)
        elif action == 'admit':
            item.status = 'open'
            item.opened_at = now
            notify = (crew | set(_safety_ids()), f'{label}: допуск, работы начаты',
                      f'{KIND_TITLES[item.kind]}. Допустил {viewer.full_name}')
        elif action == 'close':
            item.status = 'closed'
            item.closed_at = now
            notify = ({item.issuer_id, item.responsible_id} | set(_safety_ids()),
                      f'{label}: работы окончены', text or viewer.full_name)
        elif action == 'stop':
            item.status = 'stopped'
            item.reason = text
            item.closed_at = now
            notify = (crew, f'{label}: работы остановлены БиОТ', text)
        elif action == 'cancel':
            item.status = 'cancelled'
            item.closed_at = now
            notify = (crew | ({item.approver_id} if item.approver_id else set()),
                      f'{label} отменён', viewer.full_name)
        elif action == 'comment':
            others = crew | ({item.approver_id} if item.approver_id else set())
            if not item.approver_id:
                others |= set(_safety_ids())
            notify = (others, f'Комментарий: {label}', f'{viewer.full_name}: {text}')

        item.updated_at = now
        db.session.add(WorkPermitEvent(permit_id=item.id, actor_id=viewer.employee_id,
                                       action=action, comment=text or None, at=now))
        db.session.commit()
        logging.info('Наряд-допуск №%s: %s (%s)', item.id, action, viewer.employee_id)
        if notify:
            _notify(notify[0], notify[1], notify[2], item.id, viewer.employee_id)
        return jsonify({'message': 'Success', 'item': _detail(item, viewer)})
