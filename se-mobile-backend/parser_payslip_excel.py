"""Расчётные листки из печатной формы 1С, сохранённой в Excel.

Бухгалтер формирует в 1С отчёт «Расчетный листок» сразу на всё предприятие
и сохраняет его как есть — .xls или .xlsx. XML-выгрузки для этого в 1С нет,
а печатную форму умеет сохранить любой. В файле листки идут один под другим:

    Расчетный листок за Июль 2026
    Организация: …                          Подразделение: …
    Работник: Фамилия Имя Отчество          Должность: …
    Табельный номер: 0000001296             Месячная (часовая) тарифная ставка: …
    ОПВР с начала года: …   ОПВР за месяц: …
    Вид  Период  Дни  Часы  Сумма           Вид  Период  Сумма
    1.Начислено                             2. Удержано
    …                                       …
    Всего начислено                         Всего удержано
    3. Доходы в натуральной форме           4. Выплачено
    5. Налоговые вычеты
    Долг за организацией на начало месяца   Долг за организацией на конец месяца

Номера колонок у листков разные: 1С объединяет ячейки под каждый листок
по-своему, и правая половина у одних начинается с 214-й колонки, у других
с 203-й. Поэтому колонки берём не постоянными, а из строки «Вид Период …»
каждого листка.

Результат — те же словари, что у parse_1c_xml: загрузка в базу одна.
"""

import io
import re

from openpyxl import load_workbook

_MONTHS = ('январь', 'февраль', 'март', 'апрель', 'май', 'июнь', 'июль',
           'август', 'сентябрь', 'октябрь', 'ноябрь', 'декабрь')
_TITLE = re.compile(r'^Расч[её]тный листок за\s+(\S+)\s+(\d{4})', re.IGNORECASE)
# Так payslip_xlsx узнаёт натуральные доходы среди справочных строк.
NATURAL_PREFIX = 'Натуральный доход: '

# С октября 2026 1С печатает в шапке строку итогов с начала года:
#   «С нач.года: начисл. дох.: 6 754 725,00 | необл. дох.: … | ОПВ: … |
#    Выч.: … | ИПН: …»
# Подписи у ячеек короткие, а «с начала года» стоит только в первой. Без
# этого приложение теряло начисленный доход с начала года, а ОПВ и ИПН за
# год показывало как будто за месяц: «ОПВ 668 984» рядом с удержанными
# за месяц 49 295.
_YEAR_TO_DATE = re.compile(r'^С\s*нач(?:ала|\.)\s*года\s*:\s*', re.IGNORECASE)
_YEAR_TO_DATE_NAMES = {
    'начисл. дох.': 'Начисленный доход',
    'необл. дох.': 'Необлагаемый доход',
    'опв': 'ОПВ',
    'выч.': 'Вычеты',
    'ипн': 'ИПН',
}
YEAR_TO_DATE_SUFFIX = ' с начала года'


def _text(value):
    if value is None:
        return ''
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    return ' '.join(str(value).split())


def _number(value):
    """Число из ячейки: 448139.0, «448 139,00», «1 817,00». Пусто — None."""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).replace('\xa0', '').replace(' ', '').replace(',', '.')
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def _read_rows(data):
    """Все строки первого листа: список словарей «колонка → значение».

    Пустые ячейки не храним: в печатной форме 1С колонок под 250, а занято
    в строке пять-восемь.
    """
    if data[:4] == b'PK\x03\x04':
        try:
            wb = load_workbook(io.BytesIO(data), read_only=True, data_only=True)
        except Exception as e:
            raise ValueError(f'Не удалось открыть файл Excel: {e}')
        rows = []
        for values in wb.worksheets[0].iter_rows(values_only=True):
            rows.append({c: v for c, v in enumerate(values)
                         if v is not None and _text(v)})
        wb.close()
        return rows

    # Старый формат .xls — так 1С сохраняет «Лист Excel» по умолчанию.
    try:
        import xlrd
        book = xlrd.open_workbook(file_contents=data, on_demand=True)
    except Exception as e:
        raise ValueError(f'Не удалось открыть файл Excel: {e}')
    try:
        sheet = book.sheet_by_index(0)
        rows = []
        for r in range(sheet.nrows):
            rows.append({c: v for c, v in enumerate(sheet.row_values(r))
                         if _text(v)})
        return rows
    finally:
        book.release_resources()


def _labelled(text):
    """«Табельный номер: 0000001296» → («Табельный номер», «0000001296»)."""
    label, colon, value = text.partition(':')
    if not colon:
        return None, None
    return label.strip(), value.strip()


def _section(text):
    """Заголовок раздела листка → куда класть его строки."""
    if not re.match(r'^\d\s*\.', text):
        return None
    lower = text.lower()
    if 'начислено' in lower:
        return 'accruals'
    if 'удержано' in lower:
        return 'deductions'
    if 'натуральн' in lower:
        return 'natural'
    if 'выплачено' in lower:
        return 'paid'
    if 'вычет' in lower:
        return 'tax'
    # Раздел, которого в образце не было («Пособия» и т.п.) — не теряем его
    # строки, кладём в справочные.
    return 'other'


class _Slip:
    def __init__(self, month, year, display):
        self.data = {
            'employee_1c_id': '', 'full_name': '', 'position': '',
            'department': '', 'salary_rate': 0.0,
            'period_month': month, 'period_year': year,
            'period_display': display,
            'total_accruals': 0.0, 'total_deductions': 0.0,
            'total_paid': 0.0, 'net_pay': 0.0,
            'debt_start': 0.0, 'debt_end': 0.0,
            'accruals': [], 'deductions': [], 'paid': [],
            'benefits': [], 'reference': [],
        }
        # Колонки «Период/Дни/Часы/Сумма» обеих половин и начало правой.
        self.left = {}
        self.right = {}
        self.right_from = None
        self.sections = {'left': None, 'right': None}

    def header(self, label, value):
        d = self.data
        if label == 'Работник':
            d['full_name'] = value
        elif label == 'Табельный номер':
            d['employee_1c_id'] = value
        elif label == 'Должность':
            d['position'] = value
        elif label == 'Подразделение':
            d['department'] = value
        elif label.startswith('Месячная') or label.startswith('Оклад'):
            d['salary_rate'] = _number(value) or 0.0
        elif label == 'Организация':
            pass
        else:
            # Взносы: «ОПВР с начала года», «ООСМС за месяц». Пустые 1С
            # печатает как «ОПВР за месяц:  » — их нет смысла показывать.
            amount = _number(value)
            if amount is not None:
                d['reference'].append({'name': label, 'amount': amount})

    def columns(self, cells):
        """Строка «Вид Период Дни Часы Сумма | Вид Период Сумма»."""
        vid = [c for c, v in cells if v == 'Вид']
        if len(vid) >= 2:
            self.right_from = vid[1]
        self.left = {v: c for c, v in cells
                     if self.right_from is None or c < self.right_from}
        self.right = {v: c for c, v in cells
                      if self.right_from is not None and c >= self.right_from}

    def split(self, row):
        cells = sorted(row.items())
        if self.right_from is None:
            return cells, []
        return ([(c, v) for c, v in cells if c < self.right_from],
                [(c, v) for c, v in cells if c >= self.right_from])

    def total(self, name, amount):
        lower = name.lower()
        d = self.data
        if lower.startswith('всего начислено'):
            d['total_accruals'] = amount
        elif lower.startswith('всего удержано'):
            d['total_deductions'] = amount
        elif lower.startswith('всего выплат'):
            d['total_paid'] = amount

    def debt(self, name, amount):
        # «Долг за работником» — работник должен организации: со знаком минус,
        # как его и понимает payslip_xlsx.
        if 'за работником' in name.lower():
            amount = -abs(amount)
        if 'начало' in name.lower():
            self.data['debt_start'] = amount
        else:
            self.data['debt_end'] = amount

    def line(self, side, cells):
        if not cells:
            return
        name = _text(cells[0][1])
        rest = cells[1:]
        lower = name.lower()

        section = _section(name)
        if section:
            self.sections[side] = section
            return
        numbers = [(c, _number(v)) for c, v in rest if _number(v) is not None]
        amount = numbers[-1][1] if numbers else 0.0
        if lower.startswith('долг за'):
            self.debt(name, amount)
            self.sections[side] = None
            return
        if lower.startswith('всего'):
            self.total(name, amount)
            self.sections[side] = None
            return

        section = self.sections[side]
        if section is None:
            return
        texts = [_text(v) for c, v in rest if _number(v) is None]
        period = texts[0] if texts else ''
        at = dict(numbers)
        columns = self.left if side == 'left' else self.right
        if 'Сумма' in columns and section != 'tax':
            # Пустая «Сумма» — это ноль: больничный, оплаченный за счёт ФСС,
            # 1С печатает с днями и часами, но без суммы. Брать вместо неё
            # последнее число из строки значило бы записать часы деньгами.
            amount = at.get(columns['Сумма'], 0.0)
        d = self.data
        if section == 'accruals':
            days = at.get(columns.get('Дни'))
            hours = at.get(columns.get('Часы'))
            d['accruals'].append({
                'name': name, 'amount': amount, 'period': period,
                'working_days': int(days) if days is not None else None,
                'working_hours': hours,
            })
        elif section == 'deductions':
            d['deductions'].append({'name': name, 'amount': amount,
                                    'period': period})
        elif section == 'paid':
            d['paid'].append({'payment_type': name, 'period': period,
                              'document': '', 'date': '', 'amount': amount})
        elif section == 'tax':
            d['benefits'].append({'name': name, 'amount': amount})
        elif section == 'natural':
            d['reference'].append({'name': NATURAL_PREFIX + name,
                                   'amount': amount})
        else:
            d['reference'].append({'name': name, 'amount': amount})

    def result(self):
        d = self.data
        d['full_name'] = ' '.join(d['full_name'].split())
        d['net_pay'] = round(d['total_accruals'] - d['total_deductions'], 2)
        return d


def parse_payslip_excel(data: bytes) -> list[dict]:
    """Листки из файла Excel с печатной формой 1С. ValueError — не тот файл."""
    if not data:
        raise ValueError('Файл пустой')
    rows = _read_rows(data)

    slips = []
    slip = None
    for row in rows:
        first = _text(row.get(min(row))) if row else ''
        title = _TITLE.match(first)
        if title:
            if slip is not None:
                slips.append(slip)
            month_name, year = title.group(1).lower(), int(title.group(2))
            if month_name not in _MONTHS:
                raise ValueError(f'Не понятен месяц в заголовке «{first}»')
            month = _MONTHS.index(month_name) + 1
            slip = _Slip(month, year, f'{_MONTHS[month - 1].capitalize()} {year}')
            continue
        if slip is None or not row:
            continue

        values = [_text(v) for _, v in sorted(row.items())]
        if values[0] == 'Вид':
            slip.columns([(c, _text(v)) for c, v in sorted(row.items())])
            continue
        if values[0] == 'Подразделение организации':
            # Строка группировки отчёта между листками, не часть листка.
            continue

        if _YEAR_TO_DATE.match(values[0]):
            for c, v in sorted(row.items()):
                label, value = _labelled(_YEAR_TO_DATE.sub('', _text(v)))
                if label is None:
                    continue
                name = _YEAR_TO_DATE_NAMES.get(label.lower(), label)
                slip.header(name + YEAR_TO_DATE_SUFFIX, value)
            continue

        labels = [_labelled(v) for v in values]
        if all(label for label, _ in labels) and not _section(values[0]):
            # Шапка: «Работник: …», «Должность: …». Правая половина шапки
            # начинается там же, где правая половина таблицы, — запомним,
            # если строки «Вид …» у листка не будет.
            for c, v in sorted(row.items()):
                label, value = _labelled(_text(v))
                if label == 'Подразделение' and slip.right_from is None:
                    slip.right_from = c
                slip.header(label, value)
            continue

        left, right = slip.split(row)
        slip.line('left', left)
        slip.line('right', right)
    if slip is not None:
        slips.append(slip)

    if not slips:
        raise ValueError('В файле нет расчётных листков. Нужен отчёт 1С '
                         '«Расчетный листок», сохранённый в Excel.')
    result = [s.result() for s in slips]
    missing = [r for r in result if not r['employee_1c_id']]
    if missing:
        names = ', '.join(r['full_name'] or '?' for r in missing[:5])
        raise ValueError(f'У {len(missing)} листков нет табельного номера '
                         f'({names}). Сформируйте отчёт с табельными номерами.')
    return result
