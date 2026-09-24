"""Ошибка сервера должна приходить как JSON, а не как страница.

Приложение всюду разбирает ответ как JSON. Когда обработчик падал, Flask
отдавал HTML с описанием ошибки, разбор ломался, и человек видел «ошибка
сети» — то же самое, что при пропавшей связи. Отличить одно от другого не мог
ни он, ни поддержка: в «О программе» ложилась запись про разбор JSON, а не про
то, что на самом деле сломалось на сервере.
"""

import json

import app as app_module


def _post(client, path, body):
    return client.post(path, data=json.dumps(body),
                       content_type='application/json')


def test_unknown_path_is_json(app, client):
    answer = client.get('/такого-адреса-нет')
    assert answer.status_code == 404
    assert answer.is_json, 'вернулась страница, а не JSON'
    assert answer.get_json()['message'] == 'Failure'


def test_wrong_method_is_json(app, client):
    answer = client.get('/login')          # /login принимает POST
    assert answer.status_code == 405
    assert answer.is_json
    assert answer.get_json()['status'] == 405


def test_unexpected_error_is_json_and_five_hundred(app, client, monkeypatch):
    """Настоящий сбой в обработчике.

    В проверках Flask по умолчанию пробрасывает исключение наружу, поэтому
    на время этой проверки ведём себя как на боевом сервере — иначе
    проверялось бы не то, что происходит у людей.
    """
    def _boom():
        raise RuntimeError('что-то сломалось')

    monkeypatch.setattr(app_module, '_latest_apk', _boom)
    monkeypatch.setitem(app.config, 'PROPAGATE_EXCEPTIONS', False)

    answer = client.get('/api/app/latest')
    assert answer.status_code == 500
    assert answer.is_json
    assert answer.get_json() == {'message': 'Failure', 'error': 'internal'}


def test_payslip_survives_a_month_that_is_not_a_number(app, client):
    """int('август') — это пятисотый ответ, а для человека «ошибка сети»."""
    answer = _post(client, '/payslip', {
        'key_suffix': '0000002114', 'month': 'август', 'year': '2026'})
    assert answer.status_code == 400
    assert answer.get_json()['error'] == 'bad_period'


def test_news_limit_that_is_not_a_number_is_ignored(app, client):
    """Лента — не то место, где стоит отказывать из-за опечатки."""
    assert client.get('/api/news?limit=много').status_code == 200
    assert client.get('/api/news?limit=-5').status_code == 200
    assert client.get('/api/news?limit=99999').status_code == 200
