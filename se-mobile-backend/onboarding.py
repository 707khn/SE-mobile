"""Первые дни новичка: чек-лист адаптации — учётная запись, пропуск,
вводный инструктаж, спецодежда, инструктаж на рабочем месте, наставник.

Сейчас новичок в первый день ходит по кабинетам и спрашивает, куда дальше,
а кадры обзванивают ОИТиС, СБ и хозотдел. Здесь кадры заводят план на
человека (с датой выхода и наставником), каждая служба видит своих новичков
и отмечает свой пункт, а сам новичок видит, что уже готово и куда идти.

Пункт отмечает его служба или кадры; знакомство с наставником — наставник,
инструктаж на рабочем месте — наставник или руководитель подразделения
новичка. Не всем нужны все пункты: инженеру в офисе спецодежда ни к чему,
поэтому кадры выбирают их при заведении. Когда отмечены все, план закрыт.
"""

import logging
import os
from datetime import date, datetime, timedelta

from flask import g, jsonify, request

from hazards import is_safety
from it_requests import _norm, _utc, is_it_staff
from models import db
from data_corrections import is_hr

STEPS = ('account', 'pass', 'induction', 'clothing', 'workplace', 'mentor')
STEP_TITLES = {'account': 'учётная запись', 'pass': 'пропуск',
               'induction': 'вводный инструктаж', 'clothing': 'спецодежда и СИЗ',
               'workplace': 'инструктаж на рабочем месте',
               'mentor': 'знакомство с наставником'}

_MAX_NOTE = 500
_MAX_AHEAD = timedelta(days=60)
_MAX_BEHIND = timedelta(days=30)
_SHOW_DONE_FOR = timedelta(days=30)
_CLOTHING_TITLES = ('заведующ', 'начальник', 'специалист', 'машинист по стирке',
                    'кладовщик')


class Onboarding(db.Model):
    __tablename__ = 'onboardings'
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    start_date = db.Column(db.Date, nullable=False)
    mentor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                          index=True)
    note = db.Column(db.String(_MAX_NOTE))
    # active, done, cancelled
    status = db.Column(db.String(10), nullable=False, default='active', index=True)
    created_by = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    completed_at = db.Column(db.DateTime)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class OnboardingStep(db.Model):
    __tablename__ = 'onboarding_steps'
    __table_args__ = (db.UniqueConstraint('onboarding_id', 'step',
                                          name='uq_onboarding_steps_step'),)
    id = db.Column(db.Integer, primary_key=True)
    onboarding_id = db.Column(db.Integer,
                              db.ForeignKey('onboardings.id', ondelete='CASCADE'),
                              nullable=False, index=True)
    step = db.Column(db.String(10), nullable=False)
    done_at = db.Column(db.DateTime)
    done_by = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    note = db.Column(db.String(_MAX_NOTE))


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_service(step, employee, core):
    """Служба, которая закрывает пункт у любого новичка."""
    if employee is None:
        return False
    dept = _norm(employee.department)
    if step == 'account':
        return is_it_staff(employee) or core._is_system_admin(employee.job_title)
    if step == 'pass':
        return '(сб)' in dept or employee.employee_id in _env_ids('ONBOARDING_PASS_STAFF')
    if step == 'induction':
        return is_safety(employee)
    if step == 'clothing':
        # Заведующий, специалист и кладовая спецодежды — не механик гаража.
        return (('хозяйствен' in dept
                 and _norm(employee.job_title).startswith(_CLOTHING_TITLES))
                or employee.employee_id in _env_ids('ONBOARDING_CLOTHING_STAFF'))
    return False


def may_mark(step, viewer, item, newcomer, core):
    if viewer is None:
        return False
    if is_hr(viewer) or is_service(step, viewer, core):
        return True
    if step in ('workplace', 'mentor') and item.mentor_id == viewer.employee_id:
        return True
    if step == 'workplace' and newcomer is not None \
            and viewer.employee_id != newcomer.employee_id \
            and core._is_admin_role(viewer.job_title) \
            and _norm(viewer.department) == _norm(newcomer.department):
        return True
    return False


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

    def _steps(item):
        rows = OnboardingStep.query.filter_by(onboarding_id=item.id).all()
        return sorted(rows, key=lambda s: STEPS.index(s.step)
                      if s.step in STEPS else len(STEPS))

    def _json(item, steps, people, viewer):
        newcomer = people.get(item.employee_id)
        rows = []
        for s in steps:
            rows.append({
                'step': s.step,
                'done': s.done_at is not None,
                'done_at': _utc(s.done_at),
                'done_by': _person(people.get(s.done_by), s.done_by),
                'note': s.note or '',
                'can_mark': item.status == 'active'
                and may_mark(s.step, viewer, item, newcomer, core),
            })
        return {
            'id': item.id,
            'employee': _person(newcomer, item.employee_id),
            'mentor': _person(people.get(item.mentor_id), item.mentor_id),
            'start_date': item.start_date.isoformat(),
            'note': item.note or '',
            'status': item.status,
            'steps': rows,
            'done_count': sum(1 for r in rows if r['done']),
            'total': len(rows),
            'completed_at': _utc(item.completed_at),
            'is_mine': item.employee_id == viewer.employee_id,
            'can_manage': is_hr(viewer) and item.status == 'active',
        }

    def _full(items, viewer):
        steps = {i.id: _steps(i) for i in items}
        ids = []
        for i in items:
            ids += [i.employee_id, i.mentor_id] + [s.done_by for s in steps[i.id]]
        people = _names(ids)
        return [_json(i, steps[i.id], people, viewer) for i in items]

    def _relevant(item, viewer, newcomer, steps):
        """Видит ли человек этого новичка у себя: наставник или есть его пункт."""
        if item.mentor_id == viewer.employee_id:
            return True
        return any(s.done_at is None
                   and may_mark(s.step, viewer, item, newcomer, core)
                   for s in steps)

    def _may_see(item, viewer):
        if is_hr(viewer) or item.employee_id == viewer.employee_id:
            return True
        newcomer = db.session.get(Employee, item.employee_id)
        if item.mentor_id == viewer.employee_id:
            return True
        return any(may_mark(s.step, viewer, item, newcomer, core)
                   for s in _steps(item))

    def _owners(step, item, newcomer):
        if step == 'mentor':
            return [item.mentor_id]
        if step == 'workplace':
            heads = [e.employee_id for e in Employee.query.filter(
                Employee.department == (newcomer.department if newcomer else None))
                if core._is_admin_role(e.job_title)
                and e.employee_id != item.employee_id]
            return heads + [item.mentor_id]
        return [e.employee_id for e in Employee.query.all()
                if is_service(step, e, core)]

    def _notify(ids, title, body, ref, actor_id=None):
        ids = sorted({i for i in ids if i and i != actor_id})
        if ids:
            core._record_notice('onboarding', title[:200], body[:500],
                                employee_ids=ids, ref=ref)

    @app.route('/api/onboarding', methods=['GET'])
    @core.require_auth
    def onboarding_list():
        """Мой план (если я новичок) и новички, у которых есть мой пункт;
        кадрам — все текущие и закрытые за месяц."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        hr = is_hr(viewer)
        mine = (Onboarding.query.filter_by(employee_id=viewer.employee_id)
                .filter(Onboarding.status != 'cancelled')
                .order_by(Onboarding.created_at.desc()).first())
        since = datetime.utcnow() - _SHOW_DONE_FOR
        if hr:
            items = (Onboarding.query
                     .filter(db.or_(Onboarding.status == 'active',
                                    Onboarding.updated_at >= since))
                     .order_by(Onboarding.start_date.desc()).limit(200).all())
        else:
            items = []
            active = (Onboarding.query.filter_by(status='active')
                      .filter(Onboarding.employee_id != viewer.employee_id)
                      .order_by(Onboarding.start_date).limit(200).all())
            people = _names([i.employee_id for i in active])
            for item in active:
                if _relevant(item, viewer, people.get(item.employee_id), _steps(item)):
                    items.append(item)
        items = [i for i in items if i.employee_id != viewer.employee_id]
        items.sort(key=lambda i: (i.status != 'active', i.start_date))
        return jsonify({
            'message': 'Success',
            'hr': hr,
            'mine': _full([mine], viewer)[0] if mine else None,
            'items': _full(items, viewer),
        })

    @app.route('/api/onboarding/people', methods=['GET'])
    @core.require_auth
    def onboarding_people():
        """Кадрам: кого взять новичком или наставником, `?q=`."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not is_hr(viewer):
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

    @app.route('/api/onboarding', methods=['POST'])
    @core.require_auth
    def onboarding_create():
        """Кадрам: `{"employee_id", "start_date", "mentor_id", "steps": [...],
        "note"}`. Без `steps` — все пункты."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        if not is_hr(viewer):
            return core._deny()
        data = core._json_body()
        newcomer = db.session.get(Employee, core._text(data, 'employee_id'))
        if newcomer is None:
            return _fail('no_employee', 400)
        try:
            start = date.fromisoformat(core._text(data, 'start_date'))
        except ValueError:
            return _fail('bad_date', 400)
        today = core._plant_today()
        if not today - _MAX_BEHIND <= start <= today + _MAX_AHEAD:
            return _fail('bad_date', 400)
        mentor_id = core._text(data, 'mentor_id') or None
        if mentor_id:
            if mentor_id == newcomer.employee_id:
                return _fail('mentor_self', 400)
            if db.session.get(Employee, mentor_id) is None:
                return _fail('no_mentor', 400)
        raw = data.get('steps')
        if raw is None:
            steps = list(STEPS)
        elif not isinstance(raw, list) or not raw \
                or any(s not in STEPS for s in raw):
            return _fail('bad_steps', 400)
        else:
            steps = [s for s in STEPS if s in raw]
        if 'mentor' in steps and not mentor_id:
            return _fail('mentor_required', 400)
        if Onboarding.query.filter_by(employee_id=newcomer.employee_id,
                                      status='active').first():
            return _fail('exists', 409)
        now = datetime.utcnow()
        item = Onboarding(employee_id=newcomer.employee_id, start_date=start,
                          mentor_id=mentor_id, created_by=viewer.employee_id,
                          note=core._text(data, 'note')[:_MAX_NOTE] or None,
                          status='active', created_at=now, updated_at=now)
        db.session.add(item)
        db.session.flush()
        for step in steps:
            db.session.add(OnboardingStep(onboarding_id=item.id, step=step))
        db.session.commit()
        logging.info('План адаптации №%s для %s (%s)', item.id,
                     newcomer.employee_id, ', '.join(steps))
        when = start.strftime('%d.%m.%Y')
        _notify([newcomer.employee_id], 'Ваш план первых дней на заводе',
                f'Выход: {when}. Что уже готово и куда идти — в приложении',
                item.id, viewer.employee_id)
        if mentor_id:
            _notify([mentor_id], f'Вы наставник: {newcomer.full_name}',
                    f'Выход: {when}', item.id, viewer.employee_id)
        for step in steps:
            if step == 'mentor':
                continue
            owners = [o for o in _owners(step, item, newcomer) if o != mentor_id]
            _notify(owners, f'Новый сотрудник: {newcomer.full_name}',
                    f'Нужно: {STEP_TITLES[step]}. Выход: {when}', item.id,
                    viewer.employee_id)
        return jsonify({'message': 'Success', 'item': _full([item], viewer)[0]}), 201

    @app.route('/api/onboarding/<int:item_id>', methods=['GET'])
    @core.require_auth
    def onboarding_detail(item_id):
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(Onboarding, item_id)
        if item is None or not _may_see(item, viewer):
            return _fail('not_found', 404)
        return jsonify({'message': 'Success', 'item': _full([item], viewer)[0]})

    @app.route('/api/onboarding/<int:item_id>', methods=['POST'])
    @core.require_auth
    def onboarding_action(item_id):
        """`step` (`{"step", "done", "note"}`) — службе пункта, наставнику,
        кадрам; `mentor` (`{"mentor_id"}`) и `cancel` — кадрам."""
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        item = db.session.get(Onboarding, item_id)
        if item is None or not _may_see(item, viewer):
            return _fail('not_found', 404)
        data = core._json_body()
        action = core._text(data, 'action')
        hr = is_hr(viewer)
        newcomer = db.session.get(Employee, item.employee_id)
        name = newcomer.full_name if newcomer else item.employee_id
        now = datetime.utcnow()
        if action == 'step':
            step = OnboardingStep.query.filter_by(
                onboarding_id=item.id, step=core._text(data, 'step')).first()
            if step is None:
                return _fail('bad_step', 400)
            if item.status == 'cancelled':
                return _fail('closed', 409)
            if not may_mark(step.step, viewer, item, newcomer, core):
                return core._deny()
            done = data.get('done', True) is not False
            if done:
                if step.done_at is not None:
                    return _fail('already_done', 409)
                step.done_at = now
                step.done_by = viewer.employee_id
                step.note = core._text(data, 'note')[:_MAX_NOTE] or None
            else:
                if step.done_at is None:
                    return _fail('not_done', 409)
                if not hr and step.done_by != viewer.employee_id:
                    return core._deny()
                step.done_at = None
                step.done_by = None
                step.note = None
            steps = _steps(item)
            finished = all(s.done_at is not None for s in steps)
            was_done = item.status == 'done'
            item.status = 'done' if finished else 'active'
            item.completed_at = now if finished else None
            item.updated_at = now
            db.session.commit()
            logging.info('План адаптации №%s: %s %s (%s)', item.id, step.step,
                         'готово' if done else 'снято', viewer.employee_id)
            if done:
                _notify([item.employee_id], f'Готово: {STEP_TITLES[step.step]}',
                        step.note or viewer.full_name, item.id, viewer.employee_id)
            if finished and not was_done:
                _notify([item.created_by], f'Адаптация пройдена: {name}',
                        'Все пункты плана отмечены', item.id, viewer.employee_id)
        elif action == 'mentor':
            if not hr:
                return core._deny()
            if item.status != 'active':
                return _fail('closed', 409)
            mentor_id = core._text(data, 'mentor_id')
            if mentor_id == item.employee_id:
                return _fail('mentor_self', 400)
            if db.session.get(Employee, mentor_id) is None:
                return _fail('no_mentor', 400)
            if mentor_id == item.mentor_id:
                return _fail('same_mentor', 409)
            item.mentor_id = mentor_id
            item.updated_at = now
            db.session.commit()
            _notify([mentor_id], f'Вы наставник: {name}',
                    f'Выход: {item.start_date.strftime("%d.%m.%Y")}', item.id,
                    viewer.employee_id)
        elif action == 'cancel':
            if not hr:
                return core._deny()
            if item.status != 'active':
                return _fail('closed', 409)
            item.status = 'cancelled'
            item.updated_at = now
            db.session.commit()
        else:
            return _fail('bad_action', 400)
        return jsonify({'message': 'Success', 'item': _full([item], viewer)[0]})
