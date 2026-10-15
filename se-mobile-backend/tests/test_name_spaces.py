"""Двойной пробел в ФИО — тот же человек.

Выгрузка расчётных листков из 1С пробелы внутри ФИО не трогала, а загрузка
списка сотрудников из Excel схлопывала. Имя менялось при каждой загрузке
туда и обратно, а «Тестов  Аман» не находился ни поиском по «Тестов Аман»,
ни отчётом начальника, у которого в списке сохранено одно из двух написаний.
"""

import textwrap

import pytest

import app as app_module
from models import db, Employee
from parser_1c_xml import parse_1c_xml

_ID = 'SPC00001'


def _slip(name):
    return textwrap.dedent(f"""\
        <?xml version="1.0" encoding="UTF-8"?>
        <ЗарплатныеЛисты>
          <ЛистокЗарплаты>
            <Сотрудник Код="{_ID}" Наименование="{name}"
                       Должность="Слесарь  ремонтник" Подразделение="Цех"
                       Оклад="100"/>
            <Период Месяц="10" Год="2031" Отображение="Октябрь 2031"/>
            <Начислено Итого="100"/>
            <Удержано Итого="0"/>
            <КВыплате>100</КВыплате>
          </ЛистокЗарплаты>
        </ЗарплатныеЛисты>
    """).encode('utf-8')


def test_1c_name_is_single_spaced():
    slip, = parse_1c_xml(_slip('  Тестов  Аман   Тестович '))
    assert slip['full_name'] == 'Тестов Аман Тестович'
    # Должность — как была: по словам в ней решается, кому что открыто.
    assert slip['position'] == 'Слесарь  ремонтник'


@pytest.fixture
def spaced(app, remove_employee):
    with app.app_context():
        remove_employee(_ID)
        db.session.add(Employee(employee_id=_ID, full_name='Тестов  Аман',
                                job_title='Слесарь  ремонтник'))
        db.session.commit()
    yield


def test_found_as_listed_before_tidying(app, spaced):
    # Список у начальника — из базы, поэтому до уборки он пишет ФИО так же.
    with app.test_request_context():
        for asked in ('Тестов  Аман', 'Тестов'):
            found = app_module._find_reportable(asked)
            assert found is not None and found.employee_id == _ID, asked


def test_names_already_loaded_are_tidied(app, spaced):
    with app.app_context():
        app_module._tidy_employee_names()
        emp = db.session.get(Employee, _ID)
        assert emp.full_name == 'Тестов Аман'
        assert emp.job_title == 'Слесарь  ремонтник'

    with app.test_request_context():
        for asked in ('Тестов Аман', 'Тестов  Аман'):
            found = app_module._find_reportable(asked)
            assert found is not None and found.employee_id == _ID, asked
