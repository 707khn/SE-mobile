"""
Разбор план-факта бюджета из Excel — отчёта, который ведёт ПЭО.

Раскладка у таких отчётов разная, поэтому колонки ищутся по строке
заголовка:

- статья (статья затрат, статья бюджета, вид затрат) — обязательно;
- план и факт — обязательно;
- подразделение и месяц — если есть.

Подразделение берётся из колонки; если колонки нет — из строки-группы с
названием подразделения над его статьями («Подразделение: …» или просто
название из справочника); если и групп нет — из названия листа: часто
каждое подразделение ведут на своём листе. Пустая ячейка подразделения
(объединённые ячейки) — то же подразделение, что выше.

Месяц — из колонки, из строки над заголовком («Период: март 2030», «за
март 2030 г.») или из того, что прислала программа загрузки.

Отклонения и проценты не читаются: их считает приложение.

Возвращает: [{'department', 'article', 'year', 'month', 'plan', 'fact'}]
"""

import io
import re
from datetime import date, datetime

from openpyxl import load_workbook

_HEADER_ARTICLE = ('статья', 'статьи', 'вид затрат', 'наименование затрат',
                   'наименование расход')
_HEADER_DEPARTMENT = ('подразделени', 'отдел', 'цех', 'служба', 'структурн',
                      'центр ответственности', 'цфо')
_HEADER_PLAN = ('план', 'бюджет', 'лимит')
_HEADER_FACT = ('факт', 'исполнен')
_HEADER_MONTH = ('месяц', 'период')
_HEADER_SKIP = ('отклонен', 'откл.', '%', 'процент', 'экономия', 'перерасход')

_SKIP_ROWS = ('итого', 'всего')
_HEADING_PREFIX = re.compile(r'^(подразделение|отдел|цфо)\s*[:\-–—]\s*', re.I)
_DEFAULT_SHEETS = ('лист', 'sheet', 'план-факт', 'план факт', 'бюджет', 'отчет')

MONTHS = ('январ', 'феврал', 'март', 'апрел', 'ма', 'июн', 'июл', 'август',
          'сентябр', 'октябр', 'ноябр', 'декабр')
_MONTH_WORD = re.compile(r'(январ|феврал|март|апрел|ма[йя]|июн|июл|август|'
                         r'сентябр|октябр|ноябр|декабр)\w*\s+(\d{4})', re.I)

_MAX_ARTICLE = 200


def _text(value) -> str:
    if value is None:
        return ''
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return ' '.join(str(value).split())


def department_key(name) -> str:
    return ' '.join(_text(name).lower().replace('ё', 'е').split())


def _amount(value):
    """1234,5 · «1 234 567,89» · «(12 000)» → число; не число — None."""
    if isinstance(value, bool) or isinstance(value, (datetime, date)):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    raw = _text(value).replace('\xa0', '').replace(' ', '').replace(',', '.')
    negative = raw.startswith('(') and raw.endswith(')')
    raw = raw.strip('()')
    if not raw or raw in ('-', '–', '—'):
        return None
    try:
        number = float(raw)
    except ValueError:
        return None
    return -number if negative else number


def parse_month(value):
    """Дата, «03.2030», «2030-03», «март 2030» → (2030, 3); иначе None."""
    if isinstance(value, datetime) or isinstance(value, date):
        return value.year, value.month
    text = _text(value).lower()
    if not text:
        return None
    match = _MONTH_WORD.search(text)
    if match:
        word = match.group(1)
        month = next(i for i, stem in enumerate(MONTHS, 1)
                     if word.startswith(stem) and (stem != 'ма' or word[:3] in ('май', 'мая')))
        return int(match.group(2)), month
    match = re.search(r'\b(\d{4})[-./](\d{1,2})\b', text)
    if match:
        year, month = int(match.group(1)), int(match.group(2))
    else:
        match = re.search(r'\b(?:\d{1,2}[./])?(\d{1,2})[./](\d{4})\b', text)
        if not match:
            return None
        month, year = int(match.group(1)), int(match.group(2))
    if 1 <= month <= 12 and 2000 <= year <= 2100:
        return year, month
    return None


def _columns(row):
    found = {}
    for index, value in enumerate(row):
        title = _text(value).lower()
        if not title or any(key in title for key in _HEADER_SKIP):
            continue
        if any(key in title for key in _HEADER_FACT):
            found.setdefault('fact', index)
        elif any(key in title for key in _HEADER_ARTICLE):
            # Раньше плана: «Статья бюджета» — колонка статей, не план.
            found.setdefault('article', index)
        elif any(key in title for key in _HEADER_PLAN):
            found.setdefault('plan', index)
        elif any(key in title for key in _HEADER_DEPARTMENT):
            found.setdefault('department', index)
        elif any(key in title for key in _HEADER_MONTH):
            found.setdefault('month', index)
    if {'article', 'plan', 'fact'} <= set(found):
        return found
    return None


def _sheet_department(title, known):
    key = department_key(title)
    if key in known:
        return known[key]
    if not key or key.startswith(_DEFAULT_SHEETS):
        return ''
    return _text(title)


def _sheet_rows(sheet, known, period):
    rows = list(sheet.iter_rows(values_only=True))
    columns = None
    start = 0
    for index, row in enumerate(rows[:30]):
        columns = _columns(row)
        if columns:
            start = index + 1
            break
        # «Период: март 2030», «План-факт за март 2030 г.» — над заголовком.
        for value in row:
            found = parse_month(value) if _MONTH_WORD.search(_text(value).lower()) \
                or 'период' in _text(value).lower() else None
            if found:
                period = found
    if not columns:
        return None

    def cell(row, key):
        position = columns.get(key)
        if position is None or position >= len(row):
            return None
        return row[position]

    sheet_department = _sheet_department(sheet.title, known)
    current = ''
    items = []
    for row in rows[start:]:
        article = _text(cell(row, 'article'))
        if not article or article.lower().startswith(_SKIP_ROWS):
            continue
        plan = _amount(cell(row, 'plan'))
        fact = _amount(cell(row, 'fact'))
        if 'department' in columns:
            named = _text(cell(row, 'department'))
            if named:
                current = known.get(department_key(named), named)
        elif plan is None and fact is None:
            # Строка без сумм — название подразделения над его статьями или
            # группа статей («Материальные затраты»). Подразделение — только
            # если так и написано или такое есть в справочнике.
            heading = _HEADING_PREFIX.sub('', article)
            if heading != article or department_key(heading) in known:
                current = known.get(department_key(heading), heading)
            continue
        if plan is None and fact is None:
            continue
        month = parse_month(cell(row, 'month')) if 'month' in columns else None
        month = month or period
        if month is None:
            raise ValueError('Не понял, за какой месяц отчёт: нужна колонка '
                             '«Месяц» или строка «Период: март 2030» над '
                             'заголовком')
        items.append({
            'department': (current or sheet_department)[:200],
            'article': article[:_MAX_ARTICLE],
            'year': month[0],
            'month': month[1],
            'plan': plan or 0.0,
            'fact': fact or 0.0,
        })
    return items


def parse_budget_excel(content: bytes, departments=(), period=None):
    """[departments] — названия из справочника: по ним узнаются группы."""
    known = {}
    for name in departments:
        known[department_key(name)] = name
        # «Планово-экономический отдел (ПЭО)» — это и «ПЭО».
        short = re.search(r'\(([^)]+)\)\s*$', name or '')
        if short:
            known.setdefault(department_key(short.group(1)), name)
    try:
        workbook = load_workbook(io.BytesIO(content), read_only=True, data_only=True)
    except Exception as e:
        raise ValueError(f'Не удалось открыть файл Excel: {e}') from e

    items = []
    recognized = False
    try:
        for sheet in workbook.worksheets:
            rows = _sheet_rows(sheet, known, period)
            if rows is None:
                continue
            recognized = True
            items.extend(rows)
    finally:
        workbook.close()
    if not recognized:
        raise ValueError('Не найдена строка заголовков: нужны колонки '
                         '«Статья», «План» и «Факт»')
    if not items:
        raise ValueError('В файле не найдено ни одной статьи с суммами')
    if any(not item['department'] for item in items):
        raise ValueError('Не понял, чьи это статьи: нужна колонка '
                         '«Подразделение», строки с названием подразделения '
                         'над статьями или лист на каждое подразделение')
    return items
