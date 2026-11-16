"""Завести учётки всем из расчётных листков, у кого их ещё нет.

Листки за месяц — это все, кто работает: 1С пишет листок каждому. Учётки же
заводились по старым спискам, и пришедшие позже в приложение не входят
вовсе. Скрипт берёт отчёт 1С «Расчетный листок», сохранённый в Excel (тот
же файл, что грузит бухгалтер), и каждому, у кого учётки нет, заводит её:
логин — табельный номер без нулей, пароль — одноразовый код из пяти цифр,
сменить его попросят при первом входе. Коды пишутся в CSV, Excel открывает
его сразу.

Кого не трогает:
  - у кого учётка уже есть, в том числе отключённая (уволенного обратно не
    включаем);
  - у кого учётки нет, но в базе есть сотрудник с тем же ФИО и учёткой под
    другим номером: это почти всегда один человек, и второй вход ему не
    нужен. Такие перечисляются отдельно — проверить руками.

Сначала пробный прогон, он ничего не меняет:

    sudo bash -c 'set -a; . /etc/se-mobile.env; cd /opt/se-mobile/se-mobile-backend; \\
        /opt/se-mobile/venv/bin/python create_accounts.py /home/ubuntu/листки.xls /home/ubuntu/new-accounts.csv'

Чтобы завести, та же команда с --apply в конце. Коды есть только в этом
файле, в базе лежит хеш. После раздачи файл удалите.
"""

import argparse
import csv
import logging
import os
import sys


def _short(number):
    return number.lstrip('0') or '0'


def _name_key(name):
    return ' '.join((name or '').lower().replace('ё', 'е').split())


def read_people(path):
    """Табельный номер → {full_name, position, department} из отчёта 1С."""
    from parser_payslip_excel import parse_payslip_excel
    with open(path, 'rb') as f:
        payslips = parse_payslip_excel(f.read())
    people = {}
    for p in payslips:
        number = (p.get('employee_1c_id') or '').strip()
        name = ' '.join((p.get('full_name') or '').split())
        if not number.isdigit() or not name:
            continue
        people[number] = {'full_name': name,
                          'position': (p.get('position') or '').strip(),
                          'department': (p.get('department') or '').strip()}
    return people


def plan(app_module, people):
    """Кому заводить, у кого уже есть, кого проверить руками."""
    from models import db, Employee, UserAccount
    accounts = {a.login: a for a in UserAccount.query.all()}
    employees = {e.employee_id: e for e in Employee.query.all()}
    # ФИО тех, у кого учётка есть, — чтобы не завести человеку вторую.
    with_account = {}
    for a in accounts.values():
        emp = employees.get(a.employee_id)
        if emp is not None:
            with_account.setdefault(_name_key(emp.full_name), a.login)

    targets, have, twins = [], 0, []
    for number, person in sorted(people.items(), key=lambda kv: int(kv[0])):
        login = _short(number)
        if any(form in accounts for form in app_module._number_forms(login)):
            have += 1
            continue
        twin = with_account.get(_name_key(person['full_name']))
        if twin is not None:
            twins.append((login, person['full_name'], twin))
            continue
        employee_id = next((form for form in (number, login, login.zfill(10))
                            if form in employees), None)
        targets.append({'login': login, 'number': number,
                        'employee_id': employee_id, **person})
    return targets, have, twins


def _write_codes(path, targets):
    old = os.umask(0o077)
    try:
        out = open(path, 'x', newline='', encoding='utf-8-sig')
    finally:
        os.umask(old)
    with out:
        writer = csv.writer(out, delimiter=';')
        writer.writerow(['Табельный номер', 'ФИО', 'Код для входа'])
        for t in targets:
            writer.writerow([t['login'], t['full_name'], t['code']])
        out.flush()
        os.fsync(out.fileno())


def _run(app_module, args, people):
    from werkzeug.security import generate_password_hash
    from models import db, Employee, UserAccount

    targets, have, twins = plan(app_module, people)
    for t in targets:
        note = '' if t['employee_id'] else ' (нового сотрудника)'
        print(f"{t['login']:>10}  {t['full_name']}{note}")
    print()
    print(f'В листках: {len(people)}. Учётка уже есть: {have}.')
    if twins:
        print(f'Не завожу — то же ФИО уже входит под другим номером '
              f'({len(twins)}), проверьте:')
        for login, name, other in twins:
            print(f'  {login}  {name}: учётка {other}')
    print(f'Заведу учётку и выдам код: {len(targets)}')
    print()

    if not args.apply:
        print('Это пробный прогон, ничего не изменено. Чтобы завести, '
              'запустите ту же команду с --apply в конце.')
        return 0
    if not targets:
        print('Заводить некого.')
        return 0

    print(f'Готовлю коды для {len(targets)} учёток…', flush=True)
    for t in targets:
        t['code'] = app_module._one_time_code(t['login'])
        t['hash'] = generate_password_hash(t['code'])

    # Сначала файл, потом база: коды в базе без файла раздать было бы не с чего.
    try:
        _write_codes(args.out_csv, targets)
    except FileExistsError:
        print(f'{args.out_csv} уже есть, перезаписывать не буду. '
              'Ничего не изменено.')
        return 1
    try:
        for t in targets:
            employee_id = t['employee_id']
            if employee_id is None:
                employee_id = t['number']
                db.session.add(Employee(
                    employee_id=employee_id, full_name=t['full_name'],
                    job_title=(t['position'] or 'Сотрудник')[:100],
                    department=t['department'][:200] or None))
            db.session.add(UserAccount(
                login=t['login'], employee_id=employee_id,
                password_hash=t['hash'], must_change_password=True))
        db.session.commit()
    except Exception:
        db.session.rollback()
        os.remove(args.out_csv)
        print('В базу не записалось, ничего не изменено. Файл с кодами удалён.')
        raise
    logging.info('create_accounts.py: заведено %d учёток', len(targets))
    print(f'Заведено: {len(targets)}. Коды записаны в {args.out_csv}.')
    return 0


def main(argv=None, application=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('payslips', metavar='ЛИСТКИ.xls')
    parser.add_argument('out_csv', metavar='КОДЫ.csv')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)

    if os.path.exists(args.out_csv):
        print(f'{args.out_csv} уже есть, перезаписывать не буду: коды в нём '
              'пропали бы. Укажите другое имя.')
        return 1
    try:
        people = read_people(args.payslips)
    except OSError as e:
        print(f'Не открывается {args.payslips}: {e}')
        return 1
    except ValueError as e:
        print(f'{args.payslips}: {e}')
        return 1
    if not people:
        print('В файле нет ни одного листка с табельным номером. Ничего не изменено.')
        return 1

    import app as app_module
    application = application or app_module.create_app()
    with application.app_context():
        return _run(app_module, args, people)


if __name__ == '__main__':
    sys.exit(main())
