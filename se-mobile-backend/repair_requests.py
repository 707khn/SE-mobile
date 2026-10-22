"""Заявки на ремонт: «стоит токарный станок на участке 3», «течёт кран в
каб. 214».

Сейчас такое идёт звонком в электроцех или завхозу, а мастер, у которого
стоит станок, через час звонит ещё раз — уже другому. Здесь у заявки есть
номер, место, описание и фото, а у автора на экране — что с ней.

Заявку разбирают две службы, и куда она уйдёт, решает то, что сломалось:
станок, электрика — Служба главного инженера (главный энергетик, электроцех);
помещение, сантехника, мебель, машина — хозяйственный отдел и строительный
участок. Человеку не нужно знать, кто у нас за что отвечает: он выбирает,
что сломалось, и заявка приходит тем, кому надо.

Для оборудования есть отметка «стоит». Такие идут в очереди первыми, а по
закрытым считается простой: главный инженер видит, какой станок за три
месяца стоял дольше всех.

Устроено как заявки в ОИТиС (it_requests.py) и по тем же причинам —
отдельный модуль, общие вещи берутся через `core`. Схема своя: у ремонта
другие исполнители, место вместо кабинета, оборудование и простой.
"""

import logging
import os
from datetime import datetime, timedelta

from flask import Response, g, jsonify, request

from it_requests import _image_type, _norm, _utc
from models import db


# Что сломалось. По этому списку заявка и находит свою службу.
CATEGORIES = ('equipment', 'electric', 'building', 'plumbing', 'furniture',
              'vehicle', 'other')

# Кто чинит. Станки и электрика — служба главного инженера, остальное —
# хозяйственный отдел со строительным участком; механик — тоже в ХО.
ENGINEER, FACILITY = 'engineer', 'facility'
_GROUP_OF = {
    'equipment': ENGINEER, 'electric': ENGINEER,
    'building': FACILITY, 'plumbing': FACILITY, 'furniture': FACILITY,
    'vehicle': FACILITY, 'other': FACILITY,
}

_CATEGORY_RU = {
    'equipment': 'Оборудование', 'electric': 'Электрика',
    'building': 'Помещение', 'plumbing': 'Сантехника, отопление',
    'furniture': 'Мебель', 'vehicle': 'Автомобиль', 'other': 'Другое',
}

# «Стоит» имеет смысл только там, где из-за поломки встаёт работа.
_CAN_STOP = ('equipment', 'electric', 'vehicle')

STATUSES = ('new', 'in_progress', 'done', 'rejected', 'cancelled')
OPEN_STATUSES = ('new', 'in_progress')

_MAX_PHOTOS = 3
_MAX_PHOTO_BYTES = 4 * 1024 * 1024
_MAX_DESCRIPTION = 2000
_MAX_COMMENT = 1000

_MAX_OPEN_PER_AUTHOR = 10
_MAX_PER_AUTHOR_PER_DAY = 20

_QUEUE_CLOSED_FOR = timedelta(days=30)
_REOPEN_WITHIN = timedelta(days=14)
_PHOTOS_KEPT_AFTER_CLOSE = timedelta(days=180)

# За какой срок считать, что ломается чаще всего.
_STATS_FOR = timedelta(days=90)
_STATS_TOP = 5


class RepairRequest(db.Model):
    __tablename__ = 'repair_requests'
    __table_args__ = (
        db.Index('ix_repair_requests_author', 'employee_id', 'created_at'),
        db.Index('ix_repair_requests_status', 'status', 'updated_at'),
    )
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False)
    category = db.Column(db.String(20), nullable=False, default='other')
    # Кому: engineer или facility. Хранится, а не выводится из категории
    # каждый раз: служба может передать заявку другой, не меняя, что сломалось.
    service = db.Column(db.String(20), nullable=False, default=FACILITY)
    # Где: цех, участок, кабинет — как скажет человек.
    place = db.Column(db.String(100), nullable=False)
    # Какой станок: название или инвентарный номер. По нему считается, что
    # ломается чаще всего, поэтому отдельно от описания.
    equipment = db.Column(db.String(100))
    description = db.Column(db.Text, nullable=False)
    phone = db.Column(db.String(50))
    # Работа стоит, пока не починят.
    stopped = db.Column(db.Boolean, nullable=False, default=False)
    status = db.Column(db.String(20), nullable=False, default='new')
    assignee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    resolution = db.Column(db.Text)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    closed_at = db.Column(db.DateTime)


class RepairRequestPhoto(db.Model):
    """Снимок к заявке — в базе, по тем же причинам, что у ОИТиС."""
    __tablename__ = 'repair_request_photos'
    id = db.Column(db.Integer, primary_key=True)
    request_id = db.Column(db.Integer,
                           db.ForeignKey('repair_requests.id', ondelete='CASCADE'),
                           nullable=False, index=True)
    mime = db.Column(db.String(30), nullable=False)
    data = db.Column(db.LargeBinary, nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class RepairRequestEvent(db.Model):
    """Строка истории: кто, когда и что сделал с заявкой."""
    __tablename__ = 'repair_request_events'
    id = db.Column(db.Integer, primary_key=True)
    request_id = db.Column(db.Integer,
                           db.ForeignKey('repair_requests.id', ondelete='CASCADE'),
                           nullable=False, index=True)
    actor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # created, take, done, reject, cancel, reopen, comment, forward
    action = db.Column(db.String(20), nullable=False)
    comment = db.Column(db.Text)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _extra_staff(group):
    """Табельные номера сверх подразделения: REPAIR_ENGINEER_STAFF и
    REPAIR_FACILITY_STAFF, через запятую. Например, электрик, который по
    штату числится в основном производстве.
    """
    name = 'REPAIR_ENGINEER_STAFF' if group == ENGINEER else 'REPAIR_FACILITY_STAFF'
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def group_of_department(department):
    dept = _norm(department)
    if 'главного инженера' in dept:
        return ENGINEER
    if 'хозяйственный' in dept or 'строительный участок' in dept:
        return FACILITY
    return None


def staff_groups(employee):
    """Какие службы человек представляет: пусто, если никакие."""
    if employee is None:
        return set()
    groups = set()
    own = group_of_department(employee.department)
    if own:
        groups.add(own)
    for group in (ENGINEER, FACILITY):
        if employee.employee_id in _extra_staff(group):
            groups.add(group)
    return groups


def photos_allowed():
    """REPAIR_PHOTOS=0 отключает фото: снимать на территории можно не везде,
    и решает это режим, а не приложение."""
    return os.environ.get('REPAIR_PHOTOS', '1').strip() not in ('0', 'false', 'no')


def register(app, core):
    """Подключает маршруты заявок на ремонт. `core` — модуль app.py."""
    from models import Employee

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _groups(viewer):
        """Службы, чью очередь человек видит. Администратор — обе."""
        if core._is_system_admin(viewer.job_title):
            return {ENGINEER, FACILITY}
        return staff_groups(viewer)

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

    def _staff_ids(group):
        extra = _extra_staff(group)
        return sorted(e.employee_id for e in Employee.query.all()
                      if group_of_department(e.department) == group
                      or e.employee_id in extra)

    def _downtime_hours(item):
        """Сколько стояло: от заявки до «выполнено». Пока не починили — до сейчас."""
        if not item.stopped:
            return None
        end = item.closed_at if item.status == 'done' else None
        if item.status in OPEN_STATUSES:
            end = datetime.utcnow()
        if end is None:
            return None
        return round((end - item.created_at).total_seconds() / 3600, 1)

    def _json(item, people, photos=None, events=None):
        data = {
            'id': item.id,
            'category': item.category,
            'service': item.service,
            'place': item.place,
            'equipment': item.equipment or '',
            'description': item.description,
            'phone': item.phone or '',
            'stopped': bool(item.stopped),
            'downtime_hours': _downtime_hours(item),
            'status': item.status,
            'author': _person(people.get(item.employee_id), item.employee_id),
            'assignee': _person(people.get(item.assignee_id), item.assignee_id),
            'resolution': item.resolution or '',
            'created_at': _utc(item.created_at),
            'updated_at': _utc(item.updated_at),
            'closed_at': _utc(item.closed_at),
        }
        if photos is not None:
            data['photos'] = photos
        if events is not None:
            data['events'] = [{
                'action': e.action,
                'comment': e.comment or '',
                'at': _utc(e.at),
                'actor': _person(people.get(e.actor_id), e.actor_id),
            } for e in events]
        return data

    def _photo_counts(ids):
        if not ids:
            return {}
        rows = (db.session.query(RepairRequestPhoto.request_id,
                                 db.func.count(RepairRequestPhoto.id))
                .filter(RepairRequestPhoto.request_id.in_(ids))
                .group_by(RepairRequestPhoto.request_id))
        return dict(rows)

    def _list_json(items):
        people = _names([i.employee_id for i in items]
                        + [i.assignee_id for i in items])
        counts = _photo_counts([i.id for i in items])
        out = []
        for item in items:
            data = _json(item, people)
            data['photo_count'] = counts.get(item.id, 0)
            out.append(data)
        return out

    def _is_staff_for(viewer, item):
        return item.service in _groups(viewer)

    def _may_see(viewer, item):
        return viewer.employee_id == item.employee_id or _is_staff_for(viewer, item)

    def _notify(employee_ids, title, body, item_id, actor_id=None):
        """В ленту оповещений приложения, без самого действующего."""
        ids = sorted({e for e in employee_ids if e and e != actor_id})
        if not ids:
            return
        core._record_notice('repair', title, body, employee_ids=ids, ref=item_id)

    def _forget_old_photos():
        cutoff = datetime.utcnow() - _PHOTOS_KEPT_AFTER_CLOSE
        stale = db.session.query(RepairRequest.id).filter(
            RepairRequest.closed_at.isnot(None), RepairRequest.closed_at < cutoff)
        RepairRequestPhoto.query.filter(
            RepairRequestPhoto.request_id.in_(stale)
        ).delete(synchronize_session=False)

    def _stats(groups):
        """Что за три месяца ломалось чаще и стояло дольше — по оборудованию.

        Без названия оборудования заявка в счёт не идёт: «станок» без номера
        ни с чем не сложить.
        """
        since = datetime.utcnow() - _STATS_FOR
        rows = (RepairRequest.query
                .filter(RepairRequest.service.in_(groups),
                        RepairRequest.created_at >= since,
                        RepairRequest.equipment.isnot(None),
                        RepairRequest.status != 'cancelled')
                .all())
        tally = {}
        for item in rows:
            key = _norm(item.equipment)
            if not key:
                continue
            entry = tally.setdefault(key, {'equipment': item.equipment.strip(),
                                           'count': 0, 'downtime_hours': 0.0})
            entry['count'] += 1
            entry['downtime_hours'] += _downtime_hours(item) or 0.0
        top = sorted(tally.values(),
                     key=lambda e: (-e['downtime_hours'], -e['count'],
                                    e['equipment']))
        for entry in top:
            entry['downtime_hours'] = round(entry['downtime_hours'], 1)
        return [e for e in top if e['count'] > 1 or e['downtime_hours'] > 0][:_STATS_TOP]

    @app.route('/api/repair-requests', methods=['GET'])
    @core.require_auth
    def repair_requests_list():
        """Мои заявки или, для служб, очередь: `?scope=queue`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        groups = _groups(viewer)

        if request.args.get('scope') == 'queue':
            if not groups:
                return core._deny()
            since = datetime.utcnow() - _QUEUE_CLOSED_FOR
            items = (RepairRequest.query
                     .filter(RepairRequest.service.in_(groups))
                     .filter(db.or_(RepairRequest.status.in_(OPEN_STATUSES),
                                    RepairRequest.updated_at >= since))
                     .order_by(RepairRequest.created_at.desc())
                     .limit(300).all())
            # Стоящее оборудование — наверх, пока его не починили.
            items.sort(key=lambda i: not (i.stopped and i.status in OPEN_STATUSES))
        else:
            items = (RepairRequest.query
                     .filter_by(employee_id=viewer.employee_id)
                     .order_by(RepairRequest.created_at.desc())
                     .limit(100).all())

        body = {'message': 'Success', 'staff': bool(groups),
                'services': sorted(groups),
                'photos_allowed': photos_allowed(),
                'items': _list_json(items)}
        if groups:
            open_q = RepairRequest.query.filter(
                RepairRequest.service.in_(groups),
                RepairRequest.status.in_(OPEN_STATUSES))
            counts = dict(db.session.query(RepairRequest.status,
                                           db.func.count(RepairRequest.id))
                          .filter(RepairRequest.service.in_(groups),
                                  RepairRequest.status.in_(OPEN_STATUSES))
                          .group_by(RepairRequest.status))
            body['open'] = {s: counts.get(s, 0) for s in OPEN_STATUSES}
            body['open']['stopped'] = open_q.filter(
                RepairRequest.stopped.is_(True)).count()
            if request.args.get('scope') == 'queue':
                body['top_equipment'] = _stats(groups)
        return jsonify(body)

    @app.route('/api/repair-requests', methods=['POST'])
    @core.require_auth
    def repair_requests_create():
        """Новая заявка: multipart с полями и до трёх фото `photo`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)

        data = request.form if request.form or request.files else core._json_body()

        def field(key):
            value = data.get(key)
            return value.strip() if isinstance(value, str) else ''

        category = field('category') or 'other'
        if category not in CATEGORIES:
            return _fail('bad_category', 400)
        place = field('place')
        if not place:
            return _fail('place_required', 400)
        description = field('description')
        if len(description) < 3:
            return _fail('description_required', 400)
        if len(description) > _MAX_DESCRIPTION:
            return _fail('description_too_long', 400)
        raw_stopped = data.get('stopped')
        stopped = (raw_stopped is True
                   or (isinstance(raw_stopped, str)
                       and raw_stopped.strip().lower() in ('1', 'true', 'yes')))
        stopped = stopped and category in _CAN_STOP

        photos = request.files.getlist('photo')
        if photos and not photos_allowed():
            return _fail('photos_disabled', 400)
        if len(photos) > _MAX_PHOTOS:
            return _fail('too_many_photos', 400)
        blobs = []
        for upload in photos:
            blob = upload.read(_MAX_PHOTO_BYTES + 1)
            if len(blob) > _MAX_PHOTO_BYTES:
                return _fail('photo_too_large', 413)
            mime = _image_type(blob)
            if mime is None:
                return _fail('not_an_image', 400)
            blobs.append((mime, blob))

        now = datetime.utcnow()
        mine = RepairRequest.query.filter_by(employee_id=viewer.employee_id)
        if mine.filter(RepairRequest.status.in_(OPEN_STATUSES)).count() >= _MAX_OPEN_PER_AUTHOR:
            return _fail('too_many_open', 429)
        if mine.filter(RepairRequest.created_at >= now - timedelta(days=1)).count() >= _MAX_PER_AUTHOR_PER_DAY:
            return _fail('too_many_today', 429)

        item = RepairRequest(employee_id=viewer.employee_id, category=category,
                             service=_GROUP_OF[category], place=place[:100],
                             equipment=field('equipment')[:100] or None,
                             description=description,
                             phone=field('phone')[:50] or None,
                             stopped=stopped, status='new',
                             created_at=now, updated_at=now)
        db.session.add(item)
        db.session.flush()
        for mime, blob in blobs:
            db.session.add(RepairRequestPhoto(request_id=item.id, mime=mime,
                                              data=blob, created_at=now))
        db.session.add(RepairRequestEvent(request_id=item.id,
                                          actor_id=viewer.employee_id,
                                          action='created', at=now))
        try:
            _forget_old_photos()
        except Exception as e:      # уборка не повод терять заявку
            logging.warning('Не удалось убрать старые фото заявок на ремонт: %s', e)
        db.session.commit()
        logging.info('Заявка на ремонт №%s от %s: %s, %s', item.id,
                     viewer.employee_id, category, item.place)

        what = _CATEGORY_RU[category]
        if item.equipment:
            what = f'{what} «{item.equipment}»'
        title = f'Ремонт №{item.id}: {what}, {item.place}'
        if stopped:
            title = f'{title} — стоит'
        _notify(_staff_ids(item.service), title,
                f'{viewer.full_name}: {description[:200]}', item.id,
                actor_id=viewer.employee_id)
        return jsonify({'message': 'Success',
                        'item': _json(item, _names([viewer.employee_id]),
                                      photos=[], events=[])}), 201

    def _detail(item):
        events = (RepairRequestEvent.query.filter_by(request_id=item.id)
                  .order_by(RepairRequestEvent.at, RepairRequestEvent.id).all())
        photos = [p.id for p in db.session.query(RepairRequestPhoto.id)
                  .filter_by(request_id=item.id).order_by(RepairRequestPhoto.id)]
        people = _names([item.employee_id, item.assignee_id]
                        + [e.actor_id for e in events])
        return _json(item, people, photos=photos, events=events)

    @app.route('/api/repair-requests/<int:item_id>', methods=['GET'])
    @core.require_auth
    def repair_request_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(RepairRequest, item_id)
        if item is None or not _may_see(viewer, item):
            return _fail('not_found', 404)
        body = _detail(item)
        body['can_act'] = _is_staff_for(viewer, item)
        return jsonify({'message': 'Success', 'item': body})

    @app.route('/api/repair-requests/<int:item_id>/photos/<int:photo_id>',
               methods=['GET'])
    @core.require_auth
    def repair_request_photo(item_id, photo_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(RepairRequest, item_id)
        photo = db.session.get(RepairRequestPhoto, photo_id)
        if (item is None or photo is None or photo.request_id != item.id
                or not _may_see(viewer, item)):
            return _fail('not_found', 404)
        response = Response(photo.data, mimetype=photo.mime)
        response.headers['Cache-Control'] = 'private, max-age=86400'
        return response

    @app.route('/api/repair-requests/<int:item_id>', methods=['POST'])
    @core.require_auth
    def repair_request_action(item_id):
        """Что-то сделать с заявкой: `{"action": ..., "comment": ...}`.

        Служба: take, done, reject (с причиной), forward — передать другой
        службе (с причиной: «это не электрика, а вентиляция»). Автор: cancel,
        reopen. Обоим: comment.
        """
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(RepairRequest, item_id)
        if item is None or not _may_see(viewer, item):
            return _fail('not_found', 404)

        data = core._json_body()
        action = core._text(data, 'action')
        comment = core._text(data, 'comment')[:_MAX_COMMENT]
        is_author = viewer.employee_id == item.employee_id
        staff = _is_staff_for(viewer, item)
        now = datetime.utcnow()
        before = item.status

        if action == 'take':
            if not staff:
                return core._deny()
            if item.status not in OPEN_STATUSES:
                return _fail('closed', 409)
            if item.status == 'in_progress' and item.assignee_id == viewer.employee_id:
                body = _detail(item)
                body['can_act'] = True
                return jsonify({'message': 'Success', 'item': body})
            item.status = 'in_progress'
            item.assignee_id = viewer.employee_id
        elif action in ('done', 'reject'):
            if not staff:
                return core._deny()
            if item.status not in OPEN_STATUSES:
                return _fail('closed', 409)
            if action == 'reject' and not comment:
                return _fail('comment_required', 400)
            item.status = 'done' if action == 'done' else 'rejected'
            item.assignee_id = item.assignee_id or viewer.employee_id
            item.resolution = comment or None
            item.closed_at = now
        elif action == 'forward':
            if not staff:
                return core._deny()
            if item.status not in OPEN_STATUSES:
                return _fail('closed', 409)
            if not comment:
                return _fail('comment_required', 400)
            item.service = FACILITY if item.service == ENGINEER else ENGINEER
            item.status = 'new'
            item.assignee_id = None
        elif action == 'cancel':
            if not is_author:
                return core._deny()
            if item.status not in OPEN_STATUSES:
                return _fail('closed', 409)
            item.status = 'cancelled'
            item.closed_at = now
        elif action == 'reopen':
            if not is_author:
                return core._deny()
            if item.status != 'done' or not item.closed_at \
                    or now - item.closed_at > _REOPEN_WITHIN:
                return _fail('cannot_reopen', 409)
            item.status = 'in_progress' if item.assignee_id else 'new'
            item.closed_at = None
        elif action == 'comment':
            if not comment:
                return _fail('comment_required', 400)
            if not (is_author or staff):
                return core._deny()
        else:
            return _fail('bad_action', 400)

        item.updated_at = now
        db.session.add(RepairRequestEvent(request_id=item.id,
                                          actor_id=viewer.employee_id,
                                          action=action, comment=comment or None,
                                          at=now))
        db.session.commit()

        number = f'Ремонт №{item.id}'
        who = viewer.full_name
        if action == 'take' and before != 'in_progress':
            _notify([item.employee_id], f'{number} в работе',
                    f'Взял(а): {who}', item.id, viewer.employee_id)
        elif action == 'take':
            _notify([item.employee_id], f'{number}: новый исполнитель',
                    who, item.id, viewer.employee_id)
        elif action == 'done':
            _notify([item.employee_id], f'{number} выполнена',
                    comment or who, item.id, viewer.employee_id)
        elif action == 'reject':
            _notify([item.employee_id], f'{number} отклонена', comment,
                    item.id, viewer.employee_id)
        elif action == 'forward':
            _notify(_staff_ids(item.service), f'{number} передана вам',
                    f'{who}: {comment[:200]}', item.id, viewer.employee_id)
            _notify([item.employee_id], f'{number} передана другой службе',
                    comment, item.id, viewer.employee_id)
        elif action == 'reopen':
            _notify([item.assignee_id] if item.assignee_id
                    else _staff_ids(item.service),
                    f'{number} открыта снова', comment or who, item.id,
                    viewer.employee_id)
        elif action == 'comment':
            if is_author:
                targets = ([item.assignee_id] if item.assignee_id
                           else _staff_ids(item.service))
            else:
                targets = [item.employee_id]
            _notify(targets, f'{number}: сообщение', f'{who}: {comment[:200]}',
                    item.id, viewer.employee_id)
        body = _detail(item)
        body['can_act'] = _is_staff_for(viewer, item)
        return jsonify({'message': 'Success', 'item': body})
