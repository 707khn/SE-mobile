"""Вопрос по расчётному листку: только автор и расчётная группа."""

import pytest

import app as app_module
import payslip_questions
from payslip_questions import PayslipQuestion, PayslipQuestionMessage
from models import db, Employee, Notification

_AUTHOR = '0000002107'      # менеджер по учёту ТМЦ
_PAYROLL = '0000001469'     # бухгалтер расчётной группы
_CHIEF = '0000001298'       # главный бухгалтер
_ACCOUNTANT = '0000000726'  # бухгалтер — не расчётная группа
_HEAD = '0000000016'        # начальник ПЭО — чужой начальник


@pytest.fixture(autouse=True)
def clean(app):
    yield
    with app.app_context():
        PayslipQuestionMessage.query.delete()
        PayslipQuestion.query.delete()
        Notification.query.filter_by(kind='payslip_q').delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    sent = []

    def fake_record(kind, title, body='', employee_ids=None, ref=None, **_):
        assert kind == 'payslip_q'
        sent.append((sorted(employee_ids), title, body))

    monkeypatch.setattr(app_module, '_record_notice', fake_record)
    return sent


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _ask(client, headers, **fields):
    body = {'year': 2026, 'month': 9, 'line': 'Удержания: ИПН — 12 345,00',
            'text': 'Почему ИПН больше, чем в августе?'}
    body.update(fields)
    return client.post('/api/payslip-questions', json=body, headers=headers)


def _act(client, headers, item_id, action, **body):
    return client.post(f'/api/payslip-questions/{item_id}',
                       json={'action': action, **body}, headers=headers)


def test_who_is_payroll(app):
    with app.app_context():
        get = lambda i: db.session.get(Employee, i)
        assert payslip_questions.is_payroll(get(_PAYROLL))
        assert payslip_questions.is_payroll(get(_CHIEF))
        assert not payslip_questions.is_payroll(get(_ACCOUNTANT))


@pytest.mark.parametrize('fields, error', [
    ({'text': ''}, 'text_required'),
    ({'month': 13}, 'bad_period'),
    ({'year': 2099}, 'bad_period'),
    ({'year': 'x'}, 'bad_period'),
])
def test_bad_requests(app, client, pushes, fields, error):
    r = _ask(client, _auth(app, _AUTHOR), **fields)
    assert r.status_code == 400
    assert r.get_json()['error'] == error


def test_ask_answer_clarify_close(app, client, pushes):
    author = _auth(app, _AUTHOR)
    r = _ask(client, author)
    assert r.status_code == 201, r.get_json()
    item = r.get_json()['item']
    assert item['status'] == 'open'
    ids, title, body = pushes[-1]
    assert ids == sorted([_PAYROLL, _CHIEF])
    assert title == f'Вопрос по листку №{item["id"]}'
    # В оповещении — месяц, но ни суммы, ни строки листка.
    assert body.endswith('сентябрь 2026')
    assert '12 345' not in body

    payroll = _auth(app, _PAYROLL)
    queue = client.get('/api/payslip-questions?scope=queue', headers=payroll).get_json()
    assert queue['open'] == 1
    assert queue['items'][0]['preview'] == 'Почему ИПН больше, чем в августе?'

    pushes.clear()
    r = _act(client, payroll, item['id'], 'reply', text='В сентябре была премия.')
    got = r.get_json()['item']
    assert got['status'] == 'answered'
    assert got['assignee']['id'] == _PAYROLL
    assert pushes == [([_AUTHOR], f'Вопрос по листку №{item["id"]}: ответ '
                       'расчётной группы', 'сентябрь 2026')]

    pushes.clear()
    r = _act(client, author, item['id'], 'reply', text='А какая премия?')
    assert r.get_json()['item']['status'] == 'open'
    assert pushes[0][0] == [_PAYROLL]

    assert _act(client, payroll, item['id'], 'close').status_code == 403
    r = _act(client, author, item['id'], 'close')
    got = r.get_json()['item']
    assert got['status'] == 'closed'
    assert got['can_answer'] is False
    assert [m['from_payroll'] for m in got['messages']] == [False, True, False, False]
    assert got['messages'][-1]['kind'] == 'closed'
    assert _act(client, payroll, item['id'], 'reply', text='?').status_code == 409


def test_nobody_else_sees_salary_questions(app, client, pushes):
    item_id = _ask(client, _auth(app, _AUTHOR)).get_json()['item']['id']
    for outsider in (_HEAD, _ACCOUNTANT):
        headers = _auth(app, outsider)
        assert client.get(f'/api/payslip-questions/{item_id}',
                          headers=headers).status_code == 404
        assert client.get('/api/payslip-questions?scope=queue',
                          headers=headers).status_code == 403
        assert _act(client, headers, item_id, 'reply',
                    text='?').status_code == 404
