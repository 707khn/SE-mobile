"""
Разбор остатков на складах из Excel — отчёта, который выгружают из 1С
(«Остатки товаров на складах», оборотно-сальдовая ведомость по счёту
материалов) или ведут на складе вручную.

Раскладка у таких отчётов разная, поэтому колонки ищутся по строке
заголовка:

- номенклатура (наименование) — обязательно;
- количество: конечный остаток, а не начальный, приход или расход, —
  обязательно;
- код или артикул, единица измерения, склад — если есть.

Склада колонкой может не быть: в отчётах 1С склад идёт строкой-группой
(«Склад №2») над своими позициями. Такая строка задаёт склад для всего,
что ниже, и сама в остатки не попадает — даже если в ней стоит итог.

Суммы, цены и стоимость не читаются вовсе: приложению нужно «есть или нет
и сколько», а цены закупок — коммерческие сведения.

Возвращает: ([{'code', 'name', 'unit', 'quantity', 'warehouse'}], пропущено)
"""

import io
import re
from datetime import date, datetime

from openpyxl import load_workbook

_HEADER_NAME = ('номенклатур', 'наименование', 'материал', 'товар')
_HEADER_UNIT = ('ед.', 'ед ', 'единиц', 'ед.изм', 'ед изм')
_HEADER_QTY = ('остаток', 'количество', 'кол-во', 'кол.')
# Колонки движения и денег — не остаток, даже если в них есть «количество».
_HEADER_NOT_QTY = ('начальн', 'на начало', 'приход', 'расход', 'поступ',
                   'списан', 'оборот', 'сумма', 'цена', 'стоимость')
_HEADER_FINAL = ('конечн', 'на конец')
_HEADER_WAREHOUSE = ('склад', 'место хранения')

_SKIP_ROWS = ('итого', 'всего')

_WAREHOUSE_ROW = re.compile(r'^(центральный |основной |главный )?склад\b|склад\s*№\s*\d')

_MAX_NAME = 200


def _text(value) -> str:
    if value is None or isinstance(value, (datetime, date)):
        return ''
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return ' '.join(str(value).split())


def _quantity(value):
    """12, 12.5, «1 234,5» → число; пусто или не число — None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    raw = _text(value).replace('\xa0', '').replace(' ', '').replace(',', '.')
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def warehouse_name(raw) -> str:
    """«СКЛАД № 2» и «Склад №2» — один склад."""
    text = _text(raw)
    text = re.sub(r'№\s*', '№', text)
    return text[:1].upper() + text[1:] if text else ''


def _columns(row):
    """Номера колонок по строке заголовка или None, если это не заголовок."""
    found = {}
    qty_final = None
    for index, value in enumerate(row):
        title = _text(value).lower()
        if not title:
            continue
        if title.startswith('код') or 'артикул' in title:
            found.setdefault('code', index)
        elif 'номенклатур' in title:
            # «Склад / Номенклатура» в отчётах 1С — это колонка позиций, а
            # склады идут в ней строками-группами.
            found.setdefault('name', index)
        elif 'ответствен' in title:
            continue
        elif any(key in title for key in _HEADER_WAREHOUSE):
            found.setdefault('warehouse', index)
        elif any(key in title for key in _HEADER_NAME):
            found.setdefault('name', index)
        elif title.startswith(_HEADER_UNIT) or 'единиц' in title:
            found.setdefault('unit', index)
        elif any(key in title for key in _HEADER_FINAL) and qty_final is None:
            qty_final = index
        elif (any(key in title for key in _HEADER_QTY)
              and not any(key in title for key in _HEADER_NOT_QTY)):
            found.setdefault('qty', index)
    if qty_final is not None:
        found['qty'] = qty_final
    if 'name' in found and 'qty' in found:
        return found
    return None


def _sheet_rows(sheet):
    rows = list(sheet.iter_rows(values_only=True))
    columns = None
    start = 0
    for index, row in enumerate(rows[:30]):
        columns = _columns(row)
        if columns:
            start = index + 1
            break
    if not columns:
        return None, 0

    def cell(row, key):
        position = columns.get(key)
        if position is None or position >= len(row):
            return None
        return row[position]

    items = []
    skipped = 0
    current_warehouse = ''
    for row in rows[start:]:
        name = _text(cell(row, 'name'))
        code = _text(cell(row, 'code'))
        lowered = name.lower()
        if not name:
            continue
        if lowered.startswith(_SKIP_ROWS):
            continue
        if 'warehouse' not in columns and not code and _WAREHOUSE_ROW.search(lowered):
            current_warehouse = warehouse_name(name)
            continue
        quantity = _quantity(cell(row, 'qty'))
        if quantity is None:
            # Строка-группа номенклатуры («Электроды», «Спецодежда») —
            # без количества. Не ошибка и не пропуск.
            continue
        if quantity <= 0:
            skipped += 1
            continue
        warehouse = (warehouse_name(cell(row, 'warehouse'))
                     if 'warehouse' in columns else current_warehouse)
        items.append({
            'code': code[:50],
            'name': name[:_MAX_NAME],
            'unit': _text(cell(row, 'unit'))[:20],
            'quantity': quantity,
            'warehouse': warehouse[:100],
        })
    return items, skipped


def parse_stock_excel(content: bytes):
    try:
        workbook = load_workbook(io.BytesIO(content), read_only=True, data_only=True)
    except Exception as e:
        raise ValueError(f'Не удалось открыть файл Excel: {e}') from e

    items = []
    skipped = 0
    recognized = False
    for sheet in workbook.worksheets:
        rows, missed = _sheet_rows(sheet)
        if rows is None:
            continue
        recognized = True
        items.extend(rows)
        skipped += missed
    workbook.close()
    if not recognized:
        raise ValueError('Не найдена строка заголовков: нужны колонки '
                         '«Номенклатура» и «Количество» (или «Конечный остаток»)')
    if not items:
        raise ValueError('В файле не найдено ни одной позиции с остатком')
    return items, skipped
