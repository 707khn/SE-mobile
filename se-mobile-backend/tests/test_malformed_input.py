"""Кривой запрос — это ответ 400 или «Failure», а не падение сервера.

Старое приложение, чужой скрипт или обрыв на полпути присылают то дату
«31.02.2026», то тело `null`, то массив вместо объекта. Обработчики разбирали
это без проверки и падали: человек получал 500 — то же самое, что настоящая
поломка, — а в журнале сервера копились трассировки, за которыми не видно
настоящих ошибок.
"""

import json
from datetime import date

import pytest

import app as app_module
from models import db, Employee, MenuDate, NewsItem

_WORKER = 'BAD00001'
_ADMIN = 'BAD00002'
_MENU_DAY = '2031-05-06'
_NEWS_TITLE = 'Проверка кривых полей'


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


@pytest.fixture
def admin(app, remove_employee, monkeypatch):
    """Администратор — чтобы запрос доходил до разбора полей, а не
    заканчивался отказом в доступе. И как на боевом сервере: сбой — это
    ответ 500, а не исключение в проверке."""
    monkeypatch.setenv('TURNSTILE_SECRET', 'проверка')
    monkeypatch.setitem(app.config, 'PROPAGATE_EXCEPTIONS', False)
    # Уведомления о меню и проходах уходят в фоновом потоке, а в проверках
    # база SQLite одна на всех: поток лез бы в неё посреди следующих тестов.
    monkeypatch.setattr(app_module, '_notify_later', lambda *a, **k: None)
    with app.app_context():
        remove_employee(_ADMIN)
        db.session.add(Employee(employee_id=_ADMIN,
                                full_name='Кривцова Админ Тестовна',
                                job_title='Администратор системы',
                                department='Тестовый отдел'))
        db.session.commit()
        token = app_module._issue_token(_ADMIN)
    yield {'Authorization': f'Bearer {token}'}
    with app.app_context():
        menu = MenuDate.query.filter_by(
            date=date.fromisoformat(_MENU_DAY)).first()
        if menu is not None:
            db.session.delete(menu)
        # Объявления, принятые по дороге, иначе остаются в ленте и вытесняют
        # из неё новости, которых ждут другие проверки.
        NewsItem.query.filter(NewsItem.title.in_(
            [_NEWS_TITLE, '123'])).delete(synchronize_session=False)
        db.session.commit()


_PERIOD = {'start_date': '2026-01-01', 'end_date': '2026-01-31'}
_SLIP = {'key_suffix': _ADMIN, 'month': '1', 'year': '2026'}
_REQUESTS = [
    ('POST', '/login', {'login': 'x', 'password': 'y'}),
    ('POST', '/change-password', {'old_password': 'x', 'new_password': 'y'}),
    ('POST', '/report', {'key_suffix': _ADMIN}),
    ('POST', '/reportdate', dict(_PERIOD, key_suffix=_ADMIN)),
    ('POST', '/director_report', dict(_PERIOD, emp_sname='Кривцова')),
    ('POST', '/payslip/periods', {'key_suffix': _ADMIN}),
    ('POST', '/payslip', _SLIP),
    ('POST', '/payslip/xlsx', _SLIP),
    ('POST', '/leaves', {'key_suffix': _ADMIN}),
    ('POST', '/api/home', {'key_suffix': _ADMIN}),
    ('POST', '/api/fcm-token', {'employee_id': _ADMIN, 'token': 't'}),
    ('DELETE', '/api/fcm-token', {'token': 't'}),
    ('POST', '/api/turnstile', {'secret': 'проверка', 'employee_id': _ADMIN,
                                'direction': 'in',
                                'timestamp': '2026-01-01T08:00'}),
    ('POST', '/api/admin/news', {'title': _NEWS_TITLE, 'summary': 's',
                                 'author': 'a'}),
    ('POST', '/api/news/announcements', {'login': 'x', 'password': 'y',
                                         'title': _NEWS_TITLE,
                                         'sent_at': 'x'}),
]


@pytest.mark.parametrize('method, path, body', _REQUESTS,
                         ids=[f'{m} {p}' for m, p, _ in _REQUESTS])
def test_field_of_wrong_type_is_not_a_crash(client, admin, method, path,
                                            body):
    crashed = []
    for field in body:
        for value in ([1], {'a': 1}, 123, True, None):
            answer = client.open(path, method=method, headers=admin,
                                 json=dict(body, **{field: value}))
            if answer.status_code >= 500:
                crashed.append((field, value))
    assert not crashed, f'{path} падает на {crashed}'


def test_number_is_the_same_number(app, client, worker):
    """Номер числом — тот же номер, а не пустое место.

    Пустой номер в листках значит «свой»: если бы число превращалось в
    пустоту, на чужой номер человек получил бы свои же листки вместо отказа.
    """
    with app.app_context():
        token = app_module._issue_token(_WORKER)
    answer = client.post('/payslip/periods',
                         headers={'Authorization': f'Bearer {token}'},
                         json={'key_suffix': 2114})
    assert answer.status_code == 403


@pytest.mark.parametrize('items', [
    'Борщ', {'name': 'Борщ'}, [1], ['Борщ'],
    [{'category': 'Блюда', 'name': 'Борщ', 'price': 'дорого'}],
    [{'category': 'Блюда', 'name': 'Борщ', 'price': [1]}],
    [{'category': 'Блюда', 'name': 'Борщ', 'price': 'nan'}],
    [{'category': 'Блюда', 'name': 'Борщ', 'price': True}],
])
def test_bad_menu_keeps_the_old_one(client, admin, items):
    good = [{'category': 'Блюда', 'name': 'Плов', 'price': 900,
             'portion': 250}]
    assert client.post('/api/menu', headers=admin, json={
        'date': _MENU_DAY, 'items': good}).status_code == 200

    answer = client.post('/api/menu', headers=admin,
                         json={'date': _MENU_DAY, 'items': items})
    assert answer.status_code == 400
    assert answer.get_json()['error'] == 'bad_items'

    kept = client.get(f'/api/menu?date={_MENU_DAY}').get_json()['items']
    assert [(i['name'], i['price'], i['portion']) for i in kept] == [
        ('Плов', 900.0, '250')]


def test_menu_price_as_text_still_counts(client, admin):
    answer = client.post('/api/menu', headers=admin, json={
        'date': _MENU_DAY, 'items': [
            {'category': 'Блюда', 'name': 'Плов', 'price': '950.50',
             'portion': 0.5},
            {'category': '', 'name': 'без категории — пропуск'}]})
    assert answer.status_code == 200
    kept = client.get(f'/api/menu?date={_MENU_DAY}').get_json()['items']
    assert [(i['name'], i['price'], i['portion']) for i in kept] == [
        ('Плов', 950.5, '0.5')]
