"""План-факт бюджета: руководитель видит свои статьи, не дожидаясь ПЭО.

Сейчас ПЭО раз в месяц сводит план-факт в Excel и рассылает начальникам
по почте — а начальник, у которого кончается лимит на материалы, узнаёт об
этом, когда заявку уже завернули. Здесь ПЭО грузит тот же отчёт программкой
с рабочего стола (tools/budget-upload), как справочник и остатки: логин и
пароль — в теле запроса. Загрузка заменяет месяцы и подразделения, что есть
в файле; остальное остаётся как было.

Видят: начальник подразделения и его заместитель — своё; руководство, ПЭО,
главный бухгалтер, системный администратор и BUDGET_VIEWERS — всё. Грузят:
ПЭО, системный администратор и BUDGET_UPLOADERS.

Если по загруженному месяцу факт статьи превысил план, начальнику
подразделения приходит оповещение — в ленту приложения: суммы бюджета —
внутренние сведения, и на телефон пушем им незачем.
"""

import logging
import os
from datetime import datetime

from flask import g, jsonify, request

from business_trips import is_head, is_top
from it_requests import _norm, _utc
from models import db
from parser_budget_excel import department_key, parse_budget_excel, parse_month

_MAX_NOTICE_ARTICLES = 3


class BudgetLine(db.Model):
    __tablename__ = 'budget_lines'
    __table_args__ = (db.Index('ix_budget_lines_period', 'year', 'department_key'),)
    id = db.Column(db.Integer, primary_key=True)
    year = db.Column(db.Integer, nullable=False)
    month = db.Column(db.Integer, nullable=False)
    department = db.Column(db.String(200), nullable=False)
    department_key = db.Column(db.String(200), nullable=False)
    article = db.Column(db.String(200), nullable=False)
    # Порядок статей — как в отчёте ПЭО, а не по алфавиту.
    position = db.Column(db.Integer, nullable=False, default=0)
    plan = db.Column(db.Float, nullable=False, default=0)
    fact = db.Column(db.Float, nullable=False, default=0)
    uploaded_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class BudgetUpload(db.Model):
    __tablename__ = 'budget_uploads'
    id = db.Column(db.Integer, primary_key=True)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    file_name = db.Column(db.String(200))
    rows = db.Column(db.Integer, nullable=False, default=0)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def _is_peo(employee):
    dept = _norm(employee.department)
    return 'планово-экономическ' in dept or '(пэо)' in dept


def may_upload(employee, core):
    if employee is None:
        return False
    return (_is_peo(employee) or core._is_system_admin(employee.job_title)
            or employee.employee_id in _env_ids('BUDGET_UPLOADERS'))


def sees_all(employee, core):
    if employee is None:
        return False
    return (is_top(employee) or _is_peo(employee)
            or core._is_system_admin(employee.job_title)
            or 'главный бухгалтер' in _norm(employee.job_title)
            or employee.employee_id in _env_ids('BUDGET_VIEWERS'))


def _money(value):
    return f'{round(value):,}'.replace(',', ' ')


def _month_name(month):
    return ('январь', 'февраль', 'март', 'апрель', 'май', 'июнь', 'июль',
            'август', 'сентябрь', 'октябрь', 'ноябрь', 'декабрь')[month - 1]


def register(app, core):
    from models import Employee

    def _fail(error, status, **extra):
        return jsonify({'message': 'Failure', 'error': error, **extra}), status

    def _directory_departments():
        return sorted({d for (d,) in db.session.query(Employee.department)
                       .filter(Employee.department.isnot(None)).distinct() if d})

    def _notify_overspent(lines):
        """Начальнику — статьи, где факт месяца больше плана."""
        over = {}
        for line in lines:
            if line['fact'] > line['plan'] + 0.5:
                over.setdefault((line['department'], line['year'], line['month']),
                                []).append(line)
        for (department, year, month), articles in sorted(over.items()):
            key = department_key(department)
            heads = sorted(e.employee_id for e in Employee.query.filter(
                Employee.department.isnot(None)).all()
                if department_key(e.department) == key and is_head(e))
            if not heads:
                continue
            shown = [f"{a['article']} — факт {_money(a['fact'])} при плане "
                     f"{_money(a['plan'])}" for a in articles[:_MAX_NOTICE_ARTICLES]]
            if len(articles) > _MAX_NOTICE_ARTICLES:
                shown.append(f'и ещё {len(articles) - _MAX_NOTICE_ARTICLES}')
            core._record_notice(
                'budget', f'Перерасход бюджета: {_month_name(month)} {year}',
                '; '.join(shown)[:500], employee_ids=heads,
                ref=str(year))

    @app.route('/api/budget/import-excel', methods=['POST'])
    def import_budget():
        """План-факт из Excel. Логин и пароль — в теле запроса, как у остатков."""
        login = (request.form.get('login') or '').strip()
        password = (request.form.get('password') or '').strip()
        employee_id = core._authenticate(login, password)
        if not employee_id:
            return core._credentials_refused(login)
        uploader = db.session.get(Employee, employee_id)
        if not may_upload(uploader, core):
            return jsonify({'message': 'Загружать бюджет может ПЭО или '
                                       'администратор', 'error': True}), 403
        if 'file' not in request.files:
            return jsonify({'message': 'Файл не передан', 'error': True}), 400
        upload = request.files['file']
        file_name = upload.filename or ''
        if not file_name.lower().endswith(('.xlsx', '.xlsm')):
            return jsonify({'message': 'Нужен файл Excel (.xlsx)', 'error': True}), 400
        # Месяц, если его нет в самом отчёте: из формы или из имени файла
        # («План-факт март 2030.xlsx»).
        period = (parse_month(request.form.get('period') or '')
                  or parse_month(file_name.rsplit('.', 1)[0]))
        known = _directory_departments()
        try:
            lines = parse_budget_excel(upload.read(), known, period=period)
        except ValueError as e:
            return jsonify({'message': str(e), 'error': True}), 422

        # Одна статья одного месяца в двух строках — суммируем.
        merged = {}
        for position, line in enumerate(lines):
            key = (line['year'], line['month'], department_key(line['department']),
                   _norm(line['article']))
            if key in merged:
                merged[key]['plan'] += line['plan']
                merged[key]['fact'] += line['fact']
            else:
                merged[key] = dict(line, position=position)
        lines = list(merged.values())
        scopes = sorted({(l['year'], l['month'], department_key(l['department']))
                         for l in lines})
        now = datetime.utcnow()
        try:
            for year, month, key in scopes:
                BudgetLine.query.filter_by(year=year, month=month,
                                           department_key=key).delete()
            for line in lines:
                db.session.add(BudgetLine(
                    year=line['year'], month=line['month'],
                    department=line['department'],
                    department_key=department_key(line['department']),
                    article=line['article'], position=line['position'],
                    plan=line['plan'], fact=line['fact'], uploaded_at=now))
            db.session.add(BudgetUpload(at=now, employee_id=employee_id,
                                        file_name=file_name[:200], rows=len(lines)))
            db.session.commit()
        except Exception as e:
            db.session.rollback()
            logging.error('Budget import failed: %s', e, exc_info=True)
            return jsonify({'message': 'Сервер не смог сохранить бюджет',
                            'error': True}), 500
        _notify_overspent(lines)

        departments = sorted({l['department'] for l in lines})
        known_keys = {department_key(d) for d in known}
        unknown = [d for d in departments if department_key(d) not in known_keys]
        months = sorted({(l['year'], l['month']) for l in lines})
        logging.info('Budget by %s: %d lines, %d departments, months %s',
                     login, len(lines), len(departments), months)
        message = (f'Загружено: {len(lines)} статей, подразделений: '
                   f'{len(departments)}, месяцы: '
                   + ', '.join(f'{_month_name(m)} {y}' for y, m in months))
        if unknown:
            # Их начальники бюджета не увидят: в справочнике таких нет.
            message += ('. Нет в справочнике (никто не увидит): '
                        + ', '.join(unknown[:10]))
        return jsonify({'message': message, 'count': len(lines),
                        'departments': departments, 'unknown': unknown})

    @app.route('/api/budget', methods=['GET'])
    @core.require_auth
    def budget_view():
        """`?year=2030&department=<название>` — статьи с планом и фактом."""
        viewer = getattr(g, 'employee', None)
        if viewer is None:
            return _fail('unauthorized', 401)
        everything = sees_all(viewer, core)
        own_key = department_key(viewer.department)
        if not everything and not (is_head(viewer) and own_key):
            return core._deny()

        years = sorted({y for (y,) in db.session.query(BudgetLine.year).distinct()},
                       reverse=True)
        today = core._plant_today()
        try:
            year = int(request.args.get('year') or (years[0] if years else today.year))
        except ValueError:
            return _fail('bad_year', 400)

        names = {}
        rows = (db.session.query(BudgetLine.department_key, BudgetLine.department)
                .filter(BudgetLine.year == year)
                .order_by(BudgetLine.department_key, BudgetLine.department).all())
        for key, name in rows:
            names.setdefault(key, name)
        if not everything:
            names = {k: v for k, v in names.items() if k == own_key}
        wanted = department_key(request.args.get('department') or '')
        if wanted and wanted not in names:
            return core._deny() if not everything else _fail('not_found', 404)
        key = wanted or (own_key if own_key in names else next(iter(names), ''))

        lines = (BudgetLine.query.filter_by(year=year, department_key=key)
                 .order_by(BudgetLine.month, BudgetLine.position, BudgetLine.id).all()
                 if key else [])
        articles = {}
        for line in lines:
            item = articles.setdefault(_norm(line.article), {
                'article': line.article, 'plan': 0.0, 'fact': 0.0,
                'position': line.position, 'months': []})
            item['plan'] += line.plan
            item['fact'] += line.fact
            item['position'] = min(item['position'], line.position)
            item['months'].append({'month': line.month, 'plan': line.plan,
                                   'fact': line.fact})
        ordered = sorted(articles.values(), key=lambda a: (a['position'], a['article']))
        for item in ordered:
            item.pop('position')
        return jsonify({
            'message': 'Success',
            'all': everything,
            'year': year,
            'years': years,
            'departments': [{'key': k, 'name': v}
                            for k, v in sorted(names.items(), key=lambda kv: kv[1])],
            'department': names.get(key, ''),
            'department_key': key,
            'months': sorted({line.month for line in lines}),
            'as_of': _utc(max((line.uploaded_at for line in lines), default=None)),
            'plan': sum(a['plan'] for a in ordered),
            'fact': sum(a['fact'] for a in ordered),
            'articles': ordered,
        })
