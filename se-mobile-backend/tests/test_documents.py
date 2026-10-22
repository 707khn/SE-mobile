"""Документы предприятия: выкладка, скачивание, «ознакомлен» и кто ещё нет."""

import io
import os

import pytest

import app as app_module
import documents
from models import db

ADMIN_PASSWORD = os.environ['ADMIN_PASSWORD']

_ORDINARY = '0000002114'     # Сарсекенов, техник-программист
_SECRETARY = '0000000083'    # Бейсекина, корпоративный секретарь
_HEAD_OF_IT = '0000001465'   # Даурембекова, начальник ОИТиС

_PDF = b'%PDF-1.4\n% test\n'


def _headers(app, employee_id):
    with app.app_context():
        return {'Authorization': f'Bearer {app_module._issue_token(employee_id)}'}


def _upload(client, headers=None, **fields):
    data = {'title': 'Приказ о режиме работы', 'category': 'order',
            'number': '45-к', 'date': '2026-10-20', 'requires_ack': '1'}
    data.update(fields)
    if 'file' not in data:
        data['file'] = (io.BytesIO(_PDF), 'Приказ №45.pdf')
    return client.post('/api/admin/documents', data=data, headers=headers or {},
                       content_type='multipart/form-data')


@pytest.fixture
def cleanup(app):
    yield
    with app.app_context():
        for doc in documents.Document.query.all():
            documents.delete_document(doc)


def test_secretary_uploads_and_everyone_sees_it(app, client, cleanup):
    response = _upload(client, _headers(app, _SECRETARY))
    assert response.status_code == 200, response.get_json()
    doc_id = response.get_json()['item']['id']

    listed = client.get('/api/documents', headers=_headers(app, _ORDINARY)).get_json()
    item = next(i for i in listed['items'] if i['id'] == doc_id)
    assert item['title'] == 'Приказ о режиме работы'
    assert item['number'] == '45-к'
    assert item['date'] == '2026-10-20'
    assert item['requires_ack'] and not item['acked']
    assert listed['pending'] == 1
    assert listed['can_edit'] is False

    file = client.get(f'/api/documents/{doc_id}/file',
                      headers=_headers(app, _ORDINARY))
    assert file.status_code == 200
    assert file.data == _PDF
    assert file.mimetype == 'application/pdf'
    assert 'no-store' in file.headers['Cache-Control']


def test_ordinary_employee_cannot_upload(app, client, cleanup):
    response = _upload(client, _headers(app, _ORDINARY))
    assert response.status_code == 403
    with app.app_context():
        assert documents.Document.query.count() == 0


def test_desktop_tool_uploads_with_login_and_password(app, client, cleanup):
    response = _upload(client, login='admin', password=ADMIN_PASSWORD,
                       requires_ack='0', category='template', title='')
    assert response.status_code == 200, response.get_json()
    item = response.get_json()['item']
    # Без названия — имя файла без расширения.
    assert item['title'] == 'Приказ №45'
    assert item['category'] == 'template'
    assert not item['requires_ack']


def test_wrong_password_is_refused(app, client, cleanup):
    response = _upload(client, login='admin', password='не тот')
    assert response.status_code == 401


def test_executables_and_huge_files_are_refused(app, client, cleanup):
    headers = _headers(app, _SECRETARY)
    bad = _upload(client, headers, file=(io.BytesIO(b'MZ'), 'setup.exe'))
    assert bad.status_code == 400
    assert bad.get_json()['error'] == 'bad_type'

    big = _upload(client, headers, file=(
        io.BytesIO(b'0' * (documents.MAX_BYTES + 1)), 'scan.pdf'))
    assert big.status_code == 413

    empty = _upload(client, headers, file=(io.BytesIO(b''), 'scan.pdf'))
    assert empty.status_code == 400

    with app.app_context():
        assert documents.Document.query.count() == 0


def test_file_name_cannot_carry_a_path(app, client, cleanup):
    response = _upload(client, _headers(app, _SECRETARY),
                       file=(io.BytesIO(_PDF), '../../etc/график.pdf'))
    assert response.get_json()['item']['filename'] == 'график.pdf'


def test_ack_is_recorded_once_and_shown_to_the_editor(app, client, cleanup):
    doc_id = _upload(client, _headers(app, _SECRETARY)).get_json()['item']['id']
    reader = _headers(app, _ORDINARY)

    first = client.post(f'/api/documents/{doc_id}/ack', headers=reader).get_json()
    again = client.post(f'/api/documents/{doc_id}/ack', headers=reader).get_json()
    assert first['item']['acked']
    # Повторное нажатие не сдвигает время первой отметки.
    assert again['item']['acked_at'] == first['item']['acked_at']

    listed = client.get('/api/documents', headers=reader).get_json()
    assert listed['pending'] == 0

    report = client.get(f'/api/admin/documents/{doc_id}/acks',
                        headers=_headers(app, _SECRETARY)).get_json()
    acked_ids = [p['employee_id'] for p in report['acked']]
    waiting_ids = {p['employee_id'] for p in report['waiting']}
    assert acked_ids == [_ORDINARY]
    assert _ORDINARY not in waiting_ids
    assert report['expected'] == len(report['waiting']) + 1
    # Служебной записи администратора читать некому.
    assert app_module._ADMIN_EMPLOYEE_ID not in waiting_ids


def test_ack_report_is_closed_to_ordinary_staff(app, client, cleanup):
    doc_id = _upload(client, _headers(app, _SECRETARY)).get_json()['item']['id']
    response = client.get(f'/api/admin/documents/{doc_id}/acks',
                          headers=_headers(app, _ORDINARY))
    assert response.status_code == 403


def test_editor_changes_and_deletes(app, client, cleanup):
    editor = _headers(app, _SECRETARY)
    doc_id = _upload(client, editor).get_json()['item']['id']
    client.post(f'/api/documents/{doc_id}/ack', headers=_headers(app, _ORDINARY))

    changed = client.post(f'/api/admin/documents/{doc_id}', headers=editor,
                          json={'title': 'Новое название', 'category': 'regulation',
                                'requires_ack': False}).get_json()['item']
    assert changed['title'] == 'Новое название'
    assert changed['category'] == 'regulation'
    assert not changed['requires_ack']

    assert client.delete(f'/api/admin/documents/{doc_id}',
                         headers=editor).status_code == 200
    with app.app_context():
        assert db.session.get(documents.Document, doc_id) is None
        assert documents.DocumentAck.query.filter_by(document_id=doc_id).count() == 0
        assert db.session.get(documents.DocumentFile, doc_id) is None
    assert client.get(f'/api/documents/{doc_id}/file',
                      headers=editor).status_code == 404


def test_head_of_department_is_not_an_editor(app, client, cleanup):
    """Начальник отдела видит проходы своих — но приказы не выкладывает."""
    assert _upload(client, _headers(app, _HEAD_OF_IT)).status_code == 403


def test_who_may_edit():
    assert documents.may_edit('Администратор системы')
    assert documents.may_edit('Корпоративный секретарь')
    assert documents.may_edit('Специалист по кадрам')
    assert not documents.may_edit('Техник-программист')
    assert not documents.may_edit('')


def test_new_document_lands_in_the_notice_feed(app, client, cleanup):
    from models import Notification
    doc_id = _upload(client, _headers(app, _SECRETARY)).get_json()['item']['id']
    with app.app_context():
        notice = (Notification.query.filter_by(kind='document', ref=str(doc_id))
                  .order_by(Notification.id.desc()).first())
        assert notice is not None
        assert notice.title == 'Новый приказ — ознакомьтесь'
        assert notice.body == 'Приказ о режиме работы'
        db.session.delete(notice)
        db.session.commit()
