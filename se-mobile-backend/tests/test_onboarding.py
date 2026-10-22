"""Первые дни новичка: кадры заводят план, службы отмечают свои пункты."""

from datetime import date

import pytest

import app as app_module
from models import db, Notification
from onboarding import Onboarding, OnboardingStep

_HR = '0000002162'          # начальник административного отдела
_NEWCOMER = '0000001816'    # инженер-технолог ТО
_MENTOR = '0000001674'      # другой инженер-технолог ТО
_HEAD = '0000001520'        # начальник ТО
_IT = '0000001965'          # инженер-программист ОИТиС
_SECURITY = '0000001542'    # специалист СБ
_SAFETY = '0000001972'      # инженер по БиОТ
_CLOTHING = '0000000114'    # машинист по стирке и ремонту спецодежды
_LABORER = '0000000441'     # подсобный рабочий ХО — спецодежду не выдаёт
_OTHER = '0000000082'       # мастер ОП


@pytest.fixture(autouse=True)
def clean(app, monkeypatch):
    monkeypatch.setattr(app_module, '_plant_today', lambda: date(2030, 1, 15))
    yield
    with app.app_context():
        OnboardingStep.query.delete()
        Onboarding.query.delete()
        Notification.query.filter_by(kind='onboarding').delete()
        db.session.commit()


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _create(app, client, **extra):
    body = {'employee_id': _NEWCOMER, 'start_date': '2030-01-20',
            'mentor_id': _MENTOR, **extra}
    return client.post('/api/onboarding', headers=_auth(app, _HR), json=body)


def _mark(app, client, item_id, who, step, done=True, note=''):
    return client.post(f'/api/onboarding/{item_id}', headers=_auth(app, who),
                       json={'action': 'step', 'step': step, 'done': done,
                             'note': note})


def _notices(app, employee_id):
    with app.app_context():
        return [n.title for n in Notification.query.filter_by(
            kind='onboarding', employee_id=employee_id)]


def test_only_hr_creates_and_everyone_involved_is_told(app, client):
    denied = client.post('/api/onboarding', headers=_auth(app, _OTHER),
                         json={'employee_id': _NEWCOMER, 'start_date': '2030-01-20'})
    assert denied.status_code == 403

    answer = _create(app, client)
    assert answer.status_code == 201, answer.get_json()
    item = answer.get_json()['item']
    assert [s['step'] for s in item['steps']] == [
        'account', 'pass', 'induction', 'clothing', 'workplace', 'mentor']
    assert item['mentor']['id'] == _MENTOR and item['done_count'] == 0
    assert all(s['can_mark'] for s in item['steps'])

    assert _create(app, client).get_json()['error'] == 'exists'
    assert _notices(app, _NEWCOMER) == ['Ваш план первых дней на заводе']
    assert _notices(app, _MENTOR)[0].startswith('Вы наставник')
    for who in (_IT, _SECURITY, _SAFETY, _CLOTHING, _HEAD):
        assert _notices(app, who), who
    assert _notices(app, _LABORER) == []
    assert _notices(app, _OTHER) == []


def test_validation(app, client):
    assert _create(app, client, start_date='2031-01-01').get_json()['error'] == 'bad_date'
    assert _create(app, client, mentor_id=_NEWCOMER).get_json()['error'] == 'mentor_self'
    assert _create(app, client, steps=['nope']).get_json()['error'] == 'bad_steps'
    assert _create(app, client, mentor_id='').get_json()['error'] == 'mentor_required'
    office = _create(app, client, mentor_id='', steps=['account', 'pass', 'induction'])
    assert office.status_code == 201
    assert office.get_json()['item']['total'] == 3


def test_each_service_marks_only_its_own_step(app, client):
    item_id = _create(app, client).get_json()['item']['id']
    assert _mark(app, client, item_id, _IT, 'pass').status_code == 403
    assert _mark(app, client, item_id, _LABORER, 'clothing').status_code == 404
    assert _mark(app, client, item_id, _NEWCOMER, 'account').status_code == 403

    ok = _mark(app, client, item_id, _IT, 'account', note='Логин в письме')
    assert ok.status_code == 200
    step = ok.get_json()['item']['steps'][0]
    assert step['done'] and step['done_by']['id'] == _IT
    assert step['note'] == 'Логин в письме'
    assert 'Готово: учётная запись' in _notices(app, _NEWCOMER)
    assert _mark(app, client, item_id, _IT, 'account').get_json()['error'] == 'already_done'

    # Пункт видит своя служба, чужой — нет.
    listing = client.get('/api/onboarding', headers=_auth(app, _IT)).get_json()
    assert listing['items'] == []
    listing = client.get('/api/onboarding', headers=_auth(app, _SECURITY)).get_json()
    assert [i['id'] for i in listing['items']] == [item_id]
    pass_step = listing['items'][0]['steps'][1]
    assert pass_step['can_mark'] and not listing['items'][0]['steps'][2]['can_mark']

    assert _mark(app, client, item_id, _HEAD, 'workplace').status_code == 200
    assert _mark(app, client, item_id, _HEAD, 'mentor').status_code == 403
    assert _mark(app, client, item_id, _MENTOR, 'mentor').status_code == 200

    # Снять отметку может тот, кто ставил, или кадры.
    assert _mark(app, client, item_id, _SECURITY, 'account', done=False).status_code == 403
    assert _mark(app, client, item_id, _IT, 'account', done=False).status_code == 200


def test_newcomer_sees_plan_and_completion(app, client):
    item_id = _create(app, client).get_json()['item']['id']
    mine = client.get('/api/onboarding', headers=_auth(app, _NEWCOMER)).get_json()
    assert mine['hr'] is False and mine['items'] == []
    assert mine['mine']['id'] == item_id and mine['mine']['is_mine'] is True
    assert not any(s['can_mark'] for s in mine['mine']['steps'])
    assert client.get(f'/api/onboarding/{item_id}',
                      headers=_auth(app, _OTHER)).status_code == 404

    for who, step in ((_IT, 'account'), (_SECURITY, 'pass'), (_SAFETY, 'induction'),
                      (_CLOTHING, 'clothing'), (_MENTOR, 'workplace')):
        assert _mark(app, client, item_id, who, step).status_code == 200
    last = _mark(app, client, item_id, _MENTOR, 'mentor').get_json()['item']
    assert last['status'] == 'done' and last['done_count'] == 6
    assert any(t.startswith('Адаптация пройдена') for t in _notices(app, _HR))
    hr_list = client.get('/api/onboarding', headers=_auth(app, _HR)).get_json()
    assert hr_list['hr'] is True and hr_list['items'][0]['status'] == 'done'


def test_hr_changes_mentor_and_cancels(app, client):
    item_id = _create(app, client).get_json()['item']['id']
    url = f'/api/onboarding/{item_id}'
    headers = _auth(app, _HR)
    assert client.post(url, headers=_auth(app, _MENTOR),
                       json={'action': 'mentor', 'mentor_id': _HEAD}).status_code == 403
    changed = client.post(url, headers=headers,
                          json={'action': 'mentor', 'mentor_id': _HEAD}).get_json()
    assert changed['item']['mentor']['id'] == _HEAD
    assert _notices(app, _HEAD)[-1].startswith('Вы наставник')
    # Прежний наставник больше не видит новичка.
    assert client.get(url, headers=_auth(app, _MENTOR)).status_code == 404

    cancelled = client.post(url, headers=headers, json={'action': 'cancel'}).get_json()
    assert cancelled['item']['status'] == 'cancelled'
    assert _mark(app, client, item_id, _HR, 'account').get_json()['error'] == 'closed'
    assert _create(app, client).status_code == 201


def test_people_search_for_hr_only(app, client):
    assert client.get('/api/onboarding/people?q=технолог',
                      headers=_auth(app, _OTHER)).status_code == 403
    found = client.get('/api/onboarding/people?q=технолог',
                       headers=_auth(app, _HR)).get_json()['people']
    assert _NEWCOMER in [p['id'] for p in found]
