"""Вкладка «Уведомления» в админ-панели: журнал рассылок и отправка вручную.

Повод — меню на 25.11: загрузили, уведомление пришло; загрузили ещё раз —
не пришло, и снаружи было не понять, сломалось или так задумано. Теперь
повторная загрузка оставляет в журнале строку «пропущено» с пояснением, а
администратор может разослать меню вручную.
"""

import io
import os
from datetime import date

import pytest
from openpyxl import Workbook
from werkzeug.security import generate_password_hash

import app as app_module
from models import db, Employee, MenuDate, MenuItem, Notification, PushLog, UserAccount

_DAY = date(2026, 11, 25)
_TECH = 'NTFY0001'
_TECH_LOGIN = 'ntfytech'
_TECH_PASSWORD = 'длинная-фраза-технолога'
_WORKER = 'NTFY0002'


@pytest.fixture
def admin_headers(app):
    with app.app_context():
        admin = app_module._authenticate('admin', os.environ['ADMIN_PASSWORD'])
        token = app_module._issue_token(admin)
    return {'Authorization': f'Bearer {token}'}


@pytest.fixture
def people(app, remove_employee):
    with app.app_context():
        remove_employee(_TECH)
        remove_employee(_WORKER)
        UserAccount.query.filter_by(login=_TECH_LOGIN).delete()
        db.session.add(Employee(employee_id=_TECH, full_name='Технолог Тест',
                                job_title='Технолог столовой'))
        db.session.add(Employee(employee_id=_WORKER, full_name='Слесарь Тест',
                                job_title='Слесарь'))
        db.session.add(UserAccount(login=_TECH_LOGIN, employee_id=_TECH,
                                   password_hash=generate_password_hash(_TECH_PASSWORD),
                                   must_change_password=False))
        db.session.commit()
    yield
    with app.app_context():
        UserAccount.query.filter_by(login=_TECH_LOGIN).delete()
        Notification.query.filter(
            Notification.employee_id.in_([_TECH, _WORKER])).delete(
                synchronize_session=False)
        menu = MenuDate.query.filter_by(date=_DAY).first()
        if menu:
            db.session.delete(menu)
        PushLog.query.delete()
        db.session.commit()


@pytest.fixture
def pushes(monkeypatch):
    """Отправка «доходит» до телефона; очередь — сразу, без потока."""
    sent = []

    def _deliver(ids, title, body, data=None):
        sent.append((list(ids), title, body, dict(data or {})))
        return {'devices': 1, 'delivered': 1, 'failed': 0,
                'telegram': 0, 'note': None}

    monkeypatch.setattr(app_module, '_push_deliver', _deliver)
    monkeypatch.setattr(app_module, '_notify_later',
                        lambda app_, fn, *a, **k: fn(*a, **k))
    return sent


def _menu_file():
    wb = Workbook()
    ws = wb.active
    ws.append(['Меню на 25 ноября 2026 г.'])
    ws.append(['Наименование', 'Выход', 'Цена'])
    ws.append(['Супы'])
    ws.append(['Борщ', 250, 450])
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


def _upload(client):
    return client.post('/api/menu/import-excel', data={
        'login': _TECH_LOGIN, 'password': _TECH_PASSWORD,
        'file': (io.BytesIO(_menu_file()), 'menu.xlsx'),
        'force_date': _DAY.isoformat()}, content_type='multipart/form-data')


def test_second_menu_upload_is_logged_as_skipped(app, client, people, pushes,
                                                 admin_headers):
    assert _upload(client).status_code == 200
    assert _upload(client).status_code == 200
    # Пуш ушёл один раз — как и задумано.
    assert len([p for p in pushes if p[3].get('type') == 'menu']) == 1

    r = client.get('/api/admin/notifications', headers=admin_headers)
    assert r.status_code == 200
    menu = [i for i in r.get_json()['items'] if i['kind'] == 'menu']
    assert [i['status'] for i in menu] == ['skipped', 'sent']
    assert 'уже было опубликовано' in menu[0]['note']
    assert menu[0]['date'] == _DAY.isoformat()


def test_menu_can_be_sent_again_by_hand(app, client, people, pushes,
                                        admin_headers):
    _upload(client)
    pushes.clear()
    r = client.post('/api/admin/notifications/menu', headers=admin_headers,
                    json={'date': _DAY.isoformat()})
    assert r.status_code == 200, r.get_json()
    item = r.get_json()['item']
    assert item['source'] == 'manual' and item['status'] == 'sent'
    (_, title, body, data), = pushes
    assert title == 'Столовая' and data['date'] == _DAY.isoformat()


def test_resend_of_a_skipped_menu_row_sends_the_menu(app, client, people,
                                                    pushes, admin_headers):
    _upload(client)
    _upload(client)
    pushes.clear()
    with app.app_context():
        skipped = PushLog.query.filter_by(status='skipped').one().id
    r = client.post(f'/api/admin/notifications/{skipped}/resend',
                    headers=admin_headers)
    assert r.status_code == 200
    (_, _, body, data), = pushes
    assert 'повторная' not in body
    assert data['type'] == 'menu'


def test_menu_for_a_day_without_menu_is_refused(client, people, admin_headers):
    r = client.post('/api/admin/notifications/menu', headers=admin_headers,
                    json={'date': '2026-01-01'})
    assert r.status_code == 404
    assert r.get_json()['error'] == 'no_menu'


def test_own_message_to_chosen_people(app, client, people, pushes,
                                      admin_headers):
    r = client.post('/api/admin/notifications/send', headers=admin_headers,
                    json={'title': 'Проверка', 'body': 'Тест',
                          'audience': 'person', 'employee_ids': [_WORKER]})
    assert r.status_code == 200, r.get_json()
    assert r.get_json()['item']['people'] == 1
    (ids, title, _, _), = pushes
    assert ids == [_WORKER] and title == 'Проверка'
    with app.app_context():
        assert Notification.query.filter_by(employee_id=_WORKER,
                                            title='Проверка').count() == 1

    # Повтор из истории — тем же людям.
    log_id = r.get_json()['item']['id']
    pushes.clear()
    assert client.post(f'/api/admin/notifications/{log_id}/resend',
                       headers=admin_headers).status_code == 200
    (ids, _, _, _), = pushes
    assert ids == [_WORKER]


def test_failed_delivery_is_marked(app, client, people, monkeypatch,
                                   admin_headers):
    monkeypatch.setattr(app_module, '_get_firebase', lambda: None)
    r = client.post('/api/admin/notifications/send', headers=admin_headers,
                    json={'title': 'Т', 'audience': 'person',
                          'employee_ids': [_WORKER], 'feed': False})
    item = r.get_json()['item']
    assert item['status'] == 'error'
    assert 'Firebase' in item['note']


def test_only_admin(client, people):
    for path in ('/api/admin/notifications',):
        assert client.get(path).status_code in (401, 403)
    assert client.post('/api/admin/notifications/send',
                       json={'title': 'x'}).status_code in (401, 403)
