"""Кривой запрос — это ответ 400 или «Failure», а не падение сервера.

Старое приложение, чужой скрипт или обрыв на полпути присылают то дату
«31.02.2026», то тело `null`, то массив вместо объекта. Обработчики разбирали
это без проверки и падали: человек получал 500 — то же самое, что настоящая
поломка, — а в журнале сервера копились трассировки, за которыми не видно
настоящих ошибок.
"""

import json

import pytest

from models import db, Employee

_WORKER = 'BAD00001'


@pytest.fixture
def worker(app, remove_employee):
    with app.app_context():
        remove_employee(_WORKER)
        db.session.add(Employee(employee_id=_WORKER,
                                full_name='Кривцов Тест Тестович',
                                job_title='Слесарь'))
        db.session.commit()
    yield


def _raw(client, path, body):
    return client.post(path, data=body, content_type='application/json')


@pytest.mark.parametrize('start, end', [
    ('2026-02-31', '2026-03-01'),   # такого дня нет
    ('01.03.2026', '2026-03-31'),   # не тот формат
    ('2026-03-01', None),           # конца нет
    (20260301, '2026-03-31'),       # число вместо строки
])
def test_bad_dates_are_bad_period(client, worker, start, end):
    for path, who in (('/reportdate', {'key_suffix': _WORKER}),
                      ('/director_report', {'emp_sname': 'Кривцов'})):
        body = dict(who, start_date=start, end_date=end)
        answer = client.post(path, json=body)
        assert answer.status_code == 400, path
        assert answer.get_json() == {'message': 'Failure',
                                     'error': 'bad_period'}, path


def test_good_dates_still_work(client, worker):
    answer = client.post('/reportdate', json={
        'key_suffix': _WORKER, 'start_date': '2026-03-01',
        'end_date': '2026-03-31'})
    assert answer.status_code == 200
    assert answer.get_json()['message'] == 'Success'


@pytest.mark.parametrize('body', ['null', '[]', '"текст"', '42', '{не json'])
@pytest.mark.parametrize('path', ['/report', '/reportdate',
                                  '/director_report', '/leaves'])
def test_body_that_is_not_an_object_is_not_a_crash(client, worker, path,
                                                    body):
    answer = _raw(client, path, body)
    assert answer.status_code < 500, (path, body)
    assert answer.is_json


def test_empty_object_is_not_a_crash(client, worker):
    for path in ('/report', '/reportdate', '/director_report', '/leaves'):
        answer = _raw(client, path, json.dumps({}))
        assert answer.status_code < 500, path
        assert answer.is_json
