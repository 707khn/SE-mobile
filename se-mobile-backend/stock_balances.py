"""Остатки на складах из выгрузки 1С: «есть ли электроды МР-3 и где».

Сейчас мастер, технолог или снабженец звонит на склад, кладовщик идёт
смотреть, а потом выясняется, что электроды лежат на другом складе. Здесь
остатки — поиск по номенклатуре: сколько и на каком складе, по состоянию
на последнюю выгрузку.

Остатки грузятся отчётом из 1С в Excel — программкой с рабочего стола, как
справочник (tools/stock-upload). Логин и пароль — в теле запроса: грузит
администратор или Служба учёта ТМЦ. Загрузка заменяет остатки тех складов,
что есть в файле; остальные склады остаются как были. Файл без складов
заменяет всё.

Цены и суммы не хранятся: только наименование, код, единица, количество и
склад. Видят производство, ТО, ОТК, ДМТО, склад, службы главного инженера и
ХО, руководители и STOCK_VIEWERS — те, кому есть что брать со склада.
"""

import logging
import os
from datetime import datetime, timedelta

from flask import g, jsonify, request

from it_requests import _norm, _utc
from models import db
from parser_stock_excel import parse_stock_excel
from stock_requests import is_stock_staff

_STALE_AFTER = timedelta(days=3)
_MAX_ITEMS = 50
_MAX_ROWS = 600

_VIEWER_DEPARTMENTS = ('основное производство', 'технический отдел',
                       'технического контроля', 'материально-технического',
                       'учета тмц', 'главного инженера', 'хозяйствен',
                       'строительный участок', 'хранения вооружения',
                       'руководство')


class StockBalance(db.Model):
    __tablename__ = 'stock_balances'
    id = db.Column(db.Integer, primary_key=True)
    code = db.Column(db.String(50))
    name = db.Column(db.String(200), nullable=False)
    # Для поиска — без регистра, «ё» и лишних пробелов.
    name_key = db.Column(db.String(200), nullable=False, index=True)
    unit = db.Column(db.String(20))
    quantity = db.Column(db.Float, nullable=False)
    warehouse = db.Column(db.String(100), nullable=False, default='', index=True)
    uploaded_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class StockBalanceUpload(db.Model):
    __tablename__ = 'stock_balance_uploads'
    id = db.Column(db.Integer, primary_key=True)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    file_name = db.Column(db.String(200))
    rows = db.Column(db.Integer, nullable=False, default=0)
    warehouses = db.Column(db.Text)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def _key(text):
    return _norm(text)[:200]


def may_view(employee, core):
    if employee is None:
        return False
    if (core._is_system_admin(employee.job_title)
            or core._is_admin_role(employee.job_title)
            or employee.employee_id in _env_ids('STOCK_VIEWERS')):
        return True
    dept = _norm(employee.department).replace('учёта', 'учета')
    return any(key in dept for key in _VIEWER_DEPARTMENTS)


def may_upload(employee, core):
    if employee is None:
        return False
    return (core._is_system_admin(employee.job_title) or is_stock_staff(employee)
            or employee.employee_id in _env_ids('STOCK_UPLOADERS'))


def _merged(rows):
    """Одна позиция в нескольких строках склада (партии, серии) — одна строка."""
    merged = {}
    for row in rows:
        key = (row['warehouse'], row['code'] or _key(row['name']), row['unit'].lower())
        if key in merged:
            merged[key]['quantity'] += row['quantity']
        else:
            merged[key] = dict(row)
    return list(merged.values())


def register(app, core):
    from models import Employee

    @app.route('/api/stock-balances/import-excel', methods=['POST'])
    def import_stock_balances():
        """Остатки из Excel. Логин и пароль — в теле запроса, как у справочника."""
        login = (request.form.get('login') or '').strip()
        password = (request.form.get('password') or '').strip()
        employee_id = core._authenticate(login, password)
        if not employee_id:
            return core._credentials_refused(login)
        uploader = db.session.get(Employee, employee_id)
        if not may_upload(uploader, core):
            return jsonify({
                'message': 'Загружать остатки может администратор или '
                           'Служба учёта ТМЦ',
                'error': True,
            }), 403

        if 'file' not in request.files:
            return jsonify({'message': 'Файл не передан', 'error': True}), 400
        upload = request.files['file']
        file_name = upload.filename or ''
        if not file_name.lower().endswith(('.xlsx', '.xlsm')):
            return jsonify({'message': 'Нужен файл Excel (.xlsx)', 'error': True}), 400
        try:
            rows, skipped = parse_stock_excel(upload.read())
        except ValueError as e:
            return jsonify({'message': str(e), 'error': True}), 422

        rows = _merged(rows)
        warehouses = sorted({row['warehouse'] for row in rows})
        now = datetime.utcnow()
        try:
            stale = StockBalance.query
            if '' not in warehouses:
                stale = stale.filter(StockBalance.warehouse.in_(warehouses))
            stale.delete(synchronize_session=False)
            for row in rows:
                db.session.add(StockBalance(
                    code=row['code'] or None, name=row['name'],
                    name_key=_key(row['name']), unit=row['unit'] or None,
                    quantity=row['quantity'], warehouse=row['warehouse'],
                    uploaded_at=now))
            db.session.add(StockBalanceUpload(
                at=now, employee_id=employee_id, file_name=file_name[:200],
                rows=len(rows), warehouses='\n'.join(w for w in warehouses if w)))
            db.session.commit()
        except Exception as e:
            db.session.rollback()
            logging.error('Stock balances import failed: %s', e, exc_info=True)
            cause = str(getattr(e, 'orig', e)).strip().splitlines()
            detail = cause[0][:200] if cause else e.__class__.__name__
            return jsonify({'message': f'Сервер не смог сохранить остатки: {detail}',
                            'error': True}), 500

        named = [w for w in warehouses if w]
        logging.info('Stock balances by %s: %d rows, warehouses %s',
                     login, len(rows), named or 'all')
        message = f'Загружено: {len(rows)} позиций'
        if named:
            message += ', склады: ' + ', '.join(named)
        if skipped:
            message += f'. С нулевым остатком пропущено: {skipped}'
        return jsonify({'message': message, 'count': len(rows),
                        'warehouses': named, 'skipped': skipped})

    @app.route('/api/stock-balances', methods=['GET'])
    @core.require_auth
    def stock_balances_search():
        """`?q=электрод мр` — все слова должны найтись в наименовании; или код."""
        viewer = getattr(g, 'employee', None)
        if viewer is None:
            return jsonify({'message': 'Failure', 'error': 'unauthorized'}), 401
        if not may_view(viewer, core):
            return core._deny()

        loaded = (db.session.query(StockBalance.warehouse,
                                   db.func.max(StockBalance.uploaded_at))
                  .group_by(StockBalance.warehouse).all())
        as_of = max((at for _, at in loaded), default=None)
        oldest = min((at for _, at in loaded), default=None)
        body = {
            'message': 'Success',
            'as_of': _utc(as_of),
            # Хоть один склад не обновлялся три дня — остаток мог уйти.
            'stale': bool(oldest and datetime.utcnow() - oldest > _STALE_AFTER),
            'warehouses': [{'name': name, 'as_of': _utc(at)}
                           for name, at in sorted(loaded) if name],
            'items': [],
            'more': False,
        }
        query = (request.args.get('q') or '').strip()
        words = _key(query).split()
        if len(_key(query)) < 2:
            return jsonify(body)

        name_match = db.and_(*[StockBalance.name_key.contains(w, autoescape=True)
                               for w in words[:5]])
        found = (StockBalance.query
                 .filter(db.or_(name_match, StockBalance.code == query))
                 .order_by(StockBalance.name_key, StockBalance.warehouse)
                 .limit(_MAX_ROWS).all())

        groups = {}
        for row in found:
            key = (row.code or row.name_key, (row.unit or '').lower())
            item = groups.get(key)
            if item is None:
                item = groups[key] = {'code': row.code or '', 'name': row.name,
                                      'unit': row.unit or '', 'total': 0.0,
                                      'warehouses': []}
            item['total'] += row.quantity
            item['warehouses'].append({'name': row.warehouse,
                                       'quantity': row.quantity,
                                       'as_of': _utc(row.uploaded_at)})
        items = list(groups.values())
        body['items'] = items[:_MAX_ITEMS]
        body['more'] = len(items) > _MAX_ITEMS or len(found) >= _MAX_ROWS
        return jsonify(body)
