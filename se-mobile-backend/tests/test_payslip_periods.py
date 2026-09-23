"""За какие месяцы у человека есть расчётный лист.

Экран листка открывался на прошлом месяце. Листки приносят с задержкой, и
прошлый месяц почти никогда не тот, что уже в базе: 23 сентября прошлый
месяц — август, а последний загруженный листок был за июль. То есть первое,
что видел каждый, кто открывал «Расчётный лист», — «листок не найден».
А выбор месяца предлагал любой месяц за пять лет, из которых заполнены два.
"""

import json

import app as app_module
from models import db, Employee, Payslip

_SARSEKEN = '0000002114'


def _post(client, path, body):
    return client.post(path, data=json.dumps(body),
                       content_type='application/json')


def test_periods_are_newest_first(client):
    body = _post(client, '/payslip/periods', {'key_suffix': _SARSEKEN}).get_json()
    assert body['message'] == 'Success'
    periods = body['periods']
    assert periods, 'у техника-программиста листки есть с сидеров'

    keys = [(p['year'], p['month']) for p in periods]
    assert keys == sorted(keys, reverse=True), 'свежие должны идти первыми'
    # По первому месяцу экран и открывается — значит, дубликаты в списке
    # недопустимы: месяц в нём должен быть один раз.
    assert len(keys) == len(set(keys))


def test_no_payslips_is_an_empty_list_not_a_failure(app, client):
    """Человек есть, листков нет — это ответ, а не отказ.

    Половина справочника сейчас в таком положении: листки загружены за июнь
    и июль, а заведены в приложении и те, кого в них нет.
    """
    with app.app_context():
        db.session.add(Employee(employee_id='0000009100',
                                full_name='Без Листков Тестович',
                                job_title='Слесарь'))
        db.session.commit()

    body = _post(client, '/payslip/periods', {'key_suffix': '0000009100'}).get_json()
    assert body['message'] == 'Success'
    assert body['periods'] == []

    with app.app_context():
        db.session.delete(db.session.get(Employee, '0000009100'))
        db.session.commit()


def test_periods_match_the_payslips_that_open(app, client):
    """Список не должен расходиться с тем, что отдаёт /payslip.

    Месяц из списка приложение открывает не спрашивая, а месяцы вне списка
    показывает серыми и нажать не даёт. Разойдутся — человек либо увидит
    «не найден» там, где обещано, либо не сможет открыть то, что есть.
    """
    listed = {(p['year'], p['month']) for p in
              _post(client, '/payslip/periods',
                    {'key_suffix': _SARSEKEN}).get_json()['periods']}

    with app.app_context():
        actual = {(p.period_year, p.period_month) for p in
                  Payslip.query.filter_by(employee_id=_SARSEKEN).all()}
    assert listed == actual

    for year, month in sorted(listed, reverse=True)[:3]:
        answer = _post(client, '/payslip', {
            'key_suffix': _SARSEKEN,
            'month': f'{month:02d}',
            'year': str(year),
        }).get_json()
        assert answer['message'] == 'Success', f'{year}-{month:02d} обещан, но не открылся'


def test_someone_elses_months_are_closed(app, client):
    """Список месяцев закрыт так же, как сам листок.

    Он не показывает сумм, но говорит, за какие месяцы человеку начисляли —
    то есть когда он работал, а когда нет. Открывать это соседу незачем, и
    ворота здесь те же самые, что у /payslip.
    """
    with app.app_context():
        token = app_module._issue_token(
            app_module._authenticate(_SARSEKEN, _SARSEKEN)
            or app_module._authenticate('2114', '2114'))

    denied = client.post('/payslip/periods',
                         json={'key_suffix': '0000002183'},   # Генеральный директор
                         headers={'Authorization': f'Bearer {token}'})
    assert denied.status_code == 403

    mine = client.post('/payslip/periods',
                       json={'key_suffix': _SARSEKEN},
                       headers={'Authorization': f'Bearer {token}'})
    assert mine.get_json()['message'] == 'Success'
