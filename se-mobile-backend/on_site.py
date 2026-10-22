"""«Кто из моих сейчас на территории»: начальнику — его люди на сегодня.

Табель отвечает на вопрос «кто когда приходил за месяц», а мастеру в 8:15
нужно другое: кто из участка уже здесь, кого нет и кто из отсутствующих в
отпуске или на больничном — чтобы звонить только тем, про кого ничего не
известно. Здесь список целиком: и те, кто прошёл турникет, и те, кто нет.

Кого видно — как в табеле (`_visible_employee_ids`): начальник — свой
отдел, администратор — всех. Проходы берутся из событий турникета в
реальном времени и из выгрузки СКУД, если она уже есть за сегодня.
Отметки «нет на месте» — из away.py.

Начало смены — SHIFT_START (по умолчанию 08:00), опоздание — позже на
LATE_GRACE_MIN минут (по умолчанию 5).
"""

import os
from datetime import datetime, timedelta

from flask import g, jsonify

from models import db

_IN_EVENTS = ('Вход', 'Проход')
_OUT_EVENTS = ('Выход',)

# Порядок в списке: сначала те, про кого надо узнать, потом опоздавшие.
_ORDER = {'absent': 0, 'not_yet': 0, 'inside': 1, 'left': 2, 'away': 3}


def shift_start():
    raw = os.environ.get('SHIFT_START', '08:00').strip()
    try:
        hours, minutes = (int(x) for x in raw.split(':'))
        return hours * 60 + minutes
    except ValueError:
        return 8 * 60


def late_grace():
    try:
        return max(0, int(os.environ.get('LATE_GRACE_MIN', '5')))
    except ValueError:
        return 5


def _minutes(hhmm):
    try:
        hours, minutes = (int(x) for x in hhmm[:5].split(':'))
        return hours * 60 + minutes
    except ValueError:
        return None


def register(app, core):
    from models import AccessRecord, Employee, TurnstileEvent
    from away import AwayNote

    @app.route('/api/attendance/now', methods=['GET'])
    @core.require_auth
    def attendance_now():
        if not core._is_manager():
            return core._deny()
        viewer = getattr(g, 'employee', None)
        visible = core._visible_employee_ids()
        query = Employee.query
        if visible is not None:
            query = query.filter(Employee.employee_id.in_(list(visible) or ['']))
        people = [e for e in query.order_by(Employee.full_name).all()
                  if viewer is None or e.employee_id != viewer.employee_id]
        ids = [e.employee_id for e in people]

        now = core._plant_now()
        today = now.date()
        day_start = datetime.combine(today, datetime.min.time())
        passes = {}
        last_event = None
        if ids:
            for e in TurnstileEvent.query.filter(
                    TurnstileEvent.timestamp >= day_start,
                    TurnstileEvent.timestamp < day_start + timedelta(days=1),
                    TurnstileEvent.employee_id.in_(ids)):
                passes.setdefault(e.employee_id, []).append(
                    (e.timestamp.strftime('%H:%M'), e.direction))
                if last_event is None or e.timestamp > last_event:
                    last_event = e.timestamp
            for r in AccessRecord.query.filter(
                    AccessRecord.access_date == today,
                    AccessRecord.employee_id.in_(ids)):
                if r.event_type in _IN_EVENTS:
                    direction = 'in'
                elif r.event_type in _OUT_EVENTS:
                    direction = 'out'
                else:
                    continue
                passes.setdefault(r.employee_id, []).append(
                    (r.access_time[:5], direction))
            away = {a.employee_id: a for a in AwayNote.query.filter(
                AwayNote.employee_id.in_(ids), AwayNote.start_date <= today,
                AwayNote.end_date >= today)}
        else:
            away = {}

        start = shift_start()
        late_after = start + late_grace()
        now_min = now.hour * 60 + now.minute
        counts = {'inside': 0, 'left': 0, 'absent': 0, 'away': 0, 'late': 0}
        rows = []
        for e in people:
            # Один и тот же проход приходит и событием, и выгрузкой.
            events = sorted(set(passes.get(e.employee_id, [])))
            ins = [t for t, d in events if d == 'in']
            outs = [t for t, d in events if d == 'out']
            note = away.get(e.employee_id)
            if events:
                status = 'inside' if events[-1][1] == 'in' else 'left'
            elif note is not None:
                status = 'away'
            else:
                status = 'not_yet' if now_min < start else 'absent'
            first_in = ins[0] if ins else None
            late = bool(first_in and (_minutes(first_in) or 0) > late_after)
            counts['absent' if status == 'not_yet' else status] += 1
            if late:
                counts['late'] += 1
            rows.append({
                'id': e.employee_id,
                'name': e.full_name,
                'title': e.job_title or '',
                'department': e.department or '',
                'status': status,
                'first_in': first_in,
                'last_out': outs[-1] if outs and status == 'left' else None,
                'late': late,
                'away': {
                    'reason': note.reason,
                    'until': note.end_date.isoformat(),
                    'deputy': note.deputy_name or '',
                } if note is not None else None,
            })
        rows.sort(key=lambda r: (_ORDER[r['status']], not r['late'], r['name']))
        return jsonify({
            'message': 'Success',
            'date': today.isoformat(),
            'now': now.strftime('%H:%M'),
            'shift_start': f'{start // 60:02d}:{start % 60:02d}',
            # Когда турникет последний раз что-то присылал: если давно —
            # «никого нет» значит «нет связи со СКУД», а не прогул.
            'last_event': last_event.isoformat() if last_event else None,
            'counts': counts,
            'people': rows,
        })
