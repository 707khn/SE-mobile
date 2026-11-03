"""Уведомления на телефоны: что уходит в Firebase и что из этого следует.

Сам Firebase здесь не нужен: подменяем отправку и смотрим, какое сообщение
собрано, кому оно ушло и что сервер сделал с ответом.
"""

from types import SimpleNamespace

import pytest

pytest.importorskip('firebase_admin')

import app as app_module  # noqa: E402
from firebase_admin import messaging as fb_messaging  # noqa: E402
from models import db, Employee, FcmToken  # noqa: E402

_PEOPLE = ('PUSH0001', 'PUSH0002', 'PUSH0003')


@pytest.fixture
def phones(app, remove_employee):
    """Три сотрудника, у каждого по телефону."""
    with app.app_context():
        for employee_id in _PEOPLE:
            remove_employee(employee_id)
            db.session.add(Employee(employee_id=employee_id,
                                    full_name='Пуш Тест Тестович',
                                    job_title='Слесарь'))
        db.session.flush()
        for employee_id in _PEOPLE:
            db.session.add(FcmToken(employee_id=employee_id,
                                    token=f'tok-{employee_id}'))
        db.session.commit()
    yield {e: f'tok-{e}' for e in _PEOPLE}


@pytest.fixture
def firebase(monkeypatch):
    """Firebase «настроен», а отправка записывает, что ей дали.

    `answers` — что ответить на каждый токен: None — доставлено, иначе
    исключение, как его кладёт в ответ firebase-admin.
    """
    sent = []
    answers = {}

    def _send(message, dry_run=False, app=None):
        sent.append(message)
        responses = []
        for token in message.tokens:
            error = answers.get(token)
            responses.append(SimpleNamespace(success=error is None,
                                             exception=error))
        return SimpleNamespace(responses=responses)

    monkeypatch.setattr(app_module, '_get_firebase', lambda: object())
    monkeypatch.setattr(fb_messaging, 'send_each_for_multicast', _send)
    return SimpleNamespace(sent=sent, answers=answers)


def test_each_kind_lands_in_its_own_channel(app, phones, firebase):
    """Канал по поводу — чтобы «Столовую» можно было выключить отдельно от
    «Зарплаты». Без канала Android при закрытом приложении кладёт всё в
    «Прочее»."""
    with app.app_context():
        app_module._push_to(['PUSH0001'], 'Зарплата', 'Готов',
                            {'type': 'payslip'})
        app_module._push_to(['PUSH0001'], 'Что-то', 'Ещё')

    payslip, other = firebase.sent
    assert payslip.android.notification.channel_id == 'payslip_channel'
    assert payslip.android.priority == 'high'
    assert payslip.data == {'type': 'payslip'}
    assert other.android.notification.channel_id == 'general_channel'


def test_dead_tokens_are_dropped_and_live_ones_kept(app, phones, firebase):
    """Снесённое приложение — токен долой. Прочие отказы — нет: так же
    отвечают и на ошибку в самом сообщении, и стёрлись бы токены у всех."""
    firebase.answers[phones['PUSH0001']] = fb_messaging.UnregisteredError(
        'приложение удалено')
    firebase.answers[phones['PUSH0002']] = fb_messaging.SenderIdMismatchError(
        'другой проект')
    from firebase_admin import exceptions
    firebase.answers[phones['PUSH0003']] = exceptions.InvalidArgumentError(
        'кривое сообщение')

    with app.app_context():
        sent = app_module._push_to(list(_PEOPLE), 'Т', 'т')
        left = {t.token for t in FcmToken.query.filter(
            FcmToken.employee_id.in_(_PEOPLE)).all()}

    assert sent == 0
    assert left == {phones['PUSH0003']}


def test_nothing_is_sent_without_firebase(app, phones, monkeypatch):
    monkeypatch.setattr(app_module, '_get_firebase', lambda: None)
    with app.app_context():
        assert app_module._push_to(list(_PEOPLE), 'Т', 'т') == 0


def test_turnstile_pushes_nobody_by_default(app, monkeypatch):
    """Прежде каждый проход уходил всем начальникам — по пятьсот
    уведомлений в пересменку каждому. Теперь только названным явно."""
    monkeypatch.delenv('TURNSTILE_PUSH_TO', raising=False)
    calls = []
    monkeypatch.setattr(app_module, '_push_to',
                        lambda *a, **k: calls.append(a) or 1)
    with app.app_context():
        app_module._send_turnstile_notification('Иванов И.', 'in', '08:00',
                                                '0000002114')
    assert calls == []


def test_turnstile_pushes_to_the_named(app, monkeypatch):
    monkeypatch.setenv('TURNSTILE_PUSH_TO', '2114, 9999999')
    calls = []
    monkeypatch.setattr(app_module, '_push_to',
                        lambda *a, **k: calls.append(a) or 1)
    with app.app_context():
        app_module._send_turnstile_notification('Иванов И.', 'out', '17:05',
                                                '0000002114')
    (recipients, title, body, data), = calls
    # Логин без ведущих нулей — тот же человек, что в базе с нулями.
    assert '0000002114' in recipients
    assert body == 'Иванов И. вышел в 17:05'
    assert data['type'] == 'turnstile'


def test_announcement_text_stays_off_the_push(app, client, monkeypatch):
    """Текст внутреннего объявления — в ленте приложения, а не в пуше: всё,
    что в пуше, проходит через серверы Google."""
    pushed = []
    monkeypatch.setattr(app_module, '_notify_later',
                        lambda app_, fn, *a, **k: pushed.append(a))
    with app.app_context():
        admin = app_module._authenticate('admin',
                                         __import__('os').environ['ADMIN_PASSWORD'])
        token = app_module._issue_token(admin)
    title = 'Сокращение смены в цехе №3 с 1 декабря'
    answer = client.post('/api/admin/news',
                         headers={'Authorization': f'Bearer {token}'},
                         json={'title': title, 'summary': 'Подробности'})
    assert answer.status_code == 200

    (push_title, body, data), = pushed
    assert title not in body and title not in push_title
    assert data['type'] == 'news'

    with app.app_context():
        from models import NewsItem
        item = db.session.get(NewsItem, answer.get_json()['item']['id'])
        db.session.delete(item)
        db.session.commit()


def test_rollout_says_why_pushes_are_off(app, client, monkeypatch, tmp_path):
    monkeypatch.setenv('FIREBASE_CREDENTIALS_PATH',
                       str(tmp_path / 'нет-такого.json'))
    monkeypatch.setattr(app_module, '_fb_app', None)
    state = app_module._push_state()
    assert state['enabled'] is False
    assert 'нет ключа Firebase' in state['problem']


def test_rollout_counts_phones_when_on(app, phones, monkeypatch, tmp_path):
    key = tmp_path / 'key.json'
    key.write_text('{}')
    monkeypatch.setenv('FIREBASE_CREDENTIALS_PATH', str(key))
    monkeypatch.setattr(app_module, '_get_firebase', lambda: object())
    with app.app_context():
        state = app_module._push_state()
    assert state['enabled'] is True
    assert state['devices'] >= 3
    assert state['people'] >= 3
