"""Сбросить пароль всем, кроме тех, кто есть в CSV: одноразовый код вместо пароля.

issue_codes.py закрыл вход по табельному номеру тем, кто ещё ни разу не
входил. Остальных он не трогал, потому что у них мог быть уже свой пароль.
Но табельный номер напечатан на пропуске: кто его видел, мог войти под
чужим именем раньше владельца и поставить свой пароль. Этот скрипт выдаёт
новый код из четырёх цифр всем остальным, и кадровик раздаёт коды лично.
Вход при этом закрывается на всех устройствах, иначе телефон, где уже
вошли, сам погасил бы новый код (см. app.reset_password).

Кого скрипт не трогает:
  - тех, кто есть в CSV. Номер берётся из первого столбца. Обычно это
    codes.csv от issue_codes.py: этим людям коды только что выданы;
  - admin и другие нецифровые логины: через них входят в админ-панель;
  - отключённые учётки.

Сначала пробный прогон. Он ничего не меняет и только показывает, кого
заденет:

    sudo bash -c 'set -a; . /etc/se-mobile.env; cd /opt/se-mobile/se-mobile-backend; \\
        /opt/se-mobile/venv/bin/python reset_passwords.py /root/codes.csv /root/codes-2.csv'

Чтобы сбросить, запустите ту же команду с --apply в конце. Ещё два ключа:

  --keep 44,1874     не трогать и эти логины;
  --only-temporary   сбросить только тех, у кого пароль всё ещё выданный
                     (табельный номер или старый код). Свой пароль и вход
                     с телефона по коду из четырёх цифр не трогать.

Коды есть только в новом файле, в базе лежит хеш. После раздачи файл
удалите.
"""

import argparse
import csv
import io
import logging
import os
import sys
from collections import Counter

# Состояние пароля: коротко — для строки списка, полностью — для итога.
_STATES = {
    'number': ('табельный номер',
               'пароль всё ещё табельный номер, войдёт любой, кто видел пропуск'),
    'issued': ('выданный код', 'выданный код ещё не сменён'),
    'own': ('свой пароль', 'свой пароль'),
    'phone': ('только телефон',
              'входят только с телефона, по коду из четырёх цифр'),
}
_TEMPORARY = ('number', 'issued')


def _short(number):
    """Табельный номер без ведущих нулей: «0000000450» и «450» — один человек."""
    return number.lstrip('0') or '0'


def read_numbers(path):
    """Табельные номера из первого столбца CSV, без ведущих нулей.

    Файл бывает прямо от issue_codes.py (UTF-8, «;»), а бывает
    пересохранённым в Excel (cp1251, «;» или «,»). Строки, где в первом
    столбце не номер (заголовок, пустые), пропускаются.
    """
    with open(path, 'rb') as f:
        raw = f.read()
    try:
        text = raw.decode('utf-8-sig')
    except UnicodeDecodeError:
        text = raw.decode('cp1251', errors='replace')
    first = text.lstrip().split('\n', 1)[0]
    delimiter = next((d for d in ';\t,' if d in first), ';')
    numbers = set()
    for row in csv.reader(io.StringIO(text), delimiter=delimiter):
        cell = row[0].strip() if row else ''
        if cell.isdigit():
            numbers.add(_short(cell))
    return numbers


def _state(app_module, account):
    """Какой у учётки пароль сейчас: см. _STATES."""
    if not app_module._has_password(account):
        return 'phone'
    if not account.must_change_password:
        return 'own'
    from werkzeug.security import check_password_hash
    try:
        number = any(check_password_hash(account.password_hash, form)
                     for form in app_module._number_forms(account.login))
    except Exception:
        number = False
    return 'number' if number else 'issued'


def _roles(app_module, employee):
    """Через что, кроме приложения, входят под этой учёткой.

    Сбросить им пароль можно, но загрузка с компьютера остановится, пока
    новый пароль не впишут в её settings.txt.
    """
    if employee is None:
        return []
    import payslip_questions
    job = ' '.join((employee.job_title or '').lower().replace('-', ' ').split())
    admin = app_module._is_system_admin(job)
    roles = ['админ-панель'] if admin else []
    if 'технолог' in job and 'столов' in job:
        roles.append('загрузка меню')
    if app_module._may_upload_directory(employee) and not admin:
        roles.append('загрузка справочника')
    if payslip_questions.is_payroll(employee):
        roles.append('загрузка листков')
    return roles


def plan(app_module, keep_numbers, keep_logins, only_temporary=False):
    """Кому сбросить пароль, и сколько кого не трогаем, по причинам."""
    from models import Employee, UserAccount
    employees = {e.employee_id: e for e in Employee.query.all()}
    skipped = Counter()
    targets = []
    for account in UserAccount.query.order_by(UserAccount.login).all():
        number = _short(account.login) if account.login.isdigit() else None
        if not account.is_active:
            skipped['disabled'] += 1
        elif number is None:
            skipped['named'] += 1
        elif number in keep_numbers:
            skipped['csv'] += 1
        elif number in keep_logins:
            skipped['keep'] += 1
        else:
            state = _state(app_module, account)
            if only_temporary and state not in _TEMPORARY:
                skipped['own'] += 1
                continue
            employee = employees.get(account.employee_id)
            targets.append({
                'account': account,
                'name': employee.full_name if employee else account.employee_id,
                'state': state,
                'roles': _roles(app_module, employee),
            })
    # По номеру, а не по строке: иначе «44» стоял бы после «2222».
    targets.sort(key=lambda t: int(t['account'].login))
    return targets, skipped


def _report(targets, skipped, csv_path, in_file, found, only_temporary):
    for t in targets:
        line = f"{t['account'].login:>10}  {t['name']}: {_STATES[t['state']][0]}"
        if t['roles']:
            line += f" [{', '.join(t['roles'])}]"
        print(line)
    print()
    print('Не трогаю:')
    print(f"  из {csv_path}: {skipped['csv']} (номеров в файле {in_file}, "
          f'учётки нашлись у {found})')
    if skipped['keep']:
        print(f"  из --keep: {skipped['keep']}")
    print(f"  admin и другие нецифровые логины: {skipped['named']}")
    print(f"  отключённые: {skipped['disabled']}")
    if only_temporary:
        print(f"  свой пароль или вход с телефона: {skipped['own']}")
    print()
    print(f'Сброшу пароль и закрою вход на всех устройствах: {len(targets)}')
    counts = Counter(t['state'] for t in targets)
    for state, (_, label) in _STATES.items():
        if counts[state]:
            print(f'  {label}: {counts[state]}')
    special = [t for t in targets if t['roles']]
    if special:
        print()
        print('Через эти учётки работают загрузки с компьютера или админ-панель.\n'
              'После сброса загрузка остановится, пока новый пароль не впишут\n'
              'в settings.txt на том компьютере. Чтобы их не трогать, добавьте\n'
              '--keep с их логинами:')
        for t in special:
            print(f"  {t['account'].login}  {t['name']}: {', '.join(t['roles'])}")


def _write_codes(path, targets):
    """Коды в CSV, как у issue_codes.py: Excel открывает его сразу.

    Файл создаётся с правами только для владельца и никогда не
    перезаписывается: в старом лежали бы коды, которые уже не восстановить.
    """
    old = os.umask(0o077)
    try:
        out = open(path, 'x', newline='', encoding='utf-8-sig')
    finally:
        os.umask(old)
    with out:
        writer = csv.writer(out, delimiter=';')
        writer.writerow(['Табельный номер', 'ФИО', 'Код для входа'])
        for t in targets:
            writer.writerow([t['account'].login, t['name'], t['code']])
        out.flush()
        os.fsync(out.fileno())


def _run(app_module, args, keep_numbers, keep_logins):
    from werkzeug.security import generate_password_hash
    from models import db, UserAccount

    digits = {_short(a.login) for a in UserAccount.query.all()
              if a.login.isdigit()}
    found = len(keep_numbers & digits)
    if not found:
        # Ни один номер из файла не учётка: файл не тот. Сбросить тогда
        # пришлось бы всех подряд, включая только что выданные коды.
        print(f'Ни один номер из {args.keep_csv} не нашёлся среди учёток. '
              'Похоже, файл не тот. Ничего не изменено.')
        return 1

    print('Проверяю учётки…', flush=True)
    targets, skipped = plan(app_module, keep_numbers, keep_logins,
                            args.only_temporary)
    _report(targets, skipped, args.keep_csv, len(keep_numbers), found,
            args.only_temporary)
    print()

    if not args.apply:
        print('Это пробный прогон, ничего не изменено. Чтобы сбросить, '
              'запустите ту же команду с --apply в конце.')
        return 0
    if not targets:
        print('Сбрасывать некого.')
        return 0

    # Хеши считаем до записи в базу. Один хеш — около десятой доли секунды,
    # на сотни учёток выходит минута. Держать всё это время замок на
    # строках, через которые проходит каждый запрос с пропуском, незачем.
    print(f'Готовлю коды для {len(targets)} учёток…', flush=True)
    for t in targets:
        t['code'] = app_module._one_time_code(t['account'].login)
        t['hash'] = generate_password_hash(t['code'])

    # Сначала файл, потом база. Если коды окажутся в базе, а в файл не
    # попадут, раздавать будет нечего, и люди останутся без входа.
    try:
        _write_codes(args.out_csv, targets)
    except FileExistsError:
        print(f'{args.out_csv} уже есть, перезаписывать не буду: коды в нём '
              'пропали бы. Ничего не изменено.')
        return 1
    try:
        for t in targets:
            app_module.reset_password(t['account'], t['hash'])
        db.session.commit()
    except Exception:
        db.session.rollback()
        os.remove(args.out_csv)
        print('В базу не записалось, ничего не изменено. Файл с кодами удалён.')
        raise
    logging.info('reset_passwords.py: пароль сброшен у %d учёток', len(targets))
    print(f'Сброшено: {len(targets)}. Коды записаны в {args.out_csv}.')
    return 0


def main(argv=None, application=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('keep_csv', metavar='НЕ_ТРОГАТЬ.csv')
    parser.add_argument('out_csv', metavar='НОВЫЕ_КОДЫ.csv')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--keep', action='append', default=[])
    parser.add_argument('--only-temporary', action='store_true')
    args = parser.parse_args(argv)

    try:
        keep_numbers = read_numbers(args.keep_csv)
    except OSError as e:
        print(f'Не открывается {args.keep_csv}: {e}')
        return 1
    if not keep_numbers:
        # Пустой список «кого не трогать» значил бы «сбросить всех».
        print(f'В {args.keep_csv} нет ни одного табельного номера в первом '
              'столбце. Похоже, файл не тот. Ничего не изменено.')
        return 1
    keep_logins = {_short(x) if x.isdigit() else x
                   for part in args.keep
                   for x in part.replace(',', ' ').split()}
    if os.path.exists(args.out_csv):
        print(f'{args.out_csv} уже есть, перезаписывать не буду: коды в нём '
              'пропали бы. Укажите другое имя.')
        return 1

    import app as app_module
    application = application or app_module.create_app()
    with application.app_context():
        return _run(app_module, args, keep_numbers, keep_logins)


if __name__ == '__main__':
    sys.exit(main())
