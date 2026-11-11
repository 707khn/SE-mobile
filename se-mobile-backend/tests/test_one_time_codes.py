"""Одноразовые коды вместо пароля, равного табельному номеру.

Табельный номер напечатан на пропуске. Кто его видел, входил под чужим
именем и сам менял пароль — обязательная смена при первом входе от этого
не спасала. Теперь новым учёткам и при сбросе выдаётся случайный код, и
передаёт его кадровик лично.
"""

from werkzeug.security import generate_password_hash

import app as app_module
from models import db, Employee, UserAccount


def _make(login, last_login=None):
    db.session.add(Employee(employee_id=login.zfill(10),
                            full_name=f'Код Тестович {login}',
                            job_title='Слесарь'))
    db.session.add(UserAccount(login=login, employee_id=login.zfill(10),
                               password_hash=generate_password_hash(login),
                               must_change_password=True,
                               last_login_at=last_login))
    db.session.commit()


def _drop(*logins):
    for login in logins:
        db.session.delete(db.session.get(UserAccount, login))
        db.session.delete(db.session.get(Employee, login.zfill(10)))
    db.session.commit()


def test_code_shape():
    codes = {app_module._one_time_code() for _ in range(200)}
    assert all(len(c) == 5 and c.isdigit() and c[0] != '0' for c in codes)
    # Случайные, а не одинаковые (из 90 000 вариантов).
    assert len(codes) > 150


def test_issue_codes_closes_number_password(app, client):
    from datetime import datetime
    with app.app_context():
        _make('9301')
        _make('9302', last_login=datetime.utcnow())
        token = app_module._issue_token('ADMIN')

    answer = client.post('/api/admin/accounts/issue-codes',
                         headers={'Authorization': f'Bearer {token}'},
                         json={'logins': ['9301', '9302']})
    assert answer.status_code == 200
    codes = {c['login']: c['code'] for c in answer.get_json()['codes']}
    # Тот, кто уже входит, не тронут: его пароль может быть его собственным.
    assert set(codes) == {'9301'}

    with app.app_context():
        assert app_module._authenticate('9301', '9301') is None
        assert app_module._authenticate('9301', codes['9301']) == '0000009301'
        assert db.session.get(UserAccount, '9301').must_change_password
        assert app_module._authenticate('9302', '9302') == '0000009302'
        _drop('9301', '9302')


def test_issue_codes_is_for_admin_only(app, client):
    with app.app_context():
        token = app_module._issue_token('0000002114')
    answer = client.post('/api/admin/accounts/issue-codes',
                         headers={'Authorization': f'Bearer {token}'},
                         json={'logins': ['2114']})
    assert answer.status_code == 403
