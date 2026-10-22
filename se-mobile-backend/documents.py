"""Документы предприятия: приказы, положения, графики, образцы заявлений.

Сейчас приказ вешают на доску у проходной и рассылают по почте начальникам,
а «ознакомлен» собирают подписью на бумаге — и кто не дошёл до доски, тот
не знает. Здесь документ лежит в приложении у каждого, а для важных
приказов человек сам нажимает «Ознакомлен», и составитель видит, кто ещё
нет.

Отдельным модулем, а не очередной сотней строк в app.py: раздел живёт сам
по себе, а из app.py берёт только проверку пропуска и учётной записи.

Файл лежит в базе, а не на диске. Документов — десятки, а не тысячи, и в
базе они попадают в суточную копию и в её копию вне сервера сами; папку
на диске пришлось бы помнить отдельно — и однажды забыть.
"""

import logging
import os
import re
from datetime import datetime
from io import BytesIO

from flask import g, jsonify, request, send_file

from models import db, Employee, UserAccount


# Разделы. Порядок — тот, в котором они идут в приложении.
CATEGORIES = {
    'order': 'Приказы',
    'regulation': 'Положения',
    'schedule': 'Графики смен и праздничные дни',
    'template': 'Образцы заявлений',
    'other': 'Прочее',
}

# Что принимаем. Это то, что составляют в конторе и что телефон умеет
# открыть: проверять содержимое на вредоносность сервер не умеет, поэтому
# исполняемые и архивы не принимаем вовсе.
_TYPES = {
    '.pdf': 'application/pdf',
    '.doc': 'application/msword',
    '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    '.xls': 'application/vnd.ms-excel',
    '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    '.odt': 'application/vnd.oasis.opendocument.text',
    '.rtf': 'application/rtf',
    '.txt': 'text/plain',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.png': 'image/png',
}

# nginx пропускает тело до 12 МБ; скан приказа на пару страниц — около
# мегабайта. Десяти хватит с запасом и не раздует базу.
MAX_BYTES = 10 * 1024 * 1024


class Document(db.Model):
    __tablename__ = 'documents'
    id = db.Column(db.Integer, primary_key=True)
    category = db.Column(db.String(20), nullable=False, default='other')
    title = db.Column(db.String(300), nullable=False)
    # Номер и дата приказа — то, по чему на него ссылаются в разговоре.
    number = db.Column(db.String(50))
    doc_date = db.Column(db.Date)
    filename = db.Column(db.String(255), nullable=False)
    mime = db.Column(db.String(100), nullable=False)
    size = db.Column(db.Integer, nullable=False, default=0)
    # Нужна ли отметка «ознакомлен». Только для важных: если просить её на
    # каждый образец заявления, нажимать будут не читая.
    requires_ack = db.Column(db.Boolean, nullable=False, default=False)
    uploaded_by = db.Column(db.String(255))
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class DocumentFile(db.Model):
    """Содержимое файла — отдельно, чтобы список не тащил мегабайты."""
    __tablename__ = 'document_files'
    document_id = db.Column(db.Integer, db.ForeignKey('documents.id'),
                            primary_key=True)
    data = db.Column(db.LargeBinary, nullable=False)


class DocumentAck(db.Model):
    """«Ознакомлен»: кто и когда.

    Без ограничения неповторимости на (документ, сотрудник): склейка
    дублей сотрудника переносит строки с одной записи на другую, и если
    отметились обе, ограничение уронило бы склейку. Вторую отметку того же
    человека не пишет сам обработчик.
    """
    __tablename__ = 'document_acks'
    id = db.Column(db.Integer, primary_key=True)
    document_id = db.Column(db.Integer, db.ForeignKey('documents.id'),
                            nullable=False, index=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    acked_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def may_edit(job_title):
    """Кто выкладывает документы: администратор, корпоративный секретарь —
    через неё идут приказы, — и отдел кадров: графики и образцы заявлений."""
    job = (job_title or '').lower()
    return ('администратор системы' in job or 'корпоративный секретарь' in job
            or 'кадр' in job)


def _safe_name(name):
    """Имя файла для заголовка ответа: без пути и управляющих символов.

    Кириллицу оставляем — «Приказ №45.pdf» человеку понятнее, чем
    «document-45.pdf»; Flask сам закодирует её для заголовка.
    """
    name = os.path.basename((name or '').replace('\\', '/'))
    name = re.sub(r'[\x00-\x1f"]', '', name).strip()
    return name[:255] or 'document'


def _doc_json(doc, acked_at=None):
    return {
        'id': doc.id,
        'category': doc.category,
        'category_name': CATEGORIES.get(doc.category, CATEGORIES['other']),
        'title': doc.title,
        'number': doc.number or '',
        'date': doc.doc_date.isoformat() if doc.doc_date else None,
        'filename': doc.filename,
        'size': doc.size,
        'requires_ack': bool(doc.requires_ack),
        'acked': acked_at is not None,
        'acked_at': acked_at.isoformat() + 'Z' if acked_at else None,
        'created_at': doc.created_at.isoformat() + 'Z' if doc.created_at else None,
    }


def _expected_readers():
    """Кто должен ознакомиться: все, у кого есть действующий вход в
    приложение. Служебную запись администратора не считаем — у неё нет
    человека, который прочтёт."""
    rows = (db.session.query(Employee)
            .join(UserAccount, UserAccount.employee_id == Employee.employee_id)
            .filter(UserAccount.is_active.is_(True))
            .all())
    return {e.employee_id: e for e in rows
            if 'администратор системы' not in (e.job_title or '').lower()}


def _first_acks(document_id):
    """employee_id → время первой отметки."""
    acks = {}
    for row in (DocumentAck.query.filter_by(document_id=document_id)
                .order_by(DocumentAck.acked_at.asc())):
        acks.setdefault(row.employee_id, row.acked_at)
    return acks


def delete_document(doc):
    # Внешние ключи SQLite по умолчанию не ведёт, а PostgreSQL ведёт —
    # поэтому зависимые строки убираем сами, до самого документа.
    DocumentAck.query.filter_by(document_id=doc.id).delete()
    DocumentFile.query.filter_by(document_id=doc.id).delete()
    db.session.delete(doc)
    db.session.commit()


def register(app, core):
    """Маршруты раздела. `core` — модуль app: оттуда проверка пропуска,
    учётной записи и рассылка, чтобы не заводить их второй раз."""

    def _viewer():
        return getattr(g, 'employee', None)

    def _editor():
        """Кто выкладывает: по пропуску из приложения или по логину и паролю
        из программы на конторском компьютере. Возвращает (сотрудник, отказ)."""
        employee = core._resolve_token(core._bearer_token())
        if employee is None and request.form.get('login'):
            login = (request.form.get('login') or '').strip()
            employee_id = core._authenticate(
                login, (request.form.get('password') or '').strip())
            if not employee_id:
                return None, core._credentials_refused(login)
            employee = db.session.get(Employee, employee_id)
        if employee is None:
            return None, (jsonify({'message': 'Нужен вход',
                                   'error': 'unauthorized'}), 401)
        if not may_edit(employee.job_title):
            return None, (jsonify({
                'message': 'Выкладывать документы может администратор, '
                           'корпоративный секретарь или отдел кадров',
                'error': 'forbidden'}), 403)
        g.employee = employee
        return employee, None

    def _may_edit_now():
        viewer = _viewer()
        if viewer is None:
            return not core._AUTH_REQUIRED
        return may_edit(viewer.job_title)

    @app.route('/api/documents', methods=['GET'])
    @core.require_auth
    def documents_list():
        """Все документы; у тех, что требуют отметки, — отметился ли я."""
        viewer = _viewer()
        mine = {}
        if viewer is not None:
            for row in DocumentAck.query.filter_by(employee_id=viewer.employee_id):
                if row.document_id not in mine or row.acked_at < mine[row.document_id]:
                    mine[row.document_id] = row.acked_at
        docs = Document.query.order_by(Document.created_at.desc()).all()
        items = [_doc_json(d, mine.get(d.id)) for d in docs]
        # Без пропуска (старая сборка) не знаем, кто это, и не просим.
        pending = 0 if viewer is None else sum(
            1 for i in items if i['requires_ack'] and not i['acked'])
        return jsonify({
            'message': 'Success',
            'categories': [{'key': k, 'name': v} for k, v in CATEGORIES.items()],
            'items': items,
            'pending': pending,
            'can_edit': _may_edit_now() if viewer is not None else False,
        })

    @app.route('/api/documents/<int:doc_id>/file', methods=['GET'])
    @core.require_auth
    def documents_file(doc_id):
        doc = db.session.get(Document, doc_id)
        stored = db.session.get(DocumentFile, doc_id) if doc else None
        if stored is None:
            return jsonify({'message': 'Failure', 'error': 'not_found'}), 404
        response = send_file(BytesIO(stored.data), mimetype=doc.mime,
                             as_attachment=True, download_name=doc.filename)
        # Приказы не должны оседать в общих кешах по дороге.
        response.headers['Cache-Control'] = 'private, no-store'
        return response

    @app.route('/api/documents/<int:doc_id>/ack', methods=['POST'])
    @core.require_auth
    def documents_ack(doc_id):
        """«Ознакомлен». Повторное нажатие ничего не меняет: важна первая
        отметка, и время у неё остаётся прежним."""
        viewer = _viewer()
        if viewer is None:
            # Старая сборка без пропуска: чью отметку записывать — неизвестно.
            return jsonify({'message': 'Failure', 'error': 'unauthorized'}), 401
        doc = db.session.get(Document, doc_id)
        if doc is None:
            return jsonify({'message': 'Failure', 'error': 'not_found'}), 404
        row = (DocumentAck.query
               .filter_by(document_id=doc_id, employee_id=viewer.employee_id)
               .order_by(DocumentAck.acked_at.asc()).first())
        if row is None:
            row = DocumentAck(document_id=doc_id, employee_id=viewer.employee_id,
                              acked_at=datetime.utcnow())
            db.session.add(row)
            db.session.commit()
        return jsonify({'message': 'Success',
                        'item': _doc_json(doc, row.acked_at)})

    @app.route('/api/admin/documents', methods=['POST'])
    def documents_upload():
        """Выложить документ. multipart: file, title, category, number, date,
        requires_ack — и login/password, если без пропуска."""
        editor, refusal = _editor()
        if refusal is not None:
            return refusal

        upload = request.files.get('file')
        if upload is None or not upload.filename:
            return jsonify({'message': 'Файл не передан', 'error': 'no_file'}), 400
        filename = _safe_name(upload.filename)
        ext = os.path.splitext(filename)[1].lower()
        if ext not in _TYPES:
            return jsonify({
                'message': 'Такой файл не принимаем. Подойдут: ' +
                           ', '.join(sorted({e.lstrip('.') for e in _TYPES})),
                'error': 'bad_type'}), 400
        data = upload.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            return jsonify({'message': 'Файл больше 10 МБ', 'error': 'too_big'}), 413
        if not data:
            return jsonify({'message': 'Файл пустой', 'error': 'empty'}), 400

        title = (request.form.get('title') or '').strip() or os.path.splitext(filename)[0]
        category = (request.form.get('category') or '').strip()
        if category not in CATEGORIES:
            category = 'other'
        doc_date = None
        if (request.form.get('date') or '').strip():
            doc_date = core._iso_date(request.form.get('date'))
            if doc_date is None:
                return jsonify({'message': 'Дата — в виде 2026-10-22',
                                'error': 'bad_date'}), 400
        requires_ack = (request.form.get('requires_ack') or '').strip().lower() in (
            '1', 'true', 'yes', 'on', 'да')

        doc = Document(
            category=category,
            title=title[:300],
            number=(request.form.get('number') or '').strip()[:50] or None,
            doc_date=doc_date,
            filename=filename,
            mime=_TYPES[ext],
            size=len(data),
            requires_ack=requires_ack,
            uploaded_by=(editor.full_name or '')[:255] or None,
            created_at=datetime.utcnow(),
        )
        db.session.add(doc)
        db.session.flush()
        db.session.add(DocumentFile(document_id=doc.id, data=data))
        db.session.commit()
        logging.info('Документ выложен: %s «%s» (%d байт), %s',
                     category, title[:80], len(data), editor.employee_id)

        _announce(app, core, doc)
        return jsonify({'message': f'Выложено: {doc.title}',
                        'item': _doc_json(doc)})

    @app.route('/api/admin/documents/<int:doc_id>', methods=['POST', 'DELETE'])
    @core.require_auth
    def documents_change(doc_id):
        """Поправить название, раздел, отметку — или убрать документ."""
        if not _may_edit_now():
            return core._deny()
        doc = db.session.get(Document, doc_id)
        if doc is None:
            return jsonify({'message': 'Failure', 'error': 'not_found'}), 404
        if request.method == 'DELETE':
            delete_document(doc)
            return jsonify({'message': 'Success'})

        data = core._json_body()
        if core._text(data, 'title'):
            doc.title = core._text(data, 'title')[:300]
        if core._text(data, 'category') in CATEGORIES:
            doc.category = core._text(data, 'category')
        if 'number' in data:
            doc.number = core._text(data, 'number')[:50] or None
        if 'requires_ack' in data:
            doc.requires_ack = bool(data['requires_ack'])
        db.session.commit()
        return jsonify({'message': 'Success', 'item': _doc_json(doc)})

    @app.route('/api/admin/documents/<int:doc_id>/acks', methods=['GET'])
    @core.require_auth
    def documents_acks(doc_id):
        """Кто ознакомился и кто ещё нет — вместо листа с подписями."""
        if not _may_edit_now():
            return core._deny()
        doc = db.session.get(Document, doc_id)
        if doc is None:
            return jsonify({'message': 'Failure', 'error': 'not_found'}), 404

        readers = _expected_readers()
        acks = _first_acks(doc_id)
        names = {e.employee_id: e for e in
                 Employee.query.filter(Employee.employee_id.in_(list(acks))).all()} \
            if acks else {}

        def person(employee_id, employee):
            return {'employee_id': employee_id,
                    'full_name': employee.full_name if employee else employee_id,
                    'department': (employee.department or '') if employee else ''}

        acked = sorted(
            ({**person(eid, names.get(eid)), 'at': at.isoformat() + 'Z'}
             for eid, at in acks.items()),
            key=lambda p: p['at'])
        waiting = sorted(
            (person(eid, e) for eid, e in readers.items() if eid not in acks),
            key=lambda p: (p['department'], p['full_name']))
        return jsonify({
            'message': 'Success',
            'item': _doc_json(doc),
            'expected': len(readers),
            'acked': acked,
            'waiting': waiting,
        })


def _announce(app, core, doc):
    """Сказать всем, что появился документ.

    Лента оповещений в приложении — если она есть в этой сборке сервера
    (`_record_notice`); пуш — если настроен Firebase. Ни то ни другое не
    повод отказать в загрузке: документ уже выложен.
    """
    if doc.requires_ack:
        title, body = 'Новый приказ — ознакомьтесь', doc.title
    else:
        title, body = 'Новый документ', doc.title
    record = getattr(core, '_record_notice', None)
    if record is not None:
        try:
            record('document', title, body, ref=doc.id)
        except Exception as e:
            logging.warning('Оповещение о документе не записано: %s', e)
    try:
        core._notify_later(app, core._push_to_everyone, title, body,
                           {'type': 'document', 'id': doc.id})
    except Exception as e:
        logging.warning('Пуш о документе не отправлен: %s', e)
