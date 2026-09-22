"""Integration tests for the Flask API (se-mobile-backend/app.py).

The app fixture in conftest.py boots the app with an in-memory SQLite DB and
runs auto-seeding, which inserts employees '001', '002', '003' with attendance
records (Jan–Feb 2024) and payslips (Jan–Feb 2024 for '001'/'002', Jan 2024
for '003').  '001' is Сарсекенов, and the July payslip book gave him his real
personnel number: his record, and everything on it, now lives under
_SARSEKEN below — '001' itself is gone.

Tests that upload the XML fixture create employees '0000001874' and
'0000002031' which do not exist in the seed data.
"""
import io
import json
import os

# Табельный номер техника-программиста. Прежде он значился под «001»; с
# загрузкой июльских листков записи склеены на настоящий номер.
_SARSEKEN = '0000002114'

import pytest

import app as app_module

_TEST_XML = os.path.join(os.path.dirname(__file__), '..', 'test_payslip.xml')


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _post(client, path, body):
    return client.post(path, data=json.dumps(body),
                       content_type='application/json')


_ADMIN_HEADERS = {'X-Admin-Token': os.environ['ADMIN_TOKEN']}


def _xml_upload(client, filename='test_payslip.xml', content=None):
    if content is None:
        with open(_TEST_XML, 'rb') as f:
            content = f.read()
    data = {'file': (io.BytesIO(content), filename)}
    return client.post('/api/admin/upload-payslip-xml',
                       data=data, content_type='multipart/form-data',
                       headers=_ADMIN_HEADERS)


# ---------------------------------------------------------------------------
# Index
# ---------------------------------------------------------------------------

def test_index(client):
    r = client.get('/')
    assert r.status_code == 200
    body = r.get_json()
    assert body['status'] == 'ok'


# ---------------------------------------------------------------------------
# /login
# ---------------------------------------------------------------------------

def test_login_success(client):
    # Вход по логину и паролю. Раньше тест слал ИИН — так вход работал в
    # старой версии, и с тех пор он проверял несуществующий путь.
    r = _post(client, '/login', {'login': '2114', 'password': '2114'})
    body = r.get_json()
    assert body['message'] == 'Success'
    assert 'full_name' in body
    assert 'job' in body
    assert body['token']
    assert body['employee_id'] == _SARSEKEN


def test_login_failure(client):
    r = _post(client, '/login', {'iin': '000000000000'})
    assert r.get_json()['message'] == 'Failure'


# ---------------------------------------------------------------------------
# /report
# ---------------------------------------------------------------------------

def test_report_success(client):
    r = _post(client, '/report', {'key_suffix': _SARSEKEN})
    body = r.get_json()
    assert body['message'] == 'Success'
    assert len(body['report']) > 0


def test_report_empty_is_not_a_failure(client):
    """Пустой список — это ответ, а не отказ.

    «Failure» на «проходов нет» приложение показывало так же, как сбой связи:
    «нет данных, выберите период». Предлагать выбрать период тому, у кого
    проходов нет вовсе, — значит отправить его искать то, чего нет.
    """
    body = _post(client, '/report', {'key_suffix': 'UNKNOWN'}).get_json()
    assert body['message'] == 'Success'
    assert body['report'] == []
    assert body['coverage']['employee_has_any'] is False


# ---------------------------------------------------------------------------
# /reportdate
# ---------------------------------------------------------------------------

def test_reportdate_success(client):
    r = _post(client, '/reportdate', {
        'key_suffix': _SARSEKEN,
        'start_date': '2024-01-01',
        'end_date': '2024-01-31',
    })
    body = r.get_json()
    assert body['message'] == 'Success'
    assert len(body['report']) > 0


def test_reportdate_no_records(client):
    """Период без проходов у того, у кого проходы есть.

    Здесь экран и должен сказать «за эти дни проходов нет» — в отличие от
    случая, когда человека нет в выгрузке вовсе или период позже последней
    загрузки. Различить их можно только по coverage.
    """
    body = _post(client, '/reportdate', {
        'key_suffix': _SARSEKEN,
        'start_date': '2000-01-01',
        'end_date': '2000-01-31',
    }).get_json()
    assert body['message'] == 'Success'
    assert body['report'] == []
    assert body['coverage']['employee_has_any'] is True
    assert body['coverage']['loaded_until'] >= body['coverage']['employee_until']


def test_uploading_passes_refreshes_the_coverage(app, client):
    """Загрузили выгрузку — «загружено по» меняется сразу, а не через десять минут.

    Ответ про последнюю загруженную дату держится в памяти процесса: считать
    максимум по самой большой таблице на каждый запрос незачем. Но сбрасывать
    его надо в момент вставки, иначе администратор, загрузив сентябрьскую
    выгрузку, увидит «загружено по 20 августа» и решит, что не прошло.
    """
    from datetime import date as _date
    from models import db, AccessRecord

    before = _post(client, '/report', {'key_suffix': _SARSEKEN}
                   ).get_json()['coverage']['loaded_until']

    with app.app_context():
        db.session.add(AccessRecord(
            employee_id=_SARSEKEN, access_date=_date(2099, 6, 1),
            access_time='08:00', event_type='Вход', door_location='Проходная'))
        db.session.commit()

    after = _post(client, '/report', {'key_suffix': _SARSEKEN}
                  ).get_json()['coverage']['loaded_until']
    assert after == '2099-06-01' and after != before

    with app.app_context():
        AccessRecord.query.filter_by(access_date=_date(2099, 6, 1)).delete()
        db.session.commit()
        # Массовое удаление событий модели не поднимает — сбрасываем сами,
        # иначе следующая проверка увидит дату несуществующей записи.
        app_module._access_loaded_until['checked_at'] = None


def test_reportdate_after_the_last_upload(client):
    """Период позже последней выгрузки — главный случай.

    Выгрузку из СКУД приносят раз в месяц: 22 сентября проходы в базе были
    по 20 августа. Значит, «Сегодня», «Последние 7 дней» и «Этот месяц»
    пусты у всех подряд, и без объяснения это выглядит как поломка.
    """
    body = _post(client, '/reportdate', {
        'key_suffix': _SARSEKEN,
        'start_date': '2099-01-01',
        'end_date': '2099-01-31',
    }).get_json()
    assert body['message'] == 'Success'
    assert body['report'] == []
    coverage = body['coverage']
    # По этим двум приложение и отличает «данных ещё нет» от «не проходил».
    assert coverage['employee_has_any'] is True
    assert coverage['loaded_until'] < '2099-01-01'


# ---------------------------------------------------------------------------
# /director_report
# ---------------------------------------------------------------------------

def test_director_report_success(client):
    r = _post(client, '/director_report', {
        # Сотрудник 002 из сидеров. Прежняя фамилия из них давно ушла.
        'emp_sname': 'Касымов',
        'start_date': '2024-01-01',
        'end_date': '2024-01-31',
    })
    body = r.get_json()
    assert body['message'] == 'Success'
    assert len(body['director_report']) > 0


def test_director_report_failure(client):
    r = _post(client, '/director_report', {
        'emp_sname': 'НесуществующийСотрудник',
        'start_date': '2024-01-01',
        'end_date': '2024-01-31',
    })
    assert r.get_json()['message'] == 'Failure'


# ---------------------------------------------------------------------------
# /get_sname
# ---------------------------------------------------------------------------

def test_get_sname_list(client):
    r = _post(client, '/get_sname', {'key_suffix': _SARSEKEN})
    body = r.get_json()
    assert 'fio' in body
    assert len(body['fio']) >= 3


def test_get_sname_by_iin(client):
    # ИИН сотрудника 001 в нынешних сидерах; демонстрационный из ранней
    # версии оттуда убрали, а тест остался на него смотреть.
    r = _post(client, '/get_sname', {'emp_iin': '000000002114'})
    body = r.get_json()
    assert body['message'] == 'Success'
    assert body['employee'][0]['iin'] == '000000002114'


def test_get_sname_unknown_iin(client):
    r = _post(client, '/get_sname', {'emp_iin': '000000000000'})
    assert r.get_json()['message'] == 'Failure'


# ---------------------------------------------------------------------------
# /payslip
# ---------------------------------------------------------------------------

def test_payslip_success(client):
    r = _post(client, '/payslip', {'key_suffix': _SARSEKEN, 'month': '1', 'year': '2024'})
    body = r.get_json()
    assert body['message'] == 'Success'
    ps = body['payslip']
    assert ps['total_accruals'] > 0
    assert 'accruals' in ps
    assert 'deductions' in ps
    assert 'net_pay' in ps


def test_payslip_failure(client):
    r = _post(client, '/payslip', {'key_suffix': _SARSEKEN, 'month': '12', 'year': '1999'})
    assert r.get_json()['message'] == 'Failure'


# ---------------------------------------------------------------------------
# /leaves
# ---------------------------------------------------------------------------

def test_leaves_success(client):
    r = _post(client, '/leaves', {'key_suffix': _SARSEKEN})
    body = r.get_json()
    assert body['message'] == 'Success'
    assert len(body['leaves']['balances']) > 0


def test_leaves_failure(client):
    r = _post(client, '/leaves', {'key_suffix': 'UNKNOWN'})
    assert r.get_json()['message'] == 'Failure'


# ---------------------------------------------------------------------------
# /api/admin/upload-payslip-xml
# ---------------------------------------------------------------------------

def test_upload_xml_success(client):
    r = _xml_upload(client)
    assert r.status_code == 200
    body = r.get_json()
    assert body['message'] == 'Success'
    assert body['imported'] == 2
    names = {e['employee_id'] for e in body['employees']}
    assert '0000001874' in names
    assert '0000002031' in names


def test_upload_xml_idempotent(client):
    """Re-uploading the same file must not duplicate records."""
    _xml_upload(client)  # first upload (may already be done in test above)
    r = _xml_upload(client)  # second upload
    assert r.status_code == 200
    assert r.get_json()['imported'] == 2

    # Query the DB directly to verify no duplicates
    from app import create_app  # noqa: F401 — just need db
    from models import db, Payslip
    with client.application.app_context():
        count = Payslip.query.filter_by(
            employee_id='0000001874', period_year=2025, period_month=10
        ).count()
    assert count == 1


def test_upload_xml_invalid(client):
    r = _xml_upload(client, content=b'<not valid xml <<< garbage')
    assert r.status_code == 422
    assert r.get_json()['error'] is True


def test_upload_xml_wrong_extension(client):
    r = _xml_upload(client, filename='payslip.txt')
    assert r.status_code == 400
    assert r.get_json()['error'] is True


def test_upload_xml_no_file(client):
    r = client.post('/api/admin/upload-payslip-xml',
                    data={}, content_type='multipart/form-data',
                    headers=_ADMIN_HEADERS)
    assert r.status_code == 400


# ---------------------------------------------------------------------------
# /api/fcm-token
# ---------------------------------------------------------------------------

_FCM_TOKEN = 'test-fcm-token-abc123'


def test_fcm_register(client):
    r = _post(client, '/api/fcm-token', {
        'employee_id': _SARSEKEN,
        'token': _FCM_TOKEN,
    })
    assert r.status_code == 200
    assert r.get_json()['message'] == 'Success'


def test_fcm_register_idempotent(client):
    """Re-registering the same token must not create duplicates."""
    _post(client, '/api/fcm-token', {'employee_id': _SARSEKEN, 'token': _FCM_TOKEN})
    r = _post(client, '/api/fcm-token', {'employee_id': _SARSEKEN, 'token': _FCM_TOKEN})
    assert r.status_code == 200

    from models import FcmToken
    with client.application.app_context():
        count = FcmToken.query.filter_by(token=_FCM_TOKEN).count()
    assert count == 1


def test_fcm_delete(client):
    _post(client, '/api/fcm-token', {'employee_id': _SARSEKEN, 'token': _FCM_TOKEN})
    r = client.delete('/api/fcm-token',
                      data=json.dumps({'employee_id': _SARSEKEN, 'token': _FCM_TOKEN}),
                      content_type='application/json')
    assert r.status_code == 200
    assert r.get_json()['message'] == 'Success'


# ---------------------------------------------------------------------------
# /api/menu
# ---------------------------------------------------------------------------

_MENU_DATE = '2026-01-15'
_MENU_ITEMS = [
    {'category': 'Первое блюдо', 'name': 'Борщ', 'price': 600.0},
    {'category': 'Второе блюдо', 'name': 'Котлета с гарниром', 'price': 900.0},
    {'category': 'Напиток', 'name': 'Компот', 'price': 150.0},
]


def test_menu_get_empty(client):
    r = client.get(f'/api/menu?date={_MENU_DATE}')
    assert r.status_code == 200
    body = r.get_json()
    assert body['message'] == 'Success'
    assert body['items'] == []


def test_menu_post(client):
    r = _post(client, '/api/menu', {'date': _MENU_DATE, 'items': _MENU_ITEMS})
    assert r.status_code == 200
    assert r.get_json()['message'] == 'Success'


def test_menu_get_after_post(client):
    _post(client, '/api/menu', {'date': _MENU_DATE, 'items': _MENU_ITEMS})
    r = client.get(f'/api/menu?date={_MENU_DATE}')
    body = r.get_json()
    assert body['message'] == 'Success'
    assert len(body['items']) == 3
    names = {i['name'] for i in body['items']}
    assert 'Борщ' in names


def test_menu_post_idempotent(client):
    _post(client, '/api/menu', {'date': _MENU_DATE, 'items': _MENU_ITEMS})
    _post(client, '/api/menu', {'date': _MENU_DATE, 'items': _MENU_ITEMS})
    r = client.get(f'/api/menu?date={_MENU_DATE}')
    assert len(r.get_json()['items']) == 3


def test_menu_delete(client):
    _post(client, '/api/menu', {'date': _MENU_DATE, 'items': _MENU_ITEMS})
    r = client.delete(f'/api/menu/{_MENU_DATE}')
    assert r.status_code == 200
    assert r.get_json()['message'] == 'Success'
    r2 = client.get(f'/api/menu?date={_MENU_DATE}')
    assert r2.get_json()['items'] == []


def test_menu_default_date(client):
    r = client.get('/api/menu')
    assert r.status_code == 200
    assert 'date' in r.get_json()
