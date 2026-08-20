"""
Разбор телефонного справочника предприятия из Excel.

Лист выглядит как печатный справочник, а не как таблица: сначала шапка с
названием и адресом, потом строка заголовков, а дальше вперемешку строки
отделов и строки людей. ФИО при этом гуляет между первыми двумя столбцами —
кто-то заводил записи в один, кто-то в другой, — поэтому имя ищется в любом
столбце левее должности, а не по фиксированному номеру.

Строка, где заполнено только имя и больше ничего, — это заголовок отдела:
всё, что идёт под ней, относится к нему.

Не все записи — люди: «КПП» и «Электроцех» это посты с внутренним номером.
Они попадают в справочник наравне с людьми, потому что звонят туда так же.

Возвращает: [{'department', 'name', 'position', 'extension', 'email', 'mobile'}]
"""

import io

from openpyxl import load_workbook

# Заголовки колонок — проверяются вхождением, регистр не важен.
_H_NAME = ('фио', 'ф.и.о')
_H_POSITION = ('должност',)
_H_EXTENSION = ('вн/номер', 'вн.номер', 'вн номер', 'внутрен', 'вн/№')
_H_EMAIL = ('mail', 'почт')
_H_MOBILE = ('мобильн', 'сотов')

# Директор и его заместители стоят выше первого заголовка отдела — своего
# у них в справочнике нет.
DEFAULT_DEPARTMENT = 'Руководство'


def _text(value) -> str:
    if value is None:
        return ''
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    return str(value).strip()


def _find_header(rows):
    """Строка заголовков и номера колонок, или (None, None).

    Ищем по слову «ФИО»: без него лист не разобрать — неизвестно, где
    кончаются имена и начинается должность.
    """
    for index, values in enumerate(rows):
        lowered = [v.lower() for v in values]
        if not any(any(w in cell for w in _H_NAME) for cell in lowered):
            continue
        columns = {}
        for position, cell in enumerate(lowered):
            if not cell:
                continue
            for key, words in (('position', _H_POSITION), ('extension', _H_EXTENSION),
                               ('email', _H_EMAIL), ('mobile', _H_MOBILE)):
                if key not in columns and any(w in cell for w in words):
                    columns[key] = position
        if 'position' in columns:
            return index, columns
    return None, None


def parse_directory_excel(data: bytes):
    """Разбирает книгу в список записей справочника.

    Бросает ValueError, когда лист не похож на справочник.
    """
    try:
        workbook = load_workbook(filename=io.BytesIO(data), data_only=True)
    except Exception as exc:  # noqa: BLE001 - уходит вызывающему как текст
        raise ValueError(f'Не удалось открыть файл Excel: {exc}') from exc

    entries = []
    for sheet in workbook.worksheets:
        rows = [[_text(cell) for cell in row] for row in sheet.iter_rows(values_only=True)]
        header_at, columns = _find_header(rows)
        if header_at is None:
            continue

        position_at = columns['position']
        department = DEFAULT_DEPARTMENT
        for values in rows[header_at + 1:]:
            def at(key):
                index = columns.get(key)
                if index is None or index >= len(values):
                    return ''
                return values[index]

            # Имя — первое непустое левее должности: в этом файле оно стоит
            # то в первом столбце, то во втором.
            name = next((v for v in values[:position_at] if v), '')
            position, extension = at('position'), at('extension')
            email, mobile = at('email'), at('mobile')

            if not name:
                continue
            if not (position or extension or email or mobile):
                department = name
                continue

            entries.append({
                'department': department,
                'name': name,
                'position': position,
                'extension': extension,
                'email': email,
                'mobile': mobile,
            })

    if not entries:
        raise ValueError(
            'В файле не найдено ни одной записи. Проверьте, что это справочник '
            'со столбцами «ФИО» и «Должность».')
    return entries
