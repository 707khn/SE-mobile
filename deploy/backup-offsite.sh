#!/bin/bash
# Увозит суточные копии базы с сервера во внешнее хранилище.
#
# Копии делает deploy/backup.sh в 03:30 и кладёт их на тот же диск, где и
# сама база. Умрёт сервер или диск — пропадут и база, и все тридцать копий
# разом. Этот скрипт раз в сутки, после копирования, отправляет в объектное
# хранилище (PS Cloud или любое другое S3-совместимое) каждую копию, которой
# там ещё нет, и проверяет, что доехала она целой.
#
# Копии уходят уже зашифрованными: хранилище видит только шифр. Ключ туда
# не уходит, и поэтому его нужно хранить отдельно и от сервера, и от
# хранилища — см. deploy/README.md, «Копия вне сервера».
#
# Настройки — в /etc/se-mobile-offsite.env (ставит deploy/install-offsite.sh).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=deploy/offsite-lib.sh
. "$HERE/offsite-lib.sh"

STATE_DIR=${OFFSITE_STATE_DIR:-/var/lib/se-mobile/offsite}
# Сколько дней копии живут в хранилище. 0 — не удалять никогда: тогда
# старое чистит правило жизненного цикла в самом хранилище, а ключу
# сервера можно не давать права на удаление (см. README).
KEEP_DAYS=${OFFSITE_KEEP_DAYS:-90}
# Сколько самых свежих копий не удалять ни при каком сроке.
KEEP_MIN=7
# Свежая копия старше этого — суточное копирование встало.
STALE_HOURS=${OFFSITE_STALE_HOURS:-36}

# Чем кончился последний запуск — для админ-панели, экран «Обновление».
# Журнал systemd читает только root, а копия, переставшая уезжать, иначе
# обнаружится в тот день, когда понадобится.
STATUS="$STATE_DIR/status"
result=ok
message=
uploaded=0
remote_count=
remote_newest=

mkdir -p "$STATE_DIR" || {
    echo "Не могу создать $STATE_DIR." >&2
    exit 1
}

work=$(mktemp -d)
cleanup() {
    rc=$?
    rm -rf "$work"
    if [ "$rc" != 0 ] && [ "$result" = ok ]; then
        result=fail
        message="Запуск оборвался с кодом $rc — см. journalctl -u se-mobile-offsite"
    fi
    {
        echo "checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "result=$result"
        echo "message=$message"
        echo "uploaded=$uploaded"
        echo "remote_count=$remote_count"
        echo "remote_newest=$remote_newest"
        echo "keep_days=$KEEP_DAYS"
    } > "$STATUS.tmp" 2>/dev/null && chmod 644 "$STATUS.tmp" \
        && mv -f -- "$STATUS.tmp" "$STATUS" || true
}
trap cleanup EXIT

fail() {
    result=fail
    message=$*
    echo "$*" >&2
    exit 1
}

# Не настроено — не ошибка запуска: таймер ставится вместе с сервером, а
# хранилище заводят потом. Но и не «всё хорошо»: админ-панель покажет.
if ! offsite_configured; then
    result=not-configured
    message="Хранилище не настроено в $OFFSITE_CONFIG — копии лежат только на сервере."
    echo "$message См. deploy/README.md, «Копия вне сервера»."
    exit 0
fi

exec 9>"$STATE_DIR/lock"
if ! flock -n 9; then
    echo "Уже идёт другой запуск — этот пропускаю."
    exit 0
fi

# Что есть здесь.
local_list=()
for file in "$BACKUP_DIR"/se_mobile_*.sql.gz.enc; do
    [ -e "$file" ] || continue
    [[ $(basename "$file") =~ $BACKUP_RE ]] && local_list+=("$file")
done
if [ ${#local_list[@]} = 0 ]; then
    fail "В $BACKUP_DIR нет ни одной копии — увозить нечего." \
         "Проверьте службу: systemctl status se-mobile-backup"
fi
newest_local=${local_list[-1]}
age_hours=$(( ($(date +%s) - $(stat -c %Y "$newest_local")) / 3600 ))

# Что есть там.
S3_ERROR=
if ! s3_list "$work/remote"; then
    fail "Не получить список копий в хранилище: $S3_ERROR."
fi

for file in "${local_list[@]}"; do
    name=$(basename "$file")
    size=$(stat -c %s "$file")
    if grep -q "^$name $size " "$work/remote"; then
        continue
    fi
    # Недописанную копию не увезём: backup.sh пишет её в .tmp и
    # переименовывает, только когда она целая.
    md5_hex=$(md5sum "$file" | cut -d' ' -f1)
    md5_b64=$(openssl md5 -binary "$file" | base64)
    echo "Увожу $name ($(du -h "$file" | cut -f1))"
    # Content-MD5: хранилище само сверит, что получило ровно этот файл, и
    # откажет, если нет.
    code=$(S3_MAX_TIME=1800 s3 "$OFFSITE_PREFIX$name" \
        -T "$file" -H "Content-MD5: $md5_b64" \
        -H 'Content-Type: application/octet-stream' \
        -o "$work/put")
    if [ "$code" != 200 ]; then
        fail "$name не уехал: $(s3_error "$code" "$work/put")."
    fi
    # И сами переспросим: что лежит под этим именем.
    code=$(s3 "$OFFSITE_PREFIX$name" -I -o "$work/head")
    if [ "$code" != 200 ]; then
        fail "$name уехал, но переспросить о нём не вышло: $(s3_error "$code" /dev/null)."
    fi
    got_size=$(sed -n 's/^content-length: *//Ip' "$work/head" | tr -d '\r' | tail -n 1)
    got_etag=$(sed -n 's/^etag: *//Ip' "$work/head" | tr -d '\r"' | tail -n 1)
    if [ "$got_size" != "$size" ]; then
        fail "$name: в хранилище $got_size байт вместо $size."
    fi
    # ETag — это MD5 файла, если хранилище не шифрует его по-своему; тогда
    # он не похож на MD5, и хватает сверки размера и Content-MD5 выше.
    if [[ $got_etag =~ ^[0-9a-f]{32}$ ]] && [ "$got_etag" != "$md5_hex" ]; then
        fail "$name: контрольная сумма в хранилище не сходится."
    fi
    uploaded=$((uploaded + 1))
done

# Старое — после того, как новое доехало, и никогда не последние $KEEP_MIN.
if (( KEEP_DAYS > 0 )); then
    s3_list "$work/remote" || fail "Не получить список копий в хранилище: $S3_ERROR."
    cutoff=$(date -d "-$KEEP_DAYS days" +%Y-%m-%d)
    total=$(wc -l < "$work/remote")
    while read -r name _ _; do
        (( total > KEEP_MIN )) || break
        [[ $name =~ $BACKUP_RE ]] || continue
        [[ ${BASH_REMATCH[1]} < $cutoff ]] || break
        code=$(s3 "$OFFSITE_PREFIX$name" -X DELETE -o "$work/delete")
        case $code in
            200|204) echo "Удалена из хранилища: $name"; total=$((total - 1)) ;;
            # Ключу не дали права удалять — так и задумано, если старое
            # чистит само хранилище. Не ошибка.
            403) echo "Удалять из хранилища нельзя ($name) — оставляю."; break ;;
            *) echo "Не удалилась $name: $(s3_error "$code" "$work/delete")." >&2 ;;
        esac
    done < "$work/remote"
fi

s3_list "$work/remote" || fail "Не получить список копий в хранилище: $S3_ERROR."
remote_count=$(wc -l < "$work/remote")
remote_newest=$(tail -n 1 "$work/remote" | cut -d' ' -f1)
if [ "$remote_newest" != "$(basename "$newest_local")" ]; then
    fail "Самой свежей копии $(basename "$newest_local") нет в хранилище."
fi

if (( age_hours > STALE_HOURS )); then
    result=stale
    message="Самой свежей копии $age_hours ч. — суточное копирование встало: systemctl status se-mobile-backup"
    echo "$message" >&2
    exit 1
fi

message="В хранилище $remote_count копий, свежая — $remote_newest"
echo "Готово: увезено $uploaded. $message."
