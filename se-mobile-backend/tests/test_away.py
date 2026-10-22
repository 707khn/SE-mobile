"""«Меня нет на месте»: отметка, заместитель в справочнике, кто что может."""

from datetime import timedelta

import pytest

import app as app_module
from away import AwayNote
from models import db, DirectoryEntry, Notification

_ME = '0000002184'          # Шаяхметов, заместитель генерального директора
_DEPUTY = '0000002183'      # Асқаров, генеральный директор
_OTHER = '0000002206'       # главный инженер
_HR = '0000001573'          # на время проверки — специалист по кадрам


@pytest.fixture(autouse=True)
def directory(app):
    """Справочник из трёх строк: двое из сотрудников и пост без человека."""
    with app.app_context():
        from models import Employee
        me = db.session.get(Employee, _ME)
        deputy = db.session.get(Employee, _DEPUTY)
        saved = [(r.sort_order, r.department, r.name, r.position, r.extension,
                  r.email, r.mobile) for r in DirectoryEntry.query.all()]
        DirectoryEntry.query.delete()
        db.session.add_all([
            DirectoryEntry(sort_order=1, department='Руководство',
                           name=deputy.full_name, position='ГД',
                           extension='102', mobile='8-701-000-00-01'),
            DirectoryEntry(sort_order=2, department='Руководство',
                           name='  ' + me.full_name.upper() + ' ',
                           position='Зам', extension='151'),
            DirectoryEntry(sort_order=3, department='СБ', name='КПП',
                           extension='204'),
        ])
        db.session.commit()
        names = {'me': me.full_name, 'deputy': deputy.full_name}
    yield names
    with app.app_context():
        AwayNote.query.delete()
        Notification.query.filter_by(kind='away').delete()
        DirectoryEntry.query.delete()
        db.session.add_all([DirectoryEntry(
            sort_order=s, department=d, name=n, position=p, extension=x,
            email=e, mobile=m) for s, d, n, p, x, e, m in saved])
        db.session.commit()


@pytest.fixture
def hr(app):
    with app.app_context():
        from models import Employee
        person = db.session.get(Employee, _HR)
        before, person.job_title = person.job_title, 'Специалист по кадрам'
        db.session.commit()
    yield
    with app.app_context():
        db.session.get(Employee, _HR).job_title = before
        db.session.commit()


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _today(app):
    with app.app_context():
        return app_module._plant_today()


def _set(client, headers, app, path='/api/away', **fields):
    today = _today(app)
    body = {'reason': 'vacation', 'start': today.isoformat(),
            'end': (today + timedelta(days=13)).isoformat()}
    body.update(fields)
    return client.put(path, json=body, headers=headers)


def test_without_a_pass_nothing_works(client):
    assert client.get('/api/away').status_code == 401
    assert client.put('/api/away', json={}).status_code == 401


def test_set_and_seen_in_directory_with_deputy_number(app, client, directory):
    me = _auth(app, _ME)
    r = _set(client, me, app, deputy=directory['deputy'], note='По договорам — к юристам')
    assert r.status_code == 200, r.get_json()
    away = r.get_json()['away']
    assert away['active'] is True
    assert away['deputy_extension'] == '102'
    assert away['deputy_mobile'] == '8-701-000-00-01'

    entries = client.get('/api/directory', headers=_auth(app, _OTHER)).get_json()['entries']
    by_name = {e['name'].strip().lower(): e for e in entries}
    mine = by_name[directory['me'].lower()]
    # Имя в справочнике набрано заглавными и с пробелами — всё равно нашлось.
    assert mine['away']['reason'] == 'vacation'
    assert mine['away']['deputy'] == directory['deputy']
    assert mine['away']['note'] == 'По договорам — к юристам'
    assert by_name['кпп']['away'] is None
    assert by_name[directory['deputy'].lower()]['away'] is None


def test_deputy_is_told_once(app, client, directory):
    me = _auth(app, _ME)
    _set(client, me, app, deputy=directory['deputy'])
    # Сдвинул даты — второй раз заместителю не пишем.
    today = _today(app)
    _set(client, me, app, deputy=directory['deputy'],
         end=(today + timedelta(days=20)).isoformat())
    feed = client.get('/api/notifications', headers=_auth(app, _DEPUTY)).get_json()
    told = [n for n in feed['items'] if n['kind'] == 'away']
    assert len(told) == 1
    assert told[0]['title'].startswith('Вы замещаете: ')
    assert 'В отпуске с ' in told[0]['body']


def test_future_note_is_not_shown_yet(app, client, directory):
    today = _today(app)
    r = _set(client, _auth(app, _ME), app,
             start=(today + timedelta(days=5)).isoformat(),
             end=(today + timedelta(days=10)).isoformat())
    assert r.get_json()['away']['active'] is False
    entries = client.get('/api/directory', headers=_auth(app, _OTHER)).get_json()['entries']
    assert all(e['away'] is None for e in entries)


@pytest.mark.parametrize('shift, error', [
    ({'end': -1, 'start': -3}, 'in_the_past'),
    ({'start': 3, 'end': 1}, 'bad_dates'),
    ({'start': 70, 'end': 75}, 'too_far_ahead'),
    ({'start': 0, 'end': 200}, 'too_long'),
])
def test_bad_dates(app, client, shift, error):
    today = _today(app)
    fields = {k: (today + timedelta(days=v)).isoformat() for k, v in shift.items()}
    r = _set(client, _auth(app, _ME), app, **fields)
    assert r.status_code == 400
    assert r.get_json()['error'] == error


def test_bad_reason_and_self_deputy(app, client, directory):
    me = _auth(app, _ME)
    assert _set(client, me, app, reason='party').get_json()['error'] == 'bad_reason'
    assert _set(client, me, app, start='вчера').get_json()['error'] == 'bad_dates'
    assert _set(client, me, app, deputy=directory['me']).get_json()['error'] \
        == 'self_deputy'


def test_started_yesterday_counts_from_today(app, client):
    today = _today(app)
    away = _set(client, _auth(app, _ME), app,
                start=(today - timedelta(days=1)).isoformat()).get_json()['away']
    assert away['start'] == today.isoformat()


def test_back_early(app, client):
    me = _auth(app, _ME)
    _set(client, me, app)
    assert client.delete('/api/away', headers=me).get_json()['away'] is None
    assert client.get('/api/away', headers=me).get_json()['away'] is None


def test_only_hr_sets_it_for_others(app, client, hr):
    other = _auth(app, _OTHER)
    r = _set(client, other, app, path=f'/api/away/{_ME}')
    assert r.status_code == 403
    assert client.get('/api/away', headers=other).get_json()['can_manage'] is False

    hr_auth = _auth(app, _HR)
    assert client.get('/api/away', headers=hr_auth).get_json()['can_manage'] is True
    r = _set(client, hr_auth, app, path=f'/api/away/{_ME}', reason='sick')
    assert r.status_code == 200
    mine = client.get('/api/away', headers=_auth(app, _ME)).get_json()['away']
    assert mine['reason'] == 'sick'
    assert _set(client, hr_auth, app, path='/api/away/0000000000').status_code == 404
