"""Два номера из одной ячейки справочника — два номера, а не одно число.

В ячейку справочника пишут и два телефона: с новой строки или через десяток
пробелов. При загрузке пробелы схлопывались в один, и приложение, убирая из
номера всё, кроме цифр, набирало оба одним числом в двадцать две цифры.
Номера здесь выдуманные.
"""

import io

import pytest
from openpyxl import Workbook

import app as app_module
from models import db, DirectoryEntry
from parser_directory_excel import (parse_directory_excel, split_emails,
                                    split_phones)


@pytest.mark.parametrize('cell, numbers', [
    ('8 700 000 11 22\n8 700 000 33 44', ['8 700 000 11 22', '8 700 000 33 44']),
    ('8 700 000 11 22          8 700 000 33 44',
     ['8 700 000 11 22', '8 700 000 33 44']),
    ('8 700 000 11 22, 8 700 000 33 44', ['8 700 000 11 22', '8 700 000 33 44']),
    ('8 700 000 11 22; 8 700 000 33 44', ['8 700 000 11 22', '8 700 000 33 44']),
    # Так лежит загруженное раньше: между номерами один пробел, как и между
    # цифрами внутри номера.
    ('8 700 000 11 22 8 700 000 33 44', ['8 700 000 11 22', '8 700 000 33 44']),
    ('+7 (700) 000-11-22 8 (7222) 00-33-44',
     ['+7 (700) 000-11-22', '8 (7222) 00-33-44']),
    ('00-11-22 00-33-44', ['00-11-22', '00-33-44']),
    # Один номер не трогаем, как бы он ни был записан.
    ('8 700 000 11 22', ['8 700 000 11 22']),
    ('+7 (700) 000-11-22', ['+7 (700) 000-11-22']),
    ('87000001122', ['87000001122']),
    ('2-15', ['2-15']),
    (215, ['215']),
    (215.0, ['215']),
    ('', []),
    (None, []),
])
def test_split_phones(cell, numbers):
    assert split_phones(cell) == numbers


def test_split_phones_is_stable():
    once = ', '.join(split_phones('8 700 000 11 22\n8 700 000 33 44'))
    assert ', '.join(split_phones(once)) == once


def test_split_emails():
    assert split_emails('one@example.kz\ntwo@example.kz') == [
        'one@example.kz', 'two@example.kz']
    assert split_emails('one@example.kz, two@example.kz') == [
        'one@example.kz', 'two@example.kz']
    assert split_emails('one@example.kz') == ['one@example.kz']
    assert split_emails('почта: one@example.kz') == ['one@example.kz']
    assert split_emails('нет') == ['нет']
    assert split_emails(None) == []


def _book(rows):
    book = Workbook()
    sheet = book.active
    for row in rows:
        sheet.append(row)
    out = io.BytesIO()
    book.save(out)
    return out.getvalue()


def test_parsed_directory_keeps_numbers_apart():
    data = _book([
        ['Справочник'],
        ['ФИО', 'Должность', 'Вн/номер', 'E-mail', 'Мобильный'],
        ['Тестовый отдел'],
        ['Тестов Тест', 'Инженер', '215', 'one@example.kz\ntwo@example.kz',
         '8 700 000 11 22\n8 700 000 33 44'],
        ['Пробная Проба', 'Техник', '216', 'probe@example.kz',
         '8 700 000 55 66'],
    ])
    first, second = parse_directory_excel(data)
    assert first['mobile'] == '8 700 000 11 22, 8 700 000 33 44'
    assert first['email'] == 'one@example.kz, two@example.kz'
    assert first['extension'] == '215'
    assert first['department'] == 'Тестовый отдел'
    assert second['mobile'] == '8 700 000 55 66'
    assert second['email'] == 'probe@example.kz'


@pytest.fixture
def legacy_entry(app):
    with app.app_context():
        row = DirectoryEntry(sort_order=0, department='Тестовый отдел',
                             name='Тестов Тест', position='Инженер',
                             extension='215',
                             email='one@example.kz two@example.kz',
                             mobile='8 700 000 11 22 8 700 000 33 44')
        db.session.add(row)
        db.session.commit()
        entry_id = row.id
    yield entry_id
    with app.app_context():
        DirectoryEntry.query.filter_by(id=entry_id).delete()
        db.session.commit()


def test_loaded_directory_gets_split_once(app, legacy_entry):
    with app.app_context():
        app_module._split_directory_contacts()
        row = db.session.get(DirectoryEntry, legacy_entry)
        assert row.mobile == '8 700 000 11 22, 8 700 000 33 44'
        assert row.email == 'one@example.kz, two@example.kz'
        assert row.extension == '215'

        # Второй запуск сервера ничего не меняет.
        app_module._split_directory_contacts()
        row = db.session.get(DirectoryEntry, legacy_entry)
        assert row.mobile == '8 700 000 11 22, 8 700 000 33 44'
