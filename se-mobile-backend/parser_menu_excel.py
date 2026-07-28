"""
Parser for canteen menu spreadsheets exported from 1C.

The exact layout 1C produces is not fixed, so the parser reads the sheet
structurally rather than by hard-coded cell addresses:

- a date is taken from any cell that looks like дд.мм.гггг (or a real date
  cell); everything after it belongs to that day, so one file may hold several
  days;
- a row whose name cell is filled and whose price parses is a dish;
- a row with a name but no price is treated as a section heading and applies to
  the dishes below it;
- header rows ("Наименование", "Цена", …) and totals ("Итого") are skipped.

Returns: [{'date': date, 'items': [{'category', 'name', 'price'}, ...]}, ...]
"""

import io
import re
from datetime import date, datetime

from openpyxl import load_workbook

DEFAULT_CATEGORY = 'Блюда'

_DATE_TEXT = re.compile(r'(\d{1,2})[.\-/](\d{1,2})[.\-/](\d{2,4})')

# Cells that label the table rather than name a dish.
_HEADER_WORDS = (
    'наименование', 'блюдо', 'цена', 'стоимость', 'сумма', 'выход',
    '№', 'п/п', 'количество', 'калорийность', 'вес',
)
_SKIP_WORDS = ('итого', 'всего', 'подпись', 'утверждаю', 'директор', 'калькулятор')

# Currency suffixes that may sit next to the number in a price cell.
_CURRENCY = re.compile(r'\s*(₸|тг\.?|тенге|kzt|руб\.?)\s*$', re.I)


def _text(value) -> str:
    if value is None:
        return ''
    if isinstance(value, (datetime, date)):
        return ''
    return ' '.join(str(value).split())


def _parse_price(value):
    """Accepts 450, '450', '1 200,50', '450 тг'. Returns float or None.

    Rejects anything carrying other letters, so a portion size like "250 г"
    is not mistaken for a price.
    """
    if value is None or isinstance(value, (datetime, date, bool)):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    cleaned = str(value).strip().replace('\xa0', ' ')
    cleaned = _CURRENCY.sub('', cleaned)
    cleaned = cleaned.replace(' ', '').replace(',', '.')
    # Digits, at most one decimal point, nothing else.
    if not re.fullmatch(r'\d+(\.\d+)?', cleaned):
        return None
    return float(cleaned)


def _parse_date(value):
    """Reads a real date cell or дд.мм.гггг inside text. Returns date or None."""
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    match = _DATE_TEXT.search(str(value or ''))
    if not match:
        return None
    day, month, year = (int(part) for part in match.groups())
    if year < 100:
        year += 2000
    try:
        return date(year, month, day)
    except ValueError:
        return None


def _is_header(text: str) -> bool:
    lowered = text.lower()
    return any(word in lowered for word in _HEADER_WORDS)


def _is_skippable(text: str) -> bool:
    lowered = text.lower()
    return any(lowered.startswith(word) for word in _SKIP_WORDS)


def parse_menu_excel(data: bytes, fallback_date: date | None = None):
    """Parses the workbook bytes into per-day menus.

    [fallback_date] is used for dishes that appear before any date is found in
    the sheet. Raises ValueError when the file yields nothing usable.
    """
    try:
        workbook = load_workbook(filename=io.BytesIO(data), data_only=True)
    except Exception as exc:  # noqa: BLE001 - surfaced to the caller as a message
        raise ValueError(f'Не удалось открыть файл Excel: {exc}') from exc

    days: dict[date, list[dict]] = {}
    current_date = fallback_date
    category = DEFAULT_CATEGORY

    for sheet in workbook.worksheets:
        for row in sheet.iter_rows(values_only=True):
            if row is None or all(cell is None for cell in row):
                continue

            # A date anywhere on the row switches the day for what follows.
            found_date = next(
                (d for d in (_parse_date(cell) for cell in row) if d is not None), None)

            texts = [_text(cell) for cell in row]
            prices = [_parse_price(cell) for cell in row]
            # The name is the first text that is not a bare number — a leading
            # "№ п/п" column must not be taken for the dish.
            name_at = next(
                (i for i, t in enumerate(texts) if t and _parse_price(t) is None), None)
            name = texts[name_at] if name_at is not None else ''
            # The price column sits to the right of the name, so scan from the
            # end and only consider cells after it.
            price = next(
                (p for i, p in reversed(list(enumerate(prices)))
                 if p is not None and name_at is not None and i > name_at), None)

            if found_date is not None:
                current_date = found_date
                category = DEFAULT_CATEGORY
                # A row that only announces the day carries no dish, and its
                # text must not be taken for a section heading.
                if not name or _is_header(name) or _parse_date(name) is not None:
                    continue

            if not name or _is_header(name) or _is_skippable(name):
                continue

            if price is None:
                # Name without a price — a section heading.
                category = name
                continue

            if current_date is None:
                # Dishes before any date and without a fallback cannot be filed.
                continue

            days.setdefault(current_date, []).append({
                'category': category,
                'name': name,
                'price': price,
            })

    result = [{'date': day, 'items': items} for day, items in sorted(days.items()) if items]
    if not result:
        raise ValueError(
            'В файле не найдено ни одного блюда. Проверьте, что это выгрузка меню из 1С.')
    return result
