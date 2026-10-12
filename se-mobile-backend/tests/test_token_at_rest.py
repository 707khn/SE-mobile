"""Пропуск лежит в базе хешем, а не как есть.

Пропуск — это доступ к листкам без пароля. Утёкшая база или резервная
копия не должна открывать листки каждого, кто сейчас вошёл.
"""

from datetime import datetime, timedelta

import pytest

import app as app_module
from models import db, AuthToken, Employee

_ID = 'TKN00001'


@pytest.fixture
def person(app, remove_employee):
    with app.app_context():
        remove_employee(_ID)
        db.session.add(Employee(employee_id=_ID, full_name='Пропусков Тест',
                                job_title='Слесарь'))
        db.session.commit()
    yield


def _me(client, raw):
    return client.get('/api/me', headers={'Authorization': f'Bearer {raw}'})


def test_database_holds_no_raw_token(app, client, person):
    with app.app_context():
        raw = app_module._issue_token(_ID)
        assert db.session.get(AuthToken, raw) is None
        assert db.session.get(AuthToken, app_module._token_key(raw)) is not None
    assert _me(client, raw).status_code == 200
    # А предъявить сам хеш вместо пропуска нельзя.
    assert _me(client, app_module._token_key(raw)).status_code == 401


def test_logout_still_revokes(app, client, person):
    with app.app_context():
        raw = app_module._issue_token(_ID)
    client.post('/logout', headers={'Authorization': f'Bearer {raw}'})
    assert _me(client, raw).status_code == 401


def test_old_raw_tokens_are_rewritten_and_keep_working(app, client, person):
    """Пропуска, выданные до обновления, переписываются, а не гасятся:
    иначе обновление сервера выкинуло бы из приложения всех."""
    raw = 'старый-пропуск-как-есть-43-знака-xxxxxxxxx'[:43]
    now = datetime.utcnow()
    with app.app_context():
        db.session.add(AuthToken(token=raw, employee_id=_ID, created_at=now,
                                 last_used_at=now,
                                 expires_at=now + timedelta(days=30)))
        db.session.commit()
        app_module._hash_stored_tokens()
        assert db.session.get(AuthToken, raw) is None
        assert db.session.get(AuthToken, app_module._token_key(raw)) is not None
        # Второй проход — то же, что второй процесс gunicorn: ничего не ломает.
        app_module._hash_stored_tokens()
    assert _me(client, raw).status_code == 200
