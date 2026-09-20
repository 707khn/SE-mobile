"""Учётные записи по справочнику и августовские проходы.

Данные лежат в двух файлах рядом с кодом; проверяем не их содержимое, а то,
что сидер применяет их целиком и не задваивает при повторном запуске.
"""

import csv
import datetime
import os

from models import db, Employee, UserAccount, AccessRecord, TurnstileEvent
import app as app_module

_DATA = os.path.join(os.path.dirname(__file__), '..', 'data')


def _rows(name):
    with open(os.path.join(_DATA, name), newline='', encoding='utf-8') as f:
        return list(csv.DictReader(f, delimiter=';'))


def test_everyone_from_the_directory_exists(app):
    with app.app_context():
        missing = [r['fio'] for r in _rows('employees_2026_07.csv')
                   if db.session.get(Employee, r['tab']) is None]
        assert not missing, f'нет в базе: {missing[:5]}'


def test_everyone_can_log_in(app):
    """Логин и пароль — табельный номер; у кого учётка была, тот входит по ней."""
    with app.app_context():
        for row in _rows('employees_2026_07.csv'):
            account = UserAccount.query.filter_by(employee_id=row['tab']).first()
            assert account is not None, f'{row["fio"]} остался без учётной записи'
            if account.login == row['tab']:
                # Заведённые сейчас: пароль равен номеру и его просят сменить.
                assert app_module._authenticate(row['tab'], row['tab']) == row['tab']
                assert account.must_change_password


def test_temporary_ids_are_gone(app):
    """D0xx — временный номер на время без табельного; после загрузки их нет."""
    with app.app_context():
        left = {e.employee_id for e in
                Employee.query.filter(Employee.employee_id.like('D%')).all()}
        # Кроме троих, у которых июльского листка нет, а значит нет и номера.
        assert left == {'D100', 'D101', 'D102'}, left


def test_august_access_is_loaded(app):
    with app.app_context():
        august = AccessRecord.query.filter(
            AccessRecord.access_date >= datetime.date(2026, 8, 1),
            AccessRecord.access_date <= datetime.date(2026, 8, 31)).count()
        assert august > 2000, august

        # Вход и выход — только через двери на улицу: считыватель у кабинета
        # в табель попадать не должен.
        doors = {e.timestamp: e for e in TurnstileEvent.query.filter(
            TurnstileEvent.timestamp >= datetime.datetime(2026, 8, 1),
            TurnstileEvent.timestamp < datetime.datetime(2026, 9, 1)).all()}
        assert len(doors) > 1000

        inside = AccessRecord.query.filter(
            AccessRecord.door_location.like('считыватель%'),
            AccessRecord.event_type != 'Проход').count()
        assert inside == 0, 'у внутренней двери проставлено направление'


def test_loading_twice_changes_nothing(app):
    with app.app_context():
        before = (AccessRecord.query.count(), TurnstileEvent.query.count(),
                  UserAccount.query.count(), Employee.query.count())
        app_module._seed_directory_staff_2026()
        app_module._seed_access_august_2026()
        after = (AccessRecord.query.count(), TurnstileEvent.query.count(),
                 UserAccount.query.count(), Employee.query.count())
        assert before == after


def test_every_book_is_loaded(app):
    """Каждая книга из data/ доехала: листок есть у всех, кто есть в базе."""
    import glob
    import json
    import re as _re
    books = sorted(glob.glob(os.path.join(_DATA, 'payslips_*.json')))
    assert books, 'книг расчётных листков в data/ не нашлось'

    with app.app_context():
        from models import Payslip
        for path in books:
            year, month = (int(x) for x in
                           _re.search(r'(\d{4})_(\d{2})', path).groups())
            with open(path, encoding='utf-8') as f:
                book = {s['tab']: s for s in json.load(f)}
            have = {p.employee_id for p in Payslip.query.filter_by(
                period_year=year, period_month=month).all()}
            expected = {r['tab'] for r in _rows('employees_2026_07.csv')
                        if r['tab'] in book}
            assert expected - have == set(), \
                f'{year}-{month:02d}: без листка остались {expected - have}'


def test_payslip_adds_up(app):
    """Разобранное сходится с итогами, напечатанными в самом листке.

    Это и есть проверка разбора: цифры в книге 1С стоят в двух столбцах,
    перепутать их местами — дело одной строки кода, а заметно это только по
    тому, что сумма перестаёт сходиться.
    """
    with app.app_context():
        from models import Payslip
        for ps in Payslip.query.filter(Payslip.period_year == 2026,
                                       Payslip.period_month.in_((6, 7))).all():
            accrued = round(sum(a.amount for a in ps.accruals), 2)
            deducted = round(sum(d.amount for d in ps.deductions), 2)
            paid = round(sum(p.amount for p in ps.paid), 2)
            assert abs(accrued - ps.total_accruals) < 1, ps.employee_id
            assert abs(deducted - ps.total_deductions) < 1, ps.employee_id
            assert abs(ps.net_pay - (accrued - deducted)) < 1, ps.employee_id
            # Долг на начало плюс заработанное минус выплаченное — долг на
            # конец. Сходится у всех 374 листков книги.
            closing = round((ps.debt_start or 0) + accrued - deducted - paid, 2)
            assert abs(closing - (ps.debt_end or 0)) < 1, ps.employee_id


def test_payslips_load_once(app):
    """Второй прогон подряд не добавляет ничего.

    Сравниваем два прогона подряд, а не «до и после»: между стартом
    приложения и этой проверкой другие тесты успевают завести сотрудников,
    и их листки сидер подберёт — это его работа, а не задвоение.
    """
    with app.app_context():
        from models import Payslip, PayslipAccrual
        app_module._seed_payslips_from_data()
        before = (Payslip.query.count(), PayslipAccrual.query.count())
        app_module._seed_payslips_from_data()
        assert (Payslip.query.count(), PayslipAccrual.query.count()) == before


def test_merged_employee_keeps_the_iin(app):
    """ИИН — колонка записи, а не отдельная строка: при склейке он терялся."""
    with app.app_context():
        keep = db.session.get(Employee, '0000002114')   # Сарсекенов
        assert keep is not None and keep.iin, 'ИИН пропал при склейке записей'


def test_june_hands_over_to_july(app):
    """Долг на конец июня равен долгу на начало июля.

    Две книги разбирались одним разборщиком, но независимо друг от друга,
    и сходятся они только если обе разобраны верно: ошибка в знаке долга
    или в столбце сразу разводит месяцы.
    """
    with app.app_context():
        from models import Payslip
        june = {p.employee_id: p for p in Payslip.query.filter_by(
            period_year=2026, period_month=6).all()}
        july = {p.employee_id: p for p in Payslip.query.filter_by(
            period_year=2026, period_month=7).all()}
        both = set(june) & set(july)
        assert len(both) > 100, len(both)
        for emp in both:
            assert abs((june[emp].debt_end or 0) -
                       (july[emp].debt_start or 0)) < 1, emp


def test_merge_moves_a_live_token(app):
    """Пропуск тоже ссылается на сотрудника.

    На боевой базе у людей есть действующие пропуска, и удаление прежней
    записи упиралось в них: «violates foreign key constraint auth_tokens».
    В проверках этого не было видно — там никто не входил до склейки.
    """
    from models import AuthToken
    with app.app_context():
        stale = Employee(employee_id='D999', full_name='Временный Т.',
                         job_title='Слесарь')
        keep = db.session.get(Employee, '0000002114')
        db.session.add(stale)
        db.session.commit()
        token = app_module._issue_token('D999')

        assert app_module._absorb_employee('D999', keep.employee_id) is not None
        assert db.session.get(Employee, 'D999') is None
        assert db.session.get(AuthToken, token).employee_id == keep.employee_id
