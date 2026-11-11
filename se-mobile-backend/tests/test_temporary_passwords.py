"""Пароль, равный табельному номеру, — временный. Везде и у всех.

Двадцать три учётные записи годами ходили с паролем, напечатанным открытым
текстом в app.py: он был равен табельному номеру, и сменить его никто не
просил. Заметить это было не на чем — список тех, кого просить, велся
руками, и в нём стояла ровно одна запись из двадцати трёх.

Здесь проверяется, что списка больше нет: временный пароль узнаётся по
самому паролю, и узнаётся у кого угодно.
"""

import os

from werkzeug.security import check_password_hash, generate_password_hash

import app as app_module
from models import db, Employee, UserAccount

ADMIN_PASSWORD = os.environ['ADMIN_PASSWORD']


def _back_to_number(login):
    """База общая на весь прогон, и другие проверки входят по табельному
    номеру — возвращаем учётке прежний пароль после сброса."""
    from werkzeug.security import generate_password_hash as _hash
    account = db.session.get(UserAccount, login)
    account.password_hash = _hash(login)
    db.session.commit()


def test_no_account_keeps_a_password_equal_to_its_login(app):
    """Главное утверждение: такой пары в базе нет ни у кого.

    Пароль, совпадающий с логином, придумать нельзя — _password_problem
    такой отклоняет. Значит, каждый такой пароль выдан при заведении, и
    приложение обязано попросить новый.
    """
    with app.app_context():
        settled = UserAccount.query.filter_by(must_change_password=False).all()
        for account in settled:
            for form in app_module._number_forms(account.login):
                assert not check_password_hash(account.password_hash, form), (
                    f'у {account.login} пароль равен табельному номеру, '
                    'а сменить его не просят')

        # Те самые двадцать три: их пароли печатались в app.py, и просить
        # сменить их никто не просил.
        for login in app_module._CREDENTIALS:
            account = db.session.get(UserAccount, login)
            assert account is not None and account.must_change_password, \
                f'{login}: пароль из кода, а сменить не просят'


def test_the_seeder_finds_them_without_a_list(app):
    """Учётка, пережившая старый порядок, ловится проходом по базе.

    Прежний сидер брал имена из списка в коде — список отстал от данных на
    двадцать две записи. Этот смотрит на сами пароли.
    """
    with app.app_context():
        db.session.add(Employee(employee_id='0000009002',
                                full_name='Старый Порядок Тестович',
                                job_title='Слесарь'))
        db.session.add(UserAccount(
            login='0000009002',
            employee_id='0000009002',
            password_hash=generate_password_hash('0000009002'),
            must_change_password=False))
        # Свой пароль трогать не за что — сидер должен пройти мимо.
        db.session.add(Employee(employee_id='0000009003',
                                full_name='Свой Пароль Тестович',
                                job_title='Слесарь'))
        db.session.add(UserAccount(
            login='0000009003',
            employee_id='0000009003',
            password_hash=generate_password_hash('придумал-сам-3'),
            must_change_password=False))
        db.session.commit()

        app_module._force_password_change()

        assert db.session.get(UserAccount, '0000009002').must_change_password
        assert not db.session.get(UserAccount, '0000009003').must_change_password

        for emp_id in ('0000009002', '0000009003'):
            db.session.delete(db.session.get(UserAccount, emp_id))
            db.session.delete(db.session.get(Employee, emp_id))
        db.session.commit()


def test_signing_in_with_the_number_asks_for_a_new_password(app, client,
                                                            remove_employee):
    """Тот же вопрос со стороны человека, который входит.

    Флаг ставится в момент входа, бесплатно: хеш всё равно только что
    проверен. Поэтому учётка, заведённая в обход сидеров, тоже попадётся.
    """
    with app.app_context():
        db.session.add(Employee(employee_id=remove_employee('0000009001'),
                                full_name='Временный Пароль Тестович',
                                job_title='Слесарь'))
        db.session.add(UserAccount(
            login='0000009001',
            employee_id='0000009001',
            password_hash=generate_password_hash('0000009001'),
            must_change_password=False))
        db.session.commit()

    # Короткая форма номера — как человек его и набирает.
    answer = client.post('/login', json={'login': '9001',
                                         'password': '0000009001'}).get_json()
    assert answer['message'] == 'Success'
    assert answer['must_change_password'] is True, \
        'вошли временным паролем, а нового не просят'

    with app.app_context():
        account = db.session.get(UserAccount, '0000009001')
        assert account.must_change_password

        # Свой пароль таким не считается: просить сменить его не за что.
        account.password_hash = generate_password_hash('своя-мысль-7')
        account.must_change_password = False
        db.session.commit()

    again = client.post('/login', json={'login': '9001',
                                        'password': 'своя-мысль-7'}).get_json()
    assert again['message'] == 'Success'
    assert again['must_change_password'] is False

    # Убирает remove_employee: вход выдал пропуск, и просто удалить сотрудника
    # PostgreSQL не даст — на него ссылается auth_tokens.


def test_disabled_account_cannot_sign_in(app, client):
    """Выключенная учётка не входит — прежде входила.

    _find_account ищет только среди is_active, и выключенный вход до таблицы
    не доходил: он попадал в словарь паролей в коде, где про is_active никто
    не знал. То есть уволенный из тех двадцати трёх входил ровно как раньше.
    """
    login = '1874'
    with app.app_context():
        account = db.session.get(UserAccount, login)
        assert account is not None
        account.password_hash = generate_password_hash('проверка-1874')
        account.is_active = False
        account.failed_attempts = 0
        account.locked_until = None
        db.session.commit()

    denied = client.post('/login', json={'login': login,
                                         'password': 'проверка-1874'})
    assert denied.get_json()['message'] == 'Failure'

    # И тем паролем, что раньше лежал в коде, — тоже.
    assert client.post('/login', json={'login': login,
                                       'password': login}
                       ).get_json()['message'] == 'Failure'

    with app.app_context():
        account = db.session.get(UserAccount, login)
        account.is_active = True
        account.password_hash = generate_password_hash(login)
        account.must_change_password = True
        account.failed_attempts = 0
        account.locked_until = None
        db.session.commit()


def test_admin_password_is_not_the_word_admin(app):
    """Логин admin с паролем admin на сервере, смотрящем в интернет.

    Такую пару подбирают не люди, а сканеры, и первым же запросом. Здесь
    пароль задан через ADMIN_PASSWORD; когда переменной нет, сервер придумает
    случайный и напечатает его в журнал — но «admin» не останется в обоих
    случаях.
    """
    with app.app_context():
        assert app_module._authenticate('admin', 'admin') is None
        assert app_module._authenticate('admin', ADMIN_PASSWORD) == 'ADMIN'


def test_credentials_in_code_hold_no_passwords(app):
    """В словаре остались только табельные номера.

    Проверка глазами не работает: пароли пролежали в app.py годы, и их
    видели все, кто открывал файл.
    """
    for login, value in app_module._CREDENTIALS.items():
        assert isinstance(value, str), \
            f'{login}: в словаре снова пара, а не табельный номер'


def test_resetting_the_admin_does_not_hand_back_the_word_admin(app, client):
    """Сброс пароля ставит временным логин — для «admin» это снова «admin».

    Учётку администратора сброс вернул бы ровно в то состояние, из-за
    которого всё и затевалось. Ей пароль придумывается случайно и
    показывается тому, кто сбросил: иначе войти будет нечем.
    """
    with app.app_context():
        admin_token = app_module._issue_token(
            app_module._authenticate('admin', ADMIN_PASSWORD))

    answer = client.post('/api/admin/accounts/admin/reset',
                         headers={'Authorization': f'Bearer {admin_token}'})
    body = answer.get_json()
    assert body['message'] == 'Success'
    temporary = body['temporary_password']
    assert temporary != 'admin' and len(temporary) >= 12

    with app.app_context():
        assert app_module._authenticate('admin', 'admin') is None
        assert app_module._authenticate('admin', temporary) == 'ADMIN'

        # Табельный номер временным больше не бывает: он на пропуске.
        account = db.session.get(UserAccount, '1874')
        assert account is not None
        # Сброс гасит все пропуска администратора, в том числе тот, которым
        # сбрасывали. Дальше — с новым, выданным по временному паролю.
        admin_token = app_module._issue_token('ADMIN')

    numeric = client.post('/api/admin/accounts/1874/reset',
                          headers={'Authorization': f'Bearer {admin_token}'})
    code = numeric.get_json()['temporary_password']
    assert code != '1874' and len(code) == 5 and code.isdigit()
    with app.app_context():
        assert app_module._authenticate('1874', '1874') is None
        assert app_module._authenticate('1874', code) is not None
        _back_to_number('1874')

    # Возвращаем администратора на известный пароль: учётка общая на весь
    # прогон. Флаг оставляем поднятым — иначе второй прогон по той же базе
    # (а на своём PostgreSQL их гоняют подряд) увидит администратора с
    # «улёгшимся» паролем и справедливо возмутится. Входу флаг не мешает.
    with app.app_context():
        admin_account = db.session.get(UserAccount, 'admin')
        admin_account.password_hash = generate_password_hash(ADMIN_PASSWORD)
        admin_account.must_change_password = True
        db.session.commit()
