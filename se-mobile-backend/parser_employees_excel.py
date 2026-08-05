"""
Разбор списка сотрудников из Excel — того, что выгружают из 1С или ведут
в отделе кадров.

Как и у меню, раскладка листа не фиксирована, поэтому колонки определяются
по строке заголовка, а не по номерам. Ищем четыре вещи:

- табельный номер — он же логин;
- ФИО;
- должность — от неё зависит, что человек видит в приложении;
- подразделение — по нему начальник видит свой отдел и только его.

Обязательны первые две. Строки без табельного номера или без ФИО
пропускаются и возвращаются отдельным списком, чтобы кадровик увидел, что
именно не загрузилось, а не гадал по разнице в количестве.

Возвращает: ({'employee_id', 'full_name', 'job_title', 'department', 'iin'}, [пропуски])
"""

import io
import re
from datetime import date, datetime

from openpyxl import load_workbook

# Заголовки колонок. Проверяются вхождением, поэтому «Таб. №» и
# «Табельный номер» ловятся одним ключом.
_HEADER_ID = ('табел', 'таб.', 'таб №', 'таб. №', 'кадровый номер', 'код')
_HEADER_NAME = ('фио', 'ф.и.о', 'фамилия', 'сотрудник', 'работник')
_HEADER_JOB = ('должность', 'профессия', 'позиция')
_HEADER_DEPT = ('подразделение', 'отдел', 'департамент', 'цех', 'участок')
_HEADER_IIN = ('иин', 'ин', 'идентификационный')

_SKIP_ROWS = ('итого', 'всего', 'список', 'утверждаю', 'подпись', 'приложение')

_IIN = re.compile(r'^\d{12}$')


def _text(value) -> str:
    if value is None:
        return ''
    if isinstance(value, (datetime, date)):
        return ''
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return ' '.join(str(value).split())


def _tab_number(value) -> str:
    """Табельный номер как строка без ведущих нулей.

    В выгрузках он приходит то числом 2005, то текстом «0000002005», то
    «2005,0» после конвертации. Логины у нас без ведущих нулей — приводим
    к тому же виду, иначе один человек заведётся дважды.
    """
    raw = _text(value)
    if not raw:
        return ''
    digits = re.sub(r'\D', '', raw)
    if not digits:
        return ''
    stripped = digits.lstrip('0')
    return stripped or '0'


def _read_header(texts):
    """Строка заголовка → {назначение: номер колонки}, или None."""
    columns = {}
    for idx, raw in enumerate(texts):
        low = raw.lower()
        if not low:
            continue
        if 'id' not in columns and any(k in low for k in _HEADER_ID):
            columns['id'] = idx
        elif 'name' not in columns and any(k in low for k in _HEADER_NAME):
            columns['name'] = idx
        elif 'job' not in columns and any(k in low for k in _HEADER_JOB):
            columns['job'] = idx
        elif 'dept' not in columns and any(k in low for k in _HEADER_DEPT):
            columns['dept'] = idx
        elif 'iin' not in columns and low.strip() in _HEADER_IIN:
            columns['iin'] = idx
    # Без табельного номера и ФИО это не список сотрудников, а что-то другое.
    if 'id' in columns and 'name' in columns:
        return columns
    return None


def _looks_like_name(text: str) -> bool:
    """«Иванов Иван Иванович» — да, «Итого» — нет."""
    parts = text.split()
    return len(parts) >= 2 and all(p[0].isalpha() for p in parts if p)


def parse_employees_excel(data: bytes):
    """bytes .xlsx → (список сотрудников, список пропущенных строк)."""
    try:
        book = load_workbook(io.BytesIO(data), data_only=True)
    except Exception as e:
        raise ValueError(f'Не удалось открыть файл: {e}')

    employees = {}
    skipped = []

    for sheet in book.worksheets:
        columns = None
        for row_idx, row in enumerate(sheet.iter_rows(values_only=True), start=1):
            if row is None:
                continue
            texts = [_text(cell) for cell in row]
            joined = ' '.join(texts).strip()
            if not joined:
                continue

            if columns is None:
                columns = _read_header(texts)
                continue

            low = joined.lower()
            if any(low.startswith(k) for k in _SKIP_ROWS):
                continue

            def cell(key):
                idx = columns.get(key)
                return texts[idx] if idx is not None and idx < len(texts) else ''

            emp_id = _tab_number(cell('id'))
            full_name = cell('name')

            if not emp_id or not _looks_like_name(full_name):
                # Заголовки-разделители и пустые строки — не ошибка, о них
                # сообщаем только если там было хоть что-то похожее на данные.
                if emp_id or full_name:
                    skipped.append({
                        'sheet': sheet.title,
                        'row': row_idx,
                        'content': joined[:120],
                        'reason': 'нет табельного номера' if not emp_id
                                  else 'ФИО не распознано',
                    })
                continue

            iin = cell('iin')
            employees[emp_id] = {
                'employee_id': emp_id,
                'full_name': full_name,
                'job_title': cell('job') or 'Сотрудник',
                'department': cell('dept'),
                'iin': iin if _IIN.match(iin) else '',
            }

        if columns is None:
            skipped.append({
                'sheet': sheet.title,
                'row': 0,
                'content': '',
                'reason': 'не найдена строка заголовка с табельным номером и ФИО',
            })

    if not employees:
        raise ValueError(
            'В файле не найдено ни одного сотрудника. Нужны колонки '
            '«Табельный номер» и «ФИО».')

    return list(employees.values()), skipped
