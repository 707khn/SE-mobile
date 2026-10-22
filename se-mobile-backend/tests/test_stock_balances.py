"""Остатки на складах: разбор выгрузки 1С, замена по складам, поиск, доступ."""

import io
import os
from datetime import datetime, timedelta

import pytest
from openpyxl import Workbook
from werkzeug.security import generate_password_hash

import app as app_module
from models import db, UserAccount
from parser_stock_excel import parse_stock_excel
from stock_balances import StockBalance, StockBalanceUpload

_ADMIN_PASSWORD = os.environ['ADMIN_PASSWORD']
_KEEPER = '0000000009'      # зав. складом №1, Служба учёта ТМЦ
_KEEPER_LOGIN = 'sklad1-test'
_KEEPER_PASSWORD = 'склад-номер-один'
_MASTER = '0000000082'      # мастер ОП
_ACCOUNTANT = '0000000137'  # бухгалтер — остатки ему ни к чему
_DRIVER = '0000000155'      # водитель гаража


@pytest.fixture(autouse=True)
def clean(app):
    yield
    with app.app_context():
        StockBalance.query.delete()
        StockBalanceUpload.query.delete()
        db.session.commit()


@pytest.fixture
def keeper_account(app):
    with app.app_context():
        UserAccount.query.filter_by(login=_KEEPER_LOGIN).delete()
        db.session.add(UserAccount(
            login=_KEEPER_LOGIN, employee_id=_KEEPER,
            password_hash=generate_password_hash(_KEEPER_PASSWORD),
            must_change_password=False))
        db.session.commit()
    yield
    with app.app_context():
        UserAccount.query.filter_by(login=_KEEPER_LOGIN).delete()
        db.session.commit()


def _xlsx(rows):
    book = Workbook()
    sheet = book.active
    for row in rows:
        sheet.append(row)
    out = io.BytesIO()
    book.save(out)
    return out.getvalue()


# Как «Остатки товаров на складах» из 1С: шапка отчёта, склады строками-
# группами, внутри номенклатура, внизу «Итого».
_REPORT = [
    ['Остатки товаров на складах'],
    ['Период: 21.10.2026'],
    [],
    ['Склад / Номенклатура', 'Код', 'Ед. изм.', 'Начальный остаток',
     'Приход', 'Расход', 'Конечный остаток', 'Сумма'],
    ['Склад № 1', None, None, None, None, None, 140, 99000],
    ['Электроды МР-3 ф3', '00-123', 'кг', 50, 10, 5, 55, 41000],
    ['Перчатки х/б', '00-200', 'пар', 100, 0, 15, 85, 58000],
    ['Склад №2', None, None, None, None, None, 30, 1],
    ['Электроды МР-3 ф3', '00-123', 'кг', 20, 0, 0, 20, 15000],
    ['Электроды МР-3 ф3', '00-123', 'кг', 0, 10, 0, 10, 7500],
    ['Ветошь', '00-300', 'кг', 0, 0, 0, 0, 0],
    ['Итого', None, None, None, None, None, 170, 1],
]

_SECOND = [
    ['Номенклатура', 'Склад', 'Количество', 'Ед.'],
    ['Электроды УОНИ 13/55', 'Склад №2', '1 234,5', 'кг'],
]


def _upload(client, content, login='admin', password=_ADMIN_PASSWORD,
            name='ostatki.xlsx'):
    return client.post('/api/stock-balances/import-excel', data={
        'login': login, 'password': password,
        'file': (io.BytesIO(content), name)},
        content_type='multipart/form-data')


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _search(client, headers, q):
    return client.get('/api/stock-balances', query_string={'q': q},
                      headers=headers)


def test_parser_reads_1c_report_without_prices():
    rows, skipped = parse_stock_excel(_xlsx(_REPORT))
    assert skipped == 1   # ветошь с нулём
    assert [(r['warehouse'], r['name'], r['quantity']) for r in rows] == [
        ('Склад №1', 'Электроды МР-3 ф3', 55),
        ('Склад №1', 'Перчатки х/б', 85),
        ('Склад №2', 'Электроды МР-3 ф3', 20),
        ('Склад №2', 'Электроды МР-3 ф3', 10),
    ]
    assert rows[0]['code'] == '00-123' and rows[0]['unit'] == 'кг'
    assert all(set(r) == {'code', 'name', 'unit', 'quantity', 'warehouse'}
               for r in rows)


def test_parser_takes_warehouse_column_and_text_numbers():
    rows, _ = parse_stock_excel(_xlsx(_SECOND))
    assert rows == [{'code': '', 'name': 'Электроды УОНИ 13/55', 'unit': 'кг',
                     'quantity': 1234.5, 'warehouse': 'Склад №2'}]


def test_parser_refuses_file_without_header():
    with pytest.raises(ValueError):
        parse_stock_excel(_xlsx([['ФИО', 'Должность'], ['Иванов', 'Мастер']]))


def test_search_groups_warehouses(app, client):
    answer = _upload(client, _xlsx(_REPORT))
    assert answer.status_code == 200, answer.get_json()
    assert answer.get_json()['count'] == 3   # две партии на складе №2 — одна
    assert answer.get_json()['warehouses'] == ['Склад №1', 'Склад №2']

    body = _search(client, _auth(app, _MASTER), 'электроды  мр').get_json()
    assert body['as_of'] and body['stale'] is False
    assert [w['name'] for w in body['warehouses']] == ['Склад №1', 'Склад №2']
    [item] = body['items']
    assert item['name'] == 'Электроды МР-3 ф3' and item['total'] == 85
    assert [(w['name'], w['quantity']) for w in item['warehouses']] == [
        ('Склад №1', 55), ('Склад №2', 30)]
    assert '41000' not in str(body)

    by_code = _search(client, _auth(app, _MASTER), '00-200').get_json()
    assert [i['name'] for i in by_code['items']] == ['Перчатки х/б']
    assert _search(client, _auth(app, _MASTER), 'э').get_json()['items'] == []


def test_upload_replaces_only_warehouses_in_file(app, client, keeper_account):
    _upload(client, _xlsx(_REPORT))
    answer = _upload(client, _xlsx(_SECOND), login=_KEEPER_LOGIN,
                     password=_KEEPER_PASSWORD)
    assert answer.status_code == 200, answer.get_json()
    headers = _auth(app, _MASTER)
    [item] = _search(client, headers, 'мр-3').get_json()['items']
    assert [(w['name'], w['quantity']) for w in item['warehouses']] == [
        ('Склад №1', 55)]
    assert _search(client, headers, 'уони').get_json()['items'][0]['total'] == 1234.5
    with app.app_context():
        assert StockBalanceUpload.query.count() == 2


def test_who_may_upload(client, app):
    assert _upload(client, _xlsx(_REPORT), password='неверный').status_code == 401
    with app.app_context():
        UserAccount.query.filter_by(login='driver-test').delete()
        db.session.add(UserAccount(login='driver-test', employee_id=_DRIVER,
                                   password_hash=generate_password_hash('руль'),
                                   must_change_password=False))
        db.session.commit()
    try:
        answer = _upload(client, _xlsx(_REPORT), login='driver-test', password='руль')
        assert answer.status_code == 403
    finally:
        with app.app_context():
            UserAccount.query.filter_by(login='driver-test').delete()
            db.session.commit()
    assert _upload(client, b'x', name='ostatki.csv').status_code == 400
    assert _upload(client, _xlsx([['a', 'b']])).status_code == 422


def test_who_may_search(app, client):
    _upload(client, _xlsx(_REPORT))
    assert _search(client, _auth(app, _ACCOUNTANT), 'перчатки').status_code == 403
    assert _search(client, _auth(app, _KEEPER), 'перчатки').status_code == 200
    mine = client.get('/api/stock-requests', headers=_auth(app, _MASTER)).get_json()
    assert mine['balances'] is True
    theirs = client.get('/api/stock-requests',
                        headers=_auth(app, _ACCOUNTANT)).get_json()
    assert theirs['balances'] is False


def test_stale_after_three_days(app, client):
    _upload(client, _xlsx(_REPORT))
    with app.app_context():
        for row in StockBalance.query.filter_by(warehouse='Склад №2'):
            row.uploaded_at = datetime.utcnow() - timedelta(days=4)
        db.session.commit()
    body = _search(client, _auth(app, _MASTER), 'перчатки').get_json()
    assert body['stale'] is True


def test_search_escapes_wildcards(app, client):
    _upload(client, _xlsx(_REPORT))
    assert _search(client, _auth(app, _MASTER), '%%').get_json()['items'] == []
