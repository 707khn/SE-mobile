import os
import sys

# Ensure the backend package is importable when running pytest from any directory
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

# По умолчанию SQLite в памяти — проверки идут быстро и нигде ничего не
# оставляют. Но SQLite прощает то, чего PostgreSQL не прощает: длину строковых
# колонок он не проверяет вовсе, а внешние ключи ведёт иначе. На этом здесь уже
# дважды ловились на боевом сервере — на длине колонки и на auth_tokens при
# склейке сотрудников. Поэтому DATABASE_URL можно задать снаружи, и сборка
# гоняет весь набор ещё раз по настоящему PostgreSQL.
# Пустая строка — это «не задано», а не «база по адресу ''». Сборка передаёт
# сюда пустой DATABASE_URL для прогона на SQLite, и setdefault такую не
# заменил бы: переменная-то есть.
if not os.environ.get('DATABASE_URL', '').strip():
    os.environ['DATABASE_URL'] = 'sqlite:///:memory:'
# Выгрузка расчётных листков теперь отказывает при незаданном секрете, а не
# пропускает всех. На боевом сервере его ставит setup.sh; здесь — тоже, иначе
# тесты проверяли бы поведение, которого в работе не бывает.
os.environ.setdefault('ADMIN_TOKEN', 'test-admin-token')
# Пароль «admin» у учётной записи «admin» сервер меняет сам при запуске — на
# заданный здесь или на случайный. Тестам нужен известный, иначе войти
# администратором не получится ни разу.
os.environ.setdefault('ADMIN_PASSWORD', 'test-admin-password')

import pytest
from app import create_app  # noqa: E402


@pytest.fixture(scope='session')
def app():
    application = create_app()
    application.config['TESTING'] = True
    return application


@pytest.fixture(scope='session')
def client(app):
    return app.test_client()


@pytest.fixture
def remove_employee(app):
    """Убрать за собой сотрудника, заведённого проверкой.

    Просто `db.session.delete(employee)` не годится: на сотрудника ссылаются
    пропуска, учётные записи, проходы, листки. SQLite на это закрывает глаза
    и проверка проходит, а PostgreSQL отвечает «violates foreign key
    constraint auth_tokens_employee_id_fkey» — тем же самым отказом, который
    однажды встретил на боевой базе склейку сотрудников.

    Чтобы уборка не разошлась с жизнью, ссылающиеся таблицы берём оттуда же,
    откуда их берёт рабочий код: из описания моделей.
    """
    import app as app_module
    from models import db as _db

    created = []

    def _mark(employee_id):
        created.append(employee_id)
        return employee_id

    yield _mark

    with app.app_context():
        from models import Employee
        for employee_id in created:
            for table, column in app_module._employee_referrers():
                _db.session.execute(
                    table.delete().where(column == employee_id))
            row = _db.session.get(Employee, employee_id)
            if row is not None:
                _db.session.delete(row)
        _db.session.commit()
