"""Схема живой базы: колонки, добавленные в модели позже, должны доезжать.

db.create_all() новые колонки к существующей таблице не добавляет, а в
проверках этого не видно: здесь база каждый раз создаётся заново и всегда со
всеми колонками. Поэтому старую базу изображаем нарочно — роняем колонку и
смотрим, вернёт ли её _migrate_schema.

Так уже ломался вход: в модель добавили user_accounts.failed_attempts, в
рукописный список правок — забыли, и на боевой базе вход отвечал 503.
"""

import sqlalchemy as sa

import app as app_module
from models import db


def _columns(name):
    return {c['name'] for c in sa.inspect(db.engine).get_columns(name)}


def _fresh_connections():
    """Как после перезапуска сервера: пул — заново.

    SQLite помнит схему в каждом соединении. Соединение из пула, не
    заметившее DROP COLUMN, отвечало «такая колонка уже есть» на её
    возвращение. На сервере миграция идёт при запуске, на свежих соединениях.
    """
    db.engine.dispose()


def test_every_model_column_reaches_the_database(app):
    """Не про одну колонку, а про все: список больше не ведётся руками."""
    with app.app_context():
        for name, table in db.metadata.tables.items():
            missing = {c.name for c in table.columns} - _columns(name)
            assert not missing, f'{name}: не хватает {missing}'


def test_dropped_column_comes_back(app):
    with app.app_context():
        with db.engine.begin() as conn:
            conn.execute(sa.text(
                'ALTER TABLE user_accounts DROP COLUMN failed_attempts'))
        _fresh_connections()
        assert 'failed_attempts' not in _columns('user_accounts')

        app_module._migrate_schema()

        assert 'failed_attempts' in _columns('user_accounts')
        # И не просто вернулась, а с нужным запретом пустоты и значением по
        # умолчанию: иначе INSERT без неё снова свалится.
        column = next(c for c in sa.inspect(db.engine).get_columns('user_accounts')
                      if c['name'] == 'failed_attempts')
        assert not column['nullable']


def test_login_survives_an_old_table(app, client):
    """Проверка целиком: на базе без новой колонки вход отвечал 503."""
    with app.app_context():
        with db.engine.begin() as conn:
            conn.execute(sa.text(
                'ALTER TABLE user_accounts DROP COLUMN failed_attempts'))
        _fresh_connections()
        app_module._migrate_schema()

    response = client.post('/login', json={'login': '2114', 'password': '2114'})
    assert response.status_code == 200
    assert response.get_json()['message'] == 'Success'
