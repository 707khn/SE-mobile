"""Unit tests for parser_1c_xml.parse_1c_xml."""
import os
import textwrap

import pytest

from parser_1c_xml import parse_1c_xml

_XML_DIR = os.path.join(os.path.dirname(__file__), '..')
_TEST_XML = os.path.join(_XML_DIR, 'test_payslip.xml')


def _minimal_xml(month='10', year='2025', kod='0000001874',
                 accruals_total='135600', net='57972') -> bytes:
    return textwrap.dedent(f"""\
        <?xml version="1.0" encoding="UTF-8"?>
        <ЗарплатныеЛисты>
          <ЛистокЗарплаты>
            <Сотрудник Код="{kod}" Наименование="Тест Тест" Должность="Инженер"
                       Подразделение="ИТ" Оклад="100000"/>
            <Период Месяц="{month}" Год="{year}" Отображение="Тест"/>
            <Начислено Итого="{accruals_total}">
              <Строка Вид="Оклад" Период="10.2025" Дни="23" Часы="184" Сумма="{accruals_total}"/>
            </Начислено>
            <Удержано Итого="0"/>
            <Льготы/>
            <Справочно/>
            <ДолгПредприятия НаНачало="0" НаКонец="0"/>
            <КВыплате>{net}</КВыплате>
          </ЛистокЗарплаты>
        </ЗарплатныеЛисты>
    """).encode('utf-8')


# ---------------------------------------------------------------------------
# Happy-path tests
# ---------------------------------------------------------------------------

def test_parse_two_employees():
    with open(_TEST_XML, 'rb') as f:
        results = parse_1c_xml(f.read())

    assert len(results) == 2

    ivan = results[0]
    assert ivan['employee_1c_id'] == '0000001874'
    assert ivan['full_name'] == 'Иванов Иван Иванович'
    assert ivan['period_month'] == 10
    assert ivan['period_year'] == 2025
    assert ivan['total_accruals'] == 135600.0
    assert ivan['total_deductions'] == 17628.0
    assert ivan['net_pay'] == 57972.0
    assert len(ivan['accruals']) == 2
    assert len(ivan['deductions']) == 1
    assert len(ivan['paid']) == 1
    assert len(ivan['benefits']) == 1

    petra = results[1]
    assert petra['employee_1c_id'] == '0000002031'
    assert petra['net_pay'] == 33950.0
    assert petra['benefits'] == []


def test_parse_accrual_fields():
    with open(_TEST_XML, 'rb') as f:
        results = parse_1c_xml(f.read())

    salary_row = results[0]['accruals'][0]
    assert salary_row['name'] == 'Оклад'
    assert salary_row['amount'] == 120000.0
    assert salary_row['working_days'] == 23
    assert salary_row['working_hours'] == 184.0

    bonus_row = results[0]['accruals'][1]
    assert bonus_row['working_days'] is None
    assert bonus_row['working_hours'] is None


def test_parse_single_root_slip():
    xml = textwrap.dedent("""\
        <?xml version="1.0" encoding="UTF-8"?>
        <ЛистокЗарплаты>
          <Сотрудник Код="0000099" Наименование="Одиночный Сотрудник"
                     Должность="Тестер" Подразделение="QA" Оклад="50000"/>
          <Период Месяц="3" Год="2025" Отображение="Март 2025"/>
          <Начислено Итого="50000">
            <Строка Вид="Оклад" Период="03.2025" Дни="20" Часы="160" Сумма="50000"/>
          </Начислено>
          <Удержано Итого="0"/>
          <КВыплате>50000</КВыплате>
        </ЛистокЗарплаты>
    """).encode('utf-8')

    results = parse_1c_xml(xml)
    assert len(results) == 1
    assert results[0]['employee_1c_id'] == '0000099'
    assert results[0]['period_month'] == 3


def test_parse_windows1251():
    with open(_TEST_XML, 'rb') as f:
        utf8_content = f.read()

    text = utf8_content.decode('utf-8')
    text = text.replace('encoding="UTF-8"', 'encoding="windows-1251"', 1)
    w1251_content = text.encode('windows-1251')

    results = parse_1c_xml(w1251_content)
    assert len(results) == 2
    assert results[0]['full_name'] == 'Иванов Иван Иванович'


def test_float_with_comma():
    xml = textwrap.dedent("""\
        <?xml version="1.0" encoding="UTF-8"?>
        <ЗарплатныеЛисты>
          <ЛистокЗарплаты>
            <Сотрудник Код="0000001" Наименование="Тест" Должность="Инженер"
                       Подразделение="ИТ" Оклад="120 000,50"/>
            <Период Месяц="1" Год="2026" Отображение="Январь 2026"/>
            <Начислено Итого="120 000,50">
              <Строка Вид="Оклад" Период="01.2026" Дни="21" Часы="168" Сумма="120 000,50"/>
            </Начислено>
            <Удержано Итого="0"/>
            <КВыплате>120 000,50</КВыплате>
          </ЛистокЗарплаты>
        </ЗарплатныеЛисты>
    """).encode('utf-8')

    results = parse_1c_xml(xml)
    assert results[0]['salary_rate'] == pytest.approx(120000.5)
    assert results[0]['total_accruals'] == pytest.approx(120000.5)
    assert results[0]['net_pay'] == pytest.approx(120000.5)
    assert results[0]['accruals'][0]['amount'] == pytest.approx(120000.5)


def test_empty_sections():
    results = parse_1c_xml(_minimal_xml())
    assert results[0]['benefits'] == []
    assert results[0]['reference'] == []
    assert results[0]['deductions'] == []


# ---------------------------------------------------------------------------
# Error-path tests
# ---------------------------------------------------------------------------

def test_missing_сотрудник():
    xml = textwrap.dedent("""\
        <?xml version="1.0" encoding="UTF-8"?>
        <ЗарплатныеЛисты>
          <ЛистокЗарплаты>
            <Период Месяц="1" Год="2026" Отображение="Январь 2026"/>
            <Начислено Итого="0"/>
            <Удержано Итого="0"/>
            <КВыплате>0</КВыплате>
          </ЛистокЗарплаты>
        </ЗарплатныеЛисты>
    """).encode('utf-8')

    with pytest.raises(ValueError, match='Сотрудник'):
        parse_1c_xml(xml)


def test_empty_код():
    with pytest.raises(ValueError, match='Код'):
        parse_1c_xml(_minimal_xml(kod=''))


def test_invalid_period():
    with pytest.raises(ValueError, match='Месяц'):
        parse_1c_xml(_minimal_xml(month='abc'))


def test_no_slips():
    xml = '<?xml version="1.0" encoding="UTF-8"?><ЗарплатныеЛисты/>'.encode('utf-8')
    with pytest.raises(ValueError, match='ЛистокЗарплаты'):
        parse_1c_xml(xml)


def test_invalid_xml():
    with pytest.raises(ValueError, match='Некорректный XML'):
        parse_1c_xml(b'this is not xml at all <<<')
