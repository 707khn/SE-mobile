"""Раздать одноразовые коды вместо пароля, равного табельному номеру.

Табельный номер напечатан на пропуске, и войти под чужим именем — а войдя,
сменить пароль и забрать учётку — мог любой, кто пропуск видел. Скрипт
меняет пароль на случайный код у всех, кто ещё ни разу не входил, и пишет
коды в CSV: кадровик раздаёт их лично. Кто уже входил, не трогается.

На сервере:

    sudo bash -c 'set -a; . /etc/se-mobile.env; cd /opt/se-mobile/se-mobile-backend; \
        /opt/se-mobile/venv/bin/python issue_codes.py /root/codes.csv'

Только для части людей — табельные номера через пробел после имени файла.
Коды есть только в этом файле: в базе хранится хеш. Файл после раздачи
удалить.
"""

import csv
import os
import sys


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    path, logins = argv[1], argv[2:] or None

    # Файл открываем до смены паролей: не откроется — не меняем ничего, а
    # то коды ушли бы в базу хешами, и раздать их было бы не с чего.
    old = os.umask(0o077)
    try:
        out = open(path, 'x', newline='', encoding='utf-8-sig')
    except FileExistsError:
        print(f'{path} уже есть — не перезаписываю, коды в нём пропали бы')
        return 1
    finally:
        os.umask(old)

    import app as app_module
    application = app_module.create_app()
    with out, application.app_context():
        codes = app_module.issue_one_time_codes(logins)
        writer = csv.writer(out, delimiter=';')
        writer.writerow(['Табельный номер', 'ФИО', 'Код для входа'])
        for row in codes:
            writer.writerow([row['login'], row['full_name'], row['code']])
    print(f'Выдано кодов: {len(codes)}, записаны в {path}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
