"""Горячая линия комплаенса: видит только офицер, аноним остаётся анонимом."""

import pytest

import app as app_module
import compliance
from compliance import ComplianceMessage, ComplianceReport
from models import db, Notification

_OFFICER = '0000001994'   # комплаенс-офицер
_AUDIT = '0000001584'     # руководитель внутреннего аудита — без COMPLIANCE_OFFICERS не видит
_AUTHOR = '0000000082'    # мастер ОП
_OTHER = '0000000150'
_TEXT = 'Поставщик предлагает откат за подпись акта'


@pytest.fixture(autouse=True)
def clean(app):
    yield
    with app.app_context():
        ComplianceMessage.query.delete()
        ComplianceReport.query.delete()
        Notification.query.filter_by(kind='compliance').delete()
        db.session.commit()


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _notices(app, employee_id):
    with app.app_context():
        return [(n.title, n.body) for n in Notification.query.filter_by(
            kind='compliance', employee_id=employee_id)]


def _send(app, client, anonymous=False, who=_AUTHOR, **extra):
    return client.post('/api/compliance', headers=_auth(app, who), json={
        'kind': 'corruption', 'text': _TEXT, 'anonymous': anonymous, **extra})


def test_named_report_reaches_only_the_officer(app, client):
    assert _send(app, client, text='коротко').get_json()['error'] == 'text_required'
    answer = _send(app, client)
    assert answer.status_code == 201
    item = answer.get_json()['item']
    assert 'track' not in answer.get_json() and item['anonymous'] is False
    assert _notices(app, _OFFICER) == [('Новое сообщение на горячую линию', '')]
    assert _notices(app, _AUDIT) == []

    queue = client.get('/api/compliance', headers=_auth(app, _OFFICER)).get_json()
    assert queue['officer'] is True
    assert queue['queue'][0]['author']['id'] == _AUTHOR
    assert queue['queue'][0]['text'] == _TEXT
    for who in (_AUDIT, _OTHER):
        other = client.get('/api/compliance', headers=_auth(app, who)).get_json()
        assert other['officer'] is False and 'queue' not in other and other['mine'] == []
        assert client.post(f'/api/compliance/{item["id"]}', headers=_auth(app, who), json={
            'action': 'message', 'text': 'x'}).status_code == 404

    mine = client.get('/api/compliance', headers=_auth(app, _AUTHOR)).get_json()['mine']
    assert [m['id'] for m in mine] == [item['id']] and 'author' not in mine[0]


def test_audit_can_be_added(app, client, monkeypatch):
    monkeypatch.setenv('COMPLIANCE_OFFICERS', _AUDIT)
    _send(app, client)
    assert client.get('/api/compliance', headers=_auth(app, _AUDIT)).get_json()['officer']


def test_anonymous_keeps_no_author_and_no_minute(app, client):
    answer = _send(app, client, anonymous=True).get_json()
    track, item_id = answer['track'], answer['item']['id']
    with app.app_context():
        row = db.session.get(ComplianceReport, item_id)
        assert row.author_id is None and row.track_hash != track
        assert (row.created_at.hour, row.created_at.minute) == (0, 0)
    # Офицеру — не сразу, а со сверкой, одним оповещением.
    assert _notices(app, _OFFICER) == []
    assert client.get('/api/compliance', headers=_auth(app, _AUTHOR)).get_json()['mine'] == []

    officer = _auth(app, _OFFICER)
    queued = client.get('/api/compliance', headers=officer).get_json()['queue'][0]
    assert queued['anonymous'] is True and 'author' not in queued
    client.post(f'/api/compliance/{item_id}', headers=officer,
                json={'action': 'take'})
    client.post(f'/api/compliance/{item_id}', headers=officer,
                json={'action': 'message', 'text': 'Какой поставщик и когда?'})

    # Автор без ключа не видит и не пишет, с ключом — видит ответ и дописывает.
    url = f'/api/compliance/{item_id}'
    assert client.post(url, headers=_auth(app, _AUTHOR), json={
        'action': 'message', 'text': 'ТОО «Ромашка»'}).status_code == 404
    tracked = client.post('/api/compliance/track', headers=_auth(app, _AUTHOR),
                          json={'tracks': [track, 'чужой']}).get_json()['items']
    assert [(t['id'], t['status'], t['track_index']) for t in tracked] == [
        (item_id, 'review', 0)]
    assert tracked[0]['messages'][0] == {
        'from_officer': True, 'text': 'Какой поставщик и когда?',
        'at': tracked[0]['messages'][0]['at']}
    reply = client.post(url, headers=_auth(app, _AUTHOR), json={
        'action': 'message', 'text': 'ТОО «Ромашка», в сентябре', 'track': track})
    assert reply.status_code == 200
    assert reply.get_json()['item']['messages'][1]['from_officer'] is False
    assert client.post(url, headers=_auth(app, _AUTHOR), json={
        'action': 'close', 'text': 'x', 'track': track}).status_code == 403

    with app.app_context():
        assert compliance.notify_pending(app_module) == 2
        assert compliance.notify_pending(app_module) == 0
    assert _notices(app, _OFFICER) == [
        ('Горячая линия: новых сообщений: 1, дополнений: 1', '')]


def test_close_with_resolution(app, client):
    item_id = _send(app, client).get_json()['item']['id']
    url = f'/api/compliance/{item_id}'
    officer = _auth(app, _OFFICER)
    assert client.post(url, headers=officer,
                       json={'action': 'close'}).get_json()['error'] == 'text_required'
    closed = client.post(url, headers=officer, json={
        'action': 'close', 'text': 'Проверено, передано руководству'}).get_json()
    assert closed['item']['status'] == 'closed'
    assert closed['item']['resolution'] == 'Проверено, передано руководству'
    assert ('Проверка по вашему сообщению закончена', '') in _notices(app, _AUTHOR)
    assert client.post(url, headers=_auth(app, _AUTHOR), json={
        'action': 'message', 'text': 'Спасибо'}).get_json()['error'] == 'closed'
