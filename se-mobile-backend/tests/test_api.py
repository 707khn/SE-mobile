"""Integration tests for the Flask API (se-mobile-backend/app.py).

The app fixture in conftest.py boots the app with an in-memory SQLite DB and
runs auto-seeding, which inserts employees '001', '002', '003' with attendance
records (Jan–Feb 2024) and payslips (Jan–Feb 2024 for '001'/'002', Jan 2024
for '003').  Tests that upload the XML fixture create employees '0000001874'
and '0000002031' which do not exist in the seed data.
"""
import io
import json
import os

import pytest

_TEST_XML = os.path.join(os.path.dirname(__file__), '..', 'test_payslip.xml')


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _post(client, path, body):
    return client.post(path, data=json.dumps(body),
                       content_type='application/json')


def _xml_upload(client, filename='test_payslip.xml', content=None):
    if content is None:
        with open(_TEST_XML, 'rb') as f:
            content = f.read()
    data = {'file': (io.BytesIO(content), filename)}
    return client.post('/api/admin/upload-payslip-xml',
                       data=data, content_type='multipart/form-data')


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
    r = _post(client, '/login', {'iin': '900101350123'})
    body = r.get_json()
    assert body['message'] == 'Success'
    assert 'full_name' in body
    assert 'job' in body
    assert body['employee_id'] == '001'


def test_login_failure(client):
    r = _post(client, '/login', {'iin': '000000000000'})
    assert r.get_json()['message'] == 'Failure'


# ---------------------------------------------------------------------------
# /report
# ---------------------------------------------------------------------------

def test_report_success(client):
    r = _post(client, '/report', {'key_suffix': '001'})
    body = r.get_json()
    assert body['message'] == 'Success'
    assert len(body['report']) > 0


def test_report_failure(client):
    r = _post(client, '/report', {'key_suffix': 'UNKNOWN'})
    assert r.get_json()['message'] == 'Failure'


# ---------------------------------------------------------------------------
# /reportdate
# ---------------------------------------------------------------------------

def test_reportdate_success(client):
    r = _post(client, '/reportdate', {
        'key_suffix': '001',
        'start_date': '2024-01-01',
        'end_date': '2024-01-31',
    })
    body = r.get_json()
    assert body['message'] == 'Success'
    assert len(body['report']) > 0


def test_reportdate_no_records(client):
    r = _post(client, '/reportdate', {
        'key_suffix': '001',
        'start_date': '2000-01-01',
        'end_date': '2000-01-31',
    })
    assert r.get_json()['message'] == 'Failure'


# ---------------------------------------------------------------------------
# /director_report
# ---------------------------------------------------------------------------

def test_director_report_success(client):
    r = _post(client, '/director_report', {
        'emp_sname': 'Ахметов',
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
    r = _post(client, '/get_sname', {'key_suffix': '001'})
    body = r.get_json()
    assert 'fio' in body
    assert len(body['fio']) >= 3


def test_get_sname_by_iin(client):
    r = _post(client, '/get_sname', {'emp_iin': '900101350123'})
    body = r.get_json()
    assert body['message'] == 'Success'
    assert body['employee'][0]['iin'] == '900101350123'


def test_get_sname_unknown_iin(client):
    r = _post(client, '/get_sname', {'emp_iin': '000000000000'})
    assert r.get_json()['message'] == 'Failure'


# ---------------------------------------------------------------------------
# /payslip
# ---------------------------------------------------------------------------

def test_payslip_success(client):
    r = _post(client, '/payslip', {'key_suffix': '001', 'month': '1', 'year': '2024'})
    body = r.get_json()
    assert body['message'] == 'Success'
    ps = body['payslip']
    assert ps['total_accruals'] > 0
    assert 'accruals' in ps
    assert 'deductions' in ps
    assert 'net_pay' in ps


def test_payslip_failure(client):
    r = _post(client, '/payslip', {'key_suffix': '001', 'month': '12', 'year': '1999'})
    assert r.get_json()['message'] == 'Failure'


# ---------------------------------------------------------------------------
# /leaves
# ---------------------------------------------------------------------------

def test_leaves_success(client):
    r = _post(client, '/leaves', {'key_suffix': '001'})
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
                    data={}, content_type='multipart/form-data')
    assert r.status_code == 400


# ---------------------------------------------------------------------------
# /api/fcm-token
# ---------------------------------------------------------------------------

_FCM_TOKEN = 'test-fcm-token-abc123'


def test_fcm_register(client):
    r = _post(client, '/api/fcm-token', {
        'employee_id': '001',
        'token': _FCM_TOKEN,
    })
    assert r.status_code == 200
    assert r.get_json()['message'] == 'Success'


def test_fcm_register_idempotent(client):
    """Re-registering the same token must not create duplicates."""
    _post(client, '/api/fcm-token', {'employee_id': '001', 'token': _FCM_TOKEN})
    r = _post(client, '/api/fcm-token', {'employee_id': '001', 'token': _FCM_TOKEN})
    assert r.status_code == 200

    from models import FcmToken
    with client.application.app_context():
        count = FcmToken.query.filter_by(token=_FCM_TOKEN).count()
    assert count == 1


def test_fcm_delete(client):
    _post(client, '/api/fcm-token', {'employee_id': '001', 'token': _FCM_TOKEN})
    r = client.delete('/api/fcm-token',
                      data=json.dumps({'employee_id': '001', 'token': _FCM_TOKEN}),
                      content_type='application/json')
    assert r.status_code == 200
    assert r.get_json()['message'] == 'Success'
