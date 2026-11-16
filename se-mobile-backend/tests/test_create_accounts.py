"""Учётки по расчётным листкам (create_accounts.py).

Главное: заводит только тем, у кого учётки нет; уже вошедших и отключённых
не трогает; человеку, который уже входит под другим номером, вторую не
заводит; код из файла открывает вход.
"""

import csv

import pytest
from werkzeug.security import check_password_hash, generate_password_hash

import app as app_module
import create_accounts
from models import db, Employee, UserAccount

_HAS = '0000009601'       # учётка есть
_OFF = '0000009602'       # учётка отключена
_EMP = '0000009603'       # сотрудник есть, учётки нет
_NEW = '0000009604'       # нет ни сотрудника, ни учётки
_TWIN = '0000009605'      # то же ФИО уже входит под D-номером


@pytest.fixture
def people(app, remove_employee, monkeypatch):
    with app.app_context():
        for emp_id, name, login, active in [
                (_HAS, 'Учёткин Есть Естьевич', '9601', True),
                (_OFF, 'Уволенов Был Былович', '9602', False),
                ('D960', 'Двойников Иван Иванович', 'D960', True)]:
            db.session.add(Employee(employee_id=remove_employee(emp_id),
                                    full_name=name, job_title='Слесарь'))
            db.session.add(UserAccount(login=login, employee_id=emp_id,
                                       password_hash=generate_password_hash('x1'),
                                       must_change_password=False,
                                       is_active=active))
        db.session.add(Employee(employee_id=remove_employee(_EMP),
                                full_name='Безучёткин Пётр Петрович',
                                job_title='Токарь'))
        remove_employee(_NEW)
        db.session.commit()
    sheet = {
        _HAS: 'Учёткин Есть Естьевич', _OFF: 'Уволенов Был Былович',
        _EMP: 'Безучёткин Пётр Петрович', _NEW: 'Новенькая Анна Сергеевна',
        _TWIN: 'Двойников Иван Иванович'}
    monkeypatch.setattr(create_accounts, 'read_people', lambda path: {
        n: {'full_name': f, 'position': 'Инженер', 'department': 'Отдел'}
        for n, f in sheet.items()})
    yield


def _codes(path):
    with open(path, encoding='utf-8-sig', newline='') as f:
        rows = list(csv.reader(f, delimiter=';'))
    assert rows[0] == ['Табельный номер', 'ФИО', 'Код для входа']
    return {row[0]: row[2] for row in rows[1:]}


def test_dry_run_changes_nothing(app, people, tmp_path, capsys):
    out = tmp_path / 'codes.csv'
    assert create_accounts.main(['l.xls', str(out)], application=app) == 0
    assert not out.exists()
    printed = capsys.readouterr().out
    assert 'Заведу учётку и выдам код: 2' in printed
    assert 'D960' in printed
    with app.app_context():
        assert db.session.get(UserAccount, '9603') is None


def test_apply_creates_only_the_missing(app, people, tmp_path):
    out = tmp_path / 'codes.csv'
    assert create_accounts.main(['l.xls', str(out), '--apply'],
                                application=app) == 0
    codes = _codes(out)
    assert set(codes) == {'9603', '9604'}
    assert all(len(c) == 5 and c.isdigit() for c in codes.values())
    with app.app_context():
        for login in ('9603', '9604'):
            account = db.session.get(UserAccount, login)
            assert account.must_change_password
            assert check_password_hash(account.password_hash, codes[login])
            assert app_module._authenticate(login, codes[login])
        # Сотрудник, которого не было, заведён с должностью из листка.
        assert db.session.get(Employee, _NEW).job_title == 'Инженер'
        assert db.session.get(UserAccount, '9604').employee_id == _NEW
        # Существовавший — под своим же идентификатором.
        assert db.session.get(UserAccount, '9603').employee_id == _EMP
        # Отключённого не включили, двойнику вторую учётку не завели.
        assert not db.session.get(UserAccount, '9602').is_active
        assert db.session.get(UserAccount, '9605') is None
        assert check_password_hash(
            db.session.get(UserAccount, '9601').password_hash, 'x1')
        UserAccount.query.filter(UserAccount.login.in_(['9603', '9604'])).delete()
        db.session.commit()


def test_existing_codes_file_is_not_overwritten(app, people, tmp_path):
    out = tmp_path / 'codes.csv'
    out.write_text('старые коды')
    assert create_accounts.main(['l.xls', str(out), '--apply'],
                                application=app) == 1
    assert out.read_text() == 'старые коды'
