import os
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


app = create_app()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
