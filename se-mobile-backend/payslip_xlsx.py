"""Расчётный листок в Excel — тот, что уходит по кнопке «Поделиться».

Раньше кнопка отправляла текст. В бухгалтерию, в банк, в садик просят
листок в том виде, к которому все привыкли, — как его печатает 1С. Поэтому
вёрстка здесь повторяет печатную форму 1С: шапка с организацией и
работником, слева «Начислено», справа «Удержано», ниже натуральные доходы,
выплаты, налоговые вычеты и долг на начало и конец месяца.

Файл собирается на сервере, а не в приложении: так он одинаков на любом
телефоне, а вёрстку можно проверить тестом.

В базе листка нет отдельных полей для шапки и для вычетов — 1С кладёт их в
«справочные» строки вперемешку. Что куда относится, решает classify() по
названию строки, ровно так, как они называются в выгрузке 1С.
"""

from io import BytesIO

from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side

ORGANIZATION = 'АО "Семей инжиниринг"'

_MONTHS = ('Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль',
           'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь')
# Так 1С пишет период в строках листка: «Июл 26».
_MONTHS_SHORT = ('Янв', 'Фев', 'Мар', 'Апр', 'Май', 'Июн', 'Июл', 'Авг',
                 'Сен', 'Окт', 'Ноя', 'Дек')

# Строки, которые 1С печатает в шапке: взносы с начала года и за месяц.
_HEADER_PREFIXES = ('ОПВР', 'ООСМС', 'ВОСМС')
_NATURAL_PREFIX = 'Натуральный доход:'

_MONEY = '#,##0.00'
_GREEN = PatternFill('solid', fgColor='C6E0B4')
_THIN = Side(style='thin', color='808080')
_BOX = Border(left=_THIN, right=_THIN, top=_THIN, bottom=_THIN)


def classify(benefits, reference):
    """Разложить справочные строки листка по разделам печатной формы.

    `benefits` и `reference` — списки пар (название, сумма). Возвращает
    словарь с ключами header, natural, tax, employer — те же пары.

    Одни и те же вычеты 1С иногда кладёт в обе группы сразу; в листке они
    должны стоять один раз.
    """
    groups = {'header': [], 'natural': [], 'tax': [], 'employer': []}
    seen = set()
    for name, amount in list(benefits) + list(reference):
        name = (name or '').strip()
        if not name:
            continue
        lower = name.lower()
        if name.startswith(_HEADER_PREFIXES):
            group = 'header'
        elif name.startswith(_NATURAL_PREFIX):
            group, name = 'natural', name[len(_NATURAL_PREFIX):].strip()
            name = name[:1].upper() + name[1:]
        elif 'доход' in lower:
            group = 'natural'
        elif 'вычет' in lower or lower.startswith('стандартный'):
            group = 'tax'
        else:
            group = 'employer'
        key = (group, name.lower())
        if key in seen:
            continue
        seen.add(key)
        groups[group].append((name, amount or 0.0))
    return groups


def period_label(period):
    """«07.2026» → «Июл 26», как в 1С. Другие записи — как есть."""
    period = (period or '').strip()
    month, dot, year = period.partition('.')
    if dot and month.isdigit() and year.isdigit() and 1 <= int(month) <= 12:
        return f'{_MONTHS_SHORT[int(month) - 1]} {year[-2:]}'
    return period


def title(ps):
    return f'Расчетный листок за {_MONTHS[ps.period_month - 1]} {ps.period_year}'


def file_name(ps):
    return f'Расчетный листок {_MONTHS[ps.period_month - 1]} {ps.period_year}.xlsx'


def _number(value):
    """Дни и часы: 22, а не 22.0; 7.5 — как есть."""
    if value is None:
        return None
    value = float(value)
    return int(value) if value.is_integer() else value


def _debt_label(amount, when):
    # Положительный долг — организация должна работнику, отрицательный —
    # наоборот. 1С подписывает их по-разному; так же и здесь.
    who = 'за организацией' if (amount or 0) >= 0 else 'за работником'
    return f'Долг {who} на {when} месяца'


class _Sheet:
    def __init__(self, ws):
        self.ws = ws
        self.row = 1

    def put(self, col, value, *, bold=False, money=False, merge_to=None,
            border=False):
        cell = self.ws[f'{col}{self.row}']
        cell.value = value
        if bold:
            cell.font = Font(bold=True)
        if money and value is not None:
            cell.number_format = _MONEY
        if merge_to:
            self.ws.merge_cells(f'{col}{self.row}:{merge_to}{self.row}')
        if border:
            cell.border = _BOX
        return cell

    def box(self, first='A', last='H'):
        for col in range(ord(first), ord(last) + 1):
            self.ws[f'{chr(col)}{self.row}'].border = _BOX

    def next(self, count=1):
        self.row += count


def build_payslip_xlsx(ps, employee_name):
    """Листок `ps` (модель Payslip) в виде .xlsx — байты файла."""
    month_period = period_label(f'{ps.period_month:02d}.{ps.period_year}')
    groups = classify([(b.name, b.amount) for b in ps.benefits],
                      [(r.name, r.amount) for r in ps.reference])

    wb = Workbook()
    ws = wb.active
    ws.title = 'Расчетный листок'
    for col, width in zip('ABCDEFGH', (44, 9, 7, 8, 15, 38, 9, 15)):
        ws.column_dimensions[col].width = width
    ws.page_setup.orientation = 'portrait'
    ws.page_setup.fitToWidth = 1
    ws.page_setup.fitToHeight = 0
    ws.sheet_properties.pageSetUpPr.fitToPage = True
    s = _Sheet(ws)

    # ── Шапка ───────────────────────────────────────────────────────────────
    cell = s.put('A', title(ps), merge_to='H')
    cell.font = Font(bold=True, underline='single', size=12)
    s.next()
    s.put('A', f'Организация: {ORGANIZATION}', merge_to='E')
    s.put('F', f'Подразделение: {ps.department or ""}', merge_to='H')
    s.next()
    s.put('A', f'Работник: {employee_name or ""}', merge_to='E')
    s.put('F', f'Должность: {ps.position or ""}', merge_to='H')
    s.next()
    rate = f'{ps.salary_rate:,.0f}'.replace(',', ' ') if ps.salary_rate else ''
    s.put('A', f'Табельный номер: {ps.employee_id}', merge_to='E')
    s.put('F', f'Месячная (часовая) тарифная ставка: {rate}', merge_to='H')
    s.next()
    # Взносы с начала года и за месяц — как в 1С: ОПВР своей строкой,
    # ООСМС и ВОСМС следующей, не больше трёх в строке.
    header = groups['header']
    opvr = [row for row in header if row[0].startswith('ОПВР')]
    medical = [row for row in header if not row[0].startswith('ОПВР')]
    for line in [opvr[i:i + 3] for i in range(0, len(opvr), 3)] + \
            [medical[i:i + 3] for i in range(0, len(medical), 3)]:
        for (name, amount), (col, last) in zip(
                line, (('A', 'B'), ('C', 'E'), ('F', 'H'))):
            money = f'{amount:,.2f}'.replace(',', ' ').replace('.', ',')
            s.put(col, f'{name}: {money}', merge_to=last)
        s.next()
    s.next()

    # ── Заголовок таблицы ───────────────────────────────────────────────────
    for col, text in zip('ABCDEFGH', ('Вид', 'Период', 'Дни', 'Часы', 'Сумма',
                                      'Вид', 'Период', 'Сумма')):
        cell = s.put(col, text, bold=True, border=True)
        cell.fill = _GREEN
        cell.alignment = Alignment(horizontal='center')
    s.next()

    def section(left, right=None):
        s.put('A', left, bold=True, merge_to='E')
        if right:
            s.put('F', right, bold=True, merge_to='H')
        s.box()
        s.next()

    def pairs(left_rows, right_rows, put_left, put_right):
        for i in range(max(len(left_rows), len(right_rows))):
            if i < len(left_rows):
                put_left(left_rows[i])
            if i < len(right_rows):
                put_right(right_rows[i])
            s.box()
            s.next()

    def right_row(name, period, amount):
        s.put('F', name)
        s.put('G', period)
        s.put('H', amount, money=True)

    # ── 1. Начислено | 2. Удержано ──────────────────────────────────────────
    section('1.Начислено', '2. Удержано')

    def accrual(a):
        s.put('A', a.name)
        s.put('B', period_label(a.period))
        s.put('C', _number(a.working_days))
        s.put('D', _number(a.working_hours))
        s.put('E', a.amount, money=True)

    pairs(list(ps.accruals), list(ps.deductions), accrual,
          lambda d: right_row(d.name, period_label(d.period), d.amount))

    # Дни и часы 1С складывает по всем начислениям, у которых они есть.
    days = sum(a.working_days or 0 for a in ps.accruals)
    hours = sum(a.working_hours or 0 for a in ps.accruals)
    s.put('A', 'Всего начислено', bold=True)
    s.put('C', _number(days) if days else None, bold=True)
    s.put('D', _number(hours) if hours else None, bold=True)
    s.put('E', ps.total_accruals, bold=True, money=True)
    s.put('F', 'Всего удержано', bold=True)
    s.put('H', ps.total_deductions, bold=True, money=True)
    s.box()
    s.next()

    # ── 3. Доходы в натуральной форме | 4. Выплачено ────────────────────────
    section('3. Доходы в натуральной форме', '4. Выплачено')

    def natural(row):
        name, amount = row
        s.put('A', name)
        s.put('B', month_period)
        s.put('E', amount, money=True)

    def paid(p):
        name = p.payment_type or 'Выплата'
        if p.document:
            name = f'{name} ({p.document})'
        right_row(name, period_label(p.period), p.amount)

    pairs(groups['natural'], list(ps.paid), natural, paid)
    s.put('A', 'Всего натуральных доходов', bold=True)
    s.put('E', sum(a for _, a in groups['natural']), bold=True, money=True)
    s.put('F', 'Всего выплат', bold=True)
    total_paid = ps.total_paid or sum(p.amount or 0 for p in ps.paid)
    s.put('H', total_paid, bold=True, money=True)
    s.box()
    s.next()

    # ── 5. Налоговые вычеты ─────────────────────────────────────────────────
    if groups['tax']:
        section('5. Налоговые вычеты')
        pairs(groups['tax'], [], natural, None)
        s.put('A', 'Всего вычеты', bold=True)
        s.put('E', sum(a for _, a in groups['tax']), bold=True, money=True)
        s.box()
        s.next()

    # Взносы за счёт работодателя 1С в этой форме не печатает, но в листке
    # приложения они есть — пусть будут и здесь, отдельно и с пометкой.
    if groups['employer']:
        section('Справочно (за счёт работодателя)')
        pairs(groups['employer'], [], natural, None)

    # ── Долг на начало и конец месяца ───────────────────────────────────────
    start, end = ps.debt_start or 0.0, ps.debt_end or 0.0
    s.put('A', _debt_label(start, 'начало'), bold=True)
    s.put('E', abs(start), bold=True, money=True)
    s.put('F', _debt_label(end, 'конец'), bold=True)
    s.put('H', abs(end), bold=True, money=True)
    s.box()

    out = BytesIO()
    wb.save(out)
    return out.getvalue()
