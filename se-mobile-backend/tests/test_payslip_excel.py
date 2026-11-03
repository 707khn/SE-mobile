"""Расчётные листки из печатной формы 1С в Excel — загрузка бухгалтером.

Настоящий файл с зарплатами в репозиторий не кладём. Здесь его разметка
повторена на выдуманных людях: те же строки и те же колонки, что сохраняет
1С, включая листок со сдвинутой правой половиной и листок без начислений.
"""

from io import BytesIO
from pathlib import Path

import pytest
from openpyxl import Workbook

import app as app_module
from models import db, Employee, Notification, Payslip, PayslipUpload
from parser_payslip_excel import parse_payslip_excel

_PAYROLL = '0000001469'     # бухгалтер расчётной группы
_ACCOUNTANT = '0000000726'  # бухгалтер — не расчётная группа
_KNOWN = '0000001874'       # есть в базе
_NEW = '9999990001'         # в базе нет

_XLS = Path(__file__).parent / 'data' / 'payslips_1c.xls'


def _slip(rows, emp_id, name, right=214, accruals=True):
    """Один листок так, как его кладёт 1С: (номер колонки, значение)."""
    days, hours, summa = 57, 124, 169
    r_period, r_sum = right + 22, right + 29
    rows += [
        [(0, 'Расчетный листок за Июль 2026')],
        [(0, 'Организация: АО "Семей инжиниринг"'),
         (right, 'Подразделение: Отдел тестирования')],
        [(0, f'Работник: {name}'), (right, 'Должность: Инженер')],
        [(0, f'Табельный номер: {emp_id}'),
         (right, 'Месячная (часовая) тарифная ставка: 300 000 ')],
        [(0, 'ОПВР с начала года: 107 505,00'), (57, 'ОПВР за месяц:  ')],
        [],
        [(0, 'Вид'), (2, 'Период'), (days, 'Дни'), (hours, 'Часы'),
         (summa, 'Сумма'), (right, 'Вид'), (r_period, 'Период'),
         (r_sum, 'Сумма')],
    ]
    if accruals:
        rows += [
            [(0, '1.Начислено'), (right, '2. Удержано')],
            [(0, 'Оклад по дням'), (2, 'Июл 26'), (days, 22.0), (hours, 176.0),
             (summa, 300000.0), (right, 'ИПН исчисленный'),
             (r_period, 'Июл 26'), (r_sum, 25000.0)],
            # Больничный за счёт ФСС: дни и часы есть, суммы нет.
            [(0, 'Оплата больничных листов'), (2, '13-17 Июл 26'),
             (days, 5.0), (hours, 40.0), (right, 'ОПВ исчисленные'),
             (r_period, 'Июл 26'), (r_sum, 30000.0)],
            [(0, 'Всего начислено'), (days, 27.0), (hours, 216.0),
             (summa, 300000.0), (right, 'Всего удержано'), (r_sum, 55000.0)],
            [(0, '3. Доходы в натуральной форме'), (right, '4. Выплачено')],
            [(0, 'Дополнительный доход от работодателя'), (2, 'Июл 26'),
             (summa, 1516.0), (right, 'Перечислено в банк'),
             (r_period, 'Июл 26'), (r_sum, 200000.0)],
            [(0, 'Всего натуральных доходов'), (summa, 1516.0),
             (right, 'Всего выплат'), (r_sum, 200000.0)],
            [(0, '5. Налоговые вычеты')],
            [(0, 'Базовый вычет'), (2, 'Июл 26'), (days, 129750.0)],
            [(0, 'Всего вычеты'), (summa, 129750.0)],
        ]
    rows += [
        [(0, 'Долг за организацией на начало месяца'), (summa, 10000.0),
         (right, 'Долг за организацией на конец месяца'), (r_sum, 55000.0)],
        [],
        [(0, 'Подразделение организации'), (4, 'Отдел тестирования')],
    ]


def _rows():
    rows = [[(0, 'Организация'), (2, 'АО "Семей инжиниринг"')],
            [(0, 'Месяц начисления'), (2, 'Июль 2026')]]
    _slip(rows, _KNOWN, 'Тестов  Тест Тестович')
    _slip(rows, _NEW, 'Новенький Нов Новович', right=203)
    _slip(rows, '9999990002', 'Безначислений Бек', accruals=False)
    return rows


def _xlsx(rows=None):
    wb = Workbook()
    ws = wb.active
    for r, row in enumerate(rows if rows is not None else _rows(), start=1):
        for c, value in row:
            ws.cell(row=r, column=c + 1, value=value)
    out = BytesIO()
    wb.save(out)
    return out.getvalue()


@pytest.fixture(autouse=True)
def clean(app):
    yield
    with app.app_context():
        for ps in Payslip.query.filter_by(period_year=2026, period_month=7):
            if ps.employee_id in (_KNOWN, _NEW, '9999990002'):
                db.session.delete(ps)
        Notification.query.filter_by(kind='payslip').delete()
        PayslipUpload.query.delete()
        for emp_id in (_NEW, '9999990002'):
            emp = db.session.get(Employee, emp_id)
            if emp:
                db.session.delete(emp)
        db.session.commit()


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _upload(client, headers, data=None, name='Июль.xls', **form):
    form['file'] = (BytesIO(data if data is not None else _xlsx()), name)
    return client.post('/api/payslips/import-excel', data=form,
                       headers=headers, content_type='multipart/form-data')


def test_parses_print_form():
    slips = parse_payslip_excel(_xlsx())
    assert [s['employee_1c_id'] for s in slips] == [_KNOWN, _NEW, '9999990002']

    s = slips[0]
    assert s['full_name'] == 'Тестов Тест Тестович'
    assert (s['period_month'], s['period_year'], s['period_display']) == (
        7, 2026, 'Июль 2026')
    assert s['position'] == 'Инженер'
    assert s['department'] == 'Отдел тестирования'
    assert s['salary_rate'] == 300000.0
    assert s['accruals'][0] == {
        'name': 'Оклад по дням', 'amount': 300000.0, 'period': 'Июл 26',
        'working_days': 22, 'working_hours': 176.0}
    # Пустая «Сумма» — ноль, а не часы из соседней колонки.
    assert s['accruals'][1]['amount'] == 0.0
    assert s['accruals'][1]['working_hours'] == 40.0
    assert [d['amount'] for d in s['deductions']] == [25000.0, 30000.0]
    assert s['paid'][0]['payment_type'] == 'Перечислено в банк'
    assert s['paid'][0]['amount'] == 200000.0
    assert s['benefits'] == [{'name': 'Базовый вычет', 'amount': 129750.0}]
    assert {'name': 'ОПВР с начала года', 'amount': 107505.0} in s['reference']
    # «ОПВР за месяц:  » без суммы не показываем.
    assert not any(r['name'] == 'ОПВР за месяц' for r in s['reference'])
    assert {'name': 'Натуральный доход: Дополнительный доход от работодателя',
            'amount': 1516.0} in s['reference']
    assert (s['total_accruals'], s['total_deductions'], s['total_paid']) == (
        300000.0, 55000.0, 200000.0)
    assert s['net_pay'] == 245000.0
    assert (s['debt_start'], s['debt_end']) == (10000.0, 55000.0)


def test_right_half_in_other_columns():
    """У части листков 1С начинает правую половину с другой колонки."""
    s = parse_payslip_excel(_xlsx())[1]
    assert s['department'] == 'Отдел тестирования'
    assert [d['name'] for d in s['deductions']] == [
        'ИПН исчисленный', 'ОПВ исчисленные']
    assert s['total_deductions'] == 55000.0


def test_slip_with_debt_only():
    s = parse_payslip_excel(_xlsx())[2]
    assert s['accruals'] == [] and s['deductions'] == []
    assert (s['debt_start'], s['debt_end']) == (10000.0, 55000.0)


def test_debt_of_employee_is_negative():
    rows = _rows()
    for row in rows:
        for i, (c, v) in enumerate(row):
            if v == 'Долг за организацией на начало месяца':
                row[i] = (c, 'Долг за работником на начало месяца')
    assert parse_payslip_excel(_xlsx(rows))[0]['debt_start'] == -10000.0


def test_old_xls_format():
    """.xls — так 1С сохраняет «Лист Excel» по умолчанию."""
    slips = parse_payslip_excel(_XLS.read_bytes())
    assert [s['employee_1c_id'] for s in slips] == [_KNOWN, _NEW, '9999990002']
    assert slips[0]['total_accruals'] == 300000.0
    assert slips[1]['total_deductions'] == 55000.0


@pytest.mark.parametrize('data', [b'', b'not excel at all'])
def test_garbage_is_refused(data):
    with pytest.raises(ValueError):
        parse_payslip_excel(data)


def test_other_spreadsheet_is_refused():
    with pytest.raises(ValueError, match='нет расчётных листков'):
        parse_payslip_excel(_xlsx([[(0, 'Меню на 19.08.2026')]]))


def test_only_payroll_uploads(app, client):
    assert _upload(client, {}).status_code == 401
    assert _upload(client, _auth(app, _ACCOUNTANT)).status_code == 403
    with app.app_context():
        assert Payslip.query.filter_by(employee_id=_KNOWN, period_year=2026,
                                       period_month=7).count() == 0


def test_dry_run_shows_what_is_in_file(app, client):
    r = _upload(client, _auth(app, _PAYROLL), dry_run='1')
    assert r.status_code == 200
    body = r.get_json()
    assert body['dry_run'] is True
    assert body['periods'] == ['Июль 2026']
    assert body['count'] == 3
    assert (body['new'], body['replaced']) == (3, 0)
    assert {u['employee_id'] for u in body['unknown']} == {_NEW, '9999990002'}
    with app.app_context():
        assert Payslip.query.filter_by(period_year=2026, period_month=7,
                                       employee_id=_KNOWN).count() == 0
        assert db.session.get(Employee, _NEW) is None


def test_upload_stores_and_notifies(app, client):
    with app.app_context():
        before = db.session.get(Employee, _KNOWN)
        name, job = before.full_name, before.job_title

    r = _upload(client, _auth(app, _PAYROLL))
    assert r.status_code == 200, r.get_json()
    assert r.get_json()['imported'] == 3

    with app.app_context():
        ps = Payslip.query.filter_by(employee_id=_KNOWN, period_year=2026,
                                     period_month=7).one()
        assert ps.net_pay == 245000.0
        assert len(ps.accruals) == 2
        # Должность из листка не меняет права в приложении.
        emp = db.session.get(Employee, _KNOWN)
        assert (emp.full_name, emp.job_title) == (name, job)
        assert db.session.get(Employee, _NEW) is not None
        assert Notification.query.filter_by(
            kind='payslip', employee_id=_KNOWN).count() == 1

    # Повторная загрузка с поправками заменяет листок, а не дублирует.
    r = _upload(client, _auth(app, _PAYROLL), dry_run='1')
    assert (r.get_json()['new'], r.get_json()['replaced']) == (0, 3)
    assert _upload(client, _auth(app, _PAYROLL)).status_code == 200
    with app.app_context():
        assert Payslip.query.filter_by(employee_id=_KNOWN, period_year=2026,
                                       period_month=7).count() == 1


def test_wrong_file_type(app, client):
    r = _upload(client, _auth(app, _PAYROLL), name='Июль.pdf')
    assert r.status_code == 400


# --- Раздел «Расчётные листы»: месяцы, сотрудники, удаление ---------------


def test_sections_closed_to_others(app, client):
    for method, url in (('get', '/api/payslips/periods'),
                        ('get', '/api/payslips/periods/2026/7'),
                        ('delete', '/api/payslips/periods/2026/7')):
        assert getattr(client, method)(url).status_code == 401
        assert getattr(client, method)(
            url, headers=_auth(app, _ACCOUNTANT)).status_code == 403


def test_periods_show_upload(app, client):
    headers = _auth(app, _PAYROLL)
    assert _upload(client, headers).status_code == 200

    items = client.get('/api/payslips/periods', headers=headers).get_json()['items']
    july = next(i for i in items if (i['year'], i['month']) == (2026, 7))
    assert july['title'] == 'Июль 2026'
    assert july['count'] >= 3
    assert july['uploaded']['file'] == 'Июль.xls'
    assert july['uploaded']['count'] == 3
    with app.app_context():
        assert july['uploaded']['by'] == db.session.get(
            Employee, _PAYROLL).full_name

    body = client.get('/api/payslips/periods/2026/7', headers=headers).get_json()
    mine = next(i for i in body['items'] if i['employee_id'] == _KNOWN)
    assert mine['net_pay'] == 245000.0
    assert mine['department'] == 'Отдел тестирования'


def test_payroll_opens_anyones_payslip(app, client):
    headers = _auth(app, _PAYROLL)
    assert _upload(client, headers).status_code == 200
    r = client.post('/payslip', json={'key_suffix': _KNOWN, 'month': '07',
                                      'year': '2026'}, headers=headers)
    assert r.status_code == 200
    assert r.get_json()['payslip']['net_pay'] == 245000.0
    # Рядовой бухгалтер — нет.
    r = client.post('/payslip', json={'key_suffix': _KNOWN, 'month': '07',
                                      'year': '2026'},
                    headers=_auth(app, _ACCOUNTANT))
    assert r.status_code == 403


def test_delete_one_then_month(app, client):
    headers = _auth(app, _PAYROLL)
    assert _upload(client, headers).status_code == 200

    r = client.delete(f'/api/payslips/periods/2026/7/{_NEW}', headers=headers)
    assert r.get_json()['deleted'] == 1
    with app.app_context():
        left = {p.employee_id for p in
                Payslip.query.filter_by(period_year=2026, period_month=7)}
        assert _NEW not in left and _KNOWN in left
    assert client.delete(f'/api/payslips/periods/2026/7/{_NEW}',
                         headers=headers).status_code == 404

    assert client.delete('/api/payslips/periods/2026/7',
                         headers=headers).status_code == 200
    with app.app_context():
        assert Payslip.query.filter_by(period_year=2026,
                                       period_month=7).count() == 0
    items = client.get('/api/payslips/periods', headers=headers).get_json()['items']
    assert not any((i['year'], i['month']) == (2026, 7) for i in items)


def test_bad_month(app, client):
    r = client.get('/api/payslips/periods/2026/13', headers=_auth(app, _PAYROLL))
    assert r.status_code == 400


def test_me_tells_app_about_payroll(app, client, monkeypatch):
    """Бухгалтера из PAYROLL_STAFF приложение по должности не узнает —
    об этом ему говорит /api/me."""
    me = lambda emp: client.get('/api/me', headers=_auth(app, emp)).get_json()
    assert me(_PAYROLL)['payroll'] is True
    assert me(_ACCOUNTANT)['payroll'] is False

    monkeypatch.setenv('PAYROLL_STAFF', _ACCOUNTANT)
    assert me(_ACCOUNTANT)['payroll'] is True
    assert client.get('/api/payslips/periods',
                      headers=_auth(app, _ACCOUNTANT)).status_code == 200


def test_admin_opens_payroll_section(app, client):
    """Администратор открывает раздел «Расчётные листы» без правки справочника."""
    import os
    with app.app_context():
        admin_id = app_module._authenticate('admin', os.environ['ADMIN_PASSWORD'])
    admin = _auth(app, admin_id)
    url = f'/api/admin/employees/{_ACCOUNTANT}/payroll'
    try:
        # Не администратору — нельзя, даже расчётной группе.
        assert client.post(url, json={'payroll': True},
                           headers=_auth(app, _PAYROLL)).status_code == 403

        r = client.post(url, json={'payroll': True}, headers=admin)
        assert r.get_json() == {'message': 'Success', 'payroll': True,
                                'payroll_by_title': False}
        assert client.get('/api/me', headers=_auth(
            app, _ACCOUNTANT)).get_json()['payroll'] is True
        assert client.get('/api/payslips/periods', headers=_auth(
            app, _ACCOUNTANT)).status_code == 200

        people = {e['employee_id']: e for e in client.get(
            '/api/admin/employees', headers=admin).get_json()['employees']}
        assert people[_ACCOUNTANT]['payroll'] is True
        assert people[_PAYROLL]['payroll_by_title'] is True

        r = client.post(url, json={'payroll': False}, headers=admin)
        assert r.get_json()['payroll'] is False
        assert client.get('/api/payslips/periods', headers=_auth(
            app, _ACCOUNTANT)).status_code == 403
    finally:
        with app.app_context():
            from models import PayrollGrant
            PayrollGrant.query.delete()
            db.session.commit()
