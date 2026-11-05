"""Справочник загружает офис-менеджер, и сначала можно только проверить.

Программа на её компьютере сама замечает новый файл справочника, спрашивает
у сервера «что в нём?» (dry_run) и грузит только после «Да». Одинаковый файл
сервер называет одинаковым — тогда программа не тревожит человека вовсе.
Люди и номера здесь выдуманные.
"""

import io

import pytest
from openpyxl import Workbook

import app as app_module
from models import db, DirectoryEntry

_OFFICE = '0000002063'      # офис-менеджер приёмной
_MASTER = '0000000082'      # не офис-менеджер


def _book(rows):
    wb = Workbook()
    ws = wb.active
    ws.append(['Справочник АО «Тест»'])
    ws.append(['ФИО', 'Должность', 'Вн/номер', 'e-mail', 'Мобильный'])
    for row in rows:
        ws.append(row)
    out = io.BytesIO()
    wb.save(out)
    return out.getvalue()


_FIRST = [
    ['Отдел испытаний'],
    ['Тестов Тест Тестович', 'Начальник отдела', '101', 't@test.kz', ''],
    ['Пробная Проба Пробовна', 'Инженер', '102', '', ''],
]


@pytest.fixture(autouse=True)
def clean(app, monkeypatch):
    who = {'office': _OFFICE, 'master': _MASTER}
    monkeypatch.setattr(app_module, '_authenticate',
                        lambda login, password: who.get(login))
    with app.app_context():
        saved = [(r.sort_order, r.department, r.name, r.position, r.extension,
                  r.email, r.mobile, r.updated_at)
                 for r in DirectoryEntry.query.all()]
        DirectoryEntry.query.delete()
        db.session.commit()
    yield
    with app.app_context():
        DirectoryEntry.query.delete()
        for row in saved:
            db.session.add(DirectoryEntry(
                sort_order=row[0], department=row[1], name=row[2],
                position=row[3], extension=row[4], email=row[5],
                mobile=row[6], updated_at=row[7]))
        db.session.commit()


def _post(client, rows, login='office', dry_run=False):
    form = {'login': login, 'password': 'x',
            'file': (io.BytesIO(_book(rows)), 'Справочник.xlsx')}
    if dry_run:
        form['dry_run'] = '1'
    return client.post('/api/directory/import-excel', data=form,
                       content_type='multipart/form-data')


def _names(app):
    with app.app_context():
        return [r.name for r in
                DirectoryEntry.query.order_by(DirectoryEntry.sort_order)]


def test_office_manager_uploads(app, client):
    r = _post(client, _FIRST)
    assert r.status_code == 200, r.get_json()
    assert r.get_json()['count'] == 2
    assert _names(app) == ['Тестов Тест Тестович', 'Пробная Проба Пробовна']


def test_others_may_not(app, client):
    r = _post(client, _FIRST, login='master')
    assert r.status_code == 403
    assert _names(app) == []


def test_dry_run_tells_difference_and_writes_nothing(app, client):
    assert _post(client, _FIRST).status_code == 200
    second = [
        ['Отдел испытаний'],
        ['Тестов Тест Тестович', 'Начальник отдела', '105', 't@test.kz', ''],
        ['Новикова Нова Новиковна', 'Техник', '103', '', ''],
    ]
    data = _post(client, second, dry_run=True).get_json()
    assert data['dry_run'] is True
    assert data['unchanged'] is False
    assert data['count'] == 2 and data['current_count'] == 2
    assert data['added'] == ['Новикова Нова Новиковна']
    assert data['removed'] == ['Пробная Проба Пробовна']
    assert data['changed'] == 1
    assert _names(app) == ['Тестов Тест Тестович', 'Пробная Проба Пробовна']


def test_same_file_is_unchanged(client):
    assert _post(client, _FIRST).status_code == 200
    data = _post(client, _FIRST, dry_run=True).get_json()
    assert data['unchanged'] is True
    assert data['added'] == [] and data['removed'] == [] and data['changed'] == 0


def test_dry_run_still_needs_rights(client):
    assert _post(client, _FIRST, login='master', dry_run=True).status_code == 403
