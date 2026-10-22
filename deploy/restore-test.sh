#!/bin/bash
# Пробное восстановление: берёт свежую копию базы, разворачивает её в
# отдельную временную базу, сверяет с рабочей и удаляет. Рабочую базу и
# приложение не трогает.
#
# Копия, из которой ни разу не восстанавливались, — это надежда, а не
# резерв: сломанный ключ, обрезанный файл или дамп, который не ложится в
# PostgreSQL, обнаруживаются ровно в тот день, когда копия нужна. Поэтому раз
# в квартал это делает таймер (se-mobile-restore-test.timer), а итог видно в
# админ-панели.
#
#     sudo bash /opt/se-mobile/deploy/restore-test.sh
#         копия из внешнего хранилища, если оно настроено, иначе с диска
#     sudo bash /opt/se-mobile/deploy/restore-test.sh --local
#         самая свежая копия с диска сервера
#     sudo bash /opt/se-mobile/deploy/restore-test.sh --key /tmp/backup-key
#         расшифровать ключом, который вы принесли со своего хранения, а не
#         тем, что лежит на сервере. Только так видно, что ваш экземпляр
#         ключа — правильный: если сервер умрёт, другого не будет.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=deploy/offsite-lib.sh
. "$HERE/offsite-lib.sh"

LIVE_DB=${RESTORE_LIVE_DB:-se_mobile}
TEST_DB=${RESTORE_TEST_DB:-se_mobile_restore_test}
KEY=${BACKUP_KEY:-/etc/se-mobile-backup-key}
STATE_DIR=${RESTORE_STATE_DIR:-/var/lib/se-mobile/restore-test}
# От кого ходить в PostgreSQL. На сервере — postgres через runuser; пусто —
# как есть, с PGHOST/PGUSER из окружения (так гоняют проверки).
PG_AS=${RESTORE_PG_AS-postgres}

source_kind=auto
key_kind=server
while [ $# -gt 0 ]; do
    case $1 in
        --local) source_kind=local ;;
        --offsite) source_kind=offsite ;;
        --key) KEY=${2:?после --key нужен путь к файлу ключа}; key_kind=external; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Непонятный параметр: $1 (см. --help)" >&2; exit 2 ;;
    esac
    shift
done
if [ "$source_kind" = auto ]; then
    if offsite_configured; then source_kind=offsite; else source_kind=local; fi
fi

pg() {
    if [ -n "$PG_AS" ] && [ "$(id -un)" != "$PG_AS" ]; then
        runuser -u "$PG_AS" -- "$@"
    else
        "$@"
    fi
}
sql() {
    pg psql -X -At -v ON_ERROR_STOP=1 -d "$1" -c "$2"
}

STATUS="$STATE_DIR/status"
result=ok
message=
file=
backup_date=
tables=
rows=
seconds=
key_fingerprint=
started=$(date +%s)

mkdir -p "$STATE_DIR"
# Дамп без сжатия — в десять раз больше копии: в /var/tmp места обычно
# больше, чем в /tmp. Внутри расшифрованные зарплаты: папку видит только
# root, и она удаляется при любом исходе.
work=$(mktemp -d "${TMPDIR:-/var/tmp}/se-mobile-restore.XXXXXX")
created_db=
cleanup() {
    rc=$?
    rm -rf "$work"
    if [ -n "$created_db" ]; then
        pg dropdb --if-exists "$TEST_DB" 2>/dev/null || true
    fi
    if [ "$rc" != 0 ] && [ "$result" = ok ]; then
        result=fail
        message="Проба оборвалась с кодом $rc — см. journalctl -u se-mobile-restore-test"
    fi
    seconds=$(( $(date +%s) - started ))
    {
        echo "checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "result=$result"
        echo "message=$message"
        echo "source=$source_kind"
        echo "key=$key_kind"
        echo "key_fingerprint=$key_fingerprint"
        echo "file=$file"
        echo "backup_date=$backup_date"
        echo "tables=$tables"
        echo "rows=$rows"
        echo "seconds=$seconds"
    } > "$STATUS.tmp" 2>/dev/null && chmod 644 "$STATUS.tmp" \
        && mv -f -- "$STATUS.tmp" "$STATUS" || true
    echo "$(date '+%F %T')  $result  $source_kind  ${file:--}  $message" \
        >> "$STATE_DIR/history.log" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
    result=fail
    message=$*
    echo "$*" >&2
    exit 1
}

[ -r "$KEY" ] || fail "Нет ключа $KEY — без него копию не расшифровать."
# Отпечаток, а не сам ключ: по нему вы сверите, что ваш экземпляр ключа
# тот же, что на сервере (sha256sum ФАЙЛ у себя, первые 16 знаков).
key_fingerprint=$(sha256sum "$KEY" | cut -c1-16)

# 1. Копия.
if [ "$source_kind" = offsite ]; then
    offsite_configured || fail "Внешнее хранилище не настроено в $OFFSITE_CONFIG."
    S3_ERROR=
    s3_list "$work/remote" || fail "Не получить список копий в хранилище: $S3_ERROR."
    [ -s "$work/remote" ] || fail "В хранилище нет ни одной копии."
    read -r file size etag < <(tail -n 1 "$work/remote")
    echo "Скачиваю из хранилища $file"
    code=$(S3_MAX_TIME=1800 s3 "$OFFSITE_PREFIX$file" -o "$work/$file")
    [ "$code" = 200 ] || fail "$file не скачался: $(s3_error "$code" "$work/$file")."
    [ "$(stat -c %s "$work/$file")" = "$size" ] \
        || fail "$file скачался не целиком."
    if [[ $etag =~ ^[0-9a-f]{32}$ ]] \
        && [ "$(md5sum "$work/$file" | cut -d' ' -f1)" != "$etag" ]; then
        fail "$file: контрольная сумма не сходится с хранилищем."
    fi
    copy="$work/$file"
else
    copy=
    for f in "$BACKUP_DIR"/se_mobile_*.sql.gz.enc; do
        [ -e "$f" ] || continue
        [[ $(basename "$f") =~ $BACKUP_RE ]] && copy=$f
    done
    [ -n "$copy" ] || fail "В $BACKUP_DIR нет ни одной копии."
    file=$(basename "$copy")
    echo "Беру с диска $file"
fi
[[ $file =~ $BACKUP_RE ]] && backup_date=${BASH_REMATCH[1]}

# 2. Расшифровать и распаковать — отдельно от восстановления, чтобы ошибка
# называла причину: не тот ключ, битый файл или дамп не ложится в базу.
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "file:$KEY" \
    -in "$copy" -out "$work/dump.sql.gz" 2>"$work/openssl.err" \
    || fail "Копия $file не расшифровывается ключом $KEY (отпечаток" \
            "$key_fingerprint): не тот ключ или файл испорчен."
rm -f "$work/$file"
gzip -t "$work/dump.sql.gz" 2>/dev/null \
    || fail "Копия $file расшифровалась, но внутри битый архив — файл испорчен."

# 3. Место: временная база займёт примерно столько же, сколько рабочая.
live_size=$(sql "$LIVE_DB" "SELECT pg_database_size(current_database())" 2>/dev/null) || live_size=
data_dir=$(sql "$LIVE_DB" "SHOW data_directory" 2>/dev/null) || data_dir=
if [ -n "$live_size" ] && [ -n "$data_dir" ] && [ -d "$data_dir" ]; then
    free=$(df -Pk "$data_dir" | awk 'NR == 2 {print $4}')
    if (( free * 1024 < live_size * 2 )); then
        fail "Для пробной базы мало места: свободно $((free / 1024)) МБ, а" \
             "рабочая занимает $((live_size / 1024 / 1024)) МБ."
    fi
fi

# 4. Развернуть во временную базу.
pg dropdb --if-exists "$TEST_DB" 2>/dev/null
created_db=1
pg createdb "$TEST_DB"
echo "Разворачиваю в $TEST_DB"
gzip -dc "$work/dump.sql.gz" \
    | pg psql -X -q -v ON_ERROR_STOP=1 -d "$TEST_DB" >/dev/null 2>"$work/psql.err" \
    || fail "Копия $file не легла в PostgreSQL:" \
            "$(grep -m1 -i 'error' "$work/psql.err" || tail -n 1 "$work/psql.err")"

# 5. Сверить с рабочей. Копия — на начало суток, поэтому строк может быть
# чуть меньше; пропавшая таблица или пустая база — нет.
count_rows() {
    pg psql -X -At -v ON_ERROR_STOP=1 -d "$1" <<'SQL'
SELECT format('SELECT %L || '' '' || count(*) FROM %I.%I;', tablename, schemaname, tablename)
FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename
\gexec
SQL
}
count_rows "$TEST_DB" > "$work/restored" || fail "Не прочитать таблицы восстановленной базы."
count_rows "$LIVE_DB" > "$work/live" 2>/dev/null || : > "$work/live"

tables=$(wc -l < "$work/restored")
rows=$(awk '{s += $2} END {print s + 0}' "$work/restored")
(( tables > 0 )) || fail "В копии $file нет ни одной таблицы."
(( rows > 0 )) || fail "В копии $file все таблицы пустые."

missing=()
{
    echo "таблица копия сейчас"
    while read -r table live_rows; do
        restored_rows=$(awk -v t="$table" '$1 == t {print $2}' "$work/restored")
        echo "$table ${restored_rows:--} $live_rows"
        if [ -z "$restored_rows" ] && (( live_rows > 0 )); then
            echo "$table" >> "$work/missing"
        fi
    done < "$work/live"
} | python3 -c '
import sys
rows = [line.split() for line in sys.stdin if line.strip()]
wide = max(len(r[0]) for r in rows)
for r in rows:
    print(f"{r[0]:<{wide}}  {r[1]:>10}  {r[2]:>10}")
'
[ -s "$work/missing" ] && mapfile -t missing < "$work/missing"

seconds=$(( $(date +%s) - started ))
message="Копия $file развернулась за $seconds с: $tables таблиц, $rows строк"
if [ ${#missing[@]} -gt 0 ]; then
    # Таблица могла появиться с обновлением сервера уже после копии — это
    # не провал, но посмотреть стоит.
    message="$message; в копии нет таблиц ${missing[*]} (появились после обновления?)"
fi
if [ "$key_kind" = server ]; then
    message="$message. Ключ — с сервера (отпечаток $key_fingerprint)"
else
    message="$message. Ключ — ваш, принесённый (отпечаток $key_fingerprint)"
fi
echo "Готово. $message."
