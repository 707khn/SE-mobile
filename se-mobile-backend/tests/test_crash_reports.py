"""Ошибки и падения приложения, присланные с телефонов.

Прежде ошибка оставалась на телефоне, и о ней узнавали, только если человек
сам её пересылал. Здесь — что сервер принимает отчёт и без пропуска, что
повторы не плодят строк, что один телефон не завалит базу, что личное из
текста вычищается и что смотреть всё это может только администратор.
"""

import os
from datetime import timedelta

import app as app_module
from models import db, CrashReport

ADMIN_PASSWORD = os.environ['ADMIN_PASSWORD']


def _token(app, employee_id):
    with app.app_context():
        return app_module._issue_token(employee_id)


def _admin(app):
    with app.app_context():
        admin = app_module._authenticate('admin', ADMIN_PASSWORD)
        return {'Authorization': f'Bearer {app_module._issue_token(admin)}'}


def _clean(app):
    with app.app_context():
        CrashReport.query.delete()
        db.session.commit()


def _report(**extra):
    body = {'error': 'Null check operator used on a null value',
            'stack': '#0 _PayslipState.build (package:se_mobile/screens/'
                     'payslip_screen.dart:120:7)',
            'where': 'widgets library', 'version': '1.16.18 (51)',
            'platform': 'android 14', 'install': 'a1b2c3d4-e5f6'}
    body.update(extra)
    return body


def test_report_without_a_pass_is_taken(app, client):
    _clean(app)
    r = client.post('/api/crash', json=_report())
    assert r.status_code == 202
    with app.app_context():
        row = CrashReport.query.one()
        assert row.employee_id is None
        assert row.reporter == 'i:a1b2c3d4-e5f6'
        assert row.app_version == '1.16.18 (51)'


def test_report_with_a_pass_names_the_employee(app, client):
    _clean(app)
    token = _token(app, '0000001465')
    client.post('/api/crash', json=_report(),
                headers={'Authorization': f'Bearer {token}'})
    with app.app_context():
        assert CrashReport.query.one().employee_id == '0000001465'


def test_repeats_add_up_instead_of_new_rows(app, client):
    """Ошибка отрисовки бывает на каждом кадре: тысяча строк не нужна."""
    _clean(app)
    for line in (120, 121, 122):         # номер строки меняется — та же ошибка
        client.post('/api/crash', json=_report(
            stack=f'#0 build (package:se_mobile/x.dart:{line}:7)'))
    with app.app_context():
        rows = CrashReport.query.all()
        assert len(rows) == 1
        assert rows[0].count == 3


def test_one_phone_cannot_flood(app, client):
    _clean(app)
    limit = app_module._CRASH_KINDS_PER_REPORTER
    for i in range(limit + 5):
        r = client.post('/api/crash', json=_report(error=f'Ошибка {"x" * i}'))
        assert r.status_code == 202
    with app.app_context():
        assert CrashReport.query.count() == limit


def test_personal_numbers_are_scrubbed(app, client):
    _clean(app)
    client.post('/api/crash', json=_report(
        error='FormatException: 870101300123 user@se.kz +7 (777) 123-45-67 '
              'Bearer abc.def-123'))
    with app.app_context():
        error = CrashReport.query.one().error
    assert '870101300123' not in error
    assert 'user@se.kz' not in error
    assert '123-45-67' not in error
    assert 'abc.def' not in error
    assert error.startswith('FormatException')


def test_bad_bodies_are_refused_not_crashed(app, client):
    assert client.post('/api/crash', json={}).status_code == 400
    assert client.post('/api/crash', json=['x']).status_code == 400
    assert client.post('/api/crash', data='x' * 20000,
                       content_type='application/json').status_code == 413
    r = client.post('/api/crash', json=_report(error=12, install='../../etc'))
    assert r.status_code in (202, 400)


def test_old_reports_are_dropped(app, client):
    _clean(app)
    with app.app_context():
        old = app_module._plant_today() - timedelta(
            days=app_module._CRASH_KEEP_DAYS + 1)
        db.session.add(CrashReport(day=old, fingerprint='old', reporter='x',
                                   error='old'))
        db.session.commit()
    client.post('/api/crash', json=_report())
    with app.app_context():
        assert CrashReport.query.filter_by(fingerprint='old').count() == 0


def test_crashes_are_for_a_real_admin_only(app, client):
    """Без пропуска не пускаем даже в переходном режиме: там имена."""
    assert client.get('/api/admin/crashes').status_code == 403
    token = _token(app, '0000001465')        # начальник отдела, не админ
    assert client.get('/api/admin/crashes', headers={
        'Authorization': f'Bearer {token}'}).status_code == 403
    assert client.get('/api/admin/crashes',
                      headers=_admin(app)).status_code == 200


def test_admin_sees_groups_versions_and_names(app, client):
    _clean(app)
    token = _token(app, '0000001465')
    client.post('/api/crash', json=_report(),
                headers={'Authorization': f'Bearer {token}'})
    client.post('/api/crash', json=_report(install='zzzzzzzz-1111'))
    client.post('/api/crash', json=_report(error='Other', version='1.16.17 (50)'))

    body = client.get('/api/admin/crashes', headers=_admin(app)).get_json()
    top = body['groups'][0]
    assert top['people'] == 2
    assert top['count'] == 2
    assert any('Даурембекова' in n for n in top['names'])
    assert top['versions'] == ['1.16.18 (51)']
    assert body['days'][0]['people'] == 3     # двое выше и третий телефон
    versions = {v['version']: v for v in body['versions']}
    assert versions['1.16.17 (50)']['crashes'] == 1
    assert 'users' in versions['1.16.18 (51)']

    r = client.delete(f'/api/admin/crashes/{top["fingerprint"]}',
                      headers=_admin(app))
    assert r.get_json()['removed'] == 2
    body = client.get('/api/admin/crashes', headers=_admin(app)).get_json()
    assert len(body['groups']) == 1


def test_spike_is_people_not_rows(app):
    def days(today, usual):
        return [{'day': str(i), 'count': 0, 'people': today if i == 0 else usual}
                for i in range(8)]
    assert app_module._crash_spike(days(4, 0)) is None     # мало людей
    assert app_module._crash_spike(days(6, 3)) is None     # обычный день
    spike = app_module._crash_spike(days(10, 2))
    assert spike['people'] == 10 and spike['usual'] == 2


def test_rollout_shows_crashes_today(app, client):
    _clean(app)
    client.post('/api/crash', json=_report())
    body = client.get('/api/admin/rollout', headers=_admin(app)).get_json()
    assert body['crashes']['today'] == 1
    assert body['crashes']['spike'] is None
