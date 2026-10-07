"""Список «Отчёта сотрудников»: кого руководитель может выбрать.

Он должен совпадать с тем, чей отчёт руководителю разрешено открыть, и не
зависеть от табельного номера, присланного в запросе. Данные вымышленные.
"""

import app as app_module
from models import db, Employee

_BOSS = 'SNAME0001'
_MINE = 'SNAME0002'
_OTHER = 'SNAME0003'


def _setup(app, remove_employee):
    with app.app_context():
        for employee_id, name, job, dept in (
                (_BOSS, 'Начальников Тест', 'Начальник отдела', 'Отдел А'),
                (_MINE, 'Своих Тест', 'Инженер', 'Отдел А'),
                (_OTHER, 'Чужих Тест', 'Инженер', 'Отдел Б')):
            remove_employee(employee_id)
            db.session.add(Employee(employee_id=employee_id, full_name=name,
                                    job_title=job, department=dept))
        db.session.commit()
        return {who: app_module._issue_token(who)
                for who in (_BOSS, _MINE)}


def _names(client, token, key_suffix):
    return client.post('/get_sname', json={'key_suffix': key_suffix},
                       headers={'Authorization': f'Bearer {token}'})


def test_manager_sees_own_department_whatever_number_is_sent(
        app, client, remove_employee):
    tokens = _setup(app, remove_employee)

    own = _names(client, tokens[_BOSS], _BOSS).get_json()['fio']
    assert own == ['Своих Тест']

    # Чужой номер в запросе ничего не меняет: список — по тому, кто спросил.
    spoofed = _names(client, tokens[_BOSS], _OTHER).get_json()['fio']
    assert spoofed == own


def test_ordinary_employee_gets_no_list(app, client, remove_employee):
    tokens = _setup(app, remove_employee)
    assert _names(client, tokens[_MINE], _MINE).status_code == 403
