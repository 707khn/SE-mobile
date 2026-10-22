"""Техника за сотрудником: учёт ОИТиС, «моё», выдача с оповещением."""

import pytest

import app as app_module
from it_assets import ItAsset
from models import db, Notification

_IT = '0000001965'          # инженер-программист ОИТиС
_MASTER = '0000000082'
_ACCOUNTANT = '0000000137'


@pytest.fixture(autouse=True)
def clean(app):
    yield
    with app.app_context():
        ItAsset.query.delete()
        Notification.query.filter_by(kind='itasset').delete()
        db.session.commit()


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _add(app, client, who=_IT, **extra):
    body = {'kind': 'laptop', 'model': 'HP ProBook 450', 'inventory_no': 'ИТ-0042',
            'serial': '5CD123', 'room': '214', 'employee_id': _MASTER, **extra}
    return client.post('/api/it-assets', headers=_auth(app, who), json=body)


def _mine(app, client, who):
    return client.get('/api/it-assets/mine', headers=_auth(app, who)).get_json()


def test_register_and_mine(app, client):
    assert _add(app, client, who=_MASTER).status_code == 403
    assert _add(app, client, kind='tv').get_json()['error'] == 'bad_kind'
    assert _add(app, client, model=' ').get_json()['error'] == 'model_required'
    assert _add(app, client, employee_id='0000009999').get_json()['error'] == \
        'no_employee'
    answer = _add(app, client)
    assert answer.status_code == 201, answer.get_json()
    assert answer.get_json()['item']['holder']['id'] == _MASTER
    assert _add(app, client).get_json()['error'] == 'inventory_taken'
    assert _add(app, client, kind='printer', model='Kyocera M2040',
                inventory_no='', employee_id='').status_code == 201

    mine = _mine(app, client, _MASTER)
    assert mine['staff'] is False
    assert [(i['kind'], i['inventory_no']) for i in mine['items']] == [
        ('laptop', 'ИТ-0042')]
    with app.app_context():
        notice = Notification.query.filter_by(kind='itasset',
                                              employee_id=_MASTER).one()
        assert (notice.title, notice.body) == (
            'За вами записан ноутбук', 'HP ProBook 450, инв. № ИТ-0042')
    assert _mine(app, client, _IT)['staff'] is True


def test_search_assign_release_writeoff(app, client):
    laptop = _add(app, client).get_json()['item']['id']
    printer = _add(app, client, kind='printer', model='Kyocera M2040',
                   inventory_no='ИТ-0100', employee_id='').get_json()['item']['id']
    headers = _auth(app, _IT)

    def search(**query):
        answer = client.get('/api/it-assets', headers=headers, query_string=query)
        return [i['id'] for i in answer.get_json()['items']]
    assert client.get('/api/it-assets', headers=_auth(app, _MASTER)).status_code == 403
    assert search(q='ноутбук') == [laptop]
    assert search(q='kyocera') == [printer]
    assert search(free='1') == [printer]

    def act(asset, **body):
        return client.post(f'/api/it-assets/{asset}', headers=headers, json=body)
    assert act(printer, action='assign', employee_id=_ACCOUNTANT,
               room='105').status_code == 200
    assert [i['id'] for i in _mine(app, client, _ACCOUNTANT)['items']] == [printer]
    assert act(printer, action='assign',
               employee_id=_ACCOUNTANT).get_json()['error'] == 'same_holder'
    assert act(printer, action='update',
               inventory_no='ИТ-0042').get_json()['error'] == 'inventory_taken'
    assert act(printer, action='update', note='картридж TK-1170').get_json()[
        'item']['note'] == 'картридж TK-1170'

    held = client.get(f'/api/it-assets/employees/{_MASTER}', headers=headers)
    assert [i['id'] for i in held.get_json()['items']] == [laptop]
    assert act(laptop, action='release').get_json()['item']['holder'] is None
    assert act(laptop, action='writeoff').status_code == 200
    assert search() == [printer]
    assert act(laptop, action='release').status_code == 404
