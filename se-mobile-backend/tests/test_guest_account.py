"""Гостевая учётная запись (guest_account.py, demo.py).

Гостя показывают людям со стороны, поэтому проверяется три вещи. Под ним
есть что показать в каждом разделе. Он ничего не может изменить. И два
мира не смешиваются: гость не видит ни одного настоящего сотрудника, а
настоящие — ни гостя, ни его вымышленных людей, ни его данных; «загружено
по» и сводка свежести от гостя не сдвигаются.
"""

from datetime import date, datetime, timedelta

import pytest

import app as app_module
import demo
import guest_account
import reset_passwords
from assignments import Assignment
from business_trips import BusinessTrip
from medical_visits import MedicalSlot
from models import (db, AccessRecord, Employee, MenuDate, MenuItem,
                    Notification, Payslip, PayslipAccrual, UserAccount)
from planned_outages import Outage

_TODAY = date(2030, 11, 26)
_NOW = datetime(2030, 11, 26, 10, 30)

_ADMIN = 'ADMIN'
_CEO = '0000002183'         # генеральный директор, «Руководство»
_FINANCE = '0000002184'     # заместитель по экономике — видит всё предприятие
_ACCOUNTANT = '0000000137'  # бухгалтер — бухгалтерия командировок
_PAYROLL = '0000001469'     # бухгалтер расчётной группы
_MEDIC = '0000001977'       # медицинский работник
_IT = '0000001965'          # инженер-программист ОИТиС
_OFFICE = '0000002063'      # офис-менеджер приёмной
_WORKER = '0000000082'      # мастер ОП


def _output(capsys):
    return capsys.readouterr().out


def _password(output):
    for line in output.splitlines():
        if 'пароль:' in line:
            return line.split('пароль:')[1].strip()
    raise AssertionError(output)


def _freshness(app):
    with app.app_context():
        return {s['key']: (s.get('last'), s.get('rows'), s.get('people'))
                for s in app_module._data_freshness()}


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def _guest_rows():
    """Сколько чего лежит на людях гостевого мира — по всем таблицам."""
    ids = demo.world_ids()
    counts = {}
    for table, column in app_module._employee_referrers():
        if ids:
            n = db.session.execute(
                db.select(db.func.count()).select_from(table)
                .where(column.in_(ids))).scalar()
            if n:
                counts[f'{table.name}.{column.name}'] = n
    counts['employees'] = len(ids)
    return counts


@pytest.fixture(autouse=True)
def clock(monkeypatch):
    monkeypatch.setattr(app_module, '_plant_today', lambda: _TODAY)
    monkeypatch.setattr(app_module, '_plant_now', lambda: _NOW)


@pytest.fixture
def guest(app, client, capsys):
    """Гость заведён; после проверки — убран вместе со всем своим миром."""
    assert guest_account.main(['--apply'], application=app) == 0
    password = _password(_output(capsys))
    answer = client.post('/login', json={'login': '1', 'password': password}).get_json()
    assert answer['message'] == 'Success', answer
    yield {'password': password,
           'headers': {'Authorization': f"Bearer {answer['token']}"}}
    assert guest_account.main(['--remove'], application=app) == 0
    _output(capsys)


@pytest.fixture
def yesterday_menu(app):
    with app.app_context():
        day = _TODAY - timedelta(days=1)
        menu = MenuDate(date=day)
        db.session.add(menu)
        db.session.flush()
        for name in ('Борщ', 'Плов', 'Компот'):
            db.session.add(MenuItem(menu_date_id=menu.id, category='Обед',
                                    name=name, price=500))
        db.session.commit()
        menu_id = menu.id
    yield
    with app.app_context():
        menu = db.session.get(MenuDate, menu_id)
        db.session.delete(menu)
        db.session.commit()


def test_every_section_has_something_to_show(app, client, guest, yesterday_menu):
    h = guest['headers']
    me = client.get('/api/me', headers=h).get_json()
    assert (me['full_name'], me['job'], me['manager']) == (
        'Миняев Владислав', 'Генеральный директор', True)

    home = client.post('/api/home', json={}, headers=h).get_json()
    assert home['access']['date'] == _TODAY.isoformat()     # пришёл сегодня
    assert home['payslip'] == {'year': 2030, 'month': 10}
    assert home['leave']['remaining_days'] == 23
    # Сегодня меню нет — гостю показывают вчерашнее.
    assert home['menu']['dishes'] == ['Борщ', 'Плов', 'Компот']
    menu = client.get('/api/menu', headers=h).get_json()
    assert [i['name'] for i in menu['items']] == ['Борщ', 'Плов', 'Компот']

    periods = client.post('/payslip/periods', json={'key_suffix': demo.GUEST_ID},
                          headers=h).get_json()['periods']
    assert len(periods) == 10 and periods[0] == {'year': 2030, 'month': 10}
    slip = client.post('/payslip', json={'key_suffix': demo.GUEST_ID,
                                         'year': 2030, 'month': 10},
                       headers=h).get_json()['payslip']
    assert slip['total_accruals'] == 1_200_000
    # ОПВ 10 %, ВОСМС 2 %, ИПН 10 % после них и 30 МРП.
    assert slip['net_pay'] == 963_375
    july = client.post('/payslip', json={'key_suffix': demo.GUEST_ID,
                                         'year': 2030, 'month': 7},
                       headers=h).get_json()['payslip']
    assert any('отпуска' in a['name'] for a in july['accruals'])
    xlsx = client.post('/payslip/xlsx', json={'key_suffix': demo.GUEST_ID,
                                              'year': 2030, 'month': 10},
                       headers=h)
    assert xlsx.status_code == 200

    leaves = client.post('/leaves', json={'key_suffix': demo.GUEST_ID},
                         headers=h).get_json()['leaves']
    assert {h_['start_date'][:4] for h_ in leaves['history']} == {'2030'}
    assert len(leaves['balances']) == 2

    passes = client.post('/reportdate', json={
        'key_suffix': demo.GUEST_ID, 'start_date': '2030-11-01',
        'end_date': '2030-11-26'}, headers=h).get_json()
    assert passes['report'] and passes['coverage']['loaded_until'] == '2030-11-26'
    assert all('турникет' in p['door'] for p in passes['report'])

    names = client.post('/get_sname', json={'key_suffix': demo.GUEST_ID},
                        headers=h).get_json()['fio']
    assert 'Ким Артём Олегович' in names
    staff = client.post('/director_report', json={
        'emp_sname': 'Ким Артём Олегович', 'start_date': '2030-11-01',
        'end_date': '2030-11-26'}, headers=h).get_json()
    assert staff['director_report']

    trips = client.get('/api/trips', headers=h).get_json()['items']
    assert [t['destination'] for t in trips] == ['Лос-Анджелес, США']
    trip = client.get(f"/api/trips/{trips[0]['id']}", headers=h).get_json()['item']
    assert trip['status'] == 'reported' and len(trip['expenses']) == 4

    mine = client.get('/api/assignments', headers=h).get_json()
    given = client.get('/api/assignments?scope=given', headers=h).get_json()
    assert len(mine['items']) == 2 and len(given['items']) == 5
    assert given['counts']['given_overdue'] == 1

    medical = client.get('/api/medical', headers=h).get_json()
    assert {e['kind'] for e in medical['exams']} == {
        'periodic', 'fluorography', 'vaccination'}
    assets = client.get('/api/it-assets/mine', headers=h).get_json()['items']
    assert len(assets) == 3
    outages = client.get('/api/outages', headers=h).get_json()['items']
    assert len(outages) == 1
    questions = client.get('/api/payslip-questions', headers=h).get_json()['items']
    assert [q['status'] for q in questions] == ['answered']

    directory = client.get('/api/directory', headers=h).get_json()['entries']
    assert directory and all(e['email'].endswith('@example.com') or not e['email']
                             for e in directory)
    assert all(not e['mobile'] for e in directory)

    notices = client.get('/api/notifications', headers=h).get_json()['items']
    assert len(notices) == 8
    unread = client.get('/api/notifications/unread', headers=h).get_json()
    assert unread['unread'] == 3


def test_guest_cannot_change_anything(app, client, guest):
    h = guest['headers']
    with app.app_context():
        before = _guest_rows()
        assignment = Assignment.query.filter_by(assignee_id=demo.GUEST_ID).first().id
        slot = MedicalSlot(starts_at=_NOW + timedelta(days=1), kind='exam')
        db.session.add(slot)
        db.session.commit()
        slot_id = slot.id
    try:
        writes = [
            ('post', '/api/assignments', {'title': 'Тест', 'assignee_ids': [
                'GUEST00003'], 'due_date': '2030-12-10'}),
            ('post', f'/api/assignments/{assignment}', {'action': 'done',
                                                        'comment': 'Сделал'}),
            ('post', '/api/trips', {'destination': 'Астана', 'purpose': 'Тест',
                                    'date_from': '2030-12-01',
                                    'date_to': '2030-12-02'}),
            ('post', f'/api/medical/slots/{slot_id}/book', {}),
            ('post', '/api/payslip-questions', {'year': 2030, 'month': 10,
                                                'text': 'Вопрос'}),
            ('post', '/change-password', {'old_password': guest['password'],
                                          'new_password': 'Другой2030пароль'}),
            ('post', '/api/fcm-token', {'token': 'phone-token'}),
            ('post', '/api/telegram/link', {}),
            ('post', '/api/it-requests', {'category': 'printer', 'room': '201',
                                          'description': 'Не печатает'}),
            ('delete', '/api/telegram', None),
        ]
        for method, path, body in writes:
            answer = getattr(client, method)(path, json=body, headers=h)
            assert answer.status_code == 403, path
            assert answer.get_json()['error'] == 'demo_read_only', path
        # А то, что ходит POST-ом, но только читает, — отвечает.
        for path, body in (('/report', {'key_suffix': demo.GUEST_ID}),
                           ('/api/home', {}),
                           ('/payslip/periods', {'key_suffix': demo.GUEST_ID}),
                           ('/leaves', {'key_suffix': demo.GUEST_ID}),
                           ('/api/notifications/seen', {})):
            assert client.post(path, json=body, headers=h).status_code == 200, path
        with app.app_context():
            assert _guest_rows() == before
            assert db.session.get(MedicalSlot, slot_id).employee_id is None
        # Пароль прежний: смена не прошла.
        assert client.post('/login', json={
            'login': '1', 'password': guest['password']}).get_json()['message'] \
            == 'Success'
    finally:
        with app.app_context():
            db.session.delete(db.session.get(MedicalSlot, slot_id))
            db.session.commit()


def test_read_only_exceptions_are_real_routes(app):
    """Пропуск на запись — по имени маршрута; опечатка закрыла бы раздел."""
    methods = {}
    for rule in app.url_map.iter_rules():
        methods.setdefault(rule.endpoint, set()).update(rule.methods)
    for name in demo.READ_BY_POST:
        assert name in methods, name
        assert methods[name] & {'POST', 'DELETE'}, name


def test_guest_does_not_see_real_people(app, client, guest):
    h = guest['headers']
    with app.app_context():
        ceo = db.session.get(Employee, _CEO)
        ceo_name = ceo.full_name
        app_module._record_notice('general', 'Объявление для всех', 'Только своим')
        db.session.add(Outage(kind='power', starts_at=_NOW + timedelta(days=1),
                              ends_at=_NOW + timedelta(days=1, hours=2),
                              departments='', author_id=_IT, reminded=True))
        db.session.commit()
    try:
        names = client.post('/get_sname', json={'key_suffix': demo.GUEST_ID},
                            headers=h).get_json()['fio']
        assert ceo_name not in names
        assert set(names) <= {row[1] for row in demo.STAFF}
        # По ФИО настоящего — «не найден», а не «нет доступа»: и само
        # существование человека гостю не подтверждается.
        found = client.post('/director_report', json={
            'emp_sname': ceo_name, 'start_date': '2030-11-01',
            'end_date': '2030-11-26'}, headers=h).get_json()
        assert found.get('error') == 'not_found'
        assert client.post('/report', json={'key_suffix': _CEO},
                           headers=h).status_code == 403
        assert client.post('/payslip/periods', json={'key_suffix': _CEO},
                           headers=h).status_code == 403

        people = client.get('/api/assignments/people', headers=h).get_json()['people']
        assert people and all(demo.is_demo_id(p['id']) for p in people)
        reception = client.get('/api/reception', headers=h).get_json()
        assert reception['hosts'] == []
        outages = client.get('/api/outages', headers=h).get_json()['items']
        assert [o['author']['id'] for o in outages] == ['GUEST00006']
        notices = client.get('/api/notifications', headers=h).get_json()['items']
        assert 'Объявление для всех' not in {n['title'] for n in notices}
    finally:
        with app.app_context():
            Notification.query.filter_by(title='Объявление для всех').delete()
            Outage.query.filter_by(author_id=_IT, kind='power').delete()
            db.session.commit()


def test_staff_do_not_see_the_guest(app, client, guest):
    with app.app_context():
        # Командировка вымышленного зама — на согласовании: её увидел бы
        # настоящий генеральный директор, будь миры общими.
        db.session.add(BusinessTrip(
            employee_id='GUEST00003', destination='Астана', purpose='Тест',
            date_from=_TODAY + timedelta(days=5), date_to=_TODAY + timedelta(days=6),
            transport='train', status='pending'))
        db.session.commit()
    guest_names = {row[1] for row in demo.STAFF}

    def names(rows, key='name'):
        return {r[key] for r in rows}

    admin = _auth(app, _ADMIN)
    fio = client.post('/get_sname', json={'key_suffix': _ADMIN},
                      headers=admin).get_json()['fio']
    assert fio and not guest_names & set(fio)
    fio = client.post('/get_sname', json={'key_suffix': _FINANCE},
                      headers=_auth(app, _FINANCE)).get_json()['fio']
    assert fio and not guest_names & set(fio)

    payroll = _auth(app, _PAYROLL)
    months = client.get('/api/payslips/periods', headers=payroll).get_json()['items']
    assert (2030, 10) not in {(m['year'], m['month']) for m in months}
    listed = client.get('/api/payslips/periods/2030/10', headers=payroll).get_json()
    assert listed['items'] == []
    # Удаление месяца бухгалтерией листок гостя не задевает.
    assert client.delete('/api/payslips/periods/2030/10',
                         headers=payroll).status_code == 404
    queue = client.get('/api/payslip-questions?scope=queue',
                       headers=payroll).get_json()
    assert not any(demo.is_demo_id(q['author']['id']) for q in queue['items'])

    ceo = _auth(app, _CEO)
    pending = client.get('/api/trips?scope=approve', headers=ceo).get_json()['items']
    assert not any(demo.is_demo_id(t['employee']['id']) for t in pending)
    people = client.get('/api/assignments/people', headers=ceo).get_json()['people']
    assert people and not names(people) & guest_names
    accounting = client.get('/api/trips?scope=accounting',
                            headers=_auth(app, _ACCOUNTANT)).get_json()['items']
    assert not any(demo.is_demo_id(t['employee']['id']) for t in accounting)

    medic = _auth(app, _MEDIC)
    desk = client.get('/api/medical/desk', headers=medic).get_json()
    assert not any(demo.is_demo_id(e['employee']['id']) for e in desk['due'])
    found = client.get('/api/medical/people', headers=medic).get_json()['people']
    assert found and not names(found) & guest_names
    departments = client.get('/api/medical/departments',
                             headers=medic).get_json()['departments']
    assert not any('(демо)' in d['name'] for d in departments)

    it = _auth(app, _IT)
    assets = client.get('/api/it-assets', headers=it).get_json()['items']
    assert not any(a['inventory_no'].startswith('ДЕМО') for a in assets)
    found = client.get('/api/it-assets/people', headers=it).get_json()['people']
    assert found and not names(found) & guest_names
    departments = client.get('/api/outages/departments',
                             headers=it).get_json()['departments']
    assert departments and not any('(демо)' in d for d in departments)

    worker = _auth(app, _WORKER)
    outages = client.get('/api/outages', headers=worker).get_json()['items']
    assert not any(o['author'] and demo.is_demo_id(o['author']['id'])
                   for o in outages)
    entries = client.get('/api/directory', headers=worker).get_json()['entries']
    assert not any(e['email'].endswith('@example.com') for e in entries)
    hosts = client.get('/api/reception', headers=_auth(app, _OFFICE)).get_json()['hosts']
    assert not names(hosts) & guest_names

    with app.app_context():
        # Вымышленный тёзка не забирает настоящие проходы из выгрузки СКУД.
        result = app_module._import_access_passes([{
            'name': 'Миняев Владислав', 'department': 'Руководство',
            'door': 'Турникет 1', 'at': datetime(2030, 11, 26, 8, 0)}],
            dry_run=True)
        assert result['unmatched_people'] == 1
        # Логин «1» гостевой — табельный 1 из списка кадров к гостю не липнет.
        assert app_module._resolve_employee_id('1') == '1'
        # Массовый сброс паролей гостя не трогает.
        targets, skipped = reset_passwords.plan(app_module, set(), set())
        assert '1' not in {t['account'].login for t in targets}
        assert skipped['demo'] == 1
        BusinessTrip.query.filter_by(employee_id='GUEST00003').delete()
        db.session.commit()


def test_freshness_does_not_move(app, capsys):
    """Проходы гостя идут по сегодня, листки — по прошлый месяц. В сводке
    свежести и в «загружено по» у настоящих людей это не должно отразиться."""
    before = _freshness(app)
    with app.app_context():
        app_module._access_loaded_until['checked_at'] = None
        until = app_module._loaded_until()
    try:
        assert guest_account.main(['--apply'], application=app) == 0
        assert _freshness(app) == before
        with app.app_context():
            assert app_module._loaded_until() == until
            assert app_module._loaded_until(guest=True) == _TODAY
    finally:
        assert guest_account.main(['--remove'], application=app) == 0
    _output(capsys)


def test_refresh_keeps_password_and_phones(app, client, guest, capsys):
    with app.app_context():
        before = _guest_rows()
    assert guest_account.main(['--apply'], application=app) == 0
    assert 'прежний' in _output(capsys)
    # Вошедший телефон не выкинуло, пароль прежний, дублей нет.
    assert client.get('/api/me', headers=guest['headers']).status_code == 200
    assert client.post('/login', json={
        'login': '1', 'password': guest['password']}).get_json()['message'] == 'Success'
    with app.app_context():
        after = _guest_rows()
    # Пропусков стало на один больше — от входа выше; остальное — как было.
    before.pop('auth_tokens.employee_id', None)
    after.pop('auth_tokens.employee_id', None)
    assert after == before

    assert guest_account.main(['--apply', '--new-password'], application=app) == 0
    password = _password(_output(capsys))
    assert password != guest['password']
    assert client.get('/api/me', headers=guest['headers']).status_code == 401
    assert client.post('/login', json={'login': '1', 'password': password}) \
        .get_json()['message'] == 'Success'


def test_dry_run_changes_nothing(app, capsys):
    with app.app_context():
        assert not demo.world_ids()
    assert guest_account.main([], application=app) == 0
    assert 'Пробный прогон' in _output(capsys)
    with app.app_context():
        assert not demo.world_ids()
        assert db.session.get(UserAccount, '1') is None


def test_remove_leaves_nothing_behind(app, capsys):
    assert guest_account.main(['--apply'], application=app) == 0
    assert guest_account.main(['--remove'], application=app) == 0
    _output(capsys)
    with app.app_context():
        assert _guest_rows() == {'employees': 0}
        assert db.session.get(UserAccount, '1') is None
        assert Employee.query.filter(Employee.employee_id.like('GUEST%')).count() == 0
        # Строки листков ушли вместе с листками, а не повисли.
        orphans = PayslipAccrual.query.filter(
            ~PayslipAccrual.payslip_id.in_(db.session.query(Payslip.id))).count()
        assert orphans == 0
        assert AccessRecord.query.filter(
            AccessRecord.employee_id.like('GUEST%')).count() == 0


@pytest.mark.parametrize('taken', ['account', 'employee'])
def test_does_not_take_a_real_number(app, capsys, remove_employee, taken):
    """Логин 1 у настоящего сотрудника или настоящий табельный 1 — не трогаем."""
    from werkzeug.security import generate_password_hash
    with app.app_context():
        if taken == 'account':
            db.session.add(UserAccount(login='1', employee_id=_WORKER,
                                       password_hash=generate_password_hash('x'),
                                       must_change_password=True))
        else:
            db.session.add(Employee(employee_id=remove_employee('0000000001'),
                                    full_name='Настоящий Первый', job_title='Слесарь'))
        db.session.commit()
    try:
        assert guest_account.main(['--apply'], application=app) == 1
        with app.app_context():
            assert not demo.world_ids()
    finally:
        with app.app_context():
            row = db.session.get(UserAccount, '1')
            if row is not None and row.employee_id == _WORKER:
                db.session.delete(row)
                db.session.commit()
    _output(capsys)
