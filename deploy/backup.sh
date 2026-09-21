#!/bin/bash
# Суточная копия базы. Запускается по таймеру systemd от пользователя postgres.
#
# Копия шифруется. В ней зарплаты, ИИН и телефоны всего предприятия, а лежит
# она файлом на диске — тем же самым, где и сама база. Ключ отдельным файлом
# рядом защищает от одного: унесённого файла копии. От того, кто получил
# сервер целиком, он не спасает — для этого копии нужно забирать с сервера,
# см. deploy/README.md.
#
# Хранится 30 дней: база из пары сотен мегабайт ужимается примерно в десять
# раз, поэтому месяц истории занимает меньше гигабайта.
set -euo pipefail

DIR=/var/backups/se-mobile
KEY=/etc/se-mobile-backup-key
KEEP_DAYS=30
STAMP=$(date +%Y-%m-%d)
FILE="$DIR/se_mobile_$STAMP.sql.gz.enc"

if [ ! -d "$DIR" ] || [ ! -w "$DIR" ]; then
    echo "папка $DIR недоступна для записи от пользователя $(id -un)." >&2
    echo "создайте её от root:" >&2
    echo "  sudo mkdir -p $DIR" >&2
    echo "  sudo chown postgres:semobile $DIR && sudo chmod 750 $DIR" >&2
    exit 1
fi

if [ ! -r "$KEY" ]; then
    echo "нет ключа $KEY — без него копию не зашифровать" >&2
    exit 1
fi

# pipefail выше обязателен: без него упавший pg_dump оставил бы обрезанный
# файл, который выглядит как удачная копия ровно до дня, когда понадобится.
pg_dump se_mobile \
    | gzip -9 \
    | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -pass "file:$KEY" \
    > "$FILE.tmp"
mv "$FILE.tmp" "$FILE"

# Удаляем старое только после того, как новое легло на место: иначе сбой
# посреди дампа оставил бы вас без копий вообще. Старое имя (.sql.gz) тоже
# подчищаем — до шифрования копии лежали так.
find "$DIR" -name 'se_mobile_*.sql.gz' -mtime +$KEEP_DAYS -delete
find "$DIR" -name 'se_mobile_*.sql.gz.enc' -mtime +$KEEP_DAYS -delete

echo "$(date '+%F %T')  копия готова: $FILE ($(du -h "$FILE" | cut -f1))"
