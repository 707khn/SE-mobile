"""Расчётный листок файлом Excel — для кнопки «Поделиться».

Вёрстка повторяет печатную форму 1С: её узнают в бухгалтерии и в банке.
Данные здесь вымышленные — настоящих листков в репозитории быть не должно.
"""

from io import BytesIO

import pytest
from openpyxl import load_workbook

import app as app_module
from models import (db, Employee, Payslip, PayslipAccrual, PayslipBenefit,
                    PayslipDeduction, PayslipPaid, PayslipReference)
from payslip_xlsx import classify, period_label

_WORKER = 'XLSX0001'
_NEIGHBOUR = 'XLSX0002'


@pytest.fixture
def slip(app, remove_employee):
    with app.app_context():
        for employee_id, name in ((_WORKER, 'Листков Пётр Тестович'),
                                  (_NEIGHBOUR, 'Соседова Анна Тестовна')):
            remove_employee(employee_id)
            db.session.add(Employee(employee_id=employee_id, full_name=name,
                                    job_title='Инженер'))
        ps = Payslip(employee_id=_WORKER, period_month=7, period_year=2026,
                     period_display='июль 2026', total_accruals=150_000.0,
                     total_deductions=30_000.0, net_pay=120_000.0,
                     total_paid=120_000.0, position='Инженер',
                     department='Тестовый отдел', salary_rate=100_000.0,
                     debt_start=1_000.0, debt_end=-500.0)
        db.session.add(ps)
        db.session.flush()
        db.session.add_all([
            PayslipAccrual(payslip_id=ps.id, name='Оклад по дням',
                           amount=100_000.0, period='07.2026',
                           working_days=22, working_hours=176.0),
            PayslipAccrual(payslip_id=ps.id, name='Доплата за выслугу лет',
                           amount=10_000.0, period='07.2026',
                           working_days=22, working_hours=176.0),
            PayslipAccrual(payslip_id=ps.id, name='Премия',
                           amount=40_000.0, period='07.2026'),
            PayslipDeduction(payslip_id=ps.id, name='ИПН исчисленный',
                             amount=12_000.0, period='07.2026'),
            PayslipDeduction(payslip_id=ps.id, name='ОПВ исчисленные',
                             amount=15_000.0, period='07.2026'),
            PayslipDeduction(payslip_id=ps.id, name='Питание',
                             amount=3_000.0, period='07.2026'),
            PayslipPaid(payslip_id=ps.id, payment_type='Перечислено в банк',
                        period='07.2026', amount=120_000.0),
            PayslipBenefit(payslip_id=ps.id, name='Вычет ОПВ', amount=15_000.0),
            PayslipBenefit(payslip_id=ps.id, name='Базовый вычет',
                           amount=43_000.0),
            PayslipReference(payslip_id=ps.id, name='ОПВР с начала года',
                             amount=7_000.0),
            PayslipReference(payslip_id=ps.id, name='ОПВР за месяц',
                             amount=1_000.0),
            PayslipReference(payslip_id=ps.id, name='ВОСМС с начала года',
                             amount=2_100.0),
            PayslipReference(payslip_id=ps.id,
                             name='Натуральный доход: дополнительный доход '
                                  'от работодателя', amount=1_500.0),
            # Тот же вычет второй раз — так бывает в выгрузке 1С.
            PayslipReference(payslip_id=ps.id, name='Вычет ОПВ',
                             amount=15_000.0),
            PayslipReference(payslip_id=ps.id, name='Социальный налог',
                             amount=4_000.0),
        ])
        db.session.commit()
    yield


def _post(client, body, token=None):
    headers = {'Authorization': f'Bearer {token}'} if token else {}
    return client.post('/payslip/xlsx', json=body, headers=headers)


def _rows(response):
    ws = load_workbook(BytesIO(response.data)).active
    return ws, {row[0].value: row for row in ws.iter_rows() if row[0].value}


def test_classify_sorts_reference_rows_like_1c():
    groups = classify(
        [('Вычет ОПВ', 1), ('Дополнительный доход от подотчетной суммы', 2)],
        [('ООСМС за месяц', 3), ('Натуральный доход: питание', 4),
         ('Вычет ОПВ', 1), ('Стандартный 14 МРП (1 МЗП)', 5),
         ('Обязательные пенсионные взносы работодателя', 6)])
    assert groups['header'] == [('ООСМС за месяц', 3)]
    assert groups['natural'] == [
        ('Дополнительный доход от подотчетной суммы', 2), ('Питание', 4)]
    assert groups['tax'] == [('Вычет ОПВ', 1),
                             ('Стандартный 14 МРП (1 МЗП)', 5)]
    assert groups['employer'] == [
        ('Обязательные пенсионные взносы работодателя', 6)]


def test_period_is_written_like_1c():
    assert period_label('07.2026') == 'Июл 26'
    assert period_label('20-30 Апр 26') == '20-30 Апр 26'
    assert period_label('') == ''
    assert period_label(None) == ''


def test_payslip_comes_as_1c_layout(client, slip):
    response = _post(client, {'key_suffix': _WORKER, 'month': '07',
                              'year': '2026'})
    assert response.status_code == 200
    assert response.mimetype == app_module._XLSX_MIME
    assert response.headers['Cache-Control'] == 'no-store'
    assert '.xlsx' in response.headers['Content-Disposition']

    ws, rows = _rows(response)
    assert ws['A1'].value == 'Расчетный листок за Июль 2026'
    assert 'A1:H1' in {str(r) for r in ws.merged_cells.ranges}
    assert 'Работник: Листков Пётр Тестович' in rows
    assert ws['F3'].value == 'Должность: Инженер'
    assert 'Табельный номер: XLSX0001' in rows

    total = rows['Всего начислено']
    # Дни и часы 1С складывает по всем начислениям, где они есть.
    assert [c.value for c in total[2:5]] == [44, 352, 150_000.0]
    assert total[5].value == 'Всего удержано' and total[7].value == 30_000.0

    oklad = rows['Оклад по дням']
    assert oklad[1].value == 'Июл 26'
    assert oklad[4].number_format == '#,##0.00'
    assert oklad[5].value == 'ИПН исчисленный'

    natural = rows['Дополнительный доход от работодателя']
    assert natural[4].value == 1_500.0
    assert natural[5].value == 'Перечислено в банк'
    assert rows['Всего натуральных доходов'][4].value == 1_500.0
    assert rows['Всего натуральных доходов'][7].value == 120_000.0

    assert rows['Всего вычеты'][4].value == 58_000.0, 'вычет ОПВ — один раз'
    assert 'Социальный налог' in rows
    assert any(str(k).startswith('ОПВР с начала года: 7 000,00') for k in rows)

    # Долг на конец месяца отрицательный — значит, должен работник.
    debt = rows['Долг за организацией на начало месяца']
    assert debt[4].value == 1_000.0
    assert debt[5].value == 'Долг за работником на конец месяца'
    assert debt[7].value == 500.0


def test_someone_elses_payslip_file_is_closed(app, client, slip):
    with app.app_context():
        token = app_module._issue_token(_NEIGHBOUR)
    denied = _post(client, {'key_suffix': _WORKER, 'month': '07',
                            'year': '2026'}, token)
    assert denied.status_code == 403

    with app.app_context():
        token = app_module._issue_token(_WORKER)
    mine = _post(client, {'key_suffix': _WORKER, 'month': '07',
                          'year': '2026'}, token)
    assert mine.status_code == 200
    assert mine.mimetype == app_module._XLSX_MIME


def test_missing_or_bad_period(client, slip):
    missing = _post(client, {'key_suffix': _WORKER, 'month': '06',
                             'year': '2026'})
    assert missing.get_json() == {'message': 'Failure'}

    bad = _post(client, {'key_suffix': _WORKER, 'month': 'июль',
                         'year': '2026'})
    assert bad.status_code == 400
    assert bad.get_json()['error'] == 'bad_period'


def test_payslip_names_the_previous_one(app, client, slip):
    """«К выплате» сравнивают с предыдущим листком — не обязательно с
    прошлым месяцем: листка за какой-то месяц может и не быть."""
    def previous(month, year):
        return client.post('/payslip', json={
            'key_suffix': _WORKER, 'month': month, 'year': year,
        }).get_json()['payslip']['previous']

    # Пока листок за июль — единственный, сравнивать не с чем.
    assert previous('07', '2026') is None

    with app.app_context():
        for month, net in ((4, 90_000.0), (5, 100_000.0)):
            db.session.add(Payslip(
                employee_id=_WORKER, period_month=month, period_year=2026,
                period_display='x', total_accruals=net, total_deductions=0.0,
                net_pay=net))
        db.session.commit()

    # Июня нет — с июлем сравнивается май.
    assert previous('07', '2026') == {'year': 2026, 'month': 5,
                                      'net_pay': 100_000.0}
    assert previous('05', '2026')['month'] == 4
