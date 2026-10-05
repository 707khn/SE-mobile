"""Учётная запись для проверяющих Google Play.

Без входа в приложении ничего не видно, и Google просит логин и пароль,
чтобы его проверить. Давать им настоящего сотрудника нельзя: проверяющий
увидел бы чужую зарплату и проходы. Поэтому здесь заводится вымышленный
сотрудник со своими листками и проходами.

Запуск на сервере (переменные окружения — те же, что у службы):

    sudo bash -c 'set -a; . /etc/se-mobile.env; set +a; \\
        /opt/se-mobile/venv/bin/python /opt/se-mobile/se-mobile-backend/review_account.py'

Печатает логин и пароль — их вписывают в Play Console: «Содержание
приложения» → «Доступ к приложению». Повторный запуск заводит всё заново с
новым паролем. `--remove` убирает учётную запись и все её данные.

Свежесть данных (экран «Обновление») это не сдвигает: листки ложатся в
месяцы, которые в базе уже есть, а проходы — в дни, которые уже загружены.
"""

import argparse
import random
import sys
from datetime import date, timedelta

from werkzeug.security import generate_password_hash

LOGIN = 'review'
EMPLOYEE_ID = 'REVIEW'
FULL_NAME = 'Проверка Google Play'

_MONTHS = ('Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль',
           'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь')


def _previous_months(year, month, count):
    """Последние `count` месяцев, кончая данным, — от старого к новому."""
    months = []
    for _ in range(count):
        months.append((year, month))
        year, month = (year, month - 1) if month > 1 else (year - 1, 12)
    return list(reversed(months))


def remove(app_module, db, Employee):
    """Убрать вымышленного сотрудника и всё, что на него ссылается.

    Ссылающиеся таблицы берём из описания моделей, как и рабочий код:
    перечисленные руками рано или поздно разошлись бы с жизнью.
    """
    for table, column in app_module._employee_referrers():
        db.session.execute(table.delete().where(column == EMPLOYEE_ID))
    row = db.session.get(Employee, EMPLOYEE_ID)
    if row is not None:
        db.session.delete(row)
    db.session.commit()


def create(app_module, db, models):
    (Employee, UserAccount, Payslip, PayslipAccrual, PayslipDeduction,
     AccessRecord, LeaveBalance) = models

    db.session.add(Employee(employee_id=EMPLOYEE_ID, full_name=FULL_NAME,
                            job_title='Инженер',
                            department='Учётная запись для проверки'))
    password = app_module._random_password()
    db.session.add(UserAccount(
        login=LOGIN, employee_id=EMPLOYEE_ID,
        password_hash=generate_password_hash(password),
        # Проверяющий не должен упираться в обязательную смену пароля: он
        # её не пройдёт, а пароль из Play Console перестал бы подходить.
        must_change_password=False, is_active=True))

    # Листки — в последние три месяца, за которые в базе уже есть листки.
    latest = (db.session.query(Payslip.period_year, Payslip.period_month)
              .order_by(Payslip.period_year.desc(),
                        Payslip.period_month.desc()).first())
    today = app_module._plant_today()
    year, month = latest if latest else (today.year, today.month)
    rate = 320000
    for y, m in _previous_months(year, month, 3):
        accruals = [('Оклад', rate), ('Надбавка за стаж', round(rate * 0.05))]
        if m % 3 == 0:
            accruals.append(('Премия квартальная', 60000))
        gross = sum(a for _, a in accruals)
        deductions = [('ОПВ (10%)', round(gross * 0.10)),
                      ('ВОСМС (2%)', round(gross * 0.02)),
                      ('ИПН (10%)', round(gross * 0.088))]
        withheld = sum(d for _, d in deductions)
        slip = Payslip(employee_id=EMPLOYEE_ID, period_month=m, period_year=y,
                       period_display=f'{_MONTHS[m - 1]} {y}',
                       total_accruals=gross, total_deductions=withheld,
                       net_pay=gross - withheld, position='Инженер',
                       department='Учётная запись для проверки',
                       salary_rate=rate, total_paid=gross - withheld)
        db.session.add(slip)
        db.session.flush()
        for name, amount in accruals:
            db.session.add(PayslipAccrual(payslip_id=slip.id, name=name,
                                          amount=amount))
        for name, amount in deductions:
            db.session.add(PayslipDeduction(payslip_id=slip.id, name=name,
                                            amount=amount))

    # Проходы — рабочие дни последних трёх недель, кончая последним
    # загруженным днём.
    last = db.session.query(db.func.max(AccessRecord.access_date)).scalar()
    day = last or today
    rng = random.Random(EMPLOYEE_ID)
    added = 0
    while added < 15:
        if day.weekday() < 5:
            came = f'07:{rng.randint(40, 58):02d}'
            left = f'17:{rng.randint(2, 25):02d}'
            db.session.add(AccessRecord(employee_id=EMPLOYEE_ID, access_date=day,
                                        access_time=came, event_type='Вход',
                                        door_location='Проходная №1'))
            db.session.add(AccessRecord(employee_id=EMPLOYEE_ID, access_date=day,
                                        access_time=left, event_type='Выход',
                                        door_location='Проходная №1'))
            added += 1
        day -= timedelta(days=1)

    db.session.add(LeaveBalance(employee_id=EMPLOYEE_ID,
                                leave_type='Ежегодный трудовой отпуск',
                                total_days=24, used_days=10, remaining_days=14))
    db.session.commit()
    return password


def main(argv=None, application=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--remove', action='store_true',
                        help='убрать учётную запись и её данные')
    args = parser.parse_args(argv)

    import app as app_module
    from models import (db, Employee, UserAccount, Payslip, PayslipAccrual,
                        PayslipDeduction, AccessRecord, LeaveBalance)

    application = application or app_module.create_app()
    with application.app_context():
        # Логин «review» не должен оказаться чьим-то настоящим.
        taken = db.session.get(UserAccount, LOGIN)
        if taken is not None and taken.employee_id != EMPLOYEE_ID:
            print(f'Логин {LOGIN!r} уже занят сотрудником {taken.employee_id} — '
                  'ничего не меняю.', file=sys.stderr)
            return 1

        remove(app_module, db, Employee)
        if args.remove:
            print('Учётная запись для проверки удалена.')
            return 0

        password = create(app_module, db,
                          (Employee, UserAccount, Payslip, PayslipAccrual,
                           PayslipDeduction, AccessRecord, LeaveBalance))
        print('Учётная запись для проверяющих Google Play:')
        print(f'  логин:  {LOGIN}')
        print(f'  пароль: {password}')
        print('Впишите их в Play Console → «Содержание приложения» → '
              '«Доступ к приложению».')
    return 0


if __name__ == '__main__':
    sys.exit(main())
