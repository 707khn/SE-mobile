#!/bin/bash
# Суточная копия базы. Запускается по таймеру systemd от пользователя postgres.
#
# Хранится 30 дней. Копия сжимается: база из пары сотен мегабайт ужимается
# примерно в десять раз, поэтому месяц истории занимает меньше гигабайта.
set -euo pipefail

DIR=/var/backups/se-mobile
KEEP_DAYS=30
STAMP=$(date +%Y-%m-%d)
FILE="$DIR/se_mobile_$STAMP.sql.gz"

mkdir -p "$DIR"
pg_dump se_mobile | gzip -9 > "$FILE.tmp"
mv "$FILE.tmp" "$FILE"

# Удаляем старое только после того, как новое легло на место: иначе сбой
# посреди дампа оставил бы вас без копий вообще.
find "$DIR" -name 'se_mobile_*.sql.gz' -mtime +$KEEP_DAYS -delete

echo "$(date '+%F %T')  копия готова: $FILE ($(du -h "$FILE" | cut -f1))"
