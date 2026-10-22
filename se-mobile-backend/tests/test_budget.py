"""План-факт бюджета: разбор отчёта ПЭО, замена по месяцам, кто что видит."""

import io
import os
from datetime import date

import pytest
from openpyxl import Workbook

import app as app_module
from budget import BudgetLine, BudgetUpload
from models import db, Notification
from parser_budget_excel import parse_budget_excel, parse_month

_ADMIN_PASSWORD = os.environ['ADMIN_PASSWORD']
_IT = 'Отдел информационных технологий и связи (ОИТиС)'
_STOCK = 'Служба учета ТМЦ'
_IT_HEAD = '0000001465'     # начальник ОИТиС
_IT_DEPUTY = '0000001668'   # заместитель начальника ОИТиС
_IT_ENGINEER = '0000001965'
_KEEPER = '0000000009'      # зав. складом №1 — не начальник подразделения
_DIRECTOR = '0000002183'
_PEO = '0000001295'         # главный менеджер ПЭО
_CHIEF_ACCOUNTANT = '0000001298'


@pytest.fixture(autouse=True)
def clean(app, monkeypatch):
    monkeypatch.setattr(app_module, '_plant_today', lambda: date(2030, 4, 2))
    yield
    with app.app_context():
        BudgetLine.query.delete()
        BudgetUpload.query.delete()
        Notification.query.filter_by(kind='budget').delete()
        db.session.commit()


def _xlsx(sheets):
    book = Workbook()
    book.remove(book.active)
    for title, rows in sheets.items():
        sheet = book.create_sheet(title)
        for row in rows:
            sheet.append(row)
    out = io.BytesIO()
    book.save(out)
    return out.getvalue()


# Как ведут в ПЭО: период над шапкой, подразделения строками-группами.
_MARCH = {'План-факт': [
    ['План-факт бюджета за март 2030 г.'],
    [],
    ['Статья', 'План, тг', 'Факт, тг', 'Отклонение', '% исполнения'],
    ['ОИТиС'],
    ['Материалы', 100000, 120000, -20000, 1.2],
    ['Услуги связи', '50 000', '30 000,50', 19999.5, 0.6],
    ['Подразделение: Служба учёта ТМЦ'],
    ['Материальные затраты'],          # группа статей — не подразделение
    ['Материалы', 20000, 10000, 10000, 0.5],
    ['Итого', 170000, 160000.5, None, None],
]}

# Другой вид: колонки подразделения и месяца, лист на всех.
_FEBRUARY = {'Лист1': [
    ['Подразделение', 'Статья бюджета', 'Месяц', 'План', 'Факт'],
    [_IT, 'Материалы', '02.2030', 90000, 80000],
    [None, 'Услуги связи', '02.2030', 50000, 50000],
    ['Цех №9', 'Ремонт', 'февраль 2030', 10, 5],
]}


def _upload(client, content, period=None, login='admin', password=_ADMIN_PASSWORD):
    data = {'login': login, 'password': password,
            'file': (io.BytesIO(content), 'budget.xlsx')}
    if period:
        data['period'] = period
    return client.post('/api/budget/import-excel', data=data,
                       content_type='multipart/form-data')


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _view(app, client, who, **query):
    return client.get('/api/budget', headers=_auth(app, who), query_string=query)


def test_parse_month():
    assert parse_month('март 2030') == (2030, 3)
    assert parse_month('за мая 2030 г.') == (2030, 5)
    assert parse_month('Период: 03.2030') == (2030, 3)
    assert parse_month('2030-11') == (2030, 11)
    assert parse_month('01.12.2030') == (2030, 12)
    assert parse_month(date(2030, 7, 1)) == (2030, 7)
    assert parse_month('13.2030') is None
    assert parse_month('Материалы') is None


def test_parser_reads_groups_and_columns():
    lines = parse_budget_excel(_xlsx(_MARCH), [_IT, _STOCK])
    assert [(l['department'], l['article'], l['plan'], l['fact']) for l in lines] == [
        (_IT, 'Материалы', 100000, 120000),
        (_IT, 'Услуги связи', 50000, 30000.5),
        (_STOCK, 'Материалы', 20000, 10000),
    ]
    assert {(l['year'], l['month']) for l in lines} == {(2030, 3)}

    lines = parse_budget_excel(_xlsx(_FEBRUARY), [_IT])
    assert [(l['department'], l['month']) for l in lines] == [
        (_IT, 2), (_IT, 2), ('Цех №9', 2)]


def test_parser_needs_period_and_department():
    no_period = {'Лист1': [['Статья', 'План', 'Факт'], ['ОИТиС'],
                           ['Материалы', 1, 2]]}
    with pytest.raises(ValueError, match='месяц'):
        parse_budget_excel(_xlsx(no_period), [_IT])
    assert parse_budget_excel(_xlsx(no_period), [_IT],
                              period=(2030, 1))[0]['month'] == 1
    nobody = {'Лист1': [['Статья', 'План', 'Факт'], ['Материалы', 1, 2]]}
    with pytest.raises(ValueError, match='чьи'):
        parse_budget_excel(_xlsx(nobody), [_IT], period=(2030, 1))
    # Лист с названием подразделения — его статьи.
    per_sheet = {'ОИТиС': [['Статья', 'План', 'Факт'], ['Материалы', 1, 2]]}
    assert parse_budget_excel(_xlsx(per_sheet), [_IT],
                              period=(2030, 1))[0]['department'] == _IT
    with pytest.raises(ValueError, match='заголовков'):
        parse_budget_excel(_xlsx({'Лист1': [['ФИО', 'Должность']]}), [_IT])


def test_upload_rights_and_replacement(app, client):
    assert _upload(client, _xlsx(_MARCH), password='wrong').status_code == 401
    answer = _upload(client, _xlsx(_FEBRUARY))
    assert answer.status_code == 200, answer.get_json()
    assert answer.get_json()['unknown'] == ['Цех №9']
    assert 'Нет в справочнике' in answer.get_json()['message']
    assert _upload(client, _xlsx(_MARCH)).status_code == 200

    # Март ОИТиС загрузили заново — февраль и ТМЦ остались.
    again = {'Лист1': [['Подразделение', 'Статья', 'План', 'Факт'],
                       ['ОИТиС', 'Материалы', 100000, 99000]]}
    assert _upload(client, _xlsx(again)).status_code == 422
    assert _upload(client, _xlsx(again), period='2030-03').status_code == 200
    with app.app_context():
        rows = sorted((l.month, l.department, l.article, l.fact)
                      for l in BudgetLine.query.all())
    assert rows == [
        (2, _IT, 'Материалы', 80000), (2, _IT, 'Услуги связи', 50000),
        (2, 'Цех №9', 'Ремонт', 5),
        (3, _IT, 'Материалы', 99000), (3, _STOCK, 'Материалы', 10000)]


def test_overspend_notice_goes_to_heads(app, client):
    assert _upload(client, _xlsx(_MARCH)).status_code == 200
    with app.app_context():
        notices = Notification.query.filter_by(kind='budget').all()
        assert sorted(n.employee_id for n in notices) == [_IT_HEAD, _IT_DEPUTY]
        assert notices[0].title == 'Перерасход бюджета: март 2030'
        assert notices[0].body == 'Материалы — факт 120 000 при плане 100 000'


def test_who_sees_what(app, client):
    _upload(client, _xlsx(_FEBRUARY))
    _upload(client, _xlsx(_MARCH))

    assert _view(app, client, _IT_ENGINEER).status_code == 403
    mine = _view(app, client, _IT_HEAD).get_json()
    assert mine['all'] is False and mine['year'] == 2030
    assert [d['name'] for d in mine['departments']] == [_IT]
    assert mine['months'] == [2, 3]
    assert mine['plan'] == 290000 and mine['fact'] == 280000.5
    assert [(a['article'], a['plan'], a['fact']) for a in mine['articles']] == [
        ('Материалы', 190000, 200000), ('Услуги связи', 100000, 80000.5)]
    assert mine['articles'][0]['months'] == [
        {'month': 2, 'plan': 90000, 'fact': 80000},
        {'month': 3, 'plan': 100000, 'fact': 120000}]
    assert _view(app, client, _IT_HEAD, department=_STOCK).status_code == 403

    assert _view(app, client, _KEEPER).status_code == 403

    for who in (_DIRECTOR, _PEO, _CHIEF_ACCOUNTANT):
        everything = _view(app, client, who, department=_STOCK).get_json()
        assert everything['all'] is True, who
        assert everything['department'] == _STOCK
        assert len(everything['departments']) == 3
    assert _view(app, client, _DIRECTOR, year='2029').get_json()['articles'] == []
