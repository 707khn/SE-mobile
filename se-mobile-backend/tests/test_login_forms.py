"""Табельный номер в той форме, в какой его называет человек.

В базе номер полный — «0000000450». На пропуске и вслух он «450», и первым
же, кто попробовал войти, оказался начальник юридического отдела: «данный
логин не зарегистрирован». Принимаем обе формы.
"""

import app as app_module
from models import db, UserAccount
from werkzeug.security import generate_password_hash

_FULL = '0000000450'      # Омаргалиева, начальник юридического отдела
_SHORT = '450'


def _post(client, payload):
    return client.post('/login', json=payload)


def test_short_number_gets_in(app, client):
    with app.app_context():
        assert db.session.get(UserAccount, _FULL) is not None
        assert db.session.get(UserAccount, _SHORT) is None, 'такого логина нет'
    body = _post(client, {'login': _SHORT, 'password': _SHORT}).get_json()
    assert body['message'] == 'Success', body
    assert body['employee_id'] == _FULL
    # И сменить пароль просят — иначе человек так и останется с номером.
    assert body['must_change_password'] is True


def test_full_number_still_gets_in(app, client):
    body = _post(client, {'login': _FULL, 'password': _FULL}).get_json()
    assert body['message'] == 'Success'


def test_wrong_password_is_still_wrong(app, client):
    body = _post(client, {'login': _SHORT, 'password': '451'}).get_json()
    assert body['message'] == 'Failure'


def test_number_password_stops_working_after_the_change(app, client):
    """Пока пароль временный, номер в обеих формах — пароль. Потом нет."""
    with app.app_context():
        account = UserAccount(
            login='0000009999',
            employee_id='001' if db.session.get(
                app_module.Employee, '001') else '0000002114',
            password_hash=generate_password_hash('своясложнаяфраза'),
            must_change_password=False,
        )
        db.session.add(account)
        db.session.commit()
    try:
        assert _post(client, {'login': '9999',
                              'password': '9999'}).get_json()['message'] == 'Failure'
        assert _post(client, {'login': '9999',
                              'password': 'своясложнаяфраза'}
                     ).get_json()['message'] == 'Success'
    finally:
        with app.app_context():
            db.session.delete(db.session.get(UserAccount, '0000009999'))
            db.session.commit()
