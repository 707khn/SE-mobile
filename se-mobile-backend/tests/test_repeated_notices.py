"""Повторное событие с тем же текстом — тоже оповещение.

Лента не писала второе оповещение с тем же видом, заголовком и текстом —
это нужно листкам, которые бухгалтерия выгружает повторно. Но так же
пропадали второй ответ расчётной группы («Вопрос №5: ответ расчётной
группы» — «сентябрь 2026»), второе напоминание по поручению и «заявка
выполнена» после «не помогло»: человек их не видел вовсе.
"""

import pytest
from werkzeug.security import generate_password_hash

import app as app_module
from models import db, Employee, Notification, UserAccount

_PERSON = '0000002107'      # есть в тестовой базе


@pytest.fixture
def clean(app):
    yield
    with app.app_context():
        Notification.query.filter(Notification.kind.in_(
            ('test_once', 'test_repeat', 'test_other'))).delete(synchronize_session=False)
        db.session.commit()


def _count(kind):
    return Notification.query.filter_by(kind=kind,
                                        employee_id=_PERSON).count()


def test_plain_notice_is_still_written_once(app, clean):
    with app.app_context():
        for _ in range(2):
            app_module._record_notice('test_once', 'Заголовок', 'Текст',
                                      employee_ids=[_PERSON])
        assert _count('test_once') == 1


def test_repeated_event_is_written_again_once_read(app, clean):
    with app.app_context():
        app_module._record_notice('test_repeat', 'Заголовок', 'Текст',
                                  employee_ids=[_PERSON], repeat=True)
        first = Notification.query.filter_by(kind='test_repeat').one()
        account = UserAccount.query.filter_by(employee_id=_PERSON).first()
        if account is None:
            pytest.skip('у тестового сотрудника нет учётной записи')
        before = account.notifications_seen_id
        account.notifications_seen_id = first.id
        db.session.commit()
        try:
            app_module._record_notice('test_repeat', 'Заголовок', 'Текст',
                                      employee_ids=[_PERSON], repeat=True)
            rows = (Notification.query.filter_by(kind='test_repeat')
                    .order_by(Notification.id).all())
            assert len(rows) == 2
            assert rows[-1].id > first.id
        finally:
            account.notifications_seen_id = before
            db.session.commit()


def test_unread_duplicate_is_lifted_not_doubled(app, clean):
    with app.app_context():
        app_module._record_notice('test_repeat', 'Заголовок', 'Текст',
                                  employee_ids=[_PERSON], repeat=True)
        first = Notification.query.filter_by(kind='test_repeat').one().id
        app_module._record_notice('test_other', 'Другое', 'Между ними',
                                  employee_ids=[_PERSON])
        app_module._record_notice('test_repeat', 'Заголовок', 'Текст',
                                  employee_ids=[_PERSON], repeat=True)
        rows = Notification.query.filter_by(kind='test_repeat').all()
        assert len(rows) == 1
        newest = (Notification.query.filter_by(employee_id=_PERSON)
                  .order_by(Notification.id.desc()).first())
        assert newest.kind == 'test_repeat'
        assert newest.id > first


def _auth(app, employee_id):
    with app.app_context():
        return {'Authorization': 'Bearer ' + app_module._issue_token(employee_id)}


def test_second_payroll_answer_reaches_the_author(app, client, clean):
    author = _auth(app, '0000002107')
    payroll = _auth(app, '0000001469')
    r = client.post('/api/payslip-questions', headers=author, json={
        'year': 2026, 'month': 9, 'text': 'Почему ИПН больше?'})
    assert r.status_code == 201, r.get_json()
    item_id = r.get_json()['item']['id']
    try:
        for text in ('Из-за премии', 'И ещё вычет'):
            # Автор прочитал прошлый ответ — следующий должен прийти заново.
            client.post('/api/notifications/seen', json={}, headers=author)
            r = client.post(f'/api/payslip-questions/{item_id}', headers=payroll,
                            json={'action': 'reply', 'text': text})
            assert r.status_code == 200, r.get_json()
        with app.app_context():
            answers = Notification.query.filter(
                Notification.kind == 'payslip_q',
                Notification.employee_id == '0000002107',
                Notification.title.like('%ответ расчётной группы')).count()
        assert answers == 2
    finally:
        from payslip_questions import PayslipQuestion, PayslipQuestionMessage
        with app.app_context():
            PayslipQuestionMessage.query.filter_by(question_id=item_id).delete()
            db.session.delete(db.session.get(PayslipQuestion, item_id))
            Notification.query.filter_by(kind='payslip_q').delete()
            db.session.commit()


@pytest.mark.parametrize('login, password', [
    ('450', '0000000450'),
    ('0000009450', '009450'),
])
def test_password_equal_to_number_in_other_form_is_refused(login, password):
    assert app_module._password_problem(password, login) == 'same_as_login'


def test_other_digit_passwords_still_allowed():
    assert app_module._password_problem('45019876', '450') is None
