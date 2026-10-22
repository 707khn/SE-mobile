"""Вопрос технологу или конструктору: кому уходит, решение, история."""

import pytest

import app as app_module
import tech_questions
from tech_questions import TechQuestion, TechQuestionEvent
from models import db, Employee, Notification

_MASTER = '0000000082'      # мастер ОП
_MASTER2 = '0000000150'     # другой мастер ОП
_TO_HEAD = '0000001520'     # начальник ТО
_TO_DEPUTY = '0000001856'   # заместитель начальника ТО
_TECHNOLOGIST = '0000001674'
_DESIGNER = '0000001902'
_OUTSIDER = '0000000016'    # начальник ПЭО


@pytest.fixture(autouse=True)
def clean(app):
    yield
    with app.app_context():
        TechQuestionEvent.query.delete()
        TechQuestion.query.delete()
        Notification.query.filter_by(kind='techq').delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        assert kind == 'techq'
        sent.append((sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _ask(client, headers, **fields):
    body = {'kind': 'drawing', 'product': 'Корпус  7.312',
            'document': 'ЧТ 7.312.001', 'operation': '015',
            'text': 'Размер 45 на чертеже, по калибру 44,8 — какой верный?'}
    body.update(fields)
    return client.post('/api/tech-questions', json=body, headers=headers)


def _act(client, headers, item_id, action, **body):
    return client.post(f'/api/tech-questions/{item_id}',
                       json={'action': action, **body}, headers=headers)


def _staff_ids(app, test):
    with app.app_context():
        return sorted(e.employee_id for e in Employee.query.all()
                      if tech_questions.is_tech_staff(e) and test(e))


def test_roles(app):
    with app.app_context():
        get = lambda i: db.session.get(Employee, i)
        assert tech_questions.is_tech_staff(get(_DESIGNER))
        assert tech_questions.is_tech_head(get(_TO_HEAD))
        assert not tech_questions.is_tech_staff(get(_MASTER))
        assert tech_questions.reads_history(get(_MASTER))
        assert not tech_questions.reads_history(get(_OUTSIDER))


@pytest.mark.parametrize('fields, error', [
    ({'kind': 'x'}, 'bad_kind'),
    ({'product': ' '}, 'product_required'),
    ({'text': ''}, 'text_required'),
])
def test_bad_requests(app, client, pushes, fields, error):
    r = _ask(client, _auth(app, _MASTER), **fields)
    assert r.status_code == 400
    assert r.get_json()['error'] == error


def test_routing_by_kind(app, client, pushes):
    master = _auth(app, _MASTER)
    designers = _staff_ids(app, lambda e: 'конструктор' in e.job_title.lower()
                           or e.employee_id in (_TO_HEAD, _TO_DEPUTY))
    _ask(client, master)
    assert pushes[-1][0] == designers
    assert pushes[-1][1].startswith('Вопрос по чертежу №')
    assert _TECHNOLOGIST not in pushes[-1][0]

    _ask(client, master, kind='process')
    assert _TECHNOLOGIST in pushes[-1][0] and _DESIGNER not in pushes[-1][0]

    _ask(client, master, kind='process', urgent=True)
    assert pushes[-1][0] == _staff_ids(app, lambda e: True)
    assert pushes[-1][1].startswith('Стоит работа: ')


def test_answer_clarify_close_and_history(app, client, pushes):
    master, designer = _auth(app, _MASTER), _auth(app, _DESIGNER)
    item = _ask(client, master).get_json()['item']
    assert item['product'] == 'Корпус 7.312'

    assert _act(client, master, item['id'], 'answer', text='x').status_code == 403
    assert client.get('/api/tech-questions?scope=queue',
                      headers=master).status_code == 403

    queue = client.get('/api/tech-questions?scope=queue', headers=designer).get_json()
    assert queue['waiting'] == 1 and queue['items'][0]['id'] == item['id']

    pushes.clear()
    got = _act(client, designer, item['id'], 'take').get_json()['item']
    assert got['status'] == 'in_work'
    assert _act(client, designer, item['id'], 'answer').status_code == 400
    got = _act(client, designer, item['id'], 'answer',
               text='Верный 44,8; извещение на изменение чертежа выпущу').get_json()['item']
    assert got['status'] == 'answered'
    assert pushes[-1][0] == [_MASTER]

    assert _act(client, master, item['id'], 'clarify').status_code == 400
    got = _act(client, master, item['id'], 'clarify',
               text='А допуск какой?').get_json()['item']
    assert got['status'] == 'in_work'
    assert pushes[-1][0] == [_DESIGNER]
    _act(client, designer, item['id'], 'answer', text='44,8 ±0,05')
    got = _act(client, master, item['id'], 'close').get_json()['item']
    assert got['status'] == 'closed' and got['decision'] == '44,8 ±0,05'
    assert [e['action'] for e in got['events']] == [
        'created', 'take', 'answer', 'clarify', 'answer', 'close']
    assert _act(client, designer, item['id'], 'comment', text='?').status_code == 409

    # История по изделию: другой мастер находит решение, посторонний — нет.
    other = _auth(app, _MASTER2)
    found = client.get('/api/tech-questions?product=корпус 7.312',
                       headers=other).get_json()['items']
    assert [f['decision'] for f in found] == ['44,8 ±0,05']
    assert client.get(f'/api/tech-questions/{item["id"]}',
                      headers=other).status_code == 200
    outsider = _auth(app, _OUTSIDER)
    assert client.get('/api/tech-questions?product=корпус',
                      headers=outsider).status_code == 403
    assert client.get(f'/api/tech-questions/{item["id"]}',
                      headers=outsider).status_code == 404
    # Чужой мастер смотрит, но не действует.
    assert _act(client, other, item['id'], 'comment', text='?').status_code == 404

    names = client.get('/api/tech-questions/products?q=корп',
                       headers=other).get_json()['products']
    assert names == ['Корпус 7.312']
    assert client.get('/api/tech-questions?product=%',
                      headers=other).get_json()['items'] == []
