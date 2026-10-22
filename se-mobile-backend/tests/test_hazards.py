"""«Сообщить об опасности»: БиОТ закрывает, аноним остаётся анонимом."""

import pytest

import app as app_module
import hazards
from hazards import Hazard, HazardEvent
from models import db, Employee, Notification

_AUTHOR = '0000002107'    # менеджер по учёту ТМЦ
_SAFETY = '0000001972'    # инженер по БиОТ
_SAFETY_HEAD = '0000001878'  # главный технический руководитель по БиОТ
_WIRES = '0000002161'     # слаботочник из той же службы — не БиОТ
_OTHER = '0000000016'     # начальник ПЭО


@pytest.fixture(autouse=True)
def clean(app):
    yield
    with app.app_context():
        HazardEvent.query.delete()
        Hazard.query.delete()
        Notification.query.filter_by(kind='hazard').delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        assert kind == 'hazard'
        sent.append((sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _report(client, headers, **fields):
    body = {'category': 'spill', 'place': 'Цех 2, у пресса К-2130',
            'text': 'Масло на полу, скользко'}
    body.update(fields)
    return client.post('/api/hazards', json=body, headers=headers)


def _act(client, headers, item_id, action, **body):
    return client.post(f'/api/hazards/{item_id}', json={'action': action, **body},
                       headers=headers)


def test_who_is_safety(app):
    with app.app_context():
        get = lambda i: db.session.get(Employee, i)
        assert hazards.is_safety(get(_SAFETY))
        assert hazards.is_safety(get(_SAFETY_HEAD))
        assert not hazards.is_safety(get(_WIRES))
        assert not hazards.is_safety(get(_OTHER))


@pytest.mark.parametrize('fields, error', [
    ({'category': 'boom'}, 'bad_category'),
    ({'place': ' '}, 'place_required'),
    ({'text': ''}, 'text_required'),
])
def test_bad_requests(app, client, pushes, fields, error):
    r = _report(client, _auth(app, _AUTHOR), **fields)
    assert r.status_code == 400
    assert r.get_json()['error'] == error


def test_report_take_resolve(app, client, pushes):
    author = _auth(app, _AUTHOR)
    r = _report(client, author, urgent=True)
    assert r.status_code == 201
    item = r.get_json()['item']
    assert 'track' not in r.get_json()
    assert item['author']['id'] == _AUTHOR
    ids, title, body = pushes[-1]
    assert ids == sorted([_SAFETY, _SAFETY_HEAD])
    assert title == f'Опасно сейчас №{item["id"]}: разлив, скользко'

    # Чужой не видит, в очередь не пускают.
    other = _auth(app, _OTHER)
    assert client.get(f'/api/hazards/{item["id"]}', headers=other).status_code == 404
    assert client.get('/api/hazards?scope=queue', headers=other).status_code == 403
    assert _act(client, author, item['id'], 'resolve', comment='x').status_code == 403

    safety = _auth(app, _SAFETY)
    queue = client.get('/api/hazards?scope=queue', headers=safety).get_json()
    assert queue['new'] == 1 and queue['items'][0]['urgent'] is True

    pushes.clear()
    got = _act(client, safety, item['id'], 'take').get_json()['item']
    assert got['status'] == 'in_work' and got['assignee']['id'] == _SAFETY
    assert pushes[-1][0] == [_AUTHOR]
    assert _act(client, safety, item['id'], 'resolve').status_code == 400
    got = _act(client, safety, item['id'], 'resolve',
               comment='Убрали, поставили поддон').get_json()['item']
    assert got['status'] == 'resolved' and got['outcome'] == 'Убрали, поставили поддон'
    assert pushes[-1] == ([_AUTHOR], f'Опасность устранена: №{item["id"]} '
                          '(Цех 2, у пресса К-2130)', 'Убрали, поставили поддон')
    assert _act(client, safety, item['id'], 'reject', comment='x').status_code == 409
    assert [e['action'] for e in got['events']] == ['created', 'take', 'resolve']


def test_anonymous_has_no_author_anywhere(app, client, pushes):
    author = _auth(app, _AUTHOR)
    r = _report(client, author, anonymous=True, category='electrical')
    assert r.status_code == 201
    token = r.get_json()['track']
    item_id = r.get_json()['item']['id']
    with app.app_context():
        row = db.session.get(Hazard, item_id)
        assert row.author_id is None and row.track_hash != token
        assert HazardEvent.query.filter_by(hazard_id=item_id).one().actor_id is None

    # В моих его нет — сервер не знает, что оно моё.
    assert client.get('/api/hazards', headers=author).get_json()['items'] == []
    assert client.get(f'/api/hazards/{item_id}', headers=author).status_code == 404

    safety = _auth(app, _SAFETY)
    seen = client.get(f'/api/hazards/{item_id}', headers=safety).get_json()['item']
    assert seen['anonymous'] is True and seen['author'] is None
    assert seen['events'][0]['actor'] is None

    pushes.clear()
    _act(client, safety, item_id, 'reject', comment='Щиток закрыт, проверили')
    assert pushes == []  # анониму оповещать некого

    tracked = client.post('/api/hazards/track', json={'tokens': [token, 'чужой']},
                          headers=author).get_json()['items']
    assert [t['id'] for t in tracked] == [item_id]
    assert tracked[0]['status'] == 'rejected'
    assert tracked[0]['outcome'] == 'Щиток закрыт, проверили'
    assert client.post('/api/hazards/track', json={'tokens': 'x'},
                       headers=author).status_code == 400


def test_author_comment_goes_to_assignee(app, client, pushes):
    author, safety = _auth(app, _AUTHOR), _auth(app, _SAFETY)
    item_id = _report(client, author).get_json()['item']['id']
    pushes.clear()
    _act(client, author, item_id, 'comment', comment='Ещё и лампа не горит')
    assert pushes[-1][0] == sorted([_SAFETY, _SAFETY_HEAD])
    _act(client, safety, item_id, 'take')
    pushes.clear()
    _act(client, author, item_id, 'comment', comment='Сегодня ещё хуже')
    assert pushes[-1][0] == [_SAFETY]
