"""Сброс пароля всем, кроме тех, кто есть в CSV (reset_passwords.py).

Главное здесь — кого скрипт не трогает: людей из CSV (им только что
раздали коды), admin и отключённых. И что сброшенный не войдёт ни старым
паролем, ни старым пропуском, а войдёт кодом из файла.
"""

import csv
import os
import stat
from datetime import datetime

import pytest
from werkzeug.security import check_password_hash, generate_password_hash

import app as app_module
import reset_passwords
from models import db, AuthToken, Employee, UserAccount

_OWN = 'Свой-пароль-9'

# В CSV, свой пароль, табельный номер, вход только с телефона, отключённый.
_LISTED, _OWNER, _NUMBER, _PHONE, _DISABLED = '9501', '9502', '9503', '9504', '9505'


def _account(remove_employee, login, password_hash, must_change=False,
             active=True, job='Слесарь'):
    employee_id = remove_employee(login.zfill(10))
    db.session.add(Employee(employee_id=employee_id,
                            full_name=f'Сброс Тестович {login}',
                            job_title=job))
    db.session.add(UserAccount(login=login, employee_id=employee_id,
                               password_hash=password_hash,
                               must_change_password=must_change,
                               is_active=active,
                               last_login_at=datetime.utcnow()))
    db.session.commit()


@pytest.fixture
def accounts(app, remove_employee):
    with app.app_context():
        _account(remove_employee, _LISTED, generate_password_hash('7351'),
                 must_change=True)
        _account(remove_employee, _OWNER, generate_password_hash(_OWN))
        _account(remove_employee, _NUMBER, generate_password_hash(_NUMBER),
                 must_change=True)
        _account(remove_employee, _PHONE, app_module._NO_PASSWORD)
        _account(remove_employee, _DISABLED, generate_password_hash(_OWN),
                 active=False)
        token = app_module._issue_token(_OWNER.zfill(10))
    return token


def _keep_file(app, path, reset):
    """CSV «кого не трогать», как codes.csv: все учётки, кроме `reset`.

    База общая на весь прогон, и сбросить пароль заодно учёткам других
    проверок было бы нельзя. Поэтому в «не трогать» попадают все чужие.
    """
    with app.app_context():
        logins = [a.login for a in UserAccount.query.all()
                  if a.login.isdigit() and a.login not in reset]
    with open(path, 'w', newline='', encoding='utf-8-sig') as f:
        writer = csv.writer(f, delimiter=';')
        writer.writerow(['Табельный номер', 'ФИО', 'Код для входа'])
        for login in logins:
            writer.writerow([login, 'Кто-то', '1234'])
    return str(path)


def _codes(path):
    with open(path, encoding='utf-8-sig', newline='') as f:
        rows = list(csv.reader(f, delimiter=';'))
    assert rows[0] == ['Табельный номер', 'ФИО', 'Код для входа']
    return {row[0]: row[2] for row in rows[1:]}


def _hash(app, login):
    with app.app_context():
        return db.session.get(UserAccount, login).password_hash


def test_dry_run_changes_nothing(app, accounts, tmp_path, capsys):
    keep = _keep_file(app, tmp_path / 'codes.csv', {_OWNER, _NUMBER, _PHONE})
    out = tmp_path / 'codes-2.csv'
    before = {login: _hash(app, login) for login in (_OWNER, _NUMBER, _PHONE)}

    assert reset_passwords.main([keep, str(out)], application=app) == 0

    printed = capsys.readouterr().out
    assert 'пробный прогон' in printed
    assert 'Сброшу пароль и закрою вход на всех устройствах: 3' in printed
    assert 'пароль всё ещё табельный номер' in printed
    assert not out.exists()
    assert {login: _hash(app, login) for login in before} == before
    with app.app_context():
        assert AuthToken.query.filter_by(
            employee_id=_OWNER.zfill(10)).count() == 1


def test_apply_resets_everyone_but_the_list(app, client, accounts, tmp_path):
    keep = _keep_file(app, tmp_path / 'codes.csv', {_OWNER, _NUMBER, _PHONE})
    out = tmp_path / 'codes-2.csv'
    listed, admin = _hash(app, _LISTED), _hash(app, 'admin')

    assert reset_passwords.main([keep, str(out), '--apply'],
                                application=app) == 0

    # Файл с кодами — только для владельца, как у issue_codes.py.
    assert stat.S_IMODE(os.stat(out).st_mode) == 0o600
    codes = _codes(out)
    assert set(codes) == {_OWNER, _NUMBER, _PHONE}
    with app.app_context():
        assert app_module._authenticate(_OWNER, _OWN) is None
        assert app_module._authenticate(_NUMBER, _NUMBER) is None
        for login, code in codes.items():
            assert len(code) == 5 and code.isdigit() and code != login
            assert app_module._authenticate(login, code) == login.zfill(10)
            assert db.session.get(UserAccount, login).must_change_password
    # Пропуск, выданный до сброса, больше не действует.
    me = client.get('/api/me', headers={'Authorization': f'Bearer {accounts}'})
    assert me.status_code == 401

    # Кто в CSV, admin и отключённый — как были.
    assert _hash(app, _LISTED) == listed
    assert _hash(app, 'admin') == admin
    with app.app_context():
        assert check_password_hash(_hash(app, _DISABLED), _OWN)
        assert not db.session.get(UserAccount, _DISABLED).is_active


def test_only_temporary_keeps_own_passwords(app, accounts, tmp_path):
    keep = _keep_file(app, tmp_path / 'codes.csv', {_OWNER, _NUMBER, _PHONE})
    out = tmp_path / 'codes-2.csv'
    phone = _hash(app, _PHONE)

    assert reset_passwords.main([keep, str(out), '--apply', '--only-temporary'],
                                application=app) == 0

    assert set(_codes(out)) == {_NUMBER}
    assert _hash(app, _PHONE) == phone
    with app.app_context():
        assert app_module._authenticate(_OWNER, _OWN) == _OWNER.zfill(10)


def test_keep_leaves_named_logins_alone(app, accounts, tmp_path):
    keep = _keep_file(app, tmp_path / 'codes.csv', {_OWNER, _NUMBER, _PHONE})
    out = tmp_path / 'codes-2.csv'

    assert reset_passwords.main(
        [keep, str(out), '--apply', '--keep', f'{_OWNER},000000{_PHONE}'],
        application=app) == 0

    assert set(_codes(out)) == {_NUMBER}
    with app.app_context():
        assert app_module._authenticate(_OWNER, _OWN) == _OWNER.zfill(10)


def test_excel_resaved_list_with_leading_zeros(app, accounts, tmp_path):
    """Список, пересохранённый в Excel: cp1251, запятая, номер с нулями."""
    path = tmp_path / 'codes.csv'
    keep = _keep_file(app, path, {_OWNER, _NUMBER, _PHONE, _LISTED})
    text = open(keep, encoding='utf-8-sig').read().replace(';', ',')
    text += f'{_LISTED.zfill(10)},Сброс Тестович,7351\n'
    path.write_bytes(text.encode('cp1251'))
    out = tmp_path / 'codes-2.csv'
    listed = _hash(app, _LISTED)

    assert reset_passwords.main([keep, str(out), '--apply'],
                                application=app) == 0

    assert set(_codes(out)) == {_OWNER, _NUMBER, _PHONE}
    assert _hash(app, _LISTED) == listed


@pytest.mark.parametrize('rows', [[], ['99999991', '99999992']],
                         ids=['no-numbers', 'unknown-numbers'])
def test_wrong_list_changes_nothing(app, accounts, tmp_path, capsys, rows):
    """Файл не тот — значит, «не трогать никого», то есть сбросить всех.
    Так скрипт не делает никогда."""
    keep = tmp_path / 'codes.csv'
    keep.write_text('Табельный номер;ФИО\n'
                    + ''.join(f'{r};Кто-то\n' for r in rows),
                    encoding='utf-8-sig')
    out = tmp_path / 'codes-2.csv'
    before = _hash(app, _OWNER)

    assert reset_passwords.main([str(keep), str(out), '--apply'],
                                application=app) == 1

    assert 'Ничего не изменено' in capsys.readouterr().out
    assert not out.exists()
    assert _hash(app, _OWNER) == before


def test_existing_codes_file_is_never_overwritten(app, accounts, tmp_path):
    keep = _keep_file(app, tmp_path / 'codes.csv', {_OWNER, _NUMBER, _PHONE})
    out = tmp_path / 'codes-2.csv'
    out.write_text('коды, которые уже раздают', encoding='utf-8')
    before = _hash(app, _OWNER)

    assert reset_passwords.main([keep, str(out), '--apply'],
                                application=app) == 1

    assert out.read_text(encoding='utf-8') == 'коды, которые уже раздают'
    assert _hash(app, _OWNER) == before


def test_uploaders_are_pointed_out(app, remove_employee, tmp_path, capsys):
    """Через учётку технолога меню грузится с компьютера: сброс её
    остановит, и об этом надо сказать до, а не после."""
    with app.app_context():
        _account(remove_employee, '9506', generate_password_hash(_OWN),
                 job='Технолог столовой')
    keep = _keep_file(app, tmp_path / 'codes.csv', {'9506'})

    assert reset_passwords.main([keep, str(tmp_path / 'codes-2.csv')],
                                application=app) == 0

    printed = capsys.readouterr().out
    assert '9506  Сброс Тестович 9506: загрузка меню' in printed
    assert 'settings.txt' in printed


def test_admin_panel_reset_closes_every_device(app, client, accounts):
    """«Сбросить пароль» в админ-панели идёт через тот же reset_password."""
    with app.app_context():
        admin = app_module._issue_token('ADMIN')
    answer = client.post(f'/api/admin/accounts/{_OWNER}/reset',
                         headers={'Authorization': f'Bearer {admin}'})
    code = answer.get_json()['temporary_password']

    me = client.get('/api/me', headers={'Authorization': f'Bearer {accounts}'})
    assert me.status_code == 401
    with app.app_context():
        assert app_module._authenticate(_OWNER, _OWN) is None
        assert app_module._authenticate(_OWNER, code) == _OWNER.zfill(10)
