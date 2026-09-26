"""Свежесть данных — в одном месте и на виду у того, кто может её поправить.

Все пустые экраны, которые находились в приложении, были одного рода: данные
отстают, а видит это только сотрудник, который экран открыл. Расчётные листки
кончались июлем, и экран открывался пустым у всех ста тридцати; проходы — 20
августа, и «Сегодня» был пуст у всех. Каждый раз об этом узнавали от людей.
"""

import os
import re

import app as app_module
from models import db, Payslip, AccessRecord

_LOCALIZATION = os.path.join(
    os.path.dirname(__file__), '..', '..', 'lib', 'utils', 'localization.dart')


def test_every_source_is_reported(app):
    with app.app_context():
        rows = app_module._data_freshness()
    keys = [r['key'] for r in rows]
    assert len(keys) == len(set(keys)), 'источник назван дважды'
    # Те, из-за которых всё и затевалось, должны быть здесь всегда.
    for expected in ('payslips', 'access', 'menu', 'news'):
        assert expected in keys


def test_the_payslip_date_is_the_end_of_the_period(app):
    """Листок за июль закрывает июль — отставание считается от его конца.

    С первого числа оно выходило на месяц больше правды: 84 дня вместо 54.
    """
    with app.app_context():
        latest = (db.session.query(Payslip.period_year, Payslip.period_month)
                  .order_by(Payslip.period_year.desc(),
                            Payslip.period_month.desc()).first())
        row = next(r for r in app_module._data_freshness()
                   if r['key'] == 'payslips')
    if latest is None:
        assert row['last'] is None
        return
    year, month = latest
    assert row['last'].startswith(f'{year:04d}-{month:02d}-')
    # Последний день месяца: следующий день — уже другой месяц.
    from datetime import date, timedelta
    last = date.fromisoformat(row['last'])
    assert (last + timedelta(days=1)).month != month


def test_access_counts_the_people_in_the_last_upload(app):
    """«Сколько человек» — про свежую выгрузку, а не про всю историю.

    Иначе цифра выглядит благополучной: за год в базе побывали все, а в
    последней выгрузке может не быть половины.
    """
    with app.app_context():
        row = next(r for r in app_module._data_freshness() if r['key'] == 'access')
        if row['last'] is None:
            return
        from datetime import date
        expected = (db.session.query(AccessRecord.employee_id)
                    .filter(AccessRecord.access_date == date.fromisoformat(row['last']))
                    .distinct().count())
    assert row['people'] == expected


def test_each_source_has_a_name_in_both_languages():
    """Ключ источника без перевода вылезет на экран как «data_menu».

    Проверка смотрит в сам файл переводов: список источников живёт в Python,
    список названий — в Dart, и разойтись им ничего не мешает.
    """
    text = open(_LOCALIZATION, encoding='utf-8').read()

    # Где начинается раздел языка. Ключи карты были строками «'KZ'» и «'RU'»,
    # теперь это Lang.kk и Lang.ru — понимаем оба вида, чтобы следующее
    # переименование не уронило проверку молча на поиске подстроки.
    def start(*marks):
        for mark in marks:
            if mark in text:
                return text.index(mark)
        raise AssertionError(f'в localization.dart не нашлось ни одного из {marks}')

    kz_at = start('Lang.kk: {', "'KZ': {", "'kk': {")
    ru_at = start('Lang.ru: {', "'RU': {", "'ru': {")
    kz = text[kz_at:ru_at] if kz_at < ru_at else text[kz_at:]
    ru = text[ru_at:kz_at] if ru_at < kz_at else text[ru_at:]

    # Ключи берём из самого исходника функции: список, который надо было бы
    # помнить, и есть то, что всегда отстаёт.
    import inspect
    source_keys = set(re.findall(r"source\('([a-z_]+)'",
                                 inspect.getsource(app_module._data_freshness)))
    assert source_keys, 'не нашёл ни одного источника — проверка бесполезна'

    for key in sorted(source_keys):
        for name, block in (('KZ', kz), ('RU', ru)):
            assert f"'data_{key}':" in block, \
                f'{key}: нет названия в {name} — на экране будет «data_{key}»'
