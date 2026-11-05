"""Начальник — по списку администратора, а не по слову «главный».

Трое «Главных менеджеров» ДМТО по правилу должности считались начальниками и
видели проходы всего департамента, включая руководителя. Теперь «главный
менеджер» по должности не начальник, а кого считать начальником, решает
администратор — строкой в manager_overrides, в обе стороны.
"""

import pytest

import app as app_module
from models import db, Employee, ManagerOverride

_DMTO_MANAGER = '0000001582'


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': f'Bearer {app_module._issue_token(employee_id)}'}


def _sname(client, headers, employee_id):
    return client.post('/get_sname', headers=headers,
                       json={'key_suffix': employee_id})


@pytest.mark.parametrize('title,expected', [
    ('Главный менеджер', False),
    ('Главный специалист', False),
    ('Главный инженер', True),
    ('Начальник цеха', True),
    ('Слесарь', False),
])
def test_title_rule(title, expected):
    assert app_module._is_admin_role(title) is expected


def test_override_both_ways(app, client):
    with app.app_context():
        emp = db.session.get(Employee, _DMTO_MANAGER)
        if emp is None:
            pytest.skip('нет главного менеджера ДМТО в данных')
        assert 'менеджер' in emp.job_title.lower()

    me = _auth(app, _DMTO_MANAGER)
    admin = _auth(app, 'ADMIN')
    assert _sname(client, me, _DMTO_MANAGER).status_code == 403
    assert client.get('/api/me', headers=me).get_json()['manager'] is False

    url = f'/api/admin/employees/{_DMTO_MANAGER}/manager'
    # Не администратору — нельзя.
    assert client.post(url, headers=me, json={'manager': True}).status_code == 403

    answer = client.post(url, headers=admin, json={'manager': True})
    assert answer.status_code == 200
    assert answer.get_json()['manager'] is True
    assert answer.get_json()['manager_override'] is True
    assert _sname(client, me, _DMTO_MANAGER).status_code == 200
    assert client.get('/api/me', headers=me).get_json()['manager'] is True

    answer = client.post(url, headers=admin, json={'manager': None})
    assert answer.get_json()['manager_override'] is None
    assert _sname(client, me, _DMTO_MANAGER).status_code == 403
    with app.app_context():
        assert db.session.get(ManagerOverride, _DMTO_MANAGER) is None


def test_override_can_take_it_away(app, client):
    with app.app_context():
        boss = next((e for e in Employee.query.all()
                     if (e.job_title or '').lower().startswith('начальник')
                     and e.department), None)
        if boss is None:
            pytest.skip('нет начальника в данных')
        boss_id = boss.employee_id
    me = _auth(app, boss_id)
    admin = _auth(app, 'ADMIN')
    assert _sname(client, me, boss_id).status_code == 200
    url = f'/api/admin/employees/{boss_id}/manager'
    client.post(url, headers=admin, json={'manager': False})
    assert _sname(client, me, boss_id).status_code == 403
    assert client.post(url, headers=admin, json={'manager': 'yes'}).status_code == 400
    client.post(url, headers=admin, json={'manager': None})
    assert _sname(client, me, boss_id).status_code == 200
