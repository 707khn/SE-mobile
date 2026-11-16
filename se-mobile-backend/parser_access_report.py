"""Проходы из отчёта системы контроля доступа (СКУД).

На проходной отчёт «Проходы ХО/Посетителей» сохраняют в Excel. Программа
отчётов (FastReport) пишет его как «Таблицу XML 2003» с расширением .xls:
внутри XML, и Excel открывает его как обычную книгу. Файл большой — за
полтора месяца 50 МБ и две с половиной тысячи «страниц», у каждой своя
шапка, — поэтому читаем его потоком и не держим дерево в памяти.

Колонки ищем по строке заголовка, а не по номерам:

    ФИО сотрудника | Компания | Подразделение | Дата и время | Событие |
    Зона доступа | Дверь | Код ключа

Табельного номера в отчёте нет — только ФИО; сопоставление с сотрудниками
делает сервер.

На один проход система пишет две строки: «Доступ предоставлен» (считыватель
узнал пропуск) и «Проход» (человек провернул турникет). Берём «Проход» — это
и есть проход. У дверей, где «Прохода» не бывает вовсе (замок без датчика),
берём «Доступ предоставлен»: другой отметки там нет. Отказы («Запрет
доступа», «Доступ отклонен») — не проходы.

Тот же отчёт, пересохранённый в настоящий .xlsx или .xls, тоже читается.

Возвращает список {'name', 'department', 'at' (datetime), 'door'}.
"""

import gzip
import io
import re
from datetime import datetime
from xml.etree import ElementTree

_SS = '{urn:schemas-microsoft-com:office:spreadsheet}'

# Распакованный отчёт больше этого — не отчёт. Год проходов на 500 человек
# в этом виде — около 400 МБ; держим запас, но не даём сжатому файлу
# раздуться в память без предела.
MAX_UNPACKED = 600 * 1024 * 1024

_PASS = 'проход'
_GRANTED = 'доступ предоставлен'

_DATE_FORMATS = ('%d.%m.%Y %H:%M:%S', '%d.%m.%Y %H:%M', '%Y-%m-%d %H:%M:%S',
                 '%Y-%m-%dT%H:%M:%S', '%Y-%m-%d %H:%M')


def _unpack(data: bytes) -> bytes:
    """Программа на компьютере сжимает отчёт перед отправкой: 50 МБ XML
    ужимаются до одного. Несжатый тоже принимаем."""
    if data[:2] != b'\x1f\x8b':
        return data
    out = io.BytesIO()
    with gzip.GzipFile(fileobj=io.BytesIO(data)) as packed:
        while True:
            chunk = packed.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
            if out.tell() > MAX_UNPACKED:
                raise ValueError('Файл слишком большой: загружайте отчёт '
                                 'не больше чем за несколько месяцев')
    return out.getvalue()


def _xml_rows(data: bytes):
    # DOCTYPE в отчёте не бывает. Где он есть, там могут быть и сущности,
    # раздувающиеся при разборе, — такой файл не читаем вовсе.
    if b'<!DOCTYPE' in data[:4096] or b'<!ENTITY' in data[:4096]:
        raise ValueError('Файл не похож на отчёт по проходам')
    try:
        for _, el in ElementTree.iterparse(io.BytesIO(data)):
            if el.tag != _SS + 'Row':
                continue
            cells = []
            for cell in el.findall(_SS + 'Cell'):
                # ss:Index — пропуск пустых ячеек перед этой.
                index = cell.get(_SS + 'Index')
                if index and index.isdigit():
                    while len(cells) < int(index) - 1:
                        cells.append('')
                value = cell.find(_SS + 'Data')
                cells.append(' '.join((value.text or '').split())
                             if value is not None else '')
            el.clear()
            yield cells
    except ElementTree.ParseError as exc:
        raise ValueError(f'Не удалось прочитать файл: {exc}') from None


def _cell_text(value):
    if value is None:
        return ''
    if isinstance(value, datetime):
        return value.strftime('%d.%m.%Y %H:%M:%S')
    return ' '.join(str(value).split())


def _book_rows(data: bytes):
    if data[:4] == b'PK\x03\x04':
        from openpyxl import load_workbook
        book = load_workbook(io.BytesIO(data), read_only=True, data_only=True)
        for sheet in book.worksheets:
            for row in sheet.iter_rows(values_only=True):
                yield [_cell_text(v) for v in row]
        return
    import xlrd
    book = xlrd.open_workbook(file_contents=data)
    for sheet in book.sheets():
        for r in range(sheet.nrows):
            row = []
            for c, value in enumerate(sheet.row_values(r)):
                if sheet.cell_type(r, c) == xlrd.XL_CELL_DATE:
                    value = xlrd.xldate.xldate_as_datetime(value, book.datemode)
                row.append(_cell_text(value))
            yield row


def _rows(data: bytes):
    head = data[:2048].lstrip(b'\xef\xbb\xbf \r\n\t')
    if head.startswith(b'<'):
        yield from _xml_rows(data)
        return
    try:
        yield from _book_rows(data)
    except Exception:
        raise ValueError('Не удалось прочитать файл: ожидается отчёт по '
                         'проходам из программы турникета, сохранённый в Excel') from None


def _header(cells):
    low = [c.lower() for c in cells]
    found = {}
    for i, c in enumerate(low):
        if 'фио' in c or c == 'сотрудник':
            found.setdefault('name', i)
        elif 'подразделение' in c:
            found.setdefault('department', i)
        elif 'дата' in c:
            found.setdefault('at', i)
        elif 'событие' in c:
            found.setdefault('event', i)
        elif 'дверь' in c or 'точка' in c:
            found.setdefault('door', i)
    if {'name', 'at', 'event', 'door'} <= found.keys():
        return found
    return None


def _when(raw):
    raw = raw.strip()
    for fmt in _DATE_FORMATS:
        try:
            return datetime.strptime(raw, fmt)
        except ValueError:
            continue
    return None


def parse_access_report(data: bytes):
    """Проходы из отчёта. ValueError — если файл не тот или в нём пусто."""
    data = _unpack(data)
    columns = None
    passes, granted = [], []
    doors_with_pass = set()

    def get(cells, key):
        i = columns.get(key)
        return cells[i] if i is not None and i < len(cells) else ''

    for cells in _rows(data):
        # Шапка повторяется на каждой странице — узнаём её каждый раз.
        header = _header(cells)
        if header is not None:
            columns = header
            continue
        if columns is None:
            continue
        name = get(cells, 'name')
        at = _when(get(cells, 'at'))
        if not name or at is None:
            continue
        event = get(cells, 'event').lower()
        row = {'name': name, 'department': get(cells, 'department'),
               'at': at, 'door': get(cells, 'door')[:100] or 'Турникет'}
        if event == _PASS:
            passes.append(row)
            doors_with_pass.add(row['door'])
        elif event == _GRANTED:
            granted.append(row)

    if columns is None:
        raise ValueError('В файле не найдена таблица проходов: нужны колонки '
                         '«ФИО сотрудника», «Дата и время», «Событие», «Дверь»')
    passes.extend(r for r in granted if r['door'] not in doors_with_pass)
    if not passes:
        raise ValueError('В отчёте нет ни одного прохода')
    passes.sort(key=lambda r: (r['at'], r['name']))
    return passes


_OUTER = re.compile(r'турникет|проходн|вход|кпп', re.IGNORECASE)


def is_outer_door(door: str) -> bool:
    """Дверь на улицу — у неё есть «вход» и «выход». Считыватели у кабинетов
    стоят внутри здания: пройти через них — не прийти и не уйти."""
    return bool(_OUTER.search(door or ''))
