"""Заявки в отдел кадров: справки и заявление на отпуск.

Сотрудник подаёт и видит только свои; кадры видят все и двигают состояние;
о смене состояния сотруднику уходит уведомление.
"""

from datetime import date

import pytest

import app as app_module
from models import db, Employee, HrRequest

_WORKER = 'HRQ0001'
_OTHER = 'HRQ0002'
_HR = 'HRQ0003'
_DAY = date(2031, 5, 12)


@pytest.fixture
def people(app, remove_employee, monkeypatch):
    monkeypatch.setattr(app_module, '_plant_today', lambda: _DAY)
    with app.app_context():
        for employee_id, job in ((_WORKER, 'Слесарь'), (_OTHER, 'Токарь'),
                                 (_HR, 'Специалист по кадрам')):
            remove_employee(employee_id)
            db.session.add(Employee(employee_id=employee_id,
                                    full_name=f'Заявкин {employee_id}',
                                    job_title=job, department='Цех'))
        db.session.commit()
        tokens = {who: app_module._issue_token(who)
                  for who in (_WORKER, _OTHER, _HR)}
    return {who: {'Authorization': f'Bearer {t}'} for who, t in tokens.items()}


@pytest.fixture
def pushes(monkeypatch):
    """Что ушло бы в Firebase — сразу, без очереди."""
    sent = []

    def _fake_push(ids, title, body, data=None):
        sent.append((sorted(set(ids)), title, body, data))
        return len(ids)

    monkeypatch.setattr(app_module, '_push_to', _fake_push)
    monkeypatch.setattr(app_module, '_notify_later',
                        lambda app, fn, *a, **kw: fn(*a, **kw))
    return sent


def _create(client, headers, **body):
    return client.post('/api/hr/requests', json=body, headers=headers)


def test_worker_files_a_certificate_and_sees_it(client, people, pushes):
    r = _create(client, people[_WORKER], kind='employment',
                details='в банк', copies=2)
    assert r.status_code == 200
    item = r.get_json()['item']
    assert item['status'] == 'new'
    assert item['copies'] == 2
    assert item['kind_title'] == 'Справка с места работы'

    mine = client.get('/api/hr/requests', headers=people[_WORKER]).get_json()
    assert [i['id'] for i in mine['items']] == [item['id']]
    # Коллега чужой заявки не видит.
    other = client.get('/api/hr/requests', headers=people[_OTHER]).get_json()
    assert other['items'] == []
    # Кадрам сказали, что пришла заявка.
    assert any(_HR in ids and 'Заявкин' in body for ids, _, body, _ in pushes)


def test_without_a_pass_nothing_is_filed(client, people):
    assert client.post('/api/hr/requests', json={'kind': 'income'}).status_code == 401
    assert client.get('/api/hr/requests').status_code == 401


def test_bad_kind_and_bad_vacation_dates(client, people):
    assert _create(client, people[_WORKER], kind='raise').status_code == 400
    assert _create(client, people[_WORKER], kind='vacation').status_code == 400
    assert _create(client, people[_WORKER], kind='vacation',
                   start_date='2031-06-10', end_date='2031-06-01').status_code == 400
    assert _create(client, people[_WORKER], kind='vacation',
                   start_date='2045-06-01', end_date='2045-06-10').status_code == 400
    r = _create(client, people[_WORKER], kind='vacation',
                start_date='2031-06-01', end_date='2031-06-14',
                leave_type='Экологический отпуск')
    assert r.status_code == 200
    item = r.get_json()['item']
    assert (item['start_date'], item['end_date']) == ('2031-06-01', '2031-06-14')
    assert item['leave_type'] == 'Экологический отпуск'


def test_ordinary_worker_has_no_queue(client, people):
    assert client.get('/api/hr/queue', headers=people[_WORKER]).status_code == 403
    item = _create(client, people[_WORKER], kind='income').get_json()['item']
    r = client.post(f'/api/hr/requests/{item["id"]}', json={'status': 'ready'},
                    headers=people[_OTHER])
    assert r.status_code == 403


def test_hr_moves_it_and_the_worker_is_told(client, people, pushes):
    item = _create(client, people[_WORKER], kind='income',
                   details='за 6 месяцев').get_json()['item']

    queue = client.get('/api/hr/queue', headers=people[_HR]).get_json()
    found = [i for i in queue['items'] if i['id'] == item['id']]
    assert found and found[0]['employee']['full_name'] == f'Заявкин {_WORKER}'
    assert queue['counts']['new'] >= 1

    r = client.post(f'/api/hr/requests/{item["id"]}', json={'status': 'accepted'},
                    headers=people[_HR])
    assert r.status_code == 200
    r = client.post(f'/api/hr/requests/{item["id"]}',
                    json={'status': 'ready', 'note': 'Заберите в каб. 12'},
                    headers=people[_HR])
    assert r.get_json()['item']['hr_note'] == 'Заберите в каб. 12'

    to_worker = [p for p in pushes if p[0] == [_WORKER]]
    n = item['id']
    assert [p[2] for p in to_worker] == [
        f'Справка о доходах №{n} принята',
        f'Справка о доходах №{n} готова. Заберите в каб. 12',
    ]
    assert to_worker[-1][3] == {'type': 'hr', 'id': item['id']}

    mine = client.get('/api/hr/requests', headers=people[_WORKER]).get_json()
    assert mine['items'][0]['status'] == 'ready'

    # Выдана — и дальше не двигается: назад не открывают.
    assert client.post(f'/api/hr/requests/{item["id"]}', json={'status': 'done'},
                       headers=people[_HR]).status_code == 200
    assert client.post(f'/api/hr/requests/{item["id"]}', json={'status': 'accepted'},
                       headers=people[_HR]).status_code == 409


def test_rejection_needs_a_reason(client, people, pushes):
    item = _create(client, people[_WORKER], kind='employment').get_json()['item']
    assert client.post(f'/api/hr/requests/{item["id"]}', json={'status': 'rejected'},
                       headers=people[_HR]).status_code == 400
    r = client.post(f'/api/hr/requests/{item["id"]}',
                    json={'status': 'rejected', 'note': 'Нужен паспорт'},
                    headers=people[_HR])
    assert r.status_code == 200
    assert pushes[-1][2] == \
        f'Справка с места работы №{item["id"]} отклонена. Нужен паспорт'


def test_worker_cancels_only_own_and_only_new(client, people):
    item = _create(client, people[_WORKER], kind='employment').get_json()['item']
    # Чужую — как будто её нет.
    assert client.post(f'/api/hr/requests/{item["id"]}/cancel',
                       headers=people[_OTHER]).status_code == 404
    assert client.post(f'/api/hr/requests/{item["id"]}/cancel',
                       headers=people[_WORKER]).status_code == 200

    taken = _create(client, people[_WORKER], kind='employment').get_json()['item']
    client.post(f'/api/hr/requests/{taken["id"]}', json={'status': 'accepted'},
                headers=people[_HR])
    assert client.post(f'/api/hr/requests/{taken["id"]}/cancel',
                       headers=people[_WORKER]).status_code == 409


def test_open_requests_are_limited(client, people, app):
    for _ in range(app_module._HR_OPEN_LIMIT):
        assert _create(client, people[_OTHER], kind='income').status_code == 200
    assert _create(client, people[_OTHER], kind='income').status_code == 429
    with app.app_context():
        assert HrRequest.query.filter_by(employee_id=_OTHER).count() == \
            app_module._HR_OPEN_LIMIT


def test_queue_filters(client, people):
    item = _create(client, people[_WORKER], kind='income').get_json()['item']
    client.post(f'/api/hr/requests/{item["id"]}', json={'status': 'accepted'},
                headers=people[_HR])
    accepted = client.get('/api/hr/queue?status=accepted',
                          headers=people[_HR]).get_json()['items']
    assert all(i['status'] == 'accepted' for i in accepted)
    assert item['id'] in [i['id'] for i in accepted]
    new = client.get('/api/hr/queue?status=new', headers=people[_HR]).get_json()['items']
    assert item['id'] not in [i['id'] for i in new]


def test_steps_land_in_the_in_app_feed(client, people, pushes):
    """Без Firebase оповещение всё равно есть — в ленте приложения."""
    item = _create(client, people[_WORKER], kind='employment').get_json()['item']
    hr_feed = client.get('/api/notifications', headers=people[_HR]).get_json()
    assert any(f'№{item["id"]}' in (n.get('body') or '')
               for n in hr_feed['items'])

    client.post(f'/api/hr/requests/{item["id"]}',
                json={'status': 'ready', 'note': 'Каб. 12'}, headers=people[_HR])
    feed = client.get('/api/notifications', headers=people[_WORKER]).get_json()
    mine = [n for n in feed['items'] if n.get('kind') == 'hr']
    assert mine and mine[0]['body'] == \
        f'Справка с места работы №{item["id"]} готова. Каб. 12'
    # Коллега чужого не видит.
    other = client.get('/api/notifications', headers=people[_OTHER]).get_json()
    assert not [n for n in other['items'] if n.get('kind') in ('hr', 'hr_queue')]
