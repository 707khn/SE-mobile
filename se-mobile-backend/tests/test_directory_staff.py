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
