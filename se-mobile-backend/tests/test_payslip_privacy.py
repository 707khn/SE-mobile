"""Чужую зарплату руководитель не видит.

Проходы подчинённых начальнику нужны — и правило _may_view их открывает.
Листки — нет: раньше они шли по тому же правилу, и любой «начальник»,
«главный», «директор» или «заместитель» открывал листки всего своего
отдела, а заместитель по экономике и финансам — всего предприятия.
Чужой листок теперь открывают только расчётная группа и администратор
системы.
"""

import os

import pytest

import app as app_module
from models import db, Employee

_HEAD_OF_IT = '0000001465'   # начальник ОИТиС
_ORDINARY = '0000002114'     # техник-программист из её отдела
_FINANCE = '0000002184'      # зам. по экономике и финансам
_PAYROLL = '0000001469'      # бухгалтер расчётной группы

_ENDPOINTS = ('/payslip/periods', '/payslip', '/payslip/xlsx')


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _admin(app):
    with app.app_context():
        employee_id = app_module._authenticate('admin', os.environ['ADMIN_PASSWORD'])
        assert employee_id
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _ask(client, headers, path, employee_id):
    return client.post(path, headers=headers, json={
        'key_suffix': employee_id, 'month': '7', 'year': '2026'})


def test_head_still_sees_subordinate_attendance(app):
    """Проходы — как были: ограничение только на зарплату."""
    from flask import g
    with app.test_request_context():
        g.employee = db.session.get(Employee, _HEAD_OF_IT)
        assert app_module._may_view(_ORDINARY)
        assert not app_module._may_view_payslip(_ORDINARY)


@pytest.mark.parametrize('path', _ENDPOINTS)
def test_head_of_department_cannot_open_subordinate_payslip(app, client, path):
    r = _ask(client, _auth(app, _HEAD_OF_IT), path, _ORDINARY)
    assert r.status_code == 403


@pytest.mark.parametrize('path', _ENDPOINTS)
def test_finance_deputy_cannot_open_others_payslip(app, client, path):
    r = _ask(client, _auth(app, _FINANCE), path, _ORDINARY)
    assert r.status_code == 403


def test_head_still_opens_own_payslip(app, client):
    r = _ask(client, _auth(app, _HEAD_OF_IT), '/payslip/periods', _HEAD_OF_IT)
    assert r.status_code == 200


def test_payroll_opens_anyones_payslip(app, client):
    r = _ask(client, _auth(app, _PAYROLL), '/payslip/periods', _ORDINARY)
    assert r.status_code == 200


def test_system_admin_opens_anyones_payslip(app, client):
    r = _ask(client, _admin(app), '/payslip/periods', _ORDINARY)
    assert r.status_code == 200
