"""
Parser for canteen menu spreadsheets exported from 1C.

The layout is not fixed, so the sheet is read structurally rather than by
hard-coded cell addresses:

- the date comes from any cell holding a real date, "03.08.2026" or the written
  form 1C actually produces — "Меню на 03 августа 2026 г.";
- the header row ("Наименование", "Выход", "Цена"…) decides which column is
  what. This matters: the real exports carry a portion column and no price at
  all, and reading a 100-gram portion as a 100-tenge price would put wrong
  numbers in front of every employee;
- a row with a name and no other value is a section heading and applies to the
  dishes below it;
- one file may hold several days.

Returns: [{'date': date, 'items': [{'category', 'name', 'price', 'portion'}]}]
"""

import io
import re
from datetime import date, datetime

from openpyxl import load_workbook

DEFAULT_CATEGORY = 'Блюда'

_MONTHS = {
    'январ': 1, 'феврал': 2, 'март': 3, 'апрел': 4, 'ма': 5, 'июн': 6,
    'июл': 7, 'август': 8, 'сентябр': 9, 'октябр': 10, 'ноябр': 11, 'декабр': 12,
}

_DATE_NUMERIC = re.compile(r'(\d{1,2})[.\-/](\d{1,2})[.\-/](\d{2,4})')
_DATE_WORDS = re.compile(r'(\d{1,2})\s+([А-Яа-яЁё]{3,})\s+(\d{4})')

# Header labels, mapped to the meaning of that column.
_HEADER_NAME = ('наименование', 'блюдо', 'название')
_HEADER_PORTION = ('выход', 'порция', 'вес', 'объем', 'объём', 'грамм')
_HEADER_PRICE = ('цена', 'стоимость', 'сумма')

_SKIP_ROWS = ('итого', 'всего', 'подпись', 'утверждаю', 'директор', 'калькулятор')

# Currency suffixes that may sit next to the number in a price cell.
_CURRENCY = re.compile(r'\s*(₸|тг\.?|тенге|kzt|руб\.?)\s*$', re.I)


def _text(value) -> str:
    if value is None or isinstance(value, (datetime, date)):
        return ''
    return ' '.join(str(value).split())


def _parse_number(value):
    """450, '450', '1 200,50', '450 тг' -> float. Other letters -> None."""
    if value is None or isinstance(value, (datetime, date, bool)):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    cleaned = _CURRENCY.sub('', str(value).strip().replace('\xa0', ' '))
    cleaned = cleaned.replace(' ', '').replace(',', '.')
    return float(cleaned) if re.fullmatch(r'\d+(\.\d+)?', cleaned) else None


def _parse_date(value):
    """Real date cell, "03.08.2026", or "Меню на 03 августа 2026 г."."""
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    text = str(value or '')

    match = _DATE_NUMERIC.search(text)
    if match:
        day, month, year = (int(p) for p in match.groups())
        if year < 100:
            year += 2000
        try:
            return date(year, month, day)
        except ValueError:
            return None

    match = _DATE_WORDS.search(text)
    if match:
        day, word, year = match.group(1), match.group(2).lower(), match.group(3)
        # Prefix match: the word is inflected ("августа", "мая", "января").
        month = next((n for stem, n in _MONTHS.items() if word.startswith(stem)), None)
        if month:
            try:
                return date(int(year), month, int(day))
            except ValueError:
                return None
    return None


def _read_header(texts):
    """Returns {'name': i, 'portion': i, 'price': i} for a header row, else None.

    Requires at least two recognised columns. A single match is not a header:
    the section heading "Второе блюдо" contains "блюдо" and would otherwise be
    read as one, wiping the real column map and sending portions into prices.
    """
    columns = {}
    for index, cell in enumerate(texts):
        lowered = cell.lower()
        if not lowered:
            continue
        if any(w in lowered for w in _HEADER_NAME):
            columns.setdefault('name', index)
        elif any(w in lowered for w in _HEADER_PORTION):
            columns.setdefault('portion', index)
        elif any(w in lowered for w in _HEADER_PRICE):
            columns.setdefault('price', index)
    return columns if 'name' in columns and len(columns) >= 2 else None


def _parse_sheet(sheet, days, state):
    for row in sheet.iter_rows(values_only=True):
        if row is None or all(cell is None for cell in row):
            continue
        texts = [_text(cell) for cell in row]

        found_date = next(
            (d for d in (_parse_date(cell) for cell in row) if d is not None), None)
        if found_date is not None:
            state['date'] = found_date
            state['category'] = DEFAULT_CATEGORY
            continue

        header = _read_header(texts)
        if header:
            state['columns'] = header
            continue

        columns = state['columns']
        name_at = columns.get('name', 0)
        name = texts[name_at] if name_at < len(texts) else ''
        # A leading "№ п/п" column would otherwise be taken for the dish.
        if not name or _parse_number(name) is not None:
            name = next(
                (t for t in texts if t and _parse_number(t) is None), '')
        if not name:
            continue

        lowered = name.lower()
        if any(lowered.startswith(w) for w in _SKIP_ROWS):
            continue

        def at(key):
            index = columns.get(key)
            if index is None or index >= len(texts):
                return None
            return texts[index] or None

        portion = at('portion')
        price = _parse_number(at('price'))

        # No portion and no price: a section heading, not a dish.
        if portion is None and price is None:
            others = [t for i, t in enumerate(texts) if t and i != name_at]
            if not others:
                state['category'] = name
                continue
            # Columns unknown (no header row) — treat a lone number as the price.
            price = next((_parse_number(t) for t in others
                          if _parse_number(t) is not None), None)
            if price is None:
                state['category'] = name
                continue

        if state['date'] is None:
            continue

        days.setdefault(state['date'], []).append({
            'category': state['category'],
            'name': name,
            'price': price,
            'portion': portion,
        })


def parse_menu_excel(data: bytes, fallback_date: date | None = None):
    """Parses the workbook bytes into per-day menus.

    [fallback_date] covers dishes listed before any date appears in the sheet.
    Raises ValueError when nothing usable is found.
    """
    try:
        workbook = load_workbook(filename=io.BytesIO(data), data_only=True)
    except Exception as exc:  # noqa: BLE001 - surfaced to the caller as a message
        raise ValueError(f'Не удалось открыть файл Excel: {exc}') from exc

    days: dict[date, list[dict]] = {}
    state = {'date': fallback_date, 'category': DEFAULT_CATEGORY, 'columns': {}}
    for sheet in workbook.worksheets:
        _parse_sheet(sheet, days, state)

    result = [{'date': day, 'items': items}
              for day, items in sorted(days.items()) if items]
    if not result:
        raise ValueError(
            'В файле не найдено ни одного блюда. Проверьте, что это выгрузка меню из 1С.')
    return result
