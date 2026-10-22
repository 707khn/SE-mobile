"""«Исправить мои данные»: кому видно, кому оповещение, что меняется."""

import pytest

import app as app_module
from data_corrections import DataCorrection, DataCorrectionEvent, is_hr
from models import db, Employee, Notification

_MASTER = '0000000082'       # мастер ОП
# Специалиста по кадрам 0000001874 меняет другая проверка — берём начальника АО.
_HR = '0000002162'           # начальник АО
_SECRETARY = '0000002002'    # делопроизводитель АО — не кадры
_OUTSIDER = '0000000016'     # начальник ПЭО


@pytest.fixture(autouse=True)
def clean(app):
    yield
    with app.app_context():
        DataCorrectionEvent.query.delete()
        DataCorrection.query.delete()
        Notification.query.filter_by(kind='datafix').delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        assert kind == 'datafix'
        sent.append((sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _ask(client, headers, **fields):
    body = {'kind': 'name', 'requested': 'Кучерявый Дмитрий Семёнович',
            'comment': 'Отчество записано неверно'}
    body.update(fields)
    return client.post('/api/data-corrections', json=body, headers=headers)


def _act(client, headers, item_id, action, **body):
    return client.post(f'/api/data-corrections/{item_id}',
                       json={'action': action, **body}, headers=headers)


def _hr_ids(app):
    with app.app_context():
        return sorted(e.employee_id for e in Employee.query.all() if is_hr(e))


def test_who_is_hr(app):
    with app.app_context():
        assert is_hr(db.session.get(Employee, _HR))
        assert is_hr(Employee(employee_id='X', full_name='X',
                              job_title='Специалист по кадрам',
                              department='Административный отдел (АО)'))
        assert not is_hr(db.session.get(Employee, _SECRETARY))
        assert not is_hr(db.session.get(Employee, _MASTER))


def test_request_keeps_current_value_and_tells_hr_without_details(
        app, client, pushes):
    headers = _auth(app, _MASTER)
    mine = client.get('/api/data-corrections', headers=headers).get_json()
    assert mine['staff'] is False and mine['profile']['job'] == 'Мастер'

    answer = _ask(client, headers, kind='job', requested='Старший мастер')
    assert answer.status_code == 201, answer.get_json()
    item = answer.get_json()['item']
    assert item['current'] == 'Мастер' and item['status'] == 'new'
    [(ids, title, body)] = pushes
    assert ids == _hr_ids(app) and _HR in ids and _MASTER not in ids
    assert title == 'Исправить данные: должность'
    assert 'Старший' not in body


def test_validation(app, client):
    headers = _auth(app, _MASTER)
    assert _ask(client, headers, kind='iin').status_code == 400
    assert _ask(client, headers, requested='').status_code == 400
    with app.app_context():
        name = db.session.get(Employee, _MASTER).full_name
    answer = _ask(client, headers, requested=' ' + name.upper())
    assert answer.get_json()['error'] == 'same_as_current'
    for n in range(5):
        assert _ask(client, headers, kind='other',
                    requested=f'Дети: {n + 1}').status_code == 201
    assert _ask(client, headers, kind='other', requested='ещё').status_code == 429


def test_only_author_and_hr_see_it(app, client):
    item_id = _ask(client, _auth(app, _MASTER)).get_json()['item']['id']
    for outsider in (_OUTSIDER, _SECRETARY):
        headers = _auth(app, outsider)
        assert client.get(f'/api/data-corrections/{item_id}',
                          headers=headers).status_code == 404
        assert client.get('/api/data-corrections?scope=queue',
                          headers=headers).status_code == 403
    queue = client.get('/api/data-corrections?scope=queue',
                       headers=_auth(app, _HR)).get_json()
    assert [i['id'] for i in queue['items']] == [item_id]
    assert queue['waiting'] == 1 and queue['items'][0]['can_handle'] is True


def test_hr_takes_and_fixes_but_app_data_stays(app, client, pushes):
    with app.app_context():
        before = db.session.get(Employee, _MASTER).full_name
    item_id = _ask(client, _auth(app, _MASTER)).get_json()['item']['id']
    hr = _auth(app, _HR)
    assert _act(client, _auth(app, _MASTER), item_id, 'done').status_code == 403
    assert _act(client, hr, item_id, 'take').get_json()['item']['status'] == 'in_work'
    assert _act(client, _auth(app, _MASTER), item_id, 'cancel').status_code == 409
    done = _act(client, hr, item_id, 'done', text='Исправлено в 1С')
    item = done.get_json()['item']
    assert item['status'] == 'done' and item['resolution'] == 'Исправлено в 1С'
    assert [e['action'] for e in item['events']] == ['created', 'take', 'done']
    assert pushes[-1] == ([_MASTER], 'Данные исправлены: №%d (ФИО)' % item_id,
                          'Исправлено в 1С')
    with app.app_context():
        assert db.session.get(Employee, _MASTER).full_name == before
    assert _act(client, hr, item_id, 'comment', text='ещё').status_code == 409


def test_reject_needs_reason_and_cancel_by_author(app, client, pushes):
    master = _auth(app, _MASTER)
    first = _ask(client, master).get_json()['item']['id']
    hr = _auth(app, _HR)
    assert _act(client, hr, first, 'reject').status_code == 400
    rejected = _act(client, hr, first, 'reject', text='Нужна копия свидетельства')
    assert rejected.get_json()['item']['status'] == 'rejected'
    assert pushes[-1][0] == [_MASTER]

    second = _ask(client, master, kind='contacts',
                  requested='Мобильный +7 777 000 00 00').get_json()['item']['id']
    assert _act(client, master, second, 'comment', text='Срочно').status_code == 200
    assert pushes[-1][0] == _hr_ids(app)
    assert _act(client, master, second, 'cancel').get_json()['item']['status'] == \
        'cancelled'
