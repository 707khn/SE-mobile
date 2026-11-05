"""Что сервер обещает автозагрузке меню (tools/menu-upload/watch_menu.ps1).

Программа на компьютере технолога сама отправляет каждый новый файл
«Меню № БК000000245 от 04.11.2026.xlsx» и ставит его на дату из имени. Если в
файле несколько дней, сервер отвечает 422 со словами «несколько дней» —
программа по ним понимает, что надо отправить файл ещё раз, уже без
force_date. Поменяете текст отказа — поправьте и программу.
"""

import io
from datetime import date

import pytest
from openpyxl import Workbook
from werkzeug.security import generate_password_hash

from models import db, Employee, MenuDate, UserAccount

_ID = 'AUTO0001'
_LOGIN = 'avtomenu'
_PASSWORD = 'длинная-фраза-технолога'
_NAME = 'Меню № БК000000245 от 04.11.2026.xlsx'


@pytest.fixture
def account(app, remove_employee):
    with app.app_context():
        remove_employee(_ID)
        UserAccount.query.filter_by(login=_LOGIN).delete()
        db.session.add(Employee(employee_id=_ID, full_name='Автоменю Тест',
                                job_title='Технолог столовой'))
        db.session.add(UserAccount(login=_LOGIN, employee_id=_ID,
                                   password_hash=generate_password_hash(_PASSWORD),
                                   must_change_password=False))
        db.session.commit()
    yield
    with app.app_context():
        UserAccount.query.filter_by(login=_LOGIN).delete()
        for d in (date(2026, 11, 4), date(2026, 11, 5), date(2026, 11, 6),
                  date(2026, 10, 30)):
            menu = MenuDate.query.filter_by(date=d).first()
            if menu:
                db.session.delete(menu)
        db.session.commit()


def _xlsx(*days):
    wb = Workbook()
    ws = wb.active
    for title in days:
        ws.append([title])
        ws.append(['Наименование', 'Выход', 'Цена'])
        ws.append(['Супы'])
        ws.append(['Борщ', 250, 450])
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


def _send(client, data, force_date=None):
    form = {'login': _LOGIN, 'password': _PASSWORD,
            'file': (io.BytesIO(data), _NAME)}
    if force_date:
        form['force_date'] = force_date
    return client.post('/api/menu/import-excel', data=form,
                       content_type='multipart/form-data')


def test_date_from_file_name_wins_over_date_in_sheet(client, account, app):
    # 1С проставила в таблице другое число — меню всё равно ложится на 04.11.
    r = _send(client, _xlsx('Меню на 30 октября 2026 г.'), '2026-11-04')
    assert r.status_code == 200, r.get_json()
    with app.app_context():
        assert MenuDate.query.filter_by(date=date(2026, 11, 4)).first().items
        assert MenuDate.query.filter_by(date=date(2026, 10, 30)).first() is None


def test_several_days_refused_with_words_the_watcher_looks_for(client, account, app):
    data = _xlsx('Меню на 05 ноября 2026 г.', 'Меню на 06 ноября 2026 г.')
    r = _send(client, data, '2026-11-04')
    assert r.status_code == 422
    assert 'несколько дней' in r.get_json()['message']

    # Повтор без force_date раскладывает дни по датам из таблицы.
    r = _send(client, data)
    assert r.status_code == 200, r.get_json()
    with app.app_context():
        assert MenuDate.query.filter_by(date=date(2026, 11, 5)).first().items
        assert MenuDate.query.filter_by(date=date(2026, 11, 6)).first().items
