from flask import Flask, request, jsonify
from flask_cors import CORS
from mock_data import EMPLOYEES, REPORTS, PAYSLIPS, LEAVES

app = Flask(__name__)
CORS(app)


# ─── 0. INDEX (API status) ────────────────────────────────
@app.route('/')
def index():
    return jsonify({
        'status': 'ok',
        'service': 'SE-mobile API',
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


# ─── 1. LOGIN ───────────────────────────────────────────
@app.route('/login', methods=['POST'])
def login():
    data = request.get_json()
    key_suffix = data.get('key_suffix', '')

    employee = EMPLOYEES.get(key_suffix)
    if employee and key_suffix != '':
        return jsonify({
            'message': 'Success',
            'full_name': employee['full_name'],
            'job': employee['job']
        })
    else:
        return jsonify({'message': 'Failure'})


# ─── 2. REPORT (все записи сотрудника) ──────────────────
@app.route('/report', methods=['POST'])
def report():
    data = request.get_json()
    key_suffix = data.get('key_suffix', '')

    records = REPORTS.get(key_suffix, [])
    if not records:
        return jsonify({'message': 'Failure'})
    return jsonify({'message': 'Success', 'report': records})


# ─── 3. REPORTDATE (записи за период) ───────────────────
@app.route('/reportdate', methods=['POST'])
def reportdate():
    data = request.get_json()
    key_suffix = data.get('key_suffix', '')
    start_date = data.get('start_date', '')
    end_date = data.get('end_date', '')

    records = REPORTS.get(key_suffix, [])
    filtered = [r for r in records
                if start_date <= r.get('date', '') <= end_date]
    if not filtered:
        return jsonify({'message': 'Failure'})
    return jsonify({'message': 'Success', 'report': filtered})


# ─── 4. DIRECTOR_REPORT (отчёт по сотруднику) ───────────
@app.route('/director_report', methods=['POST'])
def director_report():
    data = request.get_json()
    emp_sname = data.get('emp_sname', '')
    start_date = data.get('start_date', '')
    end_date = data.get('end_date', '')

    records = []
    for key, emp in EMPLOYEES.items():
        if emp_sname in emp['full_name']:
            records = REPORTS.get(key, [])
            break

    filtered = [r for r in records
                if start_date <= r.get('date', '') <= end_date]
    if not filtered:
        return jsonify({'message': 'Failure'})
    return jsonify({'message': 'Success', 'director_report': filtered})


# ─── 5/6. GET_SNAME (список сотрудников / поиск по ИИН) ─
@app.route('/get_sname', methods=['POST'])
def get_sname():
    data = request.get_json()

    if 'key_suffix' in data:
        fio_list = [e['full_name'] for e in EMPLOYEES.values()]
        return jsonify({'fio': fio_list})

    if 'emp_iin' in data:
        emp_iin = data['emp_iin']
        for emp in EMPLOYEES.values():
            if emp.get('iin') == emp_iin:
                return jsonify({
                    'message': 'Success',
                    'employee': [emp]
                })
        return jsonify({'message': 'Failure'})

    return jsonify({'message': 'Failure'})


# ─── 7. PAYSLIP (расчётный лист) ────────────────────────
@app.route('/payslip', methods=['POST'])
def payslip():
    data = request.get_json()
    key_suffix = data.get('key_suffix', '')
    month = data.get('month', '')
    year = data.get('year', '')

    period_key = f"{key_suffix}_{year}_{month}"
    ps = PAYSLIPS.get(period_key)

    if ps:
        return jsonify({'message': 'Success', 'payslip': ps})
    else:
        return jsonify({'message': 'Failure'})


# ─── 8. LEAVES (отпуска и больничные) ──────────────────
@app.route('/leaves', methods=['POST'])
def leaves():
    data = request.get_json()
    key_suffix = data.get('key_suffix', '')

    leave_data = LEAVES.get(key_suffix)

    if leave_data:
        return jsonify({'message': 'Success', 'leaves': leave_data})
    else:
        return jsonify({'message': 'Failure'})


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
