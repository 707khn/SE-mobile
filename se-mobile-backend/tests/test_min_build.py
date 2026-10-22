"""Минимальная сборка: ниже неё приложение дальше экрана обновления не пускает.

Это подготовка к REQUIRE_AUTH=1: сначала всех переводят на сборку, которая
умеет пропуск, и только потом проверку включают. Главное здесь — не
выключить приложение людям, которым обновиться неоткуда.
"""

import os

import pytest

import app as app_module
from models import db, AppSetting, UserAccount

ADMIN_PASSWORD = os.environ['ADMIN_PASSWORD']


def _put(directory, name):
    with open(os.path.join(str(directory), name), 'wb') as f:
        f.write(b'x' * 16)


def _admin(app):
    with app.app_context():
        admin = app_module._authenticate('admin', ADMIN_PASSWORD)
        return {'Authorization': f'Bearer {app_module._issue_token(admin)}'}


@pytest.fixture
def clean_setting(app, monkeypatch):
    monkeypatch.delenv('MIN_APP_BUILD', raising=False)

    def _drop():
        with app.app_context():
            row = db.session.get(AppSetting, app_module._MIN_BUILD_KEY)
            if row is not None:
                db.session.delete(row)
                db.session.commit()
    _drop()
    yield
    _drop()


def test_no_minimum_by_default(app, client, clean_setting):
    body = client.get('/api/app/latest').get_json()
    assert body['min_build'] == 0


def test_admin_raises_the_minimum(app, client, tmp_path, monkeypatch, clean_setting):
    monkeypatch.setattr(app_module, '_APK_DIR', str(tmp_path))
    _put(tmp_path, 'se-mobile-1.17.0+52.apk')

    r = client.post('/api/admin/min-build', json={'build': 52},
                    headers=_admin(app))
    assert r.status_code == 200, r.get_json()
    assert r.get_json()['min_build']['min_build'] == 52

    # Без пропуска: старое приложение должно узнать об этом даже на экране
    # входа.
    assert client.get('/api/app/latest').get_json()['min_build'] == 52

    # И снять можно.
    r = client.post('/api/admin/min-build', json={'build': 0},
                    headers=_admin(app))
    assert r.status_code == 200
    assert client.get('/api/app/latest').get_json()['min_build'] == 0


def test_no_minimum_without_a_build_to_download(app, client, tmp_path,
                                                monkeypatch, clean_setting):
    """Минимальная сборка, которой нет на сервере, выключила бы приложение всем.

    Человек упёрся бы в «Нужно обновить», а скачать было бы нечего.
    """
    monkeypatch.setattr(app_module, '_APK_DIR', str(tmp_path))
    r = client.post('/api/admin/min-build', json={'build': 52},
                    headers=_admin(app))
    assert r.status_code == 400
    assert r.get_json()['error'] == 'no_such_build'

    _put(tmp_path, 'se-mobile-1.16.18+51.apk')
    r = client.post('/api/admin/min-build', json={'build': 52},
                    headers=_admin(app))
    assert r.status_code == 400
    assert r.get_json()['latest'] == 51
    assert client.get('/api/app/latest').get_json()['min_build'] == 0


@pytest.mark.parametrize('bad', [-1, 'пять', None, True, [52], 1.5])
def test_nonsense_is_refused(app, client, clean_setting, bad):
    r = client.post('/api/admin/min-build', json={'build': bad},
                    headers=_admin(app))
    assert r.status_code == 400
    assert r.get_json()['error'] == 'bad_build'


def test_only_admins_set_the_minimum(app, client, clean_setting):
    with app.app_context():
        token = app_module._issue_token('0000001465')   # не админ
    r = client.post('/api/admin/min-build', json={'build': 0},
                    headers={'Authorization': f'Bearer {token}'})
    assert r.status_code == 403


def test_environment_is_a_floor(app, client, tmp_path, monkeypatch, clean_setting):
    """MIN_APP_BUILD с телефона не опустить — её ставил тот, у кого ssh."""
    monkeypatch.setattr(app_module, '_APK_DIR', str(tmp_path))
    _put(tmp_path, 'se-mobile-1.17.0+52.apk')
    monkeypatch.setenv('MIN_APP_BUILD', '50')
    assert client.get('/api/app/latest').get_json()['min_build'] == 50

    client.post('/api/admin/min-build', json={'build': 52}, headers=_admin(app))
    assert client.get('/api/app/latest').get_json()['min_build'] == 52

    client.post('/api/admin/min-build', json={'build': 0}, headers=_admin(app))
    assert client.get('/api/app/latest').get_json()['min_build'] == 50

    monkeypatch.setenv('MIN_APP_BUILD', 'не число')
    assert client.get('/api/app/latest').get_json()['min_build'] == 0


def test_rollout_counts_who_will_hit_the_wall(app, client, tmp_path,
                                              monkeypatch, clean_setting):
    monkeypatch.setattr(app_module, '_APK_DIR', str(tmp_path))
    _put(tmp_path, 'se-mobile-1.17.0+52.apk')
    with app.app_context():
        account = UserAccount.query.filter_by(employee_id='0000001465').first()
        saved = account.app_version
        account.app_version = '1.16.0 (40)'
        db.session.commit()
    try:
        client.post('/api/admin/min-build', json={'build': 52},
                    headers=_admin(app))
        body = client.get('/api/admin/rollout', headers=_admin(app)).get_json()
        assert body['min_build']['min_build'] == 52
        assert body['min_build']['below'] >= 1
        # Проверку пропуска это не включает.
        assert body['require_auth'] is False
    finally:
        with app.app_context():
            account = UserAccount.query.filter_by(employee_id='0000001465').first()
            account.app_version = saved
            db.session.commit()


def test_build_is_read_from_the_version_header():
    assert app_module._build_of('1.16.18 (51)') == 51
    assert app_module._build_of('неизвестно') is None
    assert app_module._build_of('') is None
