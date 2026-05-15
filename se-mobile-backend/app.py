import os
import logging
from datetime import date, datetime
from flask import Flask, request, jsonify
from flask_cors import CORS
from models import (db, Employee, AccessRecord, Payslip,
                    PayslipAccrual, PayslipDeduction, PayslipPaid, PayslipBenefit,
                    PayslipReference, LeaveBalance, LeaveHistory,
                    FcmToken, TurnstileEvent, MenuDate, MenuItem)
from parser_1c_xml import parse_1c_xml

try:
    import firebase_admin
    from firebase_admin import credentials, messaging as fb_messaging
    _FIREBASE_AVAILABLE = True
except ImportError:
    _FIREBASE_AVAILABLE = False

_fb_app = None


def _get_firebase():
    global _fb_app
    if not _FIREBASE_AVAILABLE:
        return None
    if _fb_app is None:
        cred_path = os.environ.get('FIREBASE_CREDENTIALS_PATH', 'firebase-credentials.json')
        if os.path.exists(cred_path):
            try:
                cred = credentials.Certificate(cred_path)
                _fb_app = firebase_admin.initialize_app(cred)
            except Exception as e:
                logging.warning(f'Firebase init failed: {e}')
    return _fb_app


def _is_admin_role(job_title: str) -> bool:
    j = job_title.lower()
    return any(k in j for k in ('руководитель', 'начальник', 'директор', 'главный', 'заместитель'))


def _send_turnstile_notification(employee_name: str, direction: str, timestamp_str: str, employee_id: str):
    if not _get_firebase():
        return
    admin_employee_ids = [
        e.employee_id for e in Employee.query.all() if _is_admin_role(e.job_title)
    ]
    if not admin_employee_ids:
        return
    tokens = [
        t.token for t in FcmToken.query.filter(
            FcmToken.employee_id.in_(admin_employee_ids)
        ).all()
    ]
    if not tokens:
        return
    direction_text = 'вошёл' if direction == 'in' else 'вышел'
    message = fb_messaging.MulticastMessage(
        tokens=tokens,
        notification=fb_messaging.Notification(
            title='СКУД — проход сотрудника',
            body=f'{employee_name} {direction_text} в {timestamp_str}',
        ),
        data={'type': 'turnstile', 'employee_id': employee_id, 'direction': direction},
    )
    try:
        resp = fb_messaging.send_each_for_multicast(message)
        invalid_tokens = set()
        for i, r in enumerate(resp.responses):
            if not r.success and r.exception:
                code = getattr(r.exception, 'code', '')
                if code in ('registration-token-not-registered', 'invalid-argument'):
                    invalid_tokens.add(tokens[i])
        if invalid_tokens:
            FcmToken.query.filter(FcmToken.token.in_(invalid_tokens)).delete(synchronize_session=False)
            db.session.commit()
    except Exception as e:
        logging.warning(f'FCM send failed: {e}')


def _migrate_schema():
    """Add columns missing from existing tables without dropping data."""
    from sqlalchemy import text, inspect
    inspector = inspect(db.engine)
    tables = inspector.get_table_names()

    if 'payslips' in tables:
        existing = {c['name'] for c in inspector.get_columns('payslips')}
        missing = {
            'position':    'VARCHAR(200)',
            'department':  'VARCHAR(200)',
            'salary_rate': 'FLOAT DEFAULT 0',
            'debt_start':  'FLOAT DEFAULT 0',
            'debt_end':    'FLOAT DEFAULT 0',
            'total_paid':  'FLOAT DEFAULT 0',
        }
        with db.engine.connect() as conn:
            for col, typedef in missing.items():
                if col not in existing:
                    conn.execute(text(f'ALTER TABLE payslips ADD COLUMN "{col}" {typedef}'))
                    logging.info(f'Migration: added payslips.{col}')
            conn.commit()


def create_app():
    app = Flask(__name__)
    CORS(app)

    logging.basicConfig(level=logging.INFO)

    db_url = os.environ.get('DATABASE_URL', 'sqlite:///se_mobile.db')
    # Render выдаёт postgres://, SQLAlchemy требует postgresql://
    if db_url.startswith('postgres://'):
        db_url = db_url.replace('postgres://', 'postgresql://', 1)
    # Маскируем пароль в логе
    safe_url = db_url.split('@')[-1] if '@' in db_url else db_url
    logging.info(f'DB backend: {safe_url}')
    app.config['SQLALCHEMY_DATABASE_URI'] = db_url
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

    db.init_app(app)

    with app.app_context():
        logging.info('Running db.create_all()...')
        db.create_all()
        _migrate_schema()
        logging.info('db.create_all() done')
        try:
            _auto_seed()
            _seed_2024_full()
            _seed_2025_full()
            _seed_2026()
            _seed_2026_full()
            _seed_may_2026()
            _seed_turnstile_events()
            _seed_leave_2026()
        except Exception as e:
            logging.error(f'Seeding failed (non-fatal): {e}', exc_info=True)

    register_routes(app)
    return app


def register_routes(app):

    @app.route('/')
    def index():
        return jsonify({
            'status': 'ok',
            'service': 'SE-mobile API',
            'version': '3.0 (PostgreSQL + FCM + Canteen)',
            'endpoints': [
                'POST /login',
                'POST /report',
                'POST /reportdate',
                'POST /director_report',
                'POST /get_sname',
                'POST /payslip',
                'POST /leaves',
                'POST /api/fcm-token',
                'DELETE /api/fcm-token',
                'POST /api/turnstile',
                'GET /api/attendance',
                'GET /api/attendance/summary',
                'GET /api/menu',
                'POST /api/menu',
                'DELETE /api/menu/<date>',
            ]
        })

    @app.route('/login', methods=['POST'])
    def login():
        data = request.get_json()
        iin = data.get('iin', '').strip()

        emp = Employee.query.filter_by(iin=iin).first()
        if emp and iin != '':
            return jsonify({
                'message': 'Success',
                'full_name': emp.full_name,
                'job': emp.job_title,
                'employee_id': emp.employee_id,
            })
        return jsonify({'message': 'Failure'})

    @app.route('/report', methods=['POST'])
    def report():
        data = request.get_json()
        key_suffix = data.get('key_suffix', '')

        records = AccessRecord.query.filter_by(employee_id=key_suffix)\
            .order_by(AccessRecord.access_date, AccessRecord.access_time).all()
        if not records:
            return jsonify({'message': 'Failure'})
        return jsonify({
            'message': 'Success',
            'report': [_access_to_dict(r) for r in records]
        })

    @app.route('/reportdate', methods=['POST'])
    def reportdate():
        data = request.get_json()
        key_suffix = data.get('key_suffix', '')
        start_date = data.get('start_date', '')
        end_date = data.get('end_date', '')

        records = AccessRecord.query.filter(
            AccessRecord.employee_id == key_suffix,
            AccessRecord.access_date >= start_date,
            AccessRecord.access_date <= end_date
        ).order_by(AccessRecord.access_date, AccessRecord.access_time).all()

        if not records:
            return jsonify({'message': 'Failure'})
        return jsonify({
            'message': 'Success',
            'report': [_access_to_dict(r) for r in records]
        })

    @app.route('/director_report', methods=['POST'])
    def director_report():
        data = request.get_json()
        emp_sname = data.get('emp_sname', '')
        start_date = data.get('start_date', '')
        end_date = data.get('end_date', '')

        emp = Employee.query.filter(Employee.full_name.contains(emp_sname)).first()
        if not emp:
            return jsonify({'message': 'Failure'})

        records = AccessRecord.query.filter(
            AccessRecord.employee_id == emp.employee_id,
            AccessRecord.access_date >= start_date,
            AccessRecord.access_date <= end_date
        ).order_by(AccessRecord.access_date, AccessRecord.access_time).all()

        if not records:
            return jsonify({'message': 'Failure'})
        return jsonify({
            'message': 'Success',
            'director_report': [_access_to_dict(r) for r in records]
        })

    @app.route('/get_sname', methods=['POST'])
    def get_sname():
        data = request.get_json()

        if 'key_suffix' in data:
            employees = Employee.query.all()
            return jsonify({'fio': [e.full_name for e in employees]})

        if 'emp_iin' in data:
            emp = Employee.query.filter_by(iin=data['emp_iin']).first()
            if emp:
                return jsonify({
                    'message': 'Success',
                    'employee': [{
                        'full_name': emp.full_name,
                        'job': emp.job_title,
                        'iin': emp.iin
                    }]
                })
            return jsonify({'message': 'Failure'})

        return jsonify({'message': 'Failure'})

    @app.route('/payslip', methods=['POST'])
    def payslip():
        data = request.get_json()
        key_suffix = data.get('key_suffix', '')
        month = data.get('month', '')
        year = data.get('year', '')

        ps = Payslip.query.filter_by(
            employee_id=key_suffix,
            period_month=int(month),
            period_year=int(year)
        ).first()

        if not ps:
            return jsonify({'message': 'Failure'})

        return jsonify({
            'message': 'Success',
            'payslip': {
                'period': ps.period_display,
                'employee': ps.employee.full_name,
                'position': ps.position or '',
                'department': ps.department or '',
                'accruals': [
                    {'name': a.name, 'amount': a.amount,
                     'period': a.period or '', 'working_days': a.working_days,
                     'working_hours': a.working_hours}
                    for a in ps.accruals
                ],
                'deductions': [
                    {'name': d.name, 'amount': d.amount, 'period': d.period or ''}
                    for d in ps.deductions
                ],
                'paid': [
                    {'payment_type': p.payment_type or '', 'period': p.period or '',
                     'document': p.document or '', 'date': p.date or '', 'amount': p.amount}
                    for p in ps.paid
                ],
                'benefits': [{'name': b.name, 'amount': b.amount} for b in ps.benefits],
                'reference': [{'name': r.name, 'amount': r.amount} for r in ps.reference],
                'total_accruals': ps.total_accruals,
                'total_deductions': ps.total_deductions,
                'total_paid': ps.total_paid or 0.0,
                'net_pay': ps.net_pay,
                'debt_start': ps.debt_start or 0.0,
                'debt_end': ps.debt_end or 0.0,
            }
        })

    @app.route('/api/admin/upload-payslip-xml', methods=['POST'])
    def upload_payslip_xml():
        admin_token = os.environ.get('ADMIN_TOKEN', '')
        if admin_token:
            provided = request.headers.get('X-Admin-Token', '')
            if provided != admin_token:
                return jsonify({'message': 'Forbidden'}), 403

        if 'file' not in request.files:
            return jsonify({'message': 'Файл не передан', 'error': True}), 400

        file = request.files['file']
        if not file.filename.lower().endswith('.xml'):
            return jsonify({'message': 'Ожидается XML файл', 'error': True}), 400

        try:
            payslips = parse_1c_xml(file.read())
        except ValueError as e:
            return jsonify({'message': str(e), 'error': True}), 422

        imported = []
        for slip in payslips:
            emp_id = slip['employee_1c_id']

            emp = Employee.query.get(emp_id)
            if emp is None:
                emp = Employee(
                    employee_id=emp_id,
                    full_name=slip['full_name'],
                    job_title=slip['position'] or 'Сотрудник',
                    iin=None,
                )
                db.session.add(emp)
                db.session.flush()
            else:
                if slip['full_name']:
                    emp.full_name = slip['full_name']
                if slip['position']:
                    emp.job_title = slip['position']

            ps = Payslip.query.filter_by(
                employee_id=emp_id,
                period_year=slip['period_year'],
                period_month=slip['period_month'],
            ).first()

            if ps is None:
                ps = Payslip(
                    employee_id=emp_id,
                    period_month=slip['period_month'],
                    period_year=slip['period_year'],
                    period_display=slip['period_display'],
                    total_accruals=slip['total_accruals'],
                    total_deductions=slip['total_deductions'],
                    net_pay=slip['net_pay'],
                    position=slip['position'],
                    department=slip['department'],
                    salary_rate=slip['salary_rate'],
                    debt_start=slip['debt_start'],
                    debt_end=slip['debt_end'],
                    total_paid=slip['total_paid'],
                )
                db.session.add(ps)
                db.session.flush()
            else:
                ps.period_display = slip['period_display']
                ps.total_accruals = slip['total_accruals']
                ps.total_deductions = slip['total_deductions']
                ps.net_pay = slip['net_pay']
                ps.position = slip['position']
                ps.department = slip['department']
                ps.salary_rate = slip['salary_rate']
                ps.debt_start = slip['debt_start']
                ps.debt_end = slip['debt_end']
                ps.total_paid = slip['total_paid']
                PayslipAccrual.query.filter_by(payslip_id=ps.id).delete()
                PayslipDeduction.query.filter_by(payslip_id=ps.id).delete()
                PayslipPaid.query.filter_by(payslip_id=ps.id).delete()
                PayslipBenefit.query.filter_by(payslip_id=ps.id).delete()
                PayslipReference.query.filter_by(payslip_id=ps.id).delete()

            for a in slip['accruals']:
                db.session.add(PayslipAccrual(
                    payslip_id=ps.id, name=a['name'], amount=a['amount'],
                    period=a['period'], working_days=a['working_days'],
                    working_hours=a['working_hours'],
                ))
            for d in slip['deductions']:
                db.session.add(PayslipDeduction(
                    payslip_id=ps.id, name=d['name'], amount=d['amount'],
                    period=d['period'],
                ))
            for p in slip['paid']:
                db.session.add(PayslipPaid(
                    payslip_id=ps.id, payment_type=p['payment_type'],
                    period=p['period'], document=p['document'],
                    date=p['date'], amount=p['amount'],
                ))
            for b in slip['benefits']:
                db.session.add(PayslipBenefit(
                    payslip_id=ps.id, name=b['name'], amount=b['amount'],
                ))
            for r in slip['reference']:
                db.session.add(PayslipReference(
                    payslip_id=ps.id, name=r['name'], amount=r['amount'],
                ))

            imported.append({
                'employee_id': emp_id,
                'full_name': slip['full_name'],
                'period': slip['period_display'],
            })

        db.session.commit()
        return jsonify({
            'message': 'Success',
            'imported': len(imported),
            'employees': imported,
        })

    @app.route('/leaves', methods=['POST'])
    def leaves():
        data = request.get_json()
        key_suffix = data.get('key_suffix', '')

        emp = Employee.query.get(key_suffix)
        if not emp:
            return jsonify({'message': 'Failure'})

        balances = LeaveBalance.query.filter_by(employee_id=key_suffix).all()
        history = LeaveHistory.query.filter_by(employee_id=key_suffix)\
            .order_by(LeaveHistory.start_date.desc()).all()

        return jsonify({
            'message': 'Success',
            'leaves': {
                'employee': emp.full_name,
                'balances': [{
                    'type': b.leave_type,
                    'total_days': b.total_days,
                    'used_days': b.used_days,
                    'remaining_days': b.remaining_days
                } for b in balances],
                'history': [{
                    'type': h.leave_type,
                    'start_date': h.start_date.isoformat(),
                    'end_date': h.end_date.isoformat(),
                    'days': h.days,
                    'status': h.status
                } for h in history]
            }
        })


    # ── FCM token registration ────────────────────────────────────────────────

    @app.route('/api/fcm-token', methods=['POST'])
    def register_fcm_token():
        data = request.get_json() or {}
        employee_id = data.get('employee_id', '').strip()
        token = data.get('token', '').strip()
        if not employee_id or not token:
            return jsonify({'message': 'Failure', 'error': 'employee_id and token required'}), 400
        emp = Employee.query.get(employee_id)
        if not emp:
            return jsonify({'message': 'Failure', 'error': 'Employee not found'}), 404
        existing = FcmToken.query.filter_by(token=token).first()
        if existing:
            existing.employee_id = employee_id
        else:
            db.session.add(FcmToken(employee_id=employee_id, token=token))
        db.session.commit()
        return jsonify({'message': 'Success'})

    @app.route('/api/fcm-token', methods=['DELETE'])
    def unregister_fcm_token():
        data = request.get_json() or {}
        token = data.get('token', '').strip()
        if not token:
            return jsonify({'message': 'Failure', 'error': 'token required'}), 400
        FcmToken.query.filter_by(token=token).delete()
        db.session.commit()
        return jsonify({'message': 'Success'})

    # ── СКУД turnstile webhook ────────────────────────────────────────────────

    @app.route('/api/turnstile', methods=['POST'])
    def turnstile_event():
        data = request.get_json() or {}
        secret = data.get('secret', '')
        expected = os.environ.get('TURNSTILE_SECRET', '')
        if expected and secret != expected:
            return jsonify({'message': 'Failure', 'error': 'Unauthorized'}), 403

        employee_id = data.get('employee_id', '').strip()
        direction = data.get('direction', '').strip()  # 'in' | 'out'
        ts_raw = data.get('timestamp')

        if not employee_id or direction not in ('in', 'out'):
            return jsonify({'message': 'Failure', 'error': 'employee_id and direction required'}), 400

        emp = Employee.query.get(employee_id)
        if not emp:
            return jsonify({'message': 'Failure', 'error': 'Employee not found'}), 404

        if ts_raw:
            try:
                ts = datetime.fromisoformat(ts_raw)
            except ValueError:
                ts = datetime.utcnow()
        else:
            ts = datetime.utcnow()

        event = TurnstileEvent(employee_id=employee_id, direction=direction, timestamp=ts)
        db.session.add(event)
        db.session.commit()

        ts_str = ts.strftime('%H:%M')
        _send_turnstile_notification(emp.full_name, direction, ts_str, employee_id)

        return jsonify({'message': 'Success', 'id': event.id})

    # ── Attendance statistics ─────────────────────────────────────────────────

    @app.route('/api/attendance', methods=['GET'])
    def attendance():
        date_str = request.args.get('date', date.today().isoformat())
        try:
            query_date = date.fromisoformat(date_str)
        except ValueError:
            return jsonify({'message': 'Failure', 'error': 'Invalid date'}), 400

        events = TurnstileEvent.query.filter(
            db.func.date(TurnstileEvent.timestamp) == query_date
        ).order_by(TurnstileEvent.timestamp).all()

        result = []
        for e in events:
            emp = Employee.query.get(e.employee_id)
            result.append({
                'id': e.id,
                'employee_id': e.employee_id,
                'full_name': emp.full_name if emp else e.employee_id,
                'direction': e.direction,
                'timestamp': e.timestamp.isoformat(),
            })
        return jsonify({'message': 'Success', 'date': date_str, 'events': result})

    @app.route('/api/attendance/summary', methods=['GET'])
    def attendance_summary():
        month_str = request.args.get('month', date.today().strftime('%Y-%m'))
        try:
            year, month = (int(x) for x in month_str.split('-'))
        except (ValueError, AttributeError):
            return jsonify({'message': 'Failure', 'error': 'Invalid month, use YYYY-MM'}), 400

        events = TurnstileEvent.query.filter(
            db.extract('year', TurnstileEvent.timestamp) == year,
            db.extract('month', TurnstileEvent.timestamp) == month,
        ).order_by(TurnstileEvent.timestamp).all()

        by_day: dict = {}
        for e in events:
            day_key = e.timestamp.date().isoformat()
            emp = Employee.query.get(e.employee_id)
            name = emp.full_name if emp else e.employee_id
            entry = by_day.setdefault(day_key, {'date': day_key, 'arrivals': 0, 'departures': 0, 'employees': {}})
            if e.direction == 'in':
                entry['arrivals'] += 1
            else:
                entry['departures'] += 1
            entry['employees'].setdefault(e.employee_id, {'full_name': name, 'in': None, 'out': None})
            if e.direction == 'in' and entry['employees'][e.employee_id]['in'] is None:
                entry['employees'][e.employee_id]['in'] = e.timestamp.strftime('%H:%M')
            if e.direction == 'out':
                entry['employees'][e.employee_id]['out'] = e.timestamp.strftime('%H:%M')

        days_list = []
        for day_key in sorted(by_day):
            d = by_day[day_key]
            d['employees'] = list(d['employees'].values())
            days_list.append(d)

        return jsonify({'message': 'Success', 'month': month_str, 'days': days_list})

    # ── Canteen menu ──────────────────────────────────────────────────────────

    @app.route('/api/menu', methods=['GET'])
    def get_menu():
        date_str = request.args.get('date', date.today().isoformat())
        try:
            query_date = date.fromisoformat(date_str)
        except ValueError:
            return jsonify({'message': 'Failure', 'error': 'Invalid date'}), 400

        menu = MenuDate.query.filter_by(date=query_date).first()
        if not menu:
            return jsonify({'message': 'Success', 'date': date_str, 'items': []})

        items = [{'id': i.id, 'category': i.category, 'name': i.name,
                  'price': float(i.price) if i.price is not None else None}
                 for i in menu.items]
        return jsonify({'message': 'Success', 'date': date_str, 'items': items})

    @app.route('/api/menu', methods=['POST'])
    def save_menu():
        data = request.get_json() or {}
        date_str = data.get('date', '')
        items_data = data.get('items', [])
        try:
            menu_date = date.fromisoformat(date_str)
        except (ValueError, TypeError):
            return jsonify({'message': 'Failure', 'error': 'Invalid or missing date'}), 400

        menu = MenuDate.query.filter_by(date=menu_date).first()
        if menu:
            MenuItem.query.filter_by(menu_date_id=menu.id).delete()
        else:
            menu = MenuDate(date=menu_date)
            db.session.add(menu)
            db.session.flush()

        for item in items_data:
            category = str(item.get('category', '')).strip()
            name = str(item.get('name', '')).strip()
            price = item.get('price')
            if not category or not name:
                continue
            db.session.add(MenuItem(
                menu_date_id=menu.id,
                category=category,
                name=name,
                price=float(price) if price is not None else None,
            ))

        db.session.commit()
        return jsonify({'message': 'Success'})

    @app.route('/api/menu/<date_str>', methods=['DELETE'])
    def delete_menu(date_str):
        try:
            menu_date = date.fromisoformat(date_str)
        except ValueError:
            return jsonify({'message': 'Failure', 'error': 'Invalid date'}), 400
        menu = MenuDate.query.filter_by(date=menu_date).first()
        if menu:
            db.session.delete(menu)
            db.session.commit()
        return jsonify({'message': 'Success'})


def _access_to_dict(record):
    return {
        'date': record.access_date.isoformat(),
        'time': record.access_time,
        'event': record.event_type,
        'door': record.door_location
    }


def _auto_seed():
    if Employee.query.first():
        return

    e1 = Employee(employee_id='001', full_name='Ахметов Асан Бекович', job_title='Инженер', iin='900101350123')
    e2 = Employee(employee_id='002', full_name='Касымов Нурлан Серикович', job_title='Руководитель отдела', iin='850515400456')
    e3 = Employee(employee_id='003', full_name='Сидорова Анна Сергеевна', job_title='Бухгалтер', iin='920720450789')
    db.session.add_all([e1, e2, e3])

    for eid, d, t, ev, door in [
        ('001', '2024-01-15', '08:55', 'Вход', 'Главный вход'),
        ('001', '2024-01-15', '18:05', 'Выход', 'Главный вход'),
        ('001', '2024-01-16', '08:50', 'Вход', 'Главный вход'),
        ('001', '2024-01-16', '18:10', 'Выход', 'Главный вход'),
        ('001', '2024-02-01', '09:00', 'Вход', 'Главный вход'),
        ('001', '2024-02-01', '18:00', 'Выход', 'Главный вход'),
        ('002', '2024-01-15', '08:30', 'Вход', 'Офис'),
        ('002', '2024-01-15', '19:00', 'Выход', 'Офис'),
        ('002', '2024-01-16', '08:40', 'Вход', 'Офис'),
        ('002', '2024-01-16', '18:30', 'Выход', 'Офис'),
        ('003', '2024-01-15', '08:45', 'Вход', 'Бухгалтерия'),
        ('003', '2024-01-15', '17:45', 'Выход', 'Бухгалтерия'),
        ('003', '2024-01-16', '08:50', 'Вход', 'Бухгалтерия'),
        ('003', '2024-01-16', '17:50', 'Выход', 'Бухгалтерия'),
    ]:
        y, m, day = d.split('-')
        db.session.add(AccessRecord(
            employee_id=eid, access_date=date(int(y), int(m), int(day)),
            access_time=t, event_type=ev, door_location=door
        ))

    for eid, month, year, display, accs, deds, ta, td, np in [
        ('001', 1, 2024, 'Январь 2024',
         [('Оклад', 350000), ('Премия', 50000), ('Надбавка за стаж', 17500)],
         [('ИПН (10%)', 41750), ('ОПВ (10%)', 41750), ('ВОСМС (2%)', 8350)],
         417500, 91850, 325650),
        ('001', 2, 2024, 'Февраль 2024',
         [('Оклад', 350000), ('Надбавка за стаж', 17500)],
         [('ИПН (10%)', 36750), ('ОПВ (10%)', 36750), ('ВОСМС (2%)', 7350)],
         367500, 80850, 286650),
        ('002', 1, 2024, 'Январь 2024',
         [('Оклад', 500000), ('Премия за KPI', 100000)],
         [('ИПН (10%)', 60000), ('ОПВ (10%)', 60000), ('ВОСМС (2%)', 12000)],
         600000, 132000, 468000),
        ('002', 2, 2024, 'Февраль 2024',
         [('Оклад', 500000)],
         [('ИПН (10%)', 50000), ('ОПВ (10%)', 50000), ('ВОСМС (2%)', 10000)],
         500000, 110000, 390000),
        ('003', 1, 2024, 'Январь 2024',
         [('Оклад', 280000)],
         [('ИПН (10%)', 28000), ('ОПВ (10%)', 28000), ('ВОСМС (2%)', 5600)],
         280000, 61600, 218400),
    ]:
        ps = Payslip(employee_id=eid, period_month=month, period_year=year,
                     period_display=display, total_accruals=ta,
                     total_deductions=td, net_pay=np)
        db.session.add(ps)
        db.session.flush()
        for name, amount in accs:
            db.session.add(PayslipAccrual(payslip_id=ps.id, name=name, amount=amount))
        for name, amount in deds:
            db.session.add(PayslipDeduction(payslip_id=ps.id, name=name, amount=amount))

    for eid, lt, total, used, rem in [
        ('001', 'Ежегодный трудовой отпуск', 24, 10, 14),
        ('001', 'Экологический отпуск', 10, 0, 10),
        ('002', 'Ежегодный трудовой отпуск', 30, 24, 6),
        ('002', 'Экологический отпуск', 10, 5, 5),
        ('003', 'Ежегодный трудовой отпуск', 24, 0, 24),
        ('003', 'Экологический отпуск', 10, 0, 10),
    ]:
        db.session.add(LeaveBalance(
            employee_id=eid, leave_type=lt,
            total_days=total, used_days=used, remaining_days=rem
        ))

    for eid, lt, sd, ed, days, status in [
        ('001', 'Ежегодный трудовой отпуск', '2024-01-15', '2024-01-24', 10, 'Утверждён'),
        ('001', 'Больничный лист', '2023-11-05', '2023-11-12', 7, 'Закрыт'),
        ('001', 'Больничный лист', '2023-06-20', '2023-06-23', 3, 'Закрыт'),
        ('002', 'Ежегодный трудовой отпуск', '2024-02-01', '2024-02-14', 14, 'Утверждён'),
        ('002', 'Ежегодный трудовой отпуск', '2023-07-10', '2023-07-19', 10, 'Утверждён'),
        ('002', 'Экологический отпуск', '2023-09-01', '2023-09-05', 5, 'Утверждён'),
        ('003', 'Больничный лист', '2024-01-08', '2024-01-12', 5, 'Закрыт'),
    ]:
        sy, sm, sday = sd.split('-')
        ey, em, eday = ed.split('-')
        db.session.add(LeaveHistory(
            employee_id=eid, leave_type=lt,
            start_date=date(int(sy), int(sm), int(sday)),
            end_date=date(int(ey), int(em), int(eday)),
            days=days, status=status
        ))

    db.session.commit()


def _seed_2026():
    exists = AccessRecord.query.filter(
        AccessRecord.access_date >= date(2026, 1, 1)
    ).first()
    if exists:
        return

    # ─── Турникет Январь-Апрель 2026 ───────────────────
    for eid, d, t, ev, door in [
        # Иванов — Январь 2026
        ('001', '2026-01-12', '08:50', 'Вход', 'Главный вход'),
        ('001', '2026-01-12', '18:10', 'Выход', 'Главный вход'),
        ('001', '2026-01-13', '08:55', 'Вход', 'Главный вход'),
        ('001', '2026-01-13', '18:00', 'Выход', 'Главный вход'),
        ('001', '2026-01-14', '09:02', 'Вход', 'Главный вход'),
        ('001', '2026-01-14', '18:15', 'Выход', 'Главный вход'),
        # Иванов — Февраль 2026
        ('001', '2026-02-02', '08:45', 'Вход', 'Главный вход'),
        ('001', '2026-02-02', '18:05', 'Выход', 'Главный вход'),
        ('001', '2026-02-03', '08:58', 'Вход', 'Главный вход'),
        ('001', '2026-02-03', '18:20', 'Выход', 'Главный вход'),
        ('001', '2026-02-04', '08:52', 'Вход', 'Главный вход'),
        ('001', '2026-02-04', '18:00', 'Выход', 'Главный вход'),
        # Иванов — Март 2026
        ('001', '2026-03-02', '08:48', 'Вход', 'Главный вход'),
        ('001', '2026-03-02', '18:12', 'Выход', 'Главный вход'),
        ('001', '2026-03-03', '08:55', 'Вход', 'Главный вход'),
        ('001', '2026-03-03', '18:05', 'Выход', 'Главный вход'),
        ('001', '2026-03-04', '09:00', 'Вход', 'Главный вход'),
        ('001', '2026-03-04', '18:10', 'Выход', 'Главный вход'),
        # Иванов — Апрель 2026
        ('001', '2026-04-01', '08:50', 'Вход', 'Главный вход'),
        ('001', '2026-04-01', '18:00', 'Выход', 'Главный вход'),
        ('001', '2026-04-02', '08:47', 'Вход', 'Главный вход'),
        ('001', '2026-04-02', '18:08', 'Выход', 'Главный вход'),
        ('001', '2026-04-03', '08:53', 'Вход', 'Главный вход'),
        ('001', '2026-04-03', '18:15', 'Выход', 'Главный вход'),
        # Петров — Январь-Апрель 2026
        ('002', '2026-01-12', '08:30', 'Вход', 'Офис'),
        ('002', '2026-01-12', '19:00', 'Выход', 'Офис'),
        ('002', '2026-01-13', '08:25', 'Вход', 'Офис'),
        ('002', '2026-01-13', '18:45', 'Выход', 'Офис'),
        ('002', '2026-02-02', '08:35', 'Вход', 'Офис'),
        ('002', '2026-02-02', '18:50', 'Выход', 'Офис'),
        ('002', '2026-02-03', '08:28', 'Вход', 'Офис'),
        ('002', '2026-02-03', '19:10', 'Выход', 'Офис'),
        ('002', '2026-03-02', '08:30', 'Вход', 'Офис'),
        ('002', '2026-03-02', '18:55', 'Выход', 'Офис'),
        ('002', '2026-03-03', '08:32', 'Вход', 'Офис'),
        ('002', '2026-03-03', '19:00', 'Выход', 'Офис'),
        ('002', '2026-04-01', '08:28', 'Вход', 'Офис'),
        ('002', '2026-04-01', '18:40', 'Выход', 'Офис'),
        ('002', '2026-04-02', '08:35', 'Вход', 'Офис'),
        ('002', '2026-04-02', '19:05', 'Выход', 'Офис'),
        # Сидорова — Январь-Апрель 2026
        ('003', '2026-01-12', '08:40', 'Вход', 'Бухгалтерия'),
        ('003', '2026-01-12', '17:50', 'Выход', 'Бухгалтерия'),
        ('003', '2026-01-13', '08:45', 'Вход', 'Бухгалтерия'),
        ('003', '2026-01-13', '17:55', 'Выход', 'Бухгалтерия'),
        ('003', '2026-02-02', '08:42', 'Вход', 'Бухгалтерия'),
        ('003', '2026-02-02', '17:48', 'Выход', 'Бухгалтерия'),
        ('003', '2026-02-03', '08:50', 'Вход', 'Бухгалтерия'),
        ('003', '2026-02-03', '17:45', 'Выход', 'Бухгалтерия'),
        ('003', '2026-03-02', '08:44', 'Вход', 'Бухгалтерия'),
        ('003', '2026-03-02', '17:50', 'Выход', 'Бухгалтерия'),
        ('003', '2026-03-03', '08:48', 'Вход', 'Бухгалтерия'),
        ('003', '2026-03-03', '17:52', 'Выход', 'Бухгалтерия'),
        ('003', '2026-04-01', '08:46', 'Вход', 'Бухгалтерия'),
        ('003', '2026-04-01', '17:55', 'Выход', 'Бухгалтерия'),
        ('003', '2026-04-02', '08:43', 'Вход', 'Бухгалтерия'),
        ('003', '2026-04-02', '17:50', 'Выход', 'Бухгалтерия'),
    ]:
        y, m, day = d.split('-')
        db.session.add(AccessRecord(
            employee_id=eid, access_date=date(int(y), int(m), int(day)),
            access_time=t, event_type=ev, door_location=door
        ))

    # ─── Расчётные листы Январь-Март 2026 ──────────────
    for eid, month, year, display, accs, deds, ta, td, np in [
        ('001', 1, 2026, 'Январь 2026',
         [('Оклад', 380000), ('Премия', 45000), ('Надбавка за стаж', 19000)],
         [('ИПН (10%)', 44400), ('ОПВ (10%)', 44400), ('ВОСМС (2%)', 8880)],
         444000, 97680, 346320),
        ('001', 2, 2026, 'Февраль 2026',
         [('Оклад', 380000), ('Надбавка за стаж', 19000)],
         [('ИПН (10%)', 39900), ('ОПВ (10%)', 39900), ('ВОСМС (2%)', 7980)],
         399000, 87780, 311220),
        ('001', 3, 2026, 'Март 2026',
         [('Оклад', 380000), ('Премия', 60000), ('Надбавка за стаж', 19000)],
         [('ИПН (10%)', 45900), ('ОПВ (10%)', 45900), ('ВОСМС (2%)', 9180)],
         459000, 100980, 358020),
        ('002', 1, 2026, 'Январь 2026',
         [('Оклад', 550000), ('Премия за KPI', 120000)],
         [('ИПН (10%)', 67000), ('ОПВ (10%)', 67000), ('ВОСМС (2%)', 13400)],
         670000, 147400, 522600),
        ('002', 2, 2026, 'Февраль 2026',
         [('Оклад', 550000)],
         [('ИПН (10%)', 55000), ('ОПВ (10%)', 55000), ('ВОСМС (2%)', 11000)],
         550000, 121000, 429000),
        ('002', 3, 2026, 'Март 2026',
         [('Оклад', 550000), ('Премия за KPI', 80000)],
         [('ИПН (10%)', 63000), ('ОПВ (10%)', 63000), ('ВОСМС (2%)', 12600)],
         630000, 138600, 491400),
        ('003', 1, 2026, 'Январь 2026',
         [('Оклад', 300000)],
         [('ИПН (10%)', 30000), ('ОПВ (10%)', 30000), ('ВОСМС (2%)', 6000)],
         300000, 66000, 234000),
        ('003', 2, 2026, 'Февраль 2026',
         [('Оклад', 300000), ('Премия', 25000)],
         [('ИПН (10%)', 32500), ('ОПВ (10%)', 32500), ('ВОСМС (2%)', 6500)],
         325000, 71500, 253500),
        ('003', 3, 2026, 'Март 2026',
         [('Оклад', 300000)],
         [('ИПН (10%)', 30000), ('ОПВ (10%)', 30000), ('ВОСМС (2%)', 6000)],
         300000, 66000, 234000),
    ]:
        ps = Payslip(employee_id=eid, period_month=month, period_year=year,
                     period_display=display, total_accruals=ta,
                     total_deductions=td, net_pay=np)
        db.session.add(ps)
        db.session.flush()
        for name, amount in accs:
            db.session.add(PayslipAccrual(payslip_id=ps.id, name=name, amount=amount))
        for name, amount in deds:
            db.session.add(PayslipDeduction(payslip_id=ps.id, name=name, amount=amount))

    db.session.commit()


def _seed_2026_full():
    """Полные рабочие дни янв–апр 2026 + расчётные листы за апрель.

    _seed_2026() добавила лишь по 2-3 дня в месяц на сотрудника.
    Здесь добавляются все оставшиеся рабочие дни Казахстана (с учётом
    государственных праздников, отпусков и больничных).

    Маркер: 2026-01-05 сотрудника 002 — его нет в разреженных данных.
    """
    if AccessRecord.query.filter(
        AccessRecord.access_date == date(2026, 1, 5),
        AccessRecord.employee_id == '002'
    ).first():
        return

    # Пулы времён прихода/ухода (16 значений, циклически)
    _t001 = [
        ('08:52', '18:10'), ('08:55', '18:05'), ('09:01', '18:15'), ('08:48', '18:00'),
        ('09:05', '18:20'), ('08:50', '18:08'), ('08:58', '18:12'), ('09:03', '18:03'),
        ('08:45', '18:18'), ('09:00', '18:07'), ('08:53', '18:01'), ('09:07', '18:14'),
        ('08:47', '18:09'), ('08:59', '18:22'), ('09:02', '18:06'), ('08:51', '18:11'),
    ]
    _t002 = [
        ('08:30', '18:45'), ('08:35', '19:00'), ('08:28', '18:50'), ('08:40', '19:10'),
        ('08:32', '18:35'), ('08:25', '19:15'), ('08:38', '18:55'), ('08:33', '19:05'),
        ('08:27', '18:40'), ('08:42', '18:30'), ('08:29', '19:20'), ('08:36', '18:48'),
        ('08:31', '19:02'), ('08:26', '18:38'), ('08:39', '18:52'), ('08:34', '19:08'),
    ]
    _t003 = [
        ('08:42', '17:50'), ('08:50', '17:55'), ('08:45', '17:48'), ('08:55', '18:05'),
        ('08:48', '17:52'), ('08:40', '17:45'), ('08:52', '18:00'), ('08:43', '17:58'),
        ('08:57', '17:46'), ('08:46', '18:03'), ('08:51', '17:53'), ('08:44', '17:47'),
        ('08:53', '18:01'), ('08:47', '17:56'), ('08:41', '17:49'), ('08:49', '18:04'),
    ]

    # Государственные праздники КЗ 2026, влияющие на рабочие дни:
    # 1-2 янв (Новый год), 7 янв (Рождество), 8 марта — вс → пн 9 марта,
    # 21-23 марта (Наурыз), 1 мая, 7 мая, 9 мая.

    # Иванов 001: отпуск 5-9 янв, больничный 16-20 фев
    # (уже есть: янв 12,13,14; фев 2,3,4; мар 2,3,4; апр 1,2,3)
    emp001_days = [
        # Январь
        '2026-01-15','2026-01-16','2026-01-19','2026-01-20','2026-01-21',
        '2026-01-22','2026-01-23','2026-01-26','2026-01-27','2026-01-28',
        '2026-01-29','2026-01-30',
        # Февраль (пропуск 16-20 — больничный)
        '2026-02-05','2026-02-06','2026-02-09','2026-02-10','2026-02-11',
        '2026-02-12','2026-02-13','2026-02-23','2026-02-24','2026-02-25',
        '2026-02-26','2026-02-27',
        # Март (пропуск 9 — замена 8 марта; 21-23 — Наурыз)
        '2026-03-05','2026-03-06','2026-03-10','2026-03-11','2026-03-12',
        '2026-03-13','2026-03-16','2026-03-17','2026-03-18','2026-03-19',
        '2026-03-20','2026-03-24','2026-03-25','2026-03-26','2026-03-27',
        '2026-03-30','2026-03-31',
        # Апрель (до 23-го)
        '2026-04-06','2026-04-07','2026-04-08','2026-04-09','2026-04-10',
        '2026-04-13','2026-04-14','2026-04-15','2026-04-16','2026-04-17',
        '2026-04-20','2026-04-21','2026-04-22','2026-04-23',
    ]

    # Петров 002: отпуск 9-22 фев
    # (уже есть: янв 12,13; фев 2,3; мар 2,3; апр 1,2)
    emp002_days = [
        # Январь
        '2026-01-05','2026-01-06','2026-01-08','2026-01-09','2026-01-14',
        '2026-01-15','2026-01-16','2026-01-19','2026-01-20','2026-01-21',
        '2026-01-22','2026-01-23','2026-01-26','2026-01-27',
        # Февраль (пропуск 9-22 — отпуск)
        '2026-02-04','2026-02-05','2026-02-06','2026-02-23','2026-02-24',
        '2026-02-25','2026-02-26','2026-02-27',
        # Март
        '2026-03-04','2026-03-05','2026-03-06','2026-03-10','2026-03-11',
        '2026-03-12','2026-03-13','2026-03-16','2026-03-17','2026-03-18',
        '2026-03-19','2026-03-20','2026-03-24','2026-03-25','2026-03-26',
        '2026-03-27','2026-03-30','2026-03-31',
        # Апрель
        '2026-04-03','2026-04-06','2026-04-07','2026-04-08','2026-04-09',
        '2026-04-10','2026-04-13','2026-04-14','2026-04-15','2026-04-16',
        '2026-04-17','2026-04-20','2026-04-21','2026-04-22','2026-04-23',
    ]

    # Сидорова 003: больничный 16-20 фев
    # (уже есть: янв 12,13; фев 2,3; мар 2,3; апр 1,2)
    emp003_days = [
        # Январь
        '2026-01-05','2026-01-06','2026-01-08','2026-01-09','2026-01-14',
        '2026-01-15','2026-01-16','2026-01-19','2026-01-20','2026-01-21',
        '2026-01-22','2026-01-23','2026-01-26',
        # Февраль (пропуск 16-20 — больничный)
        '2026-02-04','2026-02-05','2026-02-06','2026-02-09','2026-02-10',
        '2026-02-11','2026-02-12','2026-02-13','2026-02-23','2026-02-24',
        '2026-02-25','2026-02-26','2026-02-27',
        # Март
        '2026-03-04','2026-03-05','2026-03-06','2026-03-10','2026-03-11',
        '2026-03-12','2026-03-13','2026-03-16','2026-03-17','2026-03-18',
        '2026-03-19','2026-03-20','2026-03-24','2026-03-25','2026-03-26',
        '2026-03-27','2026-03-30','2026-03-31',
        # Апрель
        '2026-04-03','2026-04-06','2026-04-07','2026-04-08','2026-04-09',
        '2026-04-10','2026-04-13','2026-04-14','2026-04-15','2026-04-16',
        '2026-04-17','2026-04-20','2026-04-21','2026-04-22','2026-04-23',
    ]

    def _add_records(emp_id, days, times, door):
        for i, d in enumerate(days):
            y, m, day = d.split('-')
            t_in, t_out = times[i % len(times)]
            db.session.add(AccessRecord(
                employee_id=emp_id,
                access_date=date(int(y), int(m), int(day)),
                access_time=t_in, event_type='Вход', door_location=door))
            db.session.add(AccessRecord(
                employee_id=emp_id,
                access_date=date(int(y), int(m), int(day)),
                access_time=t_out, event_type='Выход', door_location=door))

    _add_records('001', emp001_days, _t001, 'Главный вход')
    _add_records('002', emp002_days, _t002, 'Офис')
    _add_records('003', emp003_days, _t003, 'Бухгалтерия')

    # Расчётные листы за апрель 2026
    # ИПН 10%, ОПВ 10%, ВОСМС 2% — ставки Казахстана 2026
    if not Payslip.query.filter_by(
            employee_id='001', period_year=2026, period_month=4).first():
        april_payslips = [
            ('001', 'Апрель 2026',
             [('Оклад', 380000), ('Надбавка за стаж', 19000), ('Квартальная премия', 57000)],
             [('ИПН (10%)', 45600), ('ОПВ (10%)', 45600), ('ВОСМС (2%)', 9120)],
             456000, 100320, 355680),
            ('002', 'Апрель 2026',
             [('Оклад', 550000), ('Премия за KPI', 110000)],
             [('ИПН (10%)', 66000), ('ОПВ (10%)', 66000), ('ВОСМС (2%)', 13200)],
             660000, 145200, 514800),
            ('003', 'Апрель 2026',
             [('Оклад', 300000), ('Ежемесячная премия', 30000)],
             [('ИПН (10%)', 33000), ('ОПВ (10%)', 33000), ('ВОСМС (2%)', 6600)],
             330000, 72600, 257400),
        ]
        for eid, display, accs, deds, ta, td, np_ in april_payslips:
            ps = Payslip(employee_id=eid, period_month=4, period_year=2026,
                         period_display=display, total_accruals=ta,
                         total_deductions=td, net_pay=np_)
            db.session.add(ps)
            db.session.flush()
            for name, amount in accs:
                db.session.add(PayslipAccrual(payslip_id=ps.id, name=name, amount=amount))
            for name, amount in deds:
                db.session.add(PayslipDeduction(payslip_id=ps.id, name=name, amount=amount))

    db.session.commit()


def _seed_leave_2026():
    """Остатки и история отпусков/больничных за 2026 год (КЗ)."""
    if LeaveHistory.query.filter(
        LeaveHistory.start_date >= date(2026, 1, 1)
    ).first():
        return

    # Обновляем остатки отпусков на 2026 год
    # Ежегодный отпуск КЗ: 24 к.д. (рядовые), 30 к.д. (руководители)
    # Экологический отпуск (г. Семей — зона повышенного радиационного риска): 14 к.д.
    balance_updates = [
        # (emp_id, тип, всего, использовано, осталось)
        ('001', 'Ежегодный трудовой отпуск',  24,  5, 19),
        ('001', 'Экологический отпуск',        14,  0, 14),
        ('002', 'Ежегодный трудовой отпуск',  30, 14, 16),
        ('002', 'Экологический отпуск',        14,  0, 14),
        ('003', 'Ежегодный трудовой отпуск',  24,  0, 24),
        ('003', 'Экологический отпуск',        14,  0, 14),
    ]
    for eid, lt, total, used, rem in balance_updates:
        bal = LeaveBalance.query.filter_by(employee_id=eid, leave_type=lt).first()
        if bal:
            bal.total_days = total
            bal.used_days = used
            bal.remaining_days = rem
        else:
            db.session.add(LeaveBalance(
                employee_id=eid, leave_type=lt,
                total_days=total, used_days=used, remaining_days=rem))

    # История отпусков/больничных 2026
    history = [
        # Иванов: ежегодный отпуск 5-9 янв (5 к.д.; 7 янв — праздник, не включается)
        ('001', 'Ежегодный трудовой отпуск', '2026-01-05', '2026-01-09',  5, 'Утверждён'),
        # Иванов: больничный 16-20 фев
        ('001', 'Больничный лист',           '2026-02-16', '2026-02-20',  5, 'Закрыт'),
        # Петров: ежегодный отпуск 9-22 фев (14 к.д.)
        ('002', 'Ежегодный трудовой отпуск', '2026-02-09', '2026-02-22', 14, 'Утверждён'),
        # Сидорова: больничный 16-20 фев
        ('003', 'Больничный лист',           '2026-02-16', '2026-02-20',  5, 'Закрыт'),
    ]
    for eid, lt, sd, ed, days, status in history:
        sy, sm, sday = sd.split('-')
        ey, em, eday = ed.split('-')
        db.session.add(LeaveHistory(
            employee_id=eid, leave_type=lt,
            start_date=date(int(sy), int(sm), int(sday)),
            end_date=date(int(ey), int(em), int(eday)),
            days=days, status=status))

    db.session.commit()


# ---------------------------------------------------------------------------
# Helpers shared by 2024/2025 seeders
# ---------------------------------------------------------------------------

_MONTH_RU = {
    1: 'Январь', 2: 'Февраль', 3: 'Март', 4: 'Апрель',
    5: 'Май', 6: 'Июнь', 7: 'Июль', 8: 'Август',
    9: 'Сентябрь', 10: 'Октябрь', 11: 'Ноябрь', 12: 'Декабрь',
}

_EMP_META = {
    '001': ('Инженер',          'Производственный отдел', 'Главный вход'),
    '002': ('Руководитель отдела', 'Администрация',         'Офис'),
    '003': ('Бухгалтер',        'Бухгалтерия',            'Бухгалтерия'),
}


def _add_payslip(emp_id, month, year, oklad, standard_deduction, vacation_days=0):
    """Create Payslip + all child rows for one employee/month."""
    from datetime import timedelta as td

    pitanie = 9_700
    worked_days = 22 - vacation_days
    worked_hours = round(worked_days * 8.0 + worked_days * 0.136)  # ~8h 8m/day → 173h full month

    pay_oklad   = round(oklad / 22 * worked_days)
    premiya     = round(oklad / 22 * worked_days)
    ekologia    = round(oklad * 0.017)
    vac_pay     = round(oklad / 22 * vacation_days) if vacation_days else 0
    total_accruals = pay_oklad + premiya + ekologia + vac_pay

    opv  = round(total_accruals * 0.10)
    osms = round(total_accruals * 0.02)
    ipn_base = max(0, total_accruals - opv - osms - standard_deduction)
    ipn  = round(ipn_base * 0.10)
    total_deductions = opv + osms + pitanie + ipn
    net_pay = total_accruals - total_deductions

    advance = round(net_pay * 0.45)
    final   = net_pay - advance
    next_month = month + 1 if month < 12 else 1
    next_year  = year if month < 12 else year + 1
    period_str = f'{month:02d}.{year}'

    pos, dept, _ = _EMP_META[emp_id]
    ps = Payslip(
        employee_id=emp_id, period_month=month, period_year=year,
        period_display=f'{_MONTH_RU[month]} {year}',
        total_accruals=float(total_accruals),
        total_deductions=float(total_deductions),
        net_pay=float(net_pay), total_paid=float(net_pay),
        position=pos, department=dept,
        salary_rate=float(oklad), debt_start=0.0, debt_end=0.0,
    )
    db.session.add(ps)
    db.session.flush()

    # --- Начислено ---
    db.session.add(PayslipAccrual(
        payslip_id=ps.id, name='Оплата по окладу', amount=float(pay_oklad),
        period=period_str, working_days=worked_days, working_hours=float(worked_hours)))
    db.session.add(PayslipAccrual(
        payslip_id=ps.id, name='Премия постоянная', amount=float(premiya),
        period=period_str))
    db.session.add(PayslipAccrual(
        payslip_id=ps.id, name='Выплаты вследствии экологического бедствия',
        amount=float(ekologia), period=period_str))
    if vac_pay:
        db.session.add(PayslipAccrual(
            payslip_id=ps.id, name='Оплата ежегодного отпуска',
            amount=float(vac_pay), period=period_str))

    # --- Удержано ---
    for name, amt in [('ИПН', ipn), ('ОПВ', opv),
                      ('Взносы ОСМС', osms), ('Питание', pitanie)]:
        db.session.add(PayslipDeduction(
            payslip_id=ps.id, name=name, amount=float(amt), period=period_str))

    # --- Выплачено ---
    db.session.add(PayslipPaid(
        payslip_id=ps.id, payment_type='Аванс', period=period_str,
        document=f'Ведомость №{month * 2 - 1}',
        date=f'15.{month:02d}.{year}', amount=float(advance)))
    db.session.add(PayslipPaid(
        payslip_id=ps.id, payment_type='Зарплата за месяц', period=period_str,
        document=f'Ведомость №{month * 2}',
        date=f'05.{next_month:02d}.{next_year}', amount=float(final)))

    # --- Льготы ---
    db.session.add(PayslipBenefit(payslip_id=ps.id, name='Вычет ОПВ', amount=float(opv)))
    db.session.add(PayslipBenefit(payslip_id=ps.id, name='Вычет ВОСМС', amount=float(osms)))
    db.session.add(PayslipBenefit(
        payslip_id=ps.id, name='Стандартный 14 МРП (1 МЗП)', amount=float(standard_deduction)))

    # --- Справочно ---
    db.session.add(PayslipReference(
        payslip_id=ps.id, name='Обязательные пенсионные взносы работодателя',
        amount=float(round(total_accruals * 0.05))))
    db.session.add(PayslipReference(
        payslip_id=ps.id, name='Отчисления на ОСМС',
        amount=float(round(total_accruals * 0.03))))
    db.session.add(PayslipReference(
        payslip_id=ps.id, name='Социальные отчисления',
        amount=float(round(total_accruals * 0.095))))
    db.session.add(PayslipReference(
        payslip_id=ps.id, name='Социальный налог',
        amount=float(round(total_accruals * 0.0525))))


def _add_access_days(emp_id, start_date, end_date, holidays, absences=None):
    """Add Вход/Выход records for every working day in [start_date, end_date]."""
    from datetime import timedelta
    absences = absences or set()
    entry_times = ['08:45', '08:55', '09:05']
    exit_times  = ['17:45', '18:00', '18:15']
    _, _, door = _EMP_META[emp_id]
    records = []
    d = start_date
    while d <= end_date:
        if d.weekday() < 5 and d not in holidays and d not in absences:
            idx = d.timetuple().tm_yday % 3
            records.append(AccessRecord(
                employee_id=emp_id, access_date=d,
                access_time=entry_times[idx], event_type='Вход', door_location=door))
            records.append(AccessRecord(
                employee_id=emp_id, access_date=d,
                access_time=exit_times[idx], event_type='Выход', door_location=door))
        d += timedelta(days=1)
    db.session.add_all(records)


# ---------------------------------------------------------------------------
# Seeding: март–декабрь 2024
# ---------------------------------------------------------------------------

def _seed_2024_full():
    if AccessRecord.query.filter(AccessRecord.access_date == date(2024, 3, 4)).first():
        return

    holidays = {
        date(2024, 3, 8),   # Международный женский день
        date(2024, 3, 21),  # Наурыз
        date(2024, 3, 22),
        date(2024, 5, 1),   # День единства народа
        date(2024, 5, 7),   # День защитника Отечества
        date(2024, 5, 9),   # День Победы
        date(2024, 7, 8),   # День столицы (6 июл — сб, перенос на пн)
        date(2024, 8, 30),  # День Конституции
        date(2024, 10, 25), # День Республики
        date(2024, 12, 2),  # Первый Президент (1 дек — вс, перенос)
        date(2024, 12, 16), # День Независимости
        date(2024, 12, 17),
    }

    # Отпуск 002: август 5-16 (10 рабочих дней)
    abs_002 = {date(2024, 8, d) for d in range(5, 17)}
    # Больничный 003: май 13-17 (5 дней)
    abs_003 = {date(2024, 5, d) for d in range(13, 18)}

    start = date(2024, 3, 1)
    end   = date(2024, 12, 31)
    _add_access_days('001', start, end, holidays)
    _add_access_days('002', start, end, holidays, abs_002)
    _add_access_days('003', start, end, holidays, abs_003)

    # Расчётные листки март–декабрь 2024
    salaries = [('001', 350_000), ('002', 500_000), ('003', 280_000)]
    std_ded  = 55_048  # 14 МРП × 3 932 тг (МРП 2024)

    for emp_id, oklad in salaries:
        for month in range(3, 13):
            vac = 10 if (emp_id == '002' and month == 8) else \
                   5 if (emp_id == '003' and month == 5) else 0
            _add_payslip(emp_id, month, 2024, oklad, std_ded, vacation_days=vac)

    db.session.commit()


# ---------------------------------------------------------------------------
# Seeding: январь–декабрь 2025
# ---------------------------------------------------------------------------

def _seed_2025_full():
    if AccessRecord.query.filter(AccessRecord.access_date == date(2025, 1, 3)).first():
        return

    holidays = {
        date(2025, 1, 1),   # Новый год
        date(2025, 1, 2),
        date(2025, 1, 7),   # Рождество
        date(2025, 3, 10),  # Международный женский день (8 мар — сб, перенос на пн)
        date(2025, 3, 21),  # Наурыз
        date(2025, 3, 24),  # Наурыз (21 пт; 22 сб; 23 вс → 24 пн перенос)
        date(2025, 5, 1),   # День единства народа
        date(2025, 5, 7),   # День защитника Отечества
        date(2025, 5, 9),   # День Победы
        date(2025, 7, 7),   # День столицы (6 июл — вс, перенос на пн)
        date(2025, 9, 1),   # День Конституции (30 авг — сб, перенос на пн)
        date(2025, 10, 27), # День Республики (25 окт — сб, перенос на пн)
        date(2025, 12, 1),  # Первый Президент
        date(2025, 12, 16), # День Независимости
        date(2025, 12, 17),
    }

    # Отпуск 001: июль 8-18 (10 рабочих дней; 7 — праздник)
    abs_001 = {date(2025, 7, d) for d in range(8, 19)}
    # Отпуск 002: август 4-15 (10 рабочих дней)
    abs_002 = {date(2025, 8, d) for d in range(4, 16)}
    # Больничный 003: март 10-14 (перекрывается с праздником 10 мар; реальных 4 дня)
    abs_003 = {date(2025, 3, d) for d in range(10, 15)}

    start = date(2025, 1, 1)
    end   = date(2025, 12, 31)
    _add_access_days('001', start, end, holidays, abs_001)
    _add_access_days('002', start, end, holidays, abs_002)
    _add_access_days('003', start, end, holidays, abs_003)

    # Расчётные листки январь–декабрь 2025 (+5% индексация)
    salaries = [('001', 367_500), ('002', 525_000), ('003', 294_000)]
    std_ded  = 57_120  # 14 МРП × 4 080 тг (МРП 2025 приблизительно)

    for emp_id, oklad in salaries:
        for month in range(1, 13):
            vac = 10 if (emp_id == '001' and month == 7) else \
                  10 if (emp_id == '002' and month == 8) else \
                   4 if (emp_id == '003' and month == 3) else 0
            _add_payslip(emp_id, month, 2025, oklad, std_ded, vacation_days=vac)

    db.session.commit()


def _seed_may_2026():
    """Расчётные листы и записи турникета за май 2026 (текущий месяц)."""
    if Payslip.query.filter_by(employee_id='001', period_month=5, period_year=2026).first():
        return

    salaries = [
        ('001', 386_500, 'Инженер',              'Производственный отдел'),
        ('002', 558_000, 'Руководитель отдела',   'Производственный отдел'),
        ('003', 303_000, 'Бухгалтер',             'Бухгалтерия'),
    ]
    for emp_id, oklad, position, dept in salaries:
        ta = round(oklad * 1.05, 2)   # оклад + 5% премия условно
        ipn  = round(ta * 0.10, 2)
        opv  = round(ta * 0.10, 2)
        osms = round(ta * 0.02, 2)
        td   = ipn + opv + osms
        np_  = round(ta - td, 2)
        ps = Payslip(employee_id=emp_id, period_month=5, period_year=2026,
                     period_display='Май 2026',
                     total_accruals=ta, total_deductions=td, net_pay=np_,
                     position=position, department=dept,
                     salary_rate=float(oklad), debt_start=0.0, debt_end=0.0,
                     total_paid=np_)
        db.session.add(ps)
        db.session.flush()
        db.session.add(PayslipAccrual(payslip_id=ps.id, name='Оплата по окладу', amount=float(oklad)))
        db.session.add(PayslipAccrual(payslip_id=ps.id, name='Премия постоянная', amount=round(oklad * 0.05, 2)))
        db.session.add(PayslipDeduction(payslip_id=ps.id, name='ИПН (10%)', amount=ipn))
        db.session.add(PayslipDeduction(payslip_id=ps.id, name='ОПВ (10%)', amount=opv))
        db.session.add(PayslipDeduction(payslip_id=ps.id, name='ВОСМС (2%)', amount=osms))

    # Записи турникета за 1-15 мая 2026
    work_days = [1,5,6,7,8,12,13,14,15]
    times = [('001','08:52','18:10'), ('002','08:30','18:45'), ('003','08:42','17:50')]
    for emp_id, t_in, t_out in times:
        for d in work_days:
            db.session.add(AccessRecord(
                employee_id=emp_id,
                access_date=date(2026, 5, d),
                access_time=t_in,
                event_type='Вход',
                door_name='Главный вход'))
            db.session.add(AccessRecord(
                employee_id=emp_id,
                access_date=date(2026, 5, d),
                access_time=t_out,
                event_type='Выход',
                door_name='Главный вход'))

    db.session.commit()


def _seed_turnstile_events():
    """TurnstileEvent — демо-данные для экрана «Проходы сотрудников»."""
    if TurnstileEvent.query.filter(
        TurnstileEvent.timestamp >= datetime(2026, 5, 1)
    ).first():
        return

    employees = [
        ('001', 'Ахметов Асан Бекович'),
        ('002', 'Касымов Нурлан Серикович'),
        ('003', 'Сидорова Анна Сергеевна'),
    ]
    work_days = [1, 5, 6, 7, 8, 12, 13, 14, 15]
    in_times  = ['08:52', '08:30', '08:42', '08:55', '08:35', '08:45',
                 '08:58', '08:28', '08:50']
    out_times = ['18:10', '18:45', '17:50', '18:05', '19:00', '17:55',
                 '18:12', '18:50', '17:48']
    for emp_id, _ in employees:
        for i, d in enumerate(work_days):
            t_in  = in_times[i % len(in_times)]
            t_out = out_times[i % len(out_times)]
            h_in,  m_in  = map(int, t_in.split(':'))
            h_out, m_out = map(int, t_out.split(':'))
            db.session.add(TurnstileEvent(
                employee_id=emp_id,
                direction='in',
                timestamp=datetime(2026, 5, d, h_in, m_in)))
            db.session.add(TurnstileEvent(
                employee_id=emp_id,
                direction='out',
                timestamp=datetime(2026, 5, d, h_out, m_out)))

    db.session.commit()


app = create_app()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
