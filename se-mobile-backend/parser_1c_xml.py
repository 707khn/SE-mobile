"""
Parser for 1C ZUP 3 payslip XML exports.

Expected XML structure:
<ЗарплатныеЛисты>
  <ЛистокЗарплаты>
    <Сотрудник Код="0000001874" Наименование="..." Должность="..." Подразделение="..." Оклад="..."/>
    <Период Месяц="10" Год="2025" Отображение="Октябрь 2025"/>
    <Начислено Итого="..."> <Строка Вид="..." Период="..." Дни="..." Часы="..." Сумма="..."/> </Начислено>
    <Удержано Итого="...">  <Строка Вид="..." Период="..." Сумма="..."/> </Удержано>
    <Выплачено Итого="..."> <Строка ВидВыплаты="..." Период="..." Документ="..." Дата="..." Сумма="..."/> </Выплачено>
    <Льготы>   <Строка Наименование="..." Сумма="..."/> </Льготы>
    <Справочно> <Строка Наименование="..." Сумма="..."/> </Справочно>
    <ДолгПредприятия НаНачало="..." НаКонец="..."/>
    <КВыплате>...</КВыплате>
  </ЛистокЗарплаты>
</ЗарплатныеЛисты>
"""

import xml.etree.ElementTree as ET


def _float(value: str | None, default: float = 0.0) -> float:
    if not value:
        return default
    try:
        return float(value.replace(',', '.').replace('\xa0', '').replace(' ', ''))
    except ValueError:
        return default


def _int(value: str | None, default: int | None = None) -> int | None:
    if not value:
        return default
    try:
        return int(value)
    except ValueError:
        return default


def _parse_rows_accruals(section) -> list[dict]:
    rows = []
    if section is None:
        return rows
    for row in section.findall('Строка'):
        rows.append({
            'name': row.get('Вид', ''),
            'amount': _float(row.get('Сумма')),
            'period': row.get('Период', ''),
            'working_days': _int(row.get('Дни')),
            'working_hours': _float(row.get('Часы')) if row.get('Часы') else None,
        })
    return rows


def _parse_rows_deductions(section) -> list[dict]:
    rows = []
    if section is None:
        return rows
    for row in section.findall('Строка'):
        rows.append({
            'name': row.get('Вид', ''),
            'amount': _float(row.get('Сумма')),
            'period': row.get('Период', ''),
        })
    return rows


def _parse_rows_paid(section) -> list[dict]:
    rows = []
    if section is None:
        return rows
    for row in section.findall('Строка'):
        rows.append({
            'payment_type': row.get('ВидВыплаты', ''),
            'period': row.get('Период', ''),
            'document': row.get('Документ', ''),
            'date': row.get('Дата', ''),
            'amount': _float(row.get('Сумма')),
        })
    return rows


def _parse_rows_named(section) -> list[dict]:
    rows = []
    if section is None:
        return rows
    for row in section.findall('Строка'):
        rows.append({
            'name': row.get('Наименование', ''),
            'amount': _float(row.get('Сумма')),
        })
    return rows


def parse_1c_xml(content: bytes) -> list[dict]:
    """Parse 1C ZUP XML payslip export bytes. Returns list of payslip dicts.

    Supports UTF-8 and windows-1251 encodings.
    Raises ValueError if the XML is invalid or missing required fields.
    """
    try:
        text = content.decode('utf-8')
    except UnicodeDecodeError:
        text = content.decode('windows-1251')

    try:
        root = ET.fromstring(text)
    except ET.ParseError as e:
        raise ValueError(f'Некорректный XML: {e}')

    slips = root.findall('ЛистокЗарплаты')
    if not slips:
        # Try root itself as a single slip
        if root.tag == 'ЛистокЗарплаты':
            slips = [root]
        else:
            raise ValueError('Не найдены элементы <ЛистокЗарплаты> в XML')

    results = []
    for slip in slips:
        emp = slip.find('Сотрудник')
        period = slip.find('Период')

        if emp is None or period is None:
            raise ValueError('Отсутствует элемент <Сотрудник> или <Период>')

        employee_1c_id = emp.get('Код', '').strip()
        if not employee_1c_id:
            raise ValueError('Атрибут Код в <Сотрудник> пустой')

        period_month = _int(period.get('Месяц'))
        period_year = _int(period.get('Год'))
        if period_month is None or period_year is None:
            raise ValueError('Атрибуты Месяц/Год в <Период> некорректны')

        accruals_el = slip.find('Начислено')
        deductions_el = slip.find('Удержано')
        paid_el = slip.find('Выплачено')
        debt_el = slip.find('ДолгПредприятия')
        net_el = slip.find('КВыплате')

        results.append({
            'employee_1c_id': employee_1c_id,
            'full_name': emp.get('Наименование', '').strip(),
            'position': emp.get('Должность', '').strip(),
            'department': emp.get('Подразделение', '').strip(),
            'salary_rate': _float(emp.get('Оклад')),
            'period_month': period_month,
            'period_year': period_year,
            'period_display': period.get('Отображение', f'{period_month}.{period_year}'),
            'total_accruals': _float(accruals_el.get('Итого') if accruals_el is not None else None),
            'total_deductions': _float(deductions_el.get('Итого') if deductions_el is not None else None),
            'total_paid': _float(paid_el.get('Итого') if paid_el is not None else None),
            'net_pay': _float(net_el.text if net_el is not None else None),
            'debt_start': _float(debt_el.get('НаНачало') if debt_el is not None else None),
            'debt_end': _float(debt_el.get('НаКонец') if debt_el is not None else None),
            'accruals': _parse_rows_accruals(accruals_el),
            'deductions': _parse_rows_deductions(deductions_el),
            'paid': _parse_rows_paid(paid_el),
            'benefits': _parse_rows_named(slip.find('Льготы')),
            'reference': _parse_rows_named(slip.find('Справочно')),
        })

    return results
