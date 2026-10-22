"""«Меня нет на месте»: кто в отпуске, на больничном или в командировке и
кто его замещает — прямо в справочнике.

Звонят на внутренний начальнику отдела, а он вторую неделю в отпуске, и
кто за него, знает только его отдел. Здесь человек сам ставит отметку
перед уходом — «в отпуске до 4 ноября, замещает Иванов», — и в справочнике
под его именем видно, до какого числа его нет и кому звонить вместо него, с
кнопкой набора номера заместителя.

Сам, а не из 1С: даты отпусков из учёта на сервер не приходят, а ждать
выгрузки ради отметки «меня нет» незачем. За того, кто ушёл и не успел
отметиться, отметку ставит специалист по кадрам (или администратор).

Справочник и сотрудники — разные таблицы (в справочнике есть посты без
людей, один человек может стоять дважды), поэтому отметка привязана к
сотруднику, а в справочнике находится по ФИО.
"""

import logging
from datetime import date, datetime, timedelta

from flask import g, jsonify

from it_requests import _norm
from models import db


REASONS = ('vacation', 'sick', 'trip', 'other')

_REASON_RU = {'vacation': 'в отпуске', 'sick': 'на больничном',
              'trip': 'в командировке', 'other': 'нет на месте'}

# Дольше этого «меня нет» уже не отметка, а декрет или увольнение — это
# дело отдела кадров, не справочника.
_MAX_DAYS = 120
# Ставить заранее — не дальше этого: отметка за полгода вперёд забудется.
_MAX_AHEAD = timedelta(days=60)
_MAX_NOTE = 200


class AwayNote(db.Model):
    """Одна отметка на человека: новая заменяет прежнюю."""
    __tablename__ = 'away_notes'
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            primary_key=True)
    reason = db.Column(db.String(20), nullable=False, default='vacation')
    start_date = db.Column(db.Date, nullable=False)
    end_date = db.Column(db.Date, nullable=False)
    # Кто замещает — ФИО, как в справочнике: по нему находится его номер.
    deputy_name = db.Column(db.String(255))
    note = db.Column(db.String(_MAX_NOTE))
    set_by = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def can_manage(employee, is_admin):
    """Кто ставит отметку за других: кадры и администратор."""
    if employee is None:
        return False
    return is_admin or 'кадр' in _norm(employee.job_title)


def _iso(day):
    return day.isoformat() if day else None


def register(app, core):
    from models import DirectoryEntry, Employee

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _today():
        return core._plant_today()

    def _directory_by_name():
        rows = {}
        for row in DirectoryEntry.query.order_by(DirectoryEntry.sort_order):
            rows.setdefault(_norm(row.name), row)
        return rows

    def _json(note, directory=None):
        if note is None:
            return None
        directory = directory if directory is not None else _directory_by_name()
        deputy = directory.get(_norm(note.deputy_name)) if note.deputy_name else None
        today = _today()
        return {
            'reason': note.reason,
            'start': _iso(note.start_date),
            'end': _iso(note.end_date),
            'active': note.start_date <= today <= note.end_date,
            'deputy': note.deputy_name or '',
            'deputy_extension': (deputy.extension or '') if deputy else '',
            'deputy_mobile': (deputy.mobile or '') if deputy else '',
            'note': note.note or '',
        }

    def _forget_finished():
        AwayNote.query.filter(AwayNote.end_date < _today()).delete(
            synchronize_session=False)

    def active_by_name():
        """Для справочника: ФИО → отметка, у кого она действует сегодня."""
        today = _today()
        notes = AwayNote.query.filter(AwayNote.start_date <= today,
                                      AwayNote.end_date >= today).all()
        if not notes:
            return {}
        people = {e.employee_id: e for e in Employee.query.filter(
            Employee.employee_id.in_([n.employee_id for n in notes]))}
        directory = _directory_by_name()
        out = {}
        for note in notes:
            emp = people.get(note.employee_id)
            if emp:
                out[_norm(emp.full_name)] = _json(note, directory)
        return out

    # Справочник берёт отметки отсюда.
    app.extensions['away_by_name'] = active_by_name

    def _target(employee_id):
        """Чью отметку меняем: свою или, кадрам, чужую."""
        viewer = getattr(g, 'employee', None)
        if viewer is None:
            return None, None, _fail('unauthorized', 401)
        if employee_id in (None, 'me', viewer.employee_id):
            return viewer, viewer, None
        if not can_manage(viewer, core._is_system_admin(viewer.job_title)):
            return viewer, None, core._deny()
        other = db.session.get(Employee, employee_id)
        if other is None:
            return viewer, None, _fail('not_found', 404)
        return viewer, other, None

    @app.route('/api/away', methods=['GET'])
    @app.route('/api/away/<employee_id>', methods=['GET'])
    @core.require_auth
    def away_get(employee_id=None):
        viewer, person, error = _target(employee_id)
        if error:
            return error
        note = db.session.get(AwayNote, person.employee_id)
        if note is not None and note.end_date < _today():
            note = None
        return jsonify({
            'message': 'Success',
            'away': _json(note),
            'can_manage': can_manage(viewer, core._is_system_admin(viewer.job_title)),
            'max_days': _MAX_DAYS,
        })

    @app.route('/api/away', methods=['PUT'])
    @app.route('/api/away/<employee_id>', methods=['PUT'])
    @core.require_auth
    def away_set(employee_id=None):
        """`{"reason", "start", "end", "deputy", "note"}`, даты — ГГГГ-ММ-ДД."""
        viewer, person, error = _target(employee_id)
        if error:
            return error
        data = core._json_body()
        reason = core._text(data, 'reason') or 'vacation'
        if reason not in REASONS:
            return _fail('bad_reason', 400)
        try:
            start = date.fromisoformat(core._text(data, 'start'))
            end = date.fromisoformat(core._text(data, 'end'))
        except ValueError:
            return _fail('bad_dates', 400)
        today = _today()
        if end < start:
            return _fail('bad_dates', 400)
        if end < today:
            return _fail('in_the_past', 400)
        if start > today + _MAX_AHEAD:
            return _fail('too_far_ahead', 400)
        if (end - start).days + 1 > _MAX_DAYS:
            return _fail('too_long', 400)
        deputy = ' '.join(core._text(data, 'deputy').split())[:255]
        if deputy and _norm(deputy) == _norm(person.full_name):
            return _fail('self_deputy', 400)

        note = db.session.get(AwayNote, person.employee_id)
        before_deputy = note.deputy_name if note else None
        if note is None:
            note = AwayNote(employee_id=person.employee_id)
            db.session.add(note)
        note.reason = reason
        note.start_date = max(start, today)
        note.end_date = end
        note.deputy_name = deputy or None
        note.note = core._text(data, 'note')[:_MAX_NOTE] or None
        note.set_by = viewer.employee_id
        note.updated_at = datetime.utcnow()
        try:
            _forget_finished()
        except Exception as e:      # уборка не повод терять отметку
            logging.warning('Не удалось убрать старые отметки «нет на месте»: %s', e)
        db.session.commit()
        logging.info('Нет на месте: %s, %s—%s, замещает %r (поставил %s)',
                     person.employee_id, note.start_date, end, deputy,
                     viewer.employee_id)

        # Заместителю — в ленту, что его назначили. Только новому: правка
        # дат не повод писать ему второй раз.
        if deputy and _norm(deputy) != _norm(before_deputy):
            wanted = _norm(deputy)
            ids = [e.employee_id for e in Employee.query.all()
                   if _norm(e.full_name) == wanted]
            if ids:
                core._record_notice(
                    'away', f'Вы замещаете: {person.full_name}',
                    f'{_REASON_RU[reason].capitalize()} '
                    f'с {note.start_date:%d.%m} по {end:%d.%m}. '
                    'В справочнике звонящим покажут ваш номер.',
                    employee_ids=ids)
        return jsonify({'message': 'Success', 'away': _json(note)})

    @app.route('/api/away', methods=['DELETE'])
    @app.route('/api/away/<employee_id>', methods=['DELETE'])
    @core.require_auth
    def away_clear(employee_id=None):
        """Вернулся раньше — отметка снимается."""
        viewer, person, error = _target(employee_id)
        if error:
            return error
        AwayNote.query.filter_by(employee_id=person.employee_id).delete()
        db.session.commit()
        return jsonify({'message': 'Success', 'away': None})
