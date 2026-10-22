"""Заявки в ОИТиС: «не работает принтер в каб. 305».

Раньше такое шло звонком: человек объяснял, где и что сломалось, а через
час, не дождавшись, звонил и объяснял заново — уже другому. Здесь у заявки
есть номер, кабинет, описание и фото, а у автора на экране — что с ней:
«новая», «в работе у Николаева», «выполнена».

Отдельным модулем, а не внутри app.py: там почти пять тысяч строк, и каждая
правка задевает всё сразу. Из app.py сюда берутся только общие вещи —
проверка пропуска, отправка уведомлений, — и берутся через `core`, модуль,
который зовёт register(). Импортировать app здесь нельзя: под gunicorn он
`app`, а при `python app.py` — `__main__`, и импорт поднял бы второй его
экземпляр со своей базой и своими маршрутами.

Схема своя и ни с чем не общая. Заявки в отдел кадров живут отдельно: у них
другие исполнители, другие статусы («готова, заберите в каб. 12») и другие
поля. Общего у них — только слово «заявка».
"""

import logging
import os
import re
from datetime import datetime, timedelta, timezone

from flask import Response, g, jsonify, request

from models import db


# Что сломалось. Список короткий намеренно: по нему ОИТиС сортирует очередь
# и понимает, кому идти, а «другое» остаётся на всё, что сюда не легло.
CATEGORIES = ('printer', 'computer', 'network', 'phone', 'software',
              'account', 'other')

# Для оповещений: телефону приходит готовый текст, перевода там нет.
_CATEGORY_RU = {
    'printer': 'Принтер', 'computer': 'Компьютер', 'network': 'Сеть',
    'phone': 'Телефон', 'software': 'Программа', 'account': 'Учётная запись',
    'other': 'Другое',
}

STATUSES = ('new', 'in_progress', 'done', 'rejected', 'cancelled')
OPEN_STATUSES = ('new', 'in_progress')

_MAX_PHOTOS = 3
# Приложение само ужимает снимок до 1600 точек по длинной стороне — это
# сотни килобайт. Запас на случай, когда ужать не вышло.
_MAX_PHOTO_BYTES = 4 * 1024 * 1024
_MAX_DESCRIPTION = 2000
_MAX_COMMENT = 1000

# Больше этого у одного человека разом не бывает по-честному. Предел не от
# злого умысла, а от зависшей кнопки «Отправить» и повторов без связи.
_MAX_OPEN_PER_AUTHOR = 10
_MAX_PER_AUTHOR_PER_DAY = 20

# Сколько закрытые висят в очереди ОИТиС, чтобы видеть, что сделано за месяц.
_QUEUE_CLOSED_FOR = timedelta(days=30)

# «Не помогло» после «выполнено» — в эти сроки. Позже это уже новая поломка.
_REOPEN_WITHIN = timedelta(days=14)

# Фото нужны, пока заявку делают. Через полгода после закрытия они только
# раздувают базу и резервные копии; сама заявка и её история остаются.
_PHOTOS_KEPT_AFTER_CLOSE = timedelta(days=180)

# Свои: без расширения файла, по первым байтам. Имя файла приходит с
# телефона и ничего не значит.
_IMAGE_MAGIC = (
    (b'\xff\xd8\xff', 'image/jpeg'),
    (b'\x89PNG\r\n\x1a\n', 'image/png'),
)


class ItRequest(db.Model):
    __tablename__ = 'it_requests'
    # Две выборки: «мои заявки» (по автору) и очередь ОИТиС (по статусу).
    __table_args__ = (
        db.Index('ix_it_requests_author', 'employee_id', 'created_at'),
        db.Index('ix_it_requests_status', 'status', 'updated_at'),
    )
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False)
    category = db.Column(db.String(20), nullable=False, default='other')
    room = db.Column(db.String(50), nullable=False)
    description = db.Column(db.Text, nullable=False)
    # Куда перезвонить: внутренний номер или мобильный. Не обязателен — в
    # справочнике номер есть не у всех, а кабинет есть у всех.
    phone = db.Column(db.String(50))
    status = db.Column(db.String(20), nullable=False, default='new')
    assignee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # Что сделали или почему отказали — последнее слово ОИТиС.
    resolution = db.Column(db.Text)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    closed_at = db.Column(db.DateTime)


class ItRequestPhoto(db.Model):
    """Снимок к заявке.

    В базе, а не файлом на диске: так он попадает в те же зашифрованные
    резервные копии, что и сама заявка, и не теряется при переезде сервера.
    Отдельной таблицей — чтобы список заявок не тащил за собой мегабайты.
    """
    __tablename__ = 'it_request_photos'
    id = db.Column(db.Integer, primary_key=True)
    request_id = db.Column(db.Integer,
                           db.ForeignKey('it_requests.id', ondelete='CASCADE'),
                           nullable=False, index=True)
    mime = db.Column(db.String(30), nullable=False)
    data = db.Column(db.LargeBinary, nullable=False)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class ItRequestEvent(db.Model):
    """Строка истории: кто, когда и что сделал с заявкой.

    Отсюда «принята в работу в 10:12, Николаев» на экране автора, и отсюда
    же видно, что заявку открывали заново.
    """
    __tablename__ = 'it_request_events'
    id = db.Column(db.Integer, primary_key=True)
    request_id = db.Column(db.Integer,
                           db.ForeignKey('it_requests.id', ondelete='CASCADE'),
                           nullable=False, index=True)
    actor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # created, take, done, reject, cancel, reopen, comment
    action = db.Column(db.String(20), nullable=False)
    comment = db.Column(db.Text)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _norm(text):
    return re.sub(r'\s+', ' ', (text or '').lower().replace('ё', 'е')).strip()


def _extra_staff():
    """Табельные номера из IT_STAFF: кто разбирает заявки, кроме самого отдела.

    Например, связист из другого подразделения. Через запятую.
    """
    return {p.strip() for p in os.environ.get('IT_STAFF', '').split(',')
            if p.strip()}


def is_it_department(department):
    dept = _norm(department)
    return 'оитис' in dept or 'информационных технологий' in dept


def is_it_staff(employee):
    """Кто видит очередь и берёт заявки: сотрудники ОИТиС.

    По подразделению, а не по должности: должности там разные — начальник,
    инженер-программист, техник, — а подразделение одно.
    """
    if employee is None:
        return False
    return (is_it_department(employee.department)
            or employee.employee_id in _extra_staff())


def _utc(moment):
    return moment.replace(tzinfo=timezone.utc).isoformat() if moment else None


def _image_type(data):
    for magic, mime in _IMAGE_MAGIC:
        if data.startswith(magic):
            return mime
    # WebP: «RIFF», четыре байта длины, «WEBP».
    if len(data) > 12 and data[:4] == b'RIFF' and data[8:12] == b'WEBP':
        return 'image/webp'
    return None


def register(app, core):
    """Подключает маршруты заявок. `core` — модуль app.py."""
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

    def _staff_ids():
        """Кому сообщать о новой заявке — всему отделу."""
        extra = _extra_staff()
        rows = Employee.query.all()
        return sorted(e.employee_id for e in rows
                      if is_it_department(e.department)
                      or e.employee_id in extra)

    def _json(item, people, photos=None, events=None):
        data = {
            'id': item.id,
            'category': item.category,
            'room': item.room,
            'description': item.description,
            'phone': item.phone or '',
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
        rows = (db.session.query(ItRequestPhoto.request_id,
                                 db.func.count(ItRequestPhoto.id))
                .filter(ItRequestPhoto.request_id.in_(ids))
                .group_by(ItRequestPhoto.request_id))
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

    def _may_see(viewer, item):
        return (viewer.employee_id == item.employee_id
                or is_it_staff(viewer)
                or core._is_system_admin(viewer.job_title))

    def _notify(employee_ids, title, body, item_id, actor_id=None):
        """В ленту оповещений приложения и пушем, без самого действующего."""
        ids = sorted({e for e in employee_ids if e and e != actor_id})
        if not ids:
            return
        # Лента оповещений в приложении появилась отдельно; где её ещё нет,
        # остаётся пуш.
        record = getattr(core, '_record_notice', None)
        if record is not None:
            record('it', title, body, employee_ids=ids, ref=item_id)
        core._notify_later(app, core._push_to, ids, title, body,
                           {'type': 'it_request', 'id': item_id})

    def _forget_old_photos():
        """Снимки закрытых давно заявок больше не нужны."""
        cutoff = datetime.utcnow() - _PHOTOS_KEPT_AFTER_CLOSE
        stale = db.session.query(ItRequest.id).filter(
            ItRequest.closed_at.isnot(None), ItRequest.closed_at < cutoff)
        ItRequestPhoto.query.filter(
            ItRequestPhoto.request_id.in_(stale)
        ).delete(synchronize_session=False)

    @app.route('/api/it-requests', methods=['GET'])
    @core.require_auth
    def it_requests_list():
        """Мои заявки или, для ОИТиС, очередь: `?scope=queue`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        staff = is_it_staff(viewer) or core._is_system_admin(viewer.job_title)

        if request.args.get('scope') == 'queue':
            if not staff:
                return core._deny()
            since = datetime.utcnow() - _QUEUE_CLOSED_FOR
            items = (ItRequest.query
                     .filter(db.or_(ItRequest.status.in_(OPEN_STATUSES),
                                    ItRequest.updated_at >= since))
                     .order_by(ItRequest.created_at.desc())
                     .limit(300).all())
        else:
            items = (ItRequest.query
                     .filter_by(employee_id=viewer.employee_id)
                     .order_by(ItRequest.created_at.desc())
                     .limit(100).all())

        body = {'message': 'Success', 'it_staff': staff,
                'items': _list_json(items)}
        if staff:
            counts = dict(db.session.query(ItRequest.status,
                                           db.func.count(ItRequest.id))
                          .filter(ItRequest.status.in_(OPEN_STATUSES))
                          .group_by(ItRequest.status))
            body['open'] = {s: counts.get(s, 0) for s in OPEN_STATUSES}
        return jsonify(body)

    @app.route('/api/it-requests', methods=['POST'])
    @core.require_auth
    def it_requests_create():
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
        room = field('room')
        if not room:
            return _fail('room_required', 400)
        description = field('description')
        if len(description) < 3:
            return _fail('description_required', 400)
        if len(description) > _MAX_DESCRIPTION:
            return _fail('description_too_long', 400)

        photos = request.files.getlist('photo')
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
        mine = ItRequest.query.filter_by(employee_id=viewer.employee_id)
        if mine.filter(ItRequest.status.in_(OPEN_STATUSES)).count() >= _MAX_OPEN_PER_AUTHOR:
            return _fail('too_many_open', 429)
        if mine.filter(ItRequest.created_at >= now - timedelta(days=1)).count() >= _MAX_PER_AUTHOR_PER_DAY:
            return _fail('too_many_today', 429)

        item = ItRequest(employee_id=viewer.employee_id, category=category,
                         room=room[:50], description=description,
                         phone=field('phone')[:50] or None, status='new',
                         created_at=now, updated_at=now)
        db.session.add(item)
        db.session.flush()
        for mime, blob in blobs:
            db.session.add(ItRequestPhoto(request_id=item.id, mime=mime,
                                          data=blob, created_at=now))
        db.session.add(ItRequestEvent(request_id=item.id,
                                      actor_id=viewer.employee_id,
                                      action='created', at=now))
        try:
            _forget_old_photos()
        except Exception as e:      # уборка не повод терять заявку
            logging.warning('Не удалось убрать старые фото заявок: %s', e)
        db.session.commit()
        logging.info('Заявка в ОИТиС №%s от %s: %s, каб. %s', item.id,
                     viewer.employee_id, category, item.room)

        _notify(_staff_ids(), f'Заявка №{item.id}: {_CATEGORY_RU[category]}, каб. {item.room}',
                f'{viewer.full_name}: {description[:200]}', item.id,
                actor_id=viewer.employee_id)
        return jsonify({'message': 'Success',
                        'item': _json(item, _names([viewer.employee_id]),
                                      photos=[], events=[])}), 201

    def _detail(item):
        events = (ItRequestEvent.query.filter_by(request_id=item.id)
                  .order_by(ItRequestEvent.at, ItRequestEvent.id).all())
        photos = [p.id for p in db.session.query(ItRequestPhoto.id)
                  .filter_by(request_id=item.id).order_by(ItRequestPhoto.id)]
        people = _names([item.employee_id, item.assignee_id]
                        + [e.actor_id for e in events])
        return _json(item, people, photos=photos, events=events)

    @app.route('/api/it-requests/<int:item_id>', methods=['GET'])
    @core.require_auth
    def it_request_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(ItRequest, item_id)
        # Чужая заявка и несуществующая отвечают одинаково: по номерам не
        # перебрать, у кого что сломалось.
        if item is None or not _may_see(viewer, item):
            return _fail('not_found', 404)
        return jsonify({'message': 'Success', 'item': _detail(item)})

    @app.route('/api/it-requests/<int:item_id>/photos/<int:photo_id>',
               methods=['GET'])
    @core.require_auth
    def it_request_photo(item_id, photo_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(ItRequest, item_id)
        photo = db.session.get(ItRequestPhoto, photo_id)
        if (item is None or photo is None or photo.request_id != item.id
                or not _may_see(viewer, item)):
            return _fail('not_found', 404)
        response = Response(photo.data, mimetype=photo.mime)
        # Снимок не меняется никогда: телефон может держать его у себя.
        response.headers['Cache-Control'] = 'private, max-age=86400'
        return response

    @app.route('/api/it-requests/<int:item_id>', methods=['POST'])
    @core.require_auth
    def it_request_action(item_id):
        """Что-то сделать с заявкой: `{"action": ..., "comment": ...}`.

        ОИТиС: take — взять себе, done — выполнено, reject — отказ (с
        причиной). Автор: cancel — уже не нужно, reopen — не помогло.
        Обоим: comment — уточнить, не меняя статуса.
        """
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(ItRequest, item_id)
        if item is None or not _may_see(viewer, item):
            return _fail('not_found', 404)

        data = core._json_body()
        action = core._text(data, 'action')
        comment = core._text(data, 'comment')[:_MAX_COMMENT]
        is_author = viewer.employee_id == item.employee_id
        staff = is_it_staff(viewer) or core._is_system_admin(viewer.job_title)
        now = datetime.utcnow()
        before = item.status

        if action == 'take':
            if not staff:
                return core._deny()
            if item.status not in OPEN_STATUSES:
                return _fail('closed', 409)
            if item.status == 'in_progress' and item.assignee_id == viewer.employee_id:
                return jsonify({'message': 'Success', 'item': _detail(item)})
            item.status = 'in_progress'
            item.assignee_id = viewer.employee_id
        elif action in ('done', 'reject'):
            if not staff:
                return core._deny()
            if item.status not in OPEN_STATUSES:
                return _fail('closed', 409)
            # Отказ без причины ничего не говорит автору — только злит.
            if action == 'reject' and not comment:
                return _fail('comment_required', 400)
            item.status = 'done' if action == 'done' else 'rejected'
            item.assignee_id = item.assignee_id or viewer.employee_id
            item.resolution = comment or None
            item.closed_at = now
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
            # К тому же, кто делал: он знает, что уже пробовали.
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
        db.session.add(ItRequestEvent(request_id=item.id,
                                      actor_id=viewer.employee_id,
                                      action=action, comment=comment or None,
                                      at=now))
        db.session.commit()

        number = f'Заявка №{item.id}'
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
        elif action == 'reopen':
            _notify([item.assignee_id] if item.assignee_id else _staff_ids(),
                    f'{number} открыта снова', comment or who, item.id,
                    viewer.employee_id)
        elif action == 'comment':
            # Автор пишет — исполнителю (или всему отделу, пока никто не
            # взял); ОИТиС пишет — автору.
            if is_author:
                targets = [item.assignee_id] if item.assignee_id else _staff_ids()
            else:
                targets = [item.employee_id]
            _notify(targets, f'{number}: сообщение', f'{who}: {comment[:200]}',
                    item.id, viewer.employee_id)
        return jsonify({'message': 'Success', 'item': _detail(item)})
