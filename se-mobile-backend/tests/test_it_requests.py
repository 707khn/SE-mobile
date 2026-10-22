"""Заявки в ОИТиС: создать с фото, взять, закрыть, и кто что видит."""

import io

import pytest

import app as app_module
import it_requests
from it_requests import ItRequest, ItRequestPhoto, ItRequestEvent
from models import db

_AUTHOR = '0000002184'      # Шаяхметов, не ОИТиС
_STRANGER = '0000002183'    # Асқаров, тоже не ОИТиС
_IT = '0000001668'          # Николаев, заместитель начальника ОИТиС
_IT_CHIEF = '0000001465'    # Даурембекова, начальник ОИТиС

_JPEG = b'\xff\xd8\xff\xe0' + b'\x00' * 200
_PNG = b'\x89PNG\r\n\x1a\n' + b'\x00' * 200


@pytest.fixture(autouse=True)
def clean(app):
    yield
    with app.app_context():
        ItRequestEvent.query.delete()
        ItRequestPhoto.query.delete()
        ItRequest.query.delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    """Что ушло бы людям: (кому, заголовок, текст)."""
    sent = []

    def fake_later(_app, fn, ids, title, body, data=None):
        sent.append((sorted(ids), title, body))

    monkeypatch.setattr(app_module, '_notify_later', fake_later)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _create(client, headers, photos=(), **fields):
    form = {'category': 'printer', 'room': '305',
            'description': 'Не печатает, мигает оранжевым'}
    form.update(fields)
    form = {k: v for k, v in form.items() if v is not None}
    data = dict(form)
    if photos:
        data['photo'] = [(io.BytesIO(p), f'{i}.jpg') for i, p in enumerate(photos)]
    return client.post('/api/it-requests', data=data, headers=headers,
                       content_type='multipart/form-data')


def _act(client, headers, item_id, action, comment=None):
    body = {'action': action}
    if comment is not None:
        body['comment'] = comment
    return client.post(f'/api/it-requests/{item_id}', json=body, headers=headers)


def test_it_department_is_recognised(app):
    with app.app_context():
        from models import Employee
        assert it_requests.is_it_staff(db.session.get(Employee, _IT))
        assert it_requests.is_it_staff(db.session.get(Employee, _IT_CHIEF))
        assert not it_requests.is_it_staff(db.session.get(Employee, _AUTHOR))
        assert not it_requests.is_it_staff(None)


def test_extra_staff_from_environment(app, monkeypatch):
    monkeypatch.setenv('IT_STAFF', f' {_STRANGER} ,x')
    with app.app_context():
        from models import Employee
        assert it_requests.is_it_staff(db.session.get(Employee, _STRANGER))


def test_without_a_pass_nothing_works(client):
    assert client.get('/api/it-requests').status_code == 401
    assert _create(client, {}).status_code == 401


def test_create_with_photos_and_whole_department_is_told(app, client, pushes):
    author = _auth(app, _AUTHOR)
    r = _create(client, author, photos=(_JPEG, _PNG), phone='12-34')
    assert r.status_code == 201, r.get_json()
    item = r.get_json()['item']
    assert item['status'] == 'new'
    assert item['room'] == '305'
    assert item['phone'] == '12-34'
    assert item['author']['id'] == _AUTHOR

    # Весь отдел, но не сам автор.
    assert len(pushes) == 1
    ids, title, body = pushes[0]
    assert _IT in ids and _IT_CHIEF in ids and _AUTHOR not in ids
    assert title == f'Заявка №{item["id"]}: Принтер, каб. 305'
    assert 'Не печатает' in body

    detail = client.get(f'/api/it-requests/{item["id"]}', headers=author).get_json()['item']
    assert len(detail['photos']) == 2
    assert [e['action'] for e in detail['events']] == ['created']

    photo = client.get(f'/api/it-requests/{item["id"]}/photos/{detail["photos"][1]}',
                       headers=author)
    assert photo.status_code == 200
    assert photo.mimetype == 'image/png'
    assert photo.data == _PNG

    mine = client.get('/api/it-requests', headers=author).get_json()
    assert mine['it_staff'] is False
    assert [i['id'] for i in mine['items']] == [item['id']]
    assert mine['items'][0]['photo_count'] == 2


@pytest.mark.parametrize('fields, error', [
    ({'room': ''}, 'room_required'),
    ({'description': 'a'}, 'description_required'),
    ({'description': 'x' * 2001}, 'description_too_long'),
    ({'category': 'coffee'}, 'bad_category'),
])
def test_bad_fields_are_refused(app, client, pushes, fields, error):
    r = _create(client, _auth(app, _AUTHOR), **fields)
    assert r.status_code == 400
    assert r.get_json()['error'] == error
    assert not pushes


def test_photos_are_checked(app, client, pushes):
    author = _auth(app, _AUTHOR)
    r = _create(client, author, photos=(b'<?php echo 1; ?>',))
    assert r.get_json()['error'] == 'not_an_image'
    r = _create(client, author, photos=(_JPEG,) * 4)
    assert r.get_json()['error'] == 'too_many_photos'
    big = b'\xff\xd8\xff' + b'\x00' * (4 * 1024 * 1024)
    r = _create(client, author, photos=(big,))
    assert r.status_code == 413
    with app.app_context():
        assert ItRequest.query.count() == 0


def test_json_without_photos_works_too(app, client, pushes):
    r = client.post('/api/it-requests', headers=_auth(app, _AUTHOR),
                    json={'category': 'network', 'room': '12',
                          'description': 'Нет интернета'})
    assert r.status_code == 201
    assert r.get_json()['item']['category'] == 'network'


def test_too_many_open_requests(app, client, pushes):
    author = _auth(app, _AUTHOR)
    for _ in range(10):
        assert _create(client, author).status_code == 201
    r = _create(client, author)
    assert r.status_code == 429
    assert r.get_json()['error'] == 'too_many_open'


def test_others_do_not_see_it(app, client, pushes):
    item_id = _create(client, _auth(app, _AUTHOR)).get_json()['item']['id']
    stranger = _auth(app, _STRANGER)
    assert client.get(f'/api/it-requests/{item_id}', headers=stranger).status_code == 404
    assert client.get('/api/it-requests?scope=queue', headers=stranger).status_code == 403
    assert _act(client, stranger, item_id, 'comment', 'привет').status_code == 404
    assert client.get(f'/api/it-requests/{item_id}/photos/1',
                      headers=stranger).status_code == 404
    assert client.get('/api/it-requests', headers=stranger).get_json()['items'] == []


def test_whole_cycle(app, client, pushes):
    author = _auth(app, _AUTHOR)
    it = _auth(app, _IT)
    item_id = _create(client, author).get_json()['item']['id']
    pushes.clear()

    queue = client.get('/api/it-requests?scope=queue', headers=it).get_json()
    assert queue['it_staff'] is True
    assert queue['open'] == {'new': 1, 'in_progress': 0}
    assert [i['id'] for i in queue['items']] == [item_id]

    # Автор не может взять или закрыть сам.
    assert _act(client, author, item_id, 'take').status_code == 403
    assert _act(client, author, item_id, 'done').status_code == 403

    r = _act(client, it, item_id, 'take')
    assert r.status_code == 200
    item = r.get_json()['item']
    assert item['status'] == 'in_progress'
    assert item['assignee']['id'] == _IT
    assert pushes[-1][0] == [_AUTHOR]
    assert pushes[-1][1] == f'Заявка №{item_id} в работе'

    # Автор уточняет — пишется исполнителю, а не всему отделу.
    _act(client, author, item_id, 'comment', 'Принтер HP у окна')
    assert pushes[-1][0] == [_IT]

    r = _act(client, it, item_id, 'done', 'Заменили картридж')
    item = r.get_json()['item']
    assert item['status'] == 'done'
    assert item['resolution'] == 'Заменили картридж'
    assert item['closed_at']
    assert pushes[-1][1] == f'Заявка №{item_id} выполнена'
    assert _act(client, it, item_id, 'done').status_code == 409

    # Не помогло — обратно к тому же исполнителю.
    r = _act(client, author, item_id, 'reopen', 'Опять мигает')
    item = r.get_json()['item']
    assert item['status'] == 'in_progress'
    assert item['assignee']['id'] == _IT
    assert item['closed_at'] is None
    assert pushes[-1][0] == [_IT]
    assert [e['action'] for e in item['events']] == [
        'created', 'take', 'comment', 'done', 'reopen']


def test_reject_needs_a_reason(app, client, pushes):
    item_id = _create(client, _auth(app, _AUTHOR)).get_json()['item']['id']
    it = _auth(app, _IT_CHIEF)
    assert _act(client, it, item_id, 'reject').get_json()['error'] == 'comment_required'
    r = _act(client, it, item_id, 'reject', 'Это к завхозу')
    assert r.get_json()['item']['status'] == 'rejected'
    assert pushes[-1][2] == 'Это к завхозу'


def test_author_cancels_and_it_leaves_the_open_count(app, client, pushes):
    author = _auth(app, _AUTHOR)
    item_id = _create(client, author).get_json()['item']['id']
    assert _act(client, _auth(app, _IT), item_id, 'cancel').status_code == 403
    assert _act(client, author, item_id, 'cancel').get_json()['item']['status'] == 'cancelled'
    assert _act(client, author, item_id, 'reopen').status_code == 409
    queue = client.get('/api/it-requests?scope=queue', headers=_auth(app, _IT)).get_json()
    assert queue['open'] == {'new': 0, 'in_progress': 0}


def test_unknown_action(app, client, pushes):
    author = _auth(app, _AUTHOR)
    item_id = _create(client, author).get_json()['item']['id']
    assert _act(client, author, item_id, 'explode').status_code == 400


def test_in_app_feed_is_used_when_present(app, client, monkeypatch):
    """Лента оповещений (если она есть на сервере) получает то же, что пуш."""
    recorded = []
    monkeypatch.setattr(app_module, '_notify_later', lambda *a, **k: None)
    monkeypatch.setattr(app_module, '_record_notice',
                        lambda kind, title, body, employee_ids=None, ref=None, **k:
                        recorded.append((kind, title, sorted(employee_ids), ref)),
                        raising=False)
    item_id = _create(client, _auth(app, _AUTHOR)).get_json()['item']['id']
    assert recorded and recorded[0][0] == 'it'
    assert recorded[0][3] == item_id
    assert _IT in recorded[0][2]


def test_old_photos_are_forgotten(app, client, pushes):
    from datetime import datetime, timedelta
    author = _auth(app, _AUTHOR)
    old_id = _create(client, author, photos=(_JPEG,)).get_json()['item']['id']
    with app.app_context():
        old = db.session.get(ItRequest, old_id)
        old.status = 'done'
        old.closed_at = datetime.utcnow() - timedelta(days=200)
        db.session.commit()
    _create(client, author, photos=(_JPEG,))
    with app.app_context():
        assert ItRequestPhoto.query.filter_by(request_id=old_id).count() == 0
        assert ItRequestPhoto.query.count() == 1
        assert db.session.get(ItRequest, old_id) is not None
