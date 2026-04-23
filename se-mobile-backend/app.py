import os
from datetime import date
from flask import Flask, request, jsonify
from flask_cors import CORS
from models import (db, Employee, AccessRecord, Payslip,
                    PayslipAccrual, PayslipDeduction, LeaveBalance, LeaveHistory)


def create_app():
    app = Flask(__name__)
    CORS(app)

    db_url = os.environ.get('DATABASE_URL', 'sqlite:///se_mobile.db')
    # Render выдаёт postgres://, SQLAlchemy требует postgresql+psycopg://
    if db_url.startswith('postgres://'):
        db_url = db_url.replace('postgres://', 'postgresql+psycopg://', 1)
    elif db_url.startswith('postgresql://'):
        db_url = db_url.replace('postgresql://', 'postgresql+psycopg://', 1)
    app.config['SQLALCHEMY_DATABASE_URI'] = db_url
    app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

    db.init_app(app)

    with app.app_context():
        db.create_all()
        _auto_seed()
        _seed_2026()
        _seed_2026_full()
        _seed_leave_2026()

    register_routes(app)
    return app


def register_routes(app):

    @app.route('/')
    def index():
        return jsonify({
            'status': 'ok',
            'service': 'SE-mobile API',
            'version': '2.0 (PostgreSQL)',
            'endpoints': [
                'POST /login',
                'POST /report',
                'POST /reportdate',
                'POST /director_report',
                'POST /get_sname',
                'POST /payslip',
                'POST /leaves'
            ]
        })

    @app.route('/login', methods=['POST'])
    def login():
        data = request.get_json()
        key_suffix = data.get('key_suffix', '')

        emp = Employee.query.get(key_suffix)
        if emp and key_suffix != '':
            return jsonify({
                'message': 'Success',
                'full_name': emp.full_name,
                'job': emp.job_title
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
                'accruals': [{'name': a.name, 'amount': a.amount} for a in ps.accruals],
                'deductions': [{'name': d.name, 'amount': d.amount} for d in ps.deductions],
                'total_accruals': ps.total_accruals,
                'total_deductions': ps.total_deductions,
                'net_pay': ps.net_pay
            }
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

    e1 = Employee(employee_id='001', full_name='Иванов Иван Иванович', job_title='Инженер', iin='900101350123')
    e2 = Employee(employee_id='002', full_name='Петров Пётр Петрович', job_title='Руководитель отдела', iin='850515400456')
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


app = create_app()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
