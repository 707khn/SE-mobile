"""Заявки на ремонт: куда уходят, кто что видит, простой оборудования."""

import io
from datetime import datetime, timedelta

import pytest

import app as app_module
import repair_requests
from repair_requests import RepairRequest, RepairRequestPhoto, RepairRequestEvent
from models import db, Notification

_AUTHOR = '0000002184'      # Шаяхметов, руководство
_STRANGER = '0000002183'    # Асқаров, руководство
_ENGINEER = '0000002206'    # главный инженер
_ENERGY = '0000000631'      # главный энергетик
_FACILITY = '0000001573'    # заведующий ХО
_CARPENTER = '0000001978'   # мастер строительного участка

_JPEG = b'\xff\xd8\xff\xe0' + b'\x00' * 200


@pytest.fixture(autouse=True)
def clean(app):
    yield
    with app.app_context():
        RepairRequestEvent.query.delete()
        RepairRequestPhoto.query.delete()
        RepairRequest.query.delete()
        Notification.query.filter_by(kind='repair').delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        assert kind == 'repair'
        sent.append((sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _create(client, headers, photos=(), **fields):
    form = {'category': 'equipment', 'place': 'Цех 1, участок 3',
            'equipment': 'Токарный 16К20 инв. 0412',
            'description': 'Не включается шпиндель'}
    form.update(fields)
    data = {k: v for k, v in form.items() if v is not None}
    if photos:
        data['photo'] = [(io.BytesIO(p), f'{i}.jpg') for i, p in enumerate(photos)]
    return client.post('/api/repair-requests', data=data, headers=headers,
                       content_type='multipart/form-data')


def _act(client, headers, item_id, action, comment=None):
    body = {'action': action}
    if comment is not None:
        body['comment'] = comment
    return client.post(f'/api/repair-requests/{item_id}', json=body,
                       headers=headers)


def _queue(client, headers):
    return client.get('/api/repair-requests?scope=queue', headers=headers)


def test_services_are_recognised_by_department(app):
    with app.app_context():
        from models import Employee
        get = lambda i: db.session.get(Employee, i)
        assert repair_requests.staff_groups(get(_ENGINEER)) == {'engineer'}
        assert repair_requests.staff_groups(get(_ENERGY)) == {'engineer'}
        assert repair_requests.staff_groups(get(_FACILITY)) == {'facility'}
        assert repair_requests.staff_groups(get(_CARPENTER)) == {'facility'}
        assert repair_requests.staff_groups(get(_AUTHOR)) == set()
        assert repair_requests.staff_groups(None) == set()


def test_extra_staff_from_environment(app, monkeypatch):
    monkeypatch.setenv('REPAIR_ENGINEER_STAFF', f' {_STRANGER} ')
    with app.app_context():
        from models import Employee
        assert repair_requests.staff_groups(
            db.session.get(Employee, _STRANGER)) == {'engineer'}


def test_without_a_pass_nothing_works(client):
    assert client.get('/api/repair-requests').status_code == 401
    assert _create(client, {}).status_code == 401


def test_equipment_goes_to_the_chief_engineer(app, client, pushes):
    author = _auth(app, _AUTHOR)
    r = _create(client, author, photos=(_JPEG,), stopped='1')
    assert r.status_code == 201, r.get_json()
    item = r.get_json()['item']
    assert item['service'] == 'engineer'
    assert item['stopped'] is True
    assert item['equipment'] == 'Токарный 16К20 инв. 0412'

    ids, title, body = pushes[0]
    assert _ENGINEER in ids and _ENERGY in ids
    assert _FACILITY not in ids and _AUTHOR not in ids
    assert title == (f'Ремонт №{item["id"]}: Оборудование «Токарный 16К20 инв. 0412», '
                     'Цех 1, участок 3 — стоит')

    # Служба главного инженера видит, хозотдел — нет.
    assert [i['id'] for i in _queue(client, _auth(app, _ENGINEER))
            .get_json()['items']] == [item['id']]
    assert _queue(client, _auth(app, _FACILITY)).get_json()['items'] == []
    assert client.get(f'/api/repair-requests/{item["id"]}',
                      headers=_auth(app, _FACILITY)).status_code == 404


def test_plumbing_goes_to_facility_and_cannot_stop(app, client, pushes):
    r = _create(client, _auth(app, _AUTHOR), category='plumbing',
                place='Каб. 214', equipment=None,
                description='Течёт кран', stopped='1')
    item = r.get_json()['item']
    assert item['service'] == 'facility'
    # «Стоит» у крана не бывает: отметка снимается.
    assert item['stopped'] is False
    ids = pushes[0][0]
    assert _FACILITY in ids and _CARPENTER in ids and _ENGINEER not in ids


@pytest.mark.parametrize('fields, error', [
    ({'place': ''}, 'place_required'),
    ({'description': 'a'}, 'description_required'),
    ({'description': 'x' * 2001}, 'description_too_long'),
    ({'category': 'coffee'}, 'bad_category'),
])
def test_bad_fields_are_refused(app, client, pushes, fields, error):
    r = _create(client, _auth(app, _AUTHOR), **fields)
    assert r.status_code == 400
    assert r.get_json()['error'] == error
    assert not pushes


def test_photos_can_be_switched_off(app, client, pushes, monkeypatch):
    monkeypatch.setenv('REPAIR_PHOTOS', '0')
    author = _auth(app, _AUTHOR)
    assert client.get('/api/repair-requests', headers=author) \
        .get_json()['photos_allowed'] is False
    r = _create(client, author, photos=(_JPEG,))
    assert r.get_json()['error'] == 'photos_disabled'
    assert _create(client, author).status_code == 201


def test_photo_is_checked(app, client, pushes):
    r = _create(client, _auth(app, _AUTHOR), photos=(b'<?php ?>',))
    assert r.get_json()['error'] == 'not_an_image'


def test_stopped_equipment_is_first_in_queue(app, client, pushes):
    author = _auth(app, _AUTHOR)
    first = _create(client, author, stopped='1').get_json()['item']['id']
    _create(client, author, category='electric', equipment=None,
            description='Мигает свет в цеху')
    queue = _queue(client, _auth(app, _ENGINEER)).get_json()
    assert queue['items'][0]['id'] == first
    assert queue['open'] == {'new': 2, 'in_progress': 0, 'stopped': 1}


def test_whole_cycle_and_downtime(app, client, pushes):
    author = _auth(app, _AUTHOR)
    engineer = _auth(app, _ENERGY)
    item_id = _create(client, author, stopped='true').get_json()['item']['id']
    with app.app_context():
        item = db.session.get(RepairRequest, item_id)
        item.created_at = datetime.utcnow() - timedelta(hours=5)
        db.session.commit()

    assert _act(client, author, item_id, 'take').status_code == 403
    r = _act(client, engineer, item_id, 'take')
    assert r.get_json()['item']['status'] == 'in_progress'
    assert r.get_json()['item']['can_act'] is True
    assert pushes[-1] == ([_AUTHOR], f'Ремонт №{item_id} в работе',
                          pushes[-1][2])

    r = _act(client, engineer, item_id, 'done', 'Заменили контактор')
    item = r.get_json()['item']
    assert item['status'] == 'done'
    assert 4.9 <= item['downtime_hours'] <= 5.1

    r = _act(client, author, item_id, 'reopen', 'Опять не включается')
    assert r.get_json()['item']['status'] == 'in_progress'
    assert pushes[-1][0] == [_ENERGY]
    events = [e['action'] for e in r.get_json()['item']['events']]
    assert events == ['created', 'take', 'done', 'reopen']


def test_forward_to_the_other_service(app, client, pushes):
    author = _auth(app, _AUTHOR)
    item_id = _create(client, author, category='electric', equipment=None,
                      description='Не работает вытяжка').get_json()['item']['id']
    engineer = _auth(app, _ENGINEER)
    assert _act(client, engineer, item_id, 'forward').get_json()['error'] \
        == 'comment_required'
    r = _act(client, engineer, item_id, 'forward', 'Это вентиляция, к завхозу')
    assert r.get_json()['item']['service'] == 'facility'
    assert r.get_json()['item']['status'] == 'new'
    told = {tuple(p[0]): p[1] for p in pushes[-2:]}
    assert any(_FACILITY in ids for ids in told)
    assert told[(_AUTHOR,)] == f'Ремонт №{item_id} передана другой службе'

    # Теперь это очередь хозотдела, а не главного инженера.
    assert [i['id'] for i in _queue(client, _auth(app, _FACILITY))
            .get_json()['items']] == [item_id]
    assert _queue(client, engineer).get_json()['items'] == []


def test_others_do_not_see_it(app, client, pushes):
    item_id = _create(client, _auth(app, _AUTHOR)).get_json()['item']['id']
    stranger = _auth(app, _STRANGER)
    assert client.get(f'/api/repair-requests/{item_id}',
                      headers=stranger).status_code == 404
    assert _queue(client, stranger).status_code == 403
    assert _act(client, stranger, item_id, 'comment', 'привет').status_code == 404
    assert client.get('/api/repair-requests', headers=stranger) \
        .get_json()['items'] == []


def test_top_equipment_by_downtime(app, client, pushes):
    author = _auth(app, _AUTHOR)
    engineer = _auth(app, _ENGINEER)
    for hours in (3, 2):
        item_id = _create(client, author, stopped='1',
                          equipment='Пресс КД2128').get_json()['item']['id']
        with app.app_context():
            item = db.session.get(RepairRequest, item_id)
            item.created_at = datetime.utcnow() - timedelta(hours=hours)
            db.session.commit()
        _act(client, engineer, item_id, 'done')
    # Один раз и без простоя — в счёт не идёт.
    _create(client, author, equipment='Фрезерный 6Р12')

    top = _queue(client, engineer).get_json()['top_equipment']
    assert len(top) == 1
    assert top[0]['equipment'] == 'Пресс КД2128'
    assert top[0]['count'] == 2
    assert 4.9 <= top[0]['downtime_hours'] <= 5.1


def test_author_sees_it_in_the_app_feed(app, client):
    author = _auth(app, _AUTHOR)
    item_id = _create(client, author).get_json()['item']['id']
    _act(client, _auth(app, _ENGINEER), item_id, 'take')
    feed = client.get('/api/notifications', headers=author).get_json()
    mine = [n for n in feed['items'] if n['kind'] == 'repair']
    assert mine[0]['title'] == f'Ремонт №{item_id} в работе'
    assert mine[0]['ref'] == str(item_id)
