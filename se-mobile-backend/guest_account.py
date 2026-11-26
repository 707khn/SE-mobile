"""Гостевая учётная запись: вымышленный генеральный директор со своими данными.

Логин 1 — «Миняев Владислав, генеральный директор». Под ним приложение
выглядит живым во всех разделах: расчётные листки за год с окладом
1 200 000 ₸, отпуска и больничный этого года, командировка в Лос-Анджелес,
проходы через турникет — свои и сотрудников, поручения, вопрос по листку,
медосмотры, техника, плановое отключение, справочник и оповещения. Меню
столовой гость видит настоящее: в день, когда меню ещё нет, — последнее
выложенное, обычно вчерашнее.

Всё это — вымышленный мир (demo.py). Гость не видит ни одного настоящего
сотрудника, настоящие сотрудники не видят гостя, а менять гость не может
ничего: только смотреть.

Запуск на сервере — одной строкой, без кавычек и скобок:

    sudo /opt/se-mobile/venv/bin/python /opt/se-mobile/se-mobile-backend/guest_account.py

Так — пробный прогон: покажет, что будет сделано, и ничего не изменит. С
--apply в конце — заводит и печатает логин и пароль. В базе лежит только
хеш пароля, поэтому пароль виден один раз — сразу запишите.

Повторный запуск с --apply сдвигает даты на сегодня (проходы, сроки
поручений, медосмотр, командировку) и оставляет прежний пароль и вход на
телефонах. Ещё ключи:

  --new-password   выдать новый пароль; со старым больше не войти;
  --password X     свой пароль вместо случайного: от 8 знаков;
  --login N        другой логин — например, если табельный 1 когда-нибудь
                   достанется настоящему сотруднику;
  --remove         убрать гостя и весь вымышленный мир.
"""

import argparse
import os
import random
import sys
from datetime import date, datetime, time, timedelta

# Сервер: настройки — те же, что у службы, а сам скрипт может лежать где
# угодно (например, в /tmp). Читаем их сами, чтобы команда обходилась без
# кавычек: в терминале, откуда её запускают, их нет.
_BACKEND = '/opt/se-mobile/se-mobile-backend'
_ENV_FILE = '/etc/se-mobile.env'

LOGIN = '1'
RATE = 1_200_000

# Казахстан, 2026: МРП, МЗП и ставки — то, из чего 1С считает листок.
_MRP = 4_325
_MZP = 85_000
_OPV = 0.10            # обязательные пенсионные взносы, предел — 50 МЗП
_VOSMS = 0.02          # взносы на медстрахование, предел — 20 МЗП
_IPN = 0.10
_OPVR = 0.035          # пенсионные взносы работодателя — справочно
_BASE_DEDUCTION = 30 * _MRP
_SICK_CAP = 15 * _MRP  # больничный за счёт работодателя — не больше в месяц
_PER_DIEM = 8 * _MRP   # суточные за границей без налога — на день

_MONTHS = ('Январь', 'Февраль', 'Март', 'Апрель', 'Май', 'Июнь', 'Июль',
           'Август', 'Сентябрь', 'Октябрь', 'Ноябрь', 'Декабрь')
_SHORT = ('Янв', 'Фев', 'Мар', 'Апр', 'Май', 'Июн', 'Июл', 'Авг', 'Сен',
          'Окт', 'Ноя', 'Дек')

# Праздники РК. Выпавший на выходной переносится на следующий рабочий
# день; 7 января — религиозный праздник, он не переносится, как и Курбан
# айт (его день — по лунному календарю, свой у каждого года).
_HOLIDAYS = ((1, 1), (1, 2), (1, 7), (3, 8), (3, 21), (3, 22), (3, 23),
             (5, 1), (5, 7), (5, 9), (7, 6), (8, 30), (10, 25), (12, 16))
_NOT_MOVED = {(1, 7)}
_KURBAN_AIT = {2026: date(2026, 5, 27)}

# Чьи проходы и как: приход, уход (часы, минуты), разброс в минутах и
# обеденный выход. У председателя совета директоров проходов нет.
_SCHEDULES = {
    'GUEST00001': ((8, 35), (18, 40), 20, False),
    'GUEST00002': ((8, 15), (18, 30), 15, False),
    'GUEST00003': ((7, 40), (17, 55), 10, False),
    'GUEST00004': ((8, 45), (18, 5), 12, True),
    'GUEST00005': ((8, 52), (18, 0), 18, True),
    'GUEST00006': ((8, 40), (18, 20), 15, True),
    'GUEST00007': ((9, 0), (18, 35), 20, False),
    'GUEST00008': ((7, 50), (16, 10), 8, False),
    'GUEST00009': ((7, 30), (17, 35), 10, False),
    'GUEST00010': ((8, 20), (17, 45), 10, True),
}
_PASS_DAYS = 62
_DOOR_IN = 'Проходная, турникет 1'
_DOOR_OUT = 'Проходная, турникет 2'

# Таблицы, без которых гость перестал бы входить: их обновление не трогает.
_KEEP_FOR_LOGIN = ('user_accounts', 'auth_tokens', 'qr_logins')


def _server_settings():
    if os.path.exists(_ENV_FILE):
        with open(_ENV_FILE, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                key, value = line.split('=', 1)
                key = key.strip()
                if key.startswith('export '):
                    key = key[len('export '):].strip()
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in '"\'':
                    value = value[1:-1]
                os.environ[key] = value
    if os.path.isdir(_BACKEND):
        os.chdir(_BACKEND)
        if _BACKEND not in sys.path:
            sys.path.insert(0, _BACKEND)


# ── Календарь ────────────────────────────────────────────────────────────────

def holidays(year):
    days = {date(year, m, d) for m, d in _HOLIDAYS}
    if year in _KURBAN_AIT:
        days.add(_KURBAN_AIT[year])
    moved = set()
    for m, d in _HOLIDAYS:
        day = date(year, m, d)
        if day.weekday() < 5 or (m, d) in _NOT_MOVED:
            continue
        nxt = day + timedelta(days=1)
        while nxt.weekday() >= 5 or nxt in days or nxt in moved:
            nxt += timedelta(days=1)
        moved.add(nxt)
    return days | moved


def _working(day, off):
    return day.weekday() < 5 and day not in off


def _days(start, end):
    day = start
    while day <= end:
        yield day
        day += timedelta(days=1)


def _month_days(year, month):
    start = date(year, month, 1)
    end = (date(year + 1, 1, 1) if month == 12 else date(year, month + 1, 1)) \
        - timedelta(days=1)
    return start, end


# ── Что заводится ────────────────────────────────────────────────────────────

def _leaves(year, today):
    """Отпуска и больничный этого года: (вид, с, по, дней, состояние)."""
    off = holidays(year)
    rows = []
    for kind, start, end in (
            ('Больничный лист', date(year, 2, 16), date(year, 2, 20)),
            ('Экологический отпуск', date(year, 5, 18), date(year, 5, 24)),
            ('Ежегодный трудовой отпуск', date(year, 7, 13), date(year, 7, 26)),
            ('Ежегодный трудовой отпуск', date(year, 12, 21), date(year, 12, 27))):
        sick = kind == 'Больничный лист'
        if sick and end >= today:
            continue    # больничный наперёд не бывает
        # Праздник внутри отпуска в его дни не входит.
        days = (end - start).days + 1 if sick else sum(
            1 for d in _days(start, end) if d not in off)
        if sick:
            state = 'Закрыт'
        else:
            state = 'Утверждён' if start <= today else 'Запланирован'
        rows.append((kind, start, end, days, state))
    return rows


def _balances(leaves, today):
    used = {'Ежегодный трудовой отпуск': 0, 'Экологический отпуск': 0}
    for kind, start, _end, days, _state in leaves:
        if kind in used and start <= today:
            used[kind] += days
    total = {'Ежегодный трудовой отпуск': 30, 'Экологический отпуск': 14}
    return [(kind, total[kind], used[kind], total[kind] - used[kind])
            for kind in total]


def _trip_dates(today, leaves):
    """Неделя в Лос-Анджелесе месяц с небольшим назад — не поверх отпуска."""
    start = today - timedelta(days=40)
    while any(start <= l_end and l_start <= start + timedelta(days=6)
              for _k, l_start, l_end, _d, _s in leaves):
        start -= timedelta(days=7)
    return start, start + timedelta(days=6)


def _bonus(month):
    """Премия по итогам квартала: план за II квартал перевыполнен, за III —
    выполнен на 96 % (об этом и вопрос по листку)."""
    return {3: 300_000, 6: 330_000, 9: 288_000}.get(month, 0)


def _payslip(year, month, leaves, previous_net):
    """Листок за месяц так, как его кладёт выгрузка из 1С."""
    off = holidays(year)
    first, last = _month_days(year, month)
    norm = [d for d in _days(first, last) if _working(d, off)]
    average = RATE / 29.3      # среднедневной для отпускных
    label = f'{_SHORT[month - 1]} {year % 100:02d}'

    accruals, absent = [], set()
    for kind, start, end, days, _state in leaves:
        inside = [d for d in _days(max(start, first), min(end, last))]
        if not inside:
            continue
        span = (f'{inside[0].day}-{inside[-1].day} {_SHORT[month - 1]} '
                f'{year % 100:02d}')
        workdays = [d for d in inside if _working(d, off)]
        absent.update(workdays)
        if kind == 'Больничный лист':
            accruals.append(('Оплата больничных листов', span, len(workdays),
                             len(workdays) * 8.0,
                             min(round(average * len(inside), 2), _SICK_CAP)))
        else:
            name = ('Оплата экологического отпуска' if kind.startswith('Эколог')
                    else 'Оплата ежегодного трудового отпуска')
            paid_days = sum(1 for d in inside if d not in off)
            accruals.append((name, span, paid_days, None,
                             round(average * paid_days, 2)))
    worked = [d for d in norm if d not in absent]
    accruals.insert(0, ('Оклад по дням', label, len(worked), len(worked) * 8.0,
                        round(RATE * len(worked) / len(norm), 2)))
    if _bonus(month):
        accruals.append(('Премия по итогам квартала', label, None, None,
                         float(_bonus(month))))

    gross = round(sum(a[4] for a in accruals), 2)
    opv = round(min(gross, 50 * _MZP) * _OPV, 2)
    vosms = round(min(gross, 20 * _MZP) * _VOSMS, 2)
    ipn = round(max(gross - opv - vosms - _BASE_DEDUCTION, 0) * _IPN, 2)
    deductions = [('ИПН исчисленный', label, ipn),
                  ('ОПВ исчисленные', label, opv),
                  ('ВОСМС исчисленные', label, vosms)]
    net = round(gross - opv - vosms - ipn, 2)

    # Зарплату за месяц перечисляют пятого числа следующего: в этом листке —
    # выплата за прошлый, а долг на конец — заработанное в этом.
    pay_day = date(year, month, 5)
    while not _working(pay_day, off):
        pay_day += timedelta(days=1)
    prev_y, prev_m = (year, month - 1) if month > 1 else (year - 1, 12)
    paid = [('Перечислено в банк', f'{_SHORT[prev_m - 1]} {prev_y % 100:02d}',
             f'Платёжное поручение № {200 + month * 7}',
             pay_day.strftime('%d.%m.%Y'), previous_net)]
    return {
        'period_display': f'{_MONTHS[month - 1]} {year}',
        'accruals': accruals, 'deductions': deductions, 'paid': paid,
        'gross': gross, 'withheld': round(opv + vosms + ipn, 2), 'net': net,
        'opv': opv, 'opvr': round(min(gross, 50 * _MZP) * _OPVR, 2),
        'debt_start': previous_net, 'debt_end': net,
        'total_paid': previous_net,
    }


def payslips(year, last_month, leaves):
    """Листки с января по `last_month` включительно, с суммами с начала года."""
    # Декабрь прошлого года — обычный месяц без отпусков и премии: с него
    # переходит долг на начало января.
    previous = _payslip(year - 1, 12, [], 0.0)['net']
    out, totals = [], {'gross': 0.0, 'opv': 0.0, 'opvr': 0.0, 'deductions': 0.0}
    for month in range(1, last_month + 1):
        slip = _payslip(year, month, leaves, previous)
        for key in ('gross', 'opv', 'opvr'):
            totals[key] = round(totals[key] + slip[key], 2)
        totals['deductions'] += _BASE_DEDUCTION
        slip['reference'] = [
            ('Начисленный доход с начала года', totals['gross']),
            ('ОПВ с начала года', totals['opv']),
            ('Вычеты с начала года', float(totals['deductions'])),
            ('ОПВР за месяц', slip['opvr']),
            ('ОПВР с начала года', totals['opvr']),
        ]
        out.append((month, slip))
        previous = slip['net']
    return out


def _clock(base, spread, rng):
    minutes = base[0] * 60 + base[1] + rng.randint(-spread, spread)
    return time(minutes // 60, minutes % 60)


def passes(employee_id, today, now, away):
    """Проходы за два месяца, кончая сегодняшним утром: (день, время, вход?)."""
    came, left, spread, lunch = _SCHEDULES[employee_id]
    off = holidays(today.year) | holidays(today.year - 1)
    rows = []
    for day in _days(today - timedelta(days=_PASS_DAYS), today):
        if not _working(day, off) or day in away:
            continue
        rng = random.Random(f'{employee_id}{day.isoformat()}')
        events = [(_clock(came, spread, rng), True)]
        if lunch and rng.random() < 0.6:
            out_at = _clock((13, 0), 10, rng)
            back = datetime.combine(day, out_at) + timedelta(minutes=40)
            events += [(out_at, False), (back.time(), True)]
        events.append((_clock(left, spread, rng), False))
        for moment, entering in events:
            if day == today and moment > now.time():
                break       # что ещё не наступило, турникет не видел
            rows.append((day, moment.strftime('%H:%M'), entering))
    return rows


def _absences(today, trip, leaves):
    """Кого когда не было: у гостя — отпуска и командировка, у пары
    сотрудников — больничный и несколько дней отпуска."""
    guest = set()
    for _kind, start, end, _days_n, _state in leaves:
        guest.update(_days(start, end))
    guest.update(_days(*trip))
    week = today - timedelta(days=today.weekday())
    return {
        'GUEST00001': guest,
        'GUEST00007': set(_days(week - timedelta(days=14),
                                week - timedelta(days=12))),
        'GUEST00005': set(_days(week - timedelta(days=35),
                                week - timedelta(days=31))),
    }


# ── База ─────────────────────────────────────────────────────────────────────

def wipe(app_module, db, keep_account=False):
    """Убрать всё гостевого мира. `keep_account` — кроме входа гостя."""
    import demo
    from sqlalchemy import or_
    from models import Employee, Payslip, UserAccount
    from assignments import Assignment, AssignmentEvent
    from business_trips import BusinessTrip, BusinessTripEvent, TripExpense
    from payslip_questions import PayslipQuestion, PayslipQuestionMessage

    ids = sorted(demo.world_ids())
    if not ids:
        return 0
    # Листки — через ORM: строки начислений уходят следом и там, где база
    # сама каскадом не удаляет (SQLite в тестах).
    for slip in Payslip.query.filter(Payslip.employee_id.in_(ids)).all():
        db.session.delete(slip)
    db.session.flush()
    # Строки, которые ссылаются не на сотрудника, а на запись, — до неё.
    for parent, child, column, owners in (
            (BusinessTrip, TripExpense, 'trip_id', (BusinessTrip.employee_id,)),
            (BusinessTrip, BusinessTripEvent, 'trip_id', (BusinessTrip.employee_id,)),
            (Assignment, AssignmentEvent, 'assignment_id',
             (Assignment.author_id, Assignment.assignee_id)),
            (PayslipQuestion, PayslipQuestionMessage, 'question_id',
             (PayslipQuestion.employee_id,))):
        parents = [pid for (pid,) in db.session.query(parent.id).filter(
            or_(*(c.in_(ids) for c in owners)))]
        if parents:
            child.query.filter(getattr(child, column).in_(parents)).delete(
                synchronize_session=False)
    keep = _KEEP_FOR_LOGIN if keep_account else ()
    for table, column in app_module._employee_referrers():
        if table.name not in keep:
            db.session.execute(table.delete().where(column.in_(ids)))
    kept = ({a.employee_id for a in UserAccount.query.filter(
        UserAccount.employee_id.in_(ids))} if keep_account else set())
    for emp in Employee.query.filter(Employee.employee_id.in_(ids)).all():
        if emp.employee_id not in kept:
            db.session.delete(emp)
    db.session.flush()
    return len(ids)


def create(app_module, db, today, now):
    """Завести вымышленный мир. Возвращает, сколько чего заведено."""
    import demo
    from models import (Employee, Payslip, PayslipAccrual, PayslipDeduction,
                        PayslipPaid, PayslipBenefit, PayslipReference,
                        AccessRecord, LeaveBalance, LeaveHistory, Notification,
                        UserAccount)
    from assignments import Assignment, AssignmentEvent
    from business_trips import BusinessTrip, BusinessTripEvent, TripExpense
    from payslip_questions import PayslipQuestion, PayslipQuestionMessage
    from medical_visits import MedicalExam
    from it_assets import ItAsset
    from planned_outages import Outage

    guest = demo.GUEST_ID
    utc_now = datetime.utcnow()

    def ago(days, hours=0):
        return utc_now - timedelta(days=days, hours=hours)

    for emp_id, name, title, department, _ext, _mail in demo.STAFF:
        emp = db.session.get(Employee, emp_id)
        if emp is None:
            emp = Employee(employee_id=emp_id)
            db.session.add(emp)
        emp.full_name, emp.job_title, emp.department = name, title, department
    db.session.flush()
    counts = {'сотрудников': len(demo.STAFF)}

    # Отпуска этого года. «Этот год» — год прошлого месяца: в январе листки
    # и отпуска ещё прошлогодние.
    last = today.replace(day=1) - timedelta(days=1)
    year = last.year
    leaves = _leaves(year, today)
    for kind, start, end, days, state in leaves:
        db.session.add(LeaveHistory(employee_id=guest, leave_type=kind,
                                    start_date=start, end_date=end, days=days,
                                    status=state))
    for kind, total, used, left in _balances(leaves, today):
        db.session.add(LeaveBalance(employee_id=guest, leave_type=kind,
                                    total_days=total, used_days=used,
                                    remaining_days=left))
    counts['отпусков и больничных'] = len(leaves)

    # Листки с января по прошлый месяц.
    slips = {}
    for month, s in payslips(year, last.month, leaves):
        ps = Payslip(employee_id=guest, period_month=month, period_year=year,
                     period_display=s['period_display'],
                     total_accruals=s['gross'], total_deductions=s['withheld'],
                     net_pay=s['net'], position='Генеральный директор',
                     department='Руководство', salary_rate=float(RATE),
                     debt_start=s['debt_start'], debt_end=s['debt_end'],
                     total_paid=s['total_paid'])
        db.session.add(ps)
        db.session.flush()
        slips[month] = ps
        for name, period, days, hours, amount in s['accruals']:
            db.session.add(PayslipAccrual(payslip_id=ps.id, name=name,
                                          amount=amount, period=period,
                                          working_days=days, working_hours=hours))
        for name, period, amount in s['deductions']:
            db.session.add(PayslipDeduction(payslip_id=ps.id, name=name,
                                            amount=amount, period=period))
        for kind, period, document, when, amount in s['paid']:
            db.session.add(PayslipPaid(payslip_id=ps.id, payment_type=kind,
                                       period=period, document=document,
                                       date=when, amount=amount))
        db.session.add(PayslipBenefit(payslip_id=ps.id, name='Базовый вычет',
                                      amount=float(_BASE_DEDUCTION)))
        for name, amount in s['reference']:
            db.session.add(PayslipReference(payslip_id=ps.id, name=name,
                                            amount=amount))
    counts['расчётных листков'] = len(slips)

    # Командировка в Лос-Анджелес: отчёт сдан, ждёт проверки бухгалтерии.
    trip_from, trip_to = _trip_dates(today, leaves)
    asked = datetime.combine(trip_from, time(6)) - timedelta(days=21)
    reported = datetime.combine(trip_to, time(6)) + timedelta(days=4)
    trip = BusinessTrip(
        employee_id=guest, destination='Лос-Анджелес, США',
        organization='Отраслевая выставка промышленного оборудования',
        purpose='Переговоры с поставщиками оборудования для модернизации '
                'цеха № 2, посещение выставки',
        date_from=trip_from, date_to=trip_to, transport='plane',
        advance_requested=2_500_000, advance_issued=2_500_000,
        status='reported', approver_id='GUEST00002', accountant_id='GUEST00004',
        created_at=asked, updated_at=reported, reported_at=reported)
    db.session.add(trip)
    db.session.flush()
    for category, amount, document in (
            ('travel', 1_450_000, 'Авиабилеты Алматы — Лос-Анджелес — Алматы'),
            ('lodging', 780_000, 'Гостиница, 6 ночей, счёт № 58214'),
            ('per_diem', 7 * _PER_DIEM, 'Суточные, 7 дней по 8 МРП'),
            ('other', 95_000, 'Виза и медицинская страховка')):
        db.session.add(TripExpense(trip_id=trip.id, category=category,
                                   amount=amount, document=document))
    for actor, action, comment, at in (
            (guest, 'created', None, asked),
            ('GUEST00002', 'approve', 'Согласовано', asked + timedelta(days=1)),
            ('GUEST00004', 'advance', 'Аванс перечислен на карту',
             asked + timedelta(days=7)),
            (guest, 'report', 'Билеты, счёт гостиницы и посадочные — в '
             'бухгалтерии', reported)):
        db.session.add(BusinessTripEvent(trip_id=trip.id, actor_id=actor,
                                         action=action, comment=comment, at=at))
    counts['командировок'] = 1

    # Поручения: пять — от гостя, два — ему от председателя совета директоров.
    # (исполнитель, автор, название, текст, важное, срок, состояние, создано
    #  дней назад, результат, события: (кто, действие, дней назад, комментарий))
    tasks = (
        ('GUEST00003', guest, 'План модернизации цеха № 2 на 2027 год',
         'Подготовить план с оценкой затрат и сроками, согласовать с главным '
         'бухгалтером.', True, today + timedelta(days=10), 'in_progress', 6,
         None, (('GUEST00003', 'accept', 5, None),)),
        ('GUEST00004', guest, 'Свод бюджета на 2027 год',
         'Свести заявки отделов, расходы на модернизацию — отдельной строкой.',
         False, today + timedelta(days=3), 'done', 12,
         'Свод готов и отправлен на почту, модернизация — отдельной строкой.',
         (('GUEST00004', 'accept', 11, None),
          ('GUEST00004', 'done', 1, 'Свод готов и отправлен на почту, '
           'модернизация — отдельной строкой.'))),
        ('GUEST00006', guest, 'Ноутбуки для бухгалтерии',
         'Заменить три старых компьютера в бухгалтерии на ноутбуки до конца '
         'года.', False, today + timedelta(days=20), 'new', 1, None, ()),
        ('GUEST00002', guest, 'Отчёт о поездке в Лос-Анджелес для совета '
         'директоров', 'Коротко: с кем встретились, что предлагают, '
         'сроки и цены.', True, today - timedelta(days=2), 'in_progress', 20,
         None, (('GUEST00002', 'accept', 19, None),
                ('GUEST00002', 'extend', 3, 'Жду от поставщика итоговое '
                 'коммерческое предложение'))),
        ('GUEST00009', guest, 'Внеплановый инструктаж по охране труда',
         'Провести инструктаж в цехе после замены станков.', False,
         today - timedelta(days=8), 'closed', 15,
         'Инструктаж проведён, журнал подписан.',
         (('GUEST00009', 'accept', 14, None),
          ('GUEST00009', 'done', 9, 'Инструктаж проведён, журнал подписан.'),
          (guest, 'close', 7, None))),
        (guest, 'GUEST00011', 'Итоги переговоров в Лос-Анджелесе — доложить '
         'совету директоров', 'Доклад на ближайшем заседании, 10–15 минут.',
         True, today + timedelta(days=7), 'in_progress', 25, None,
         ((guest, 'accept', 24, None),)),
        (guest, 'GUEST00011', f'Годовой отчёт общества за {year} год',
         'Проект годового отчёта — к заседанию совета директоров.', False,
         date(year + 1, 2, 15), 'new', 2, None, ()),
    )
    assignments = {}
    for (assignee, author, title, text, important, due, status, created,
         result, events) in tasks:
        at = ago(created, 3)
        changed = ago(min([e[2] for e in events] or [created]), 1)
        item = Assignment(author_id=author, assignee_id=assignee, title=title,
                          text=text, important=important, due_date=due,
                          status=status, result=result, created_at=at,
                          updated_at=changed,
                          closed_at=changed if status == 'closed' else None)
        for actor, action, _days, comment in events:
            if action == 'extend':
                item.proposed_due = today + timedelta(days=5)
                item.proposed_reason = comment
        db.session.add(item)
        db.session.flush()
        assignments[title] = item
        db.session.add(AssignmentEvent(assignment_id=item.id, actor_id=author,
                                       action='created', due=due, at=at))
        for actor, action, days, comment in events:
            db.session.add(AssignmentEvent(
                assignment_id=item.id, actor_id=actor, action=action,
                comment=comment, at=ago(days, 2),
                due=item.proposed_due if action == 'extend' else None))
    counts['поручений'] = len(tasks)

    # Вопрос по листку: почему премия за III квартал меньше. Есть, только
    # если листок за сентябрь уже есть.
    question = None
    if 9 in slips:
        question = PayslipQuestion(
            employee_id=guest, period_year=year, period_month=9,
            line='Премия по итогам квартала', status='answered',
            assignee_id='GUEST00005', created_at=ago(20), updated_at=ago(18))
        db.session.add(question)
        db.session.flush()
        db.session.add(PayslipQuestionMessage(
            question_id=question.id, author_id=guest, at=ago(20),
            text='Почему премия за третий квартал меньше, чем за второй?'))
        db.session.add(PayslipQuestionMessage(
            question_id=question.id, author_id='GUEST00005', at=ago(18),
            text='Премия — 25 % оклада, умноженные на выполнение плана. За III '
                 'квартал план выполнен на 96 %: 288 000 ₸. Во II квартале — '
                 'на 110 %: 330 000 ₸.'))
    counts['вопросов по листку'] = 1 if question else 0

    # Медосмотры: периодический — скоро, флюорография и прививка — в срок.
    for kind, due, done in (('periodic', 18, 347), ('fluorography', 190, 175),
                            ('vaccination', 40, 325)):
        db.session.add(MedicalExam(employee_id=guest, kind=kind,
                                   due_on=today + timedelta(days=due),
                                   last_done_on=today - timedelta(days=done),
                                   set_by='GUEST00008', updated_at=ago(done)))
    counts['медосмотров'] = 3

    # Техника за гостем. Инвентарные — «ДЕМО-…»: у настоящих таких нет.
    for kind, model, number, serial in (
            ('laptop', 'Lenovo ThinkPad X1 Carbon', 'ДЕМО-0001', 'PF4X2K9M'),
            ('monitor', 'Dell UltraSharp 27', 'ДЕМО-0002', 'CN0V2W3R'),
            ('phone', 'IP-телефон Yealink T54W', 'ДЕМО-0003', '805420817')):
        db.session.add(ItAsset(kind=kind, model=model, inventory_no=number,
                               serial=serial, employee_id=guest, room='201',
                               written_off=False, updated_at=ago(120)))
    counts['единиц техники'] = 3

    # Плановое отключение — объявлено своим, напоминать не нужно.
    start = datetime.combine(today + timedelta(days=2), time(13))
    db.session.add(Outage(kind='network', starts_at=start,
                          ends_at=start + timedelta(hours=1),
                          note='Замена коммутатора в административном корпусе',
                          departments='', author_id='GUEST00006',
                          created_at=ago(1), reminded=True))
    counts['отключений'] = 1

    # Проходы: два месяца, кончая сегодняшним утром.
    absent = _absences(today, (trip_from, trip_to), leaves)
    total = 0
    for emp_id in _SCHEDULES:
        for day, moment, entering in passes(emp_id, today, now,
                                            absent.get(emp_id, set())):
            db.session.add(AccessRecord(
                employee_id=emp_id, access_date=day, access_time=moment,
                event_type='Вход' if entering else 'Выход',
                door_location=_DOOR_IN if entering else _DOOR_OUT))
            total += 1
    counts['проходов'] = total

    # Оповещения — свои, как пришли бы по ходу дел. Три последних — новые.
    trip_label = f'Командировка №{trip.id} ({trip.destination})'
    notices = [
        ('trip', f'{trip_label} согласована', 'Сапарова Айгерим Нурлановна',
         trip.id, asked + timedelta(days=1)),
        ('trip', f'{trip_label}: аванс выдан', '2 500 000 ₸',
         trip.id, asked + timedelta(days=7)),
    ]
    if question is not None:
        notices.append(('payslip_q', f'Вопрос по листку №{question.id}: ответ '
                        'расчётной группы', f'сентябрь {year}', question.id,
                        ago(18)))
    if slips:
        month = max(slips)
        notices.append(('payslip', 'Зарплата', f'Расчётный лист за '
                        f'{_MONTHS[month - 1].lower()} {year} готов', None,
                        ago(6)))
    report = assignments['Отчёт о поездке в Лос-Анджелес для совета директоров']
    budget = assignments['Свод бюджета на 2027 год']
    annual = assignments[f'Годовой отчёт общества за {year} год']
    notices += [
        ('assignment', f'Просит перенести срок: «{report.title}»',
         f'Сапарова Айгерим Нурлановна: на '
         f'{report.proposed_due:%d.%m} — {report.proposed_reason}',
         report.id, ago(3, 2)),
        ('assignment', f'Новая задача: {annual.title}',
         f'Нурпеисов Асхат Ермекович, срок {annual.due_date:%d.%m}',
         annual.id, ago(2, 3)),
        ('assignment', f'Выполнено: «{budget.title}»',
         f'Ахметова Динара Сериковна: {budget.result}', budget.id, ago(1, 2)),
        ('medical', 'Медпункт: периодический медосмотр',
         f'Пройти до {today + timedelta(days=18):%d.%m.%Y}. Записаться можно '
         'в приложении', None, ago(0, 5)),
    ]
    rows = []
    for kind, title, body, ref, at in sorted(notices, key=lambda n: n[4]):
        row = Notification(audience='person', employee_id=guest, kind=kind,
                           title=title[:200], body=body[:500],
                           ref=str(ref) if ref is not None else None,
                           created_at=at)
        db.session.add(row)
        rows.append(row)
    db.session.flush()
    account = UserAccount.query.filter_by(employee_id=guest).first()
    if account is not None and len(rows) > 3:
        account.notifications_seen_id = rows[-4].id
    counts['оповещений'] = len(rows)
    return counts


# ── Запуск ───────────────────────────────────────────────────────────────────

def _conflict(app_module, db, login):
    """Почему этот логин гостю не годится, или None."""
    import demo
    from models import Employee, UserAccount
    for form in app_module._number_forms(login):
        account = db.session.get(UserAccount, form)
        if account is not None and not demo.is_demo_id(account.employee_id):
            return (f'логин {form} уже у сотрудника {account.employee_id} — '
                    'возьмите другой: --login N')
        emp = db.session.get(Employee, form)
        if emp is not None and not demo.is_demo_id(emp.employee_id):
            return (f'есть настоящий сотрудник с табельным {form} '
                    f'({emp.full_name}) — его логин занимать нельзя, возьмите '
                    'другой: --login N')
    return None


def main(argv=None, application=None):
    parser = argparse.ArgumentParser(
        description='Гостевая учётная запись с вымышленными данными.')
    parser.add_argument('--apply', action='store_true',
                        help='завести или обновить (без него — пробный прогон)')
    parser.add_argument('--remove', action='store_true',
                        help='убрать гостя и весь вымышленный мир')
    parser.add_argument('--new-password', action='store_true',
                        help='выдать новый пароль')
    parser.add_argument('--password', help='свой пароль вместо случайного')
    parser.add_argument('--login', default=LOGIN, help='логин гостя (1)')
    args = parser.parse_args(argv)

    import app as app_module
    import demo
    from werkzeug.security import generate_password_hash
    from models import db, AuthToken, Employee, UserAccount

    login = args.login.strip()
    application = application or app_module.create_app()
    with application.app_context():
        guest = demo.GUEST_ID
        account = UserAccount.query.filter_by(employee_id=guest).first()

        if args.remove:
            wipe(app_module, db)
            db.session.commit()
            print('Гостевая учётная запись и весь вымышленный мир удалены.')
            return 0

        problem = _conflict(app_module, db, login)
        if problem:
            print(f'Не завожу: {problem}.', file=sys.stderr)
            return 1
        if args.password is not None:
            bad = app_module._password_problem(args.password, login)
            if bad:
                print(f'Пароль не подходит ({bad}): от 8 знаков, не логин, '
                      'не «12345678» и не «11111111».', file=sys.stderr)
                return 1

        same_login = account is not None and account.login == login
        new_password = (not same_login or args.new_password
                        or args.password is not None)
        who = f'{demo.STAFF[0][1]}, {demo.STAFF[0][2].lower()}'
        if not args.apply:
            if same_login:
                print(f'Гость уже заведён (логин {login}, {who}).')
                print('С --apply: данные сдвинутся на сегодня, '
                      + ('пароль будет новый.' if new_password
                         else 'пароль и вход на телефонах останутся.'))
            else:
                if account is not None:
                    print(f'Гость сейчас под логином {account.login} — '
                          f'переведу на {login}, старый перестанет работать.')
                print(f'Заведу гостя: логин {login}, {who}.')
                print('Листки за год с окладом 1 200 000 ₸, отпуска и больничный '
                      'этого года, командировку в Лос-Анджелес, проходы, '
                      'поручения, медосмотры, технику, справочник и оповещения.')
            print('\nПробный прогон, ничего не изменено. Чтобы сделать, '
                  'добавьте в конце --apply')
            return 0

        password = None
        if new_password:
            password = args.password
            while password is None or app_module._password_problem(password, login):
                password = app_module._random_password(10)
        if account is not None and not same_login:
            # Логин — первичный ключ: переезд — это новая учётка, а старая
            # уходит вместе с пропусками.
            AuthToken.query.filter_by(employee_id=guest).delete()
            db.session.delete(account)
            db.session.flush()
            account = None

        wipe(app_module, db, keep_account=account is not None)
        today = app_module._plant_today()
        now = app_module._plant_now()
        if account is None:
            db.session.add(Employee(employee_id=guest,
                                    full_name=demo.STAFF[0][1],
                                    job_title=demo.STAFF[0][2],
                                    department=demo.STAFF[0][3]))
            db.session.flush()
            account = UserAccount(login=login, employee_id=guest,
                                  notifications_seen_id=0)
            db.session.add(account)
        if password is not None:
            account.password_hash = generate_password_hash(password)
            # Новый пароль — и на телефонах, где вошли со старым, тоже выход.
            AuthToken.query.filter_by(employee_id=guest).delete()
        # Показывают его чужим людям: обязательная смена пароля при первом
        # входе оставила бы следующего без входа.
        account.must_change_password = False
        account.is_active = True
        account.failed_attempts = 0
        account.locked_until = None
        db.session.flush()
        counts = create(app_module, db, today, now)
        db.session.commit()

        print('Гостевая учётная запись готова.')
        print(f'  логин:  {login}')
        if password is not None:
            print(f'  пароль: {password}')
        else:
            print('  пароль: прежний (в базе только его хеш; забыли — запустите '
                  'с --new-password)')
        print(f'  кто:    {who}')
        print('Заведено: ' + ', '.join(f'{name} — {n}'
                                       for name, n in counts.items()))
        print('Гость только смотрит и не видит настоящих сотрудников; они не '
              'видят его.')
    return 0


if __name__ == '__main__':
    _server_settings()
    sys.exit(main())
