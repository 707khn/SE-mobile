"""Оповещения в самом приложении — колокольчик на главном экране.

Пуш через Firebase не настроен, а смахнутый пуш пропадает. Поэтому то же
сообщение пишется в ленту: «расчётный лист готов», «меню выложено»,
объявление. Здесь — что каждый видит своё и только своё, что прочитанное
не возвращается и что администратор видит поломки сервера, пока их не
починят.
"""

import io
import os
from datetime import date, datetime, timedelta

import pytest

import app as app_module
from models import db, Notification, UserAccount, NewsItem

ADMIN_PASSWORD = os.environ['ADMIN_PASSWORD']
_ADMIN_HEADERS = {'X-Admin-Token': os.environ['ADMIN_TOKEN']}
_TEST_XML = os.path.join(os.path.dirname(__file__), '..', 'test_payslip.xml')

_KUMAROVA = '0000001874'          # есть в test_payslip.xml
_DAUREMBEKOVA = '0000001465'      # листка в файле нет


def _bearer(app, employee_id):
    with app.app_context():
        return {'Authorization': f'Bearer {app_module._issue_token(employee_id)}'}


def _admin(app):
    with app.app_context():
        admin = app_module._authenticate('admin', ADMIN_PASSWORD)
    return _bearer(app, admin)


def _feed(client, headers):
    answer = client.get('/api/notifications', headers=headers)
    assert answer.status_code == 200
    return answer.get_json()


def _upload_payslips(client):
    with open(_TEST_XML, 'rb') as f:
        content = f.read()
    return client.post('/api/admin/upload-payslip-xml',
                       data={'file': (io.BytesIO(content), 'test_payslip.xml')},
                       content_type='multipart/form-data',
                       headers=_ADMIN_HEADERS)


@pytest.fixture
def clean_notices(app):
    """Оповещения, записанные проверкой, — убрать за собой."""
    with app.app_context():
        before = db.session.query(db.func.max(Notification.id)).scalar() or 0
    yield
    with app.app_context():
        Notification.query.filter(Notification.id > before).delete()
        # SQLite отдаёт освободившиеся номера заново, и отметка «дочитал до»,
        # оставшаяся от удалённых, спрятала бы следующей проверке её же
        # оповещения.
        UserAccount.query.filter(
            UserAccount.notifications_seen_id > before
        ).update({UserAccount.notifications_seen_id: before})
        db.session.commit()


def test_without_a_pass_there_is_nothing_to_show(client):
    # Чьи оповещения отдавать, без пропуска не узнать — даже пока проверка
    # пропуска не обязательна.
    assert client.get('/api/notifications').status_code == 401
    assert client.get('/api/notifications/unread').status_code == 401
    assert client.post('/api/notifications/seen', json={}).status_code == 401


def test_payslip_notice_reaches_only_its_owner(app, client, clean_notices):
    assert _upload_payslips(client).status_code == 200

    own = _feed(client, _bearer(app, _KUMAROVA))
    texts = [i['body'] for i in own['items'] if i['kind'] == 'payslip']
    assert texts, 'оповещения о листке нет'
    assert texts[0].startswith('Расчётный лист за ')
    assert own['items'][0]['unread'] is True

    # Чужой листок — чужое дело.
    other = _feed(client, _bearer(app, _DAUREMBEKOVA))
    assert not [i for i in other['items'] if i['kind'] == 'payslip'
                and i['body'] in texts]


def test_reuploaded_payslips_do_not_repeat_the_notice(app, client, clean_notices):
    _upload_payslips(client)
    with app.app_context():
        once = Notification.query.filter_by(
            kind='payslip', employee_id=_KUMAROVA).count()
    _upload_payslips(client)
    with app.app_context():
        twice = Notification.query.filter_by(
            kind='payslip', employee_id=_KUMAROVA).count()
    assert once >= 1
    assert twice == once


def test_announcement_is_for_everyone_and_reading_clears_the_bell(
        app, client, clean_notices):
    person = _bearer(app, _DAUREMBEKOVA)
    client.post('/api/notifications/seen', json={}, headers=person)
    assert client.get('/api/notifications/unread',
                      headers=person).get_json()['unread'] == 0

    created = client.post('/api/admin/news', headers=_admin(app),
                          json={'title': 'Отключение воды в корпусе 2',
                                'summary': 'С 10 до 12'})
    assert created.status_code == 200
    news_id = created.get_json()['item']['id']

    feed = _feed(client, person)
    assert feed['unread'] == 1
    top = feed['items'][0]
    assert (top['kind'], top['title'], top['body'], top['ref']) == \
        ('news', 'Объявление', 'Отключение воды в корпусе 2', str(news_id))
    # Обычному сотруднику — никаких поломок сервера.
    assert feed['system'] == []

    seen = client.post('/api/notifications/seen',
                       json={'last_id': top['id']}, headers=person)
    assert seen.get_json()['unread'] == 0
    assert _feed(client, person)['items'][0]['unread'] is False

    # Отметка не идёт назад: телефон без связи прислал старый номер.
    client.post('/api/notifications/seen', json={'last_id': 1}, headers=person)
    assert client.get('/api/notifications/unread',
                      headers=person).get_json()['unread'] == 0

    with app.app_context():
        db.session.delete(db.session.get(NewsItem, news_id))
        db.session.commit()


def test_seen_cannot_run_ahead_of_the_feed(app, client, clean_notices):
    """Номер из будущего не прячет оповещения, которых ещё нет."""
    person = _bearer(app, _DAUREMBEKOVA)
    client.post('/api/notifications/seen', json={'last_id': 10 ** 9},
                headers=person)
    with app.app_context():
        app_module._record_notice('news', 'Объявление', 'Субботник')
    assert client.get('/api/notifications/unread',
                      headers=person).get_json()['unread'] == 1

    bad = client.post('/api/notifications/seen', json={'last_id': 'много'},
                      headers=person)
    assert bad.status_code == 400


def test_old_notices_do_not_light_the_bell(app, client, clean_notices):
    """Новому сотруднику на колокольчике не «47» — только свежее."""
    person = _bearer(app, _DAUREMBEKOVA)
    client.post('/api/notifications/seen', json={}, headers=person)
    with app.app_context():
        db.session.add(Notification(
            kind='news', title='Объявление', body='Давнее',
            created_at=datetime.utcnow() - timedelta(days=30)))
        db.session.commit()
    feed = _feed(client, person)
    assert feed['unread'] == 0
    # В ленте оно есть, просто не считается новым.
    assert any(i['body'] == 'Давнее' for i in feed['items'])


def test_queued_announcement_is_shown_to_admins_only(app, client, clean_notices):
    answer = client.post('/api/news/announcements', json={
        'login': 'admin', 'password': ADMIN_PASSWORD,
        'title': 'Письмо из профкома', 'message_id': 'notice-test-1'})
    assert answer.status_code == 200
    item_id = answer.get_json()['id']

    admin = _feed(client, _admin(app))
    queued = [i for i in admin['items'] if i['kind'] == 'queue']
    assert queued and queued[0]['body'] == 'Письмо из профкома'
    assert queued[0]['ref'] == str(item_id)

    person = _feed(client, _bearer(app, _DAUREMBEKOVA))
    assert not [i for i in person['items'] if i['kind'] == 'queue']

    with app.app_context():
        db.session.delete(db.session.get(NewsItem, item_id))
        db.session.commit()


def test_new_menu_day_is_announced_once(app, client, clean_notices):
    day = '2031-01-15'
    items = [{'category': 'Первое блюдо', 'name': 'Шорпа', 'price': 700.0}]
    client.post('/api/menu', json={'date': day, 'items': items})
    # Поправили цену — того же дня второй раз не объявляем.
    client.post('/api/menu', json={'date': day, 'items': items})

    with app.app_context():
        notices = Notification.query.filter_by(kind='menu', ref=day).all()
        assert len(notices) == 1
        assert notices[0].body == 'Меню на 15.01 опубликовано'
    client.delete(f'/api/menu/{day}')


def test_menu_notice_names_the_day(monkeypatch):
    monkeypatch.setattr(app_module, '_plant_today', lambda: date(2026, 10, 22))
    text = app_module._menu_notice_text
    assert text([date(2026, 10, 22)]) == 'Меню на сегодня опубликовано'
    assert text([date(2026, 10, 23)]) == 'Меню на завтра опубликовано'
    assert text([date(2026, 10, 30)]) == 'Меню на 30.10 опубликовано'
    assert text([date(2026, 10, 27), date(2026, 10, 23)]) == \
        'Меню на завтра – 27.10 опубликовано'


def test_admin_sees_what_is_broken_on_the_server(app, client, monkeypatch,
                                                  tmp_path):
    # Копий нет вовсе — это поломка, и о ней должен знать администратор.
    monkeypatch.setenv('BACKUP_DIR', str(tmp_path))
    admin = _admin(app)
    system = _feed(client, admin)['system']
    assert 'backup' in {p['key'] for p in system}
    assert client.get('/api/notifications/unread',
                      headers=admin).get_json()['system'] == len(system)

    # Починили — пропало само: это состояние, а не строка в ленте.
    (tmp_path / f'se_mobile_{date.today():%Y-%m-%d}.sql.gz.enc').write_bytes(b'x')
    system = _feed(client, admin)['system']
    assert 'backup' not in {p['key'] for p in system}

    # Остальным — ничего.
    person = _bearer(app, _DAUREMBEKOVA)
    assert client.get('/api/notifications/unread',
                      headers=person).get_json()['system'] == 0


def test_fresh_outage_is_reported_and_old_one_is_not(app, client, monkeypatch,
                                                     tmp_path):
    log = tmp_path / 'outages.log'
    monkeypatch.setattr(app_module, '_WATCHDOG_LOG', str(log))
    admin = _admin(app)

    old = (datetime.now() - timedelta(days=3)).astimezone().isoformat(
        timespec='seconds')
    log.write_text(f'{old} восстановился после 3 неудач подряд\n',
                   encoding='utf-8')
    assert 'outage' not in {p['key'] for p in _feed(client, admin)['system']}

    fresh = datetime.now().astimezone().isoformat(timespec='seconds')
    log.write_text(f'{fresh} перезапущен после 3 неудач подряд\n',
                   encoding='utf-8')
    outage = [p for p in _feed(client, admin)['system'] if p['key'] == 'outage']
    assert outage and 'перезапущен' in outage[0]['body']


def test_seen_mark_is_kept_per_account(app, client, clean_notices):
    person = _bearer(app, _DAUREMBEKOVA)
    with app.app_context():
        app_module._record_notice('news', 'Объявление', 'Отметка')
    client.post('/api/notifications/seen', json={}, headers=person)
    with app.app_context():
        account = UserAccount.query.filter_by(
            employee_id=_DAUREMBEKOVA).first()
        newest = db.session.query(db.func.max(Notification.id)).scalar()
        assert account.notifications_seen_id == newest
