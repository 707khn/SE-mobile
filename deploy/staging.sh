#!/bin/bash
# Тестовый стенд: второй экземпляр сервера на той же машине, со своей копией
# базы. Обновление сначала ставится сюда и проверяется, и только потом его
# видят пятьсот человек.
#
#     sudo se-mobile-staging install          один раз: папка, окружение, база,
#                                             настройки, служба
#     sudo se-mobile-staging deploy [ЧТО]     поставить ветку, метку или коммит
#                                             (без ЧТО — свежий main) и запустить
#     sudo se-mobile-staging refresh-db       база стенда заново из последней
#                                             ночной копии
#     sudo se-mobile-staging refresh-db --live   … из рабочей базы прямо сейчас
#     sudo se-mobile-staging env              заново взять настройки с рабочего
#                                             (после правки /etc/se-mobile.env)
#     sudo se-mobile-staging status           что стоит, с какой базой, жив ли
#     sudo se-mobile-staging start / stop     запустить; остановить и освободить память
#     sudo se-mobile-staging remove           убрать стенд целиком
#
# Чем стенд отличается от рабочего сервера:
#   * порт 8001 только на 127.0.0.1, наружу не открыт. В копии базы зарплаты
#     и ИИН всего предприятия, а проверка пропуска на рабочем сервере пока
#     выключена — публичный адрес стенда был бы второй такой же дырой.
#     Смотрят его через SSH-туннель, см. deploy/README.md;
#   * один рабочий процесс и потолок памяти 400 МБ: на машине 2 ГБ, и
#     стенд не должен вытеснять рабочий сервер и PostgreSQL;
#   * уведомления выключены: в копии базы — настоящие токены телефонов, и
#     проверка на стенде иначе разослала бы пуш всем сотрудникам;
#   * сам по себе после перезагрузки не стартует: запущен, пока нужен.
set -euo pipefail

LIVE_DIR=${LIVE_DIR:-/opt/se-mobile}
STAGING_DIR=${STAGING_DIR:-/opt/se-mobile-staging}
SERVICE=${STAGING_SERVICE:-se-mobile-staging}
PORT=${STAGING_PORT:-8001}
LIVE_DB=${LIVE_DB:-se_mobile}
DB=${STAGING_DB:-se_mobile_staging}
DB_OWNER=${STAGING_DB_OWNER:-se_mobile}
LIVE_ENV=${LIVE_ENV:-/etc/se-mobile.env}
ENV_FILE=${STAGING_ENV:-/etc/se-mobile-staging.env}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
BACKUP_DIR=${BACKUP_DIR:-/var/backups/se-mobile}
KEY=${BACKUP_KEY:-/etc/se-mobile-backup-key}
STATE_DIR=${STAGING_STATE_DIR:-/var/lib/se-mobile/staging}
SYSTEMCTL=${SYSTEMCTL:-systemctl}
# От кого ходить в PostgreSQL. На сервере — postgres; пусто — как есть, с
# PGHOST/PGUSER из окружения (так гоняют проверки).
PG_AS=${STAGING_PG_AS-postgres}
HEALTH_URL="http://127.0.0.1:$PORT/health"

HERE=$(cd "$(dirname "$0")" && pwd)
# Временная папка refresh-db. Не local: её убирает ловушка на выходе из
# скрипта, когда функции уже нет.
work=

say() { echo "==> $*"; }
die() { echo "Ошибка: $*" >&2; exit 1; }

pg() {
    if [ -n "$PG_AS" ] && [ "$(id -un)" != "$PG_AS" ]; then
        runuser -u "$PG_AS" -- "$@"
    else
        "$@"
    fi
}

# Рядом лежит или копия в /usr/local/bin (se-mobile-release), или
# репозиторий (release.sh).
release_tool() {
    if [ -x "$HERE/se-mobile-release" ]; then
        echo "$HERE/se-mobile-release"
    else
        echo "$HERE/release.sh"
    fi
}

# Последняя ночная копия: имена с датой, так что по имени и сортируются.
latest_backup() {
    local f last=
    for f in "$BACKUP_DIR"/se_mobile_*.sql.gz.enc; do
        [ -e "$f" ] && last=$f
    done
    [ -n "$last" ] && echo "$last"
}

refresh_db() {
    local source=backup copy was_active=
    [ "${1:-}" = --live ] && source=live
    # Последняя линия обороны: что бы ни было в настройках, рабочую базу
    # этот скрипт не удаляет.
    [ "$DB" != "$LIVE_DB" ] || die "база стенда совпадает с рабочей ($DB)."

    work=$(mktemp -d "${TMPDIR:-/var/tmp}/se-mobile-staging.XXXXXX")
    # Внутри — расшифрованные зарплаты: папка удаляется при любом исходе.
    # Её читает только root: psql от postgres получает дамп через конвейер.
    trap '[ -z "$work" ] || rm -rf "$work"' EXIT
    chmod 700 "$work"

    if [ "$source" = live ]; then
        say "Снимаю копию рабочей базы $LIVE_DB"
        pg pg_dump "$LIVE_DB" | gzip -1 > "$work/dump.sql.gz" \
            || die "pg_dump $LIVE_DB не прошёл."
        copy="рабочая база на $(date '+%F %T')"
    else
        copy=$(latest_backup) || die "в $BACKUP_DIR нет ни одной копии." \
            "Снимите её (systemctl start se-mobile-backup) или возьмите --live."
        [ -r "$KEY" ] || die "нет ключа $KEY — копию не расшифровать."
        say "Беру копию $(basename "$copy")"
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "file:$KEY" \
            -in "$copy" -out "$work/dump.sql.gz" 2>/dev/null \
            || die "$(basename "$copy") не расшифровывается ключом $KEY."
        gzip -t "$work/dump.sql.gz" 2>/dev/null \
            || die "$(basename "$copy") расшифровалась, но внутри битый архив."
        copy=$(basename "$copy")
    fi

    if "$SYSTEMCTL" is-active --quiet "$SERVICE" 2>/dev/null; then
        was_active=1
        "$SYSTEMCTL" stop "$SERVICE"
    fi

    say "Пересоздаю базу $DB"
    pg dropdb --if-exists "$DB"
    pg createdb -O "$DB_OWNER" "$DB"
    gzip -dc "$work/dump.sql.gz" \
        | pg psql -X -q -v ON_ERROR_STOP=1 -d "$DB" >/dev/null 2>"$work/psql.err" \
        || die "копия не легла в $DB: $(grep -m1 -i error "$work/psql.err" || tail -n 1 "$work/psql.err")"
    # Токены телефонов — настоящие. Уведомления на стенде и так выключены,
    # но пусть им и некуда будет уйти.
    pg psql -X -q -v ON_ERROR_STOP=1 -d "$DB" \
        -c "DO \$\$ BEGIN IF to_regclass('public.fcm_tokens') IS NOT NULL THEN DELETE FROM fcm_tokens; END IF; END \$\$;" \
        >/dev/null

    mkdir -p "$STATE_DIR"
    echo "$(date '+%F %T')  $copy" > "$STATE_DIR/db"
    say "База стенда — $copy"

    if [ -n "$was_active" ]; then
        "$SYSTEMCTL" start "$SERVICE"
        wait_health || die "стенд не поднялся на новой базе: journalctl -u $SERVICE -n 40"
    fi
}

wait_health() {
    local waited=0
    while (( waited < 90 )); do
        curl -fsS -o /dev/null --max-time 5 "$HEALTH_URL" 2>/dev/null && return 0
        sleep 3
        waited=$(( waited + 3 ))
    done
    return 1
}

write_env() {
    [ -r "$LIVE_ENV" ] || die "нет $LIVE_ENV — стенд берёт настройки с рабочего сервера."
    # Всё как на рабочем, кроме базы и уведомлений. Адрес базы — тот же, имя
    # базы — своё.
    {
        echo "# Настройки тестового стенда. Сделаны из $LIVE_ENV командой"
        echo "# se-mobile-staging install; отличаются базой и выключенными уведомлениями."
        grep -v -E '^(DATABASE_URL|FIREBASE_CREDENTIALS_PATH)=' "$LIVE_ENV" | grep -v '^#' | sed '/^$/d' || true
        grep -E '^DATABASE_URL=' "$LIVE_ENV" \
            | sed -E "s#^(DATABASE_URL=[^?]*/)[^/?]*#\\1$DB#" || true
        echo "FIREBASE_CREDENTIALS_PATH=/nonexistent/staging-has-no-push"
    } > "$ENV_FILE.tmp"
    grep -q "^DATABASE_URL=.*/$DB" "$ENV_FILE.tmp" \
        || { rm -f "$ENV_FILE.tmp"; die "в $LIVE_ENV нет DATABASE_URL — не из чего сделать адрес базы стенда."; }
    chmod 600 "$ENV_FILE.tmp"
    mv -f "$ENV_FILE.tmp" "$ENV_FILE"
}

install() {
    [ "$(id -u)" = 0 ] || die "запустите через sudo."
    [ -d "$LIVE_DIR/.git" ] || die "нет рабочего сервера в $LIVE_DIR."

    say "Код стенда в $STAGING_DIR"
    if [ ! -d "$STAGING_DIR/.git" ]; then
        # Тот же репозиторий и тот же ключ доступа, что у рабочего сервера.
        git clone -q --depth 1 "$(git -C "$LIVE_DIR" remote get-url origin)" "$STAGING_DIR"
        git config --global --add safe.directory "$STAGING_DIR" 2>/dev/null || true
    else
        echo "уже есть"
    fi

    say "Окружение Python"
    [ -d "$STAGING_DIR/venv" ] || python3 -m venv "$STAGING_DIR/venv"
    "$STAGING_DIR/venv/bin/pip" install -q --upgrade pip
    "$STAGING_DIR/venv/bin/pip" install -q -r "$STAGING_DIR/se-mobile-backend/requirements.txt"
    chown -R semobile:semobile "$STAGING_DIR"

    say "Настройки $ENV_FILE"
    write_env

    say "Служба $SERVICE"
    cp "$HERE/se-mobile-staging.service" "$UNIT_DIR/$SERVICE.service" 2>/dev/null \
        || cp "$LIVE_DIR/deploy/se-mobile-staging.service" "$UNIT_DIR/$SERVICE.service"
    "$SYSTEMCTL" daemon-reload

    if pg psql -X -At -d "$LIVE_DB" -c "SELECT 1 FROM pg_database WHERE datname = '$DB'" | grep -q 1; then
        say "База $DB уже есть — не трогаю (обновить: se-mobile-staging refresh-db)"
    else
        refresh_db
    fi

    "$SYSTEMCTL" restart "$SERVICE"
    wait_health || die "стенд не поднялся: journalctl -u $SERVICE -n 40"
    say "Стенд работает: $HEALTH_URL"
    status
}

deploy() {
    [ -d "$STAGING_DIR/.git" ] || die "стенда нет — сначала se-mobile-staging install."
    APP_DIR="$STAGING_DIR" VENV="$STAGING_DIR/venv" SERVICE="$SERVICE" \
    HEALTH_URL="$HEALTH_URL" AUTO_ROLLBACK=0 \
    RELEASE_STATE_DIR="$STATE_DIR/release" \
    RELEASE_LOCK="${STAGING_LOCK:-/run/lock/se-mobile-staging.lock}" \
        bash "$(release_tool)" "$@"
    echo
    echo "Посмотреть стенд с компьютера: ssh -L $PORT:127.0.0.1:$PORT ubuntu@<сервер>,"
    echo "затем http://127.0.0.1:$PORT/health в браузере. Рабочий сервер не тронут."
}

status() {
    local state
    if "$SYSTEMCTL" is-active --quiet "$SERVICE" 2>/dev/null; then state=работает; else state=остановлен; fi
    echo "Стенд:  $state ($SERVICE, $HEALTH_URL)"
    if [ -d "$STAGING_DIR/.git" ]; then
        echo "Код:    $(git -C "$STAGING_DIR" log -1 --format='%h  %s  (%cd)' --date=short)"
    else
        echo "Код:    не установлен"
    fi
    echo "Рабочий: $(git -C "$LIVE_DIR" log -1 --format='%h  %s' 2>/dev/null || echo '?')"
    echo "База:   $(cat "$STATE_DIR/db" 2>/dev/null || echo 'неизвестно')"
    if [ "$state" = работает ]; then
        if curl -fsS -o /dev/null --max-time 5 "$HEALTH_URL" 2>/dev/null; then
            echo "Health: отвечает"
        else
            echo "Health: НЕ отвечает — journalctl -u $SERVICE -n 40"
        fi
    fi
}

remove() {
    [ "$(id -u)" = 0 ] || die "запустите через sudo."
    [ "$DB" != "$LIVE_DB" ] || die "база стенда совпадает с рабочей ($DB)."
    [ "$STAGING_DIR" != "$LIVE_DIR" ] || die "папка стенда совпадает с рабочей."
    "$SYSTEMCTL" stop "$SERVICE" 2>/dev/null || true
    rm -f "$UNIT_DIR/$SERVICE.service"
    "$SYSTEMCTL" daemon-reload
    pg dropdb --if-exists "$DB"
    rm -rf "$STAGING_DIR" "$ENV_FILE" "$STATE_DIR"
    say "Стенд убран. Рабочий сервер не тронут."
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case $cmd in
    install) install ;;
    deploy) deploy "$@" ;;
    refresh-db) refresh_db "$@" ;;
    env) write_env; say "Настройки стенда обновлены: $ENV_FILE. Применить: se-mobile-staging start" ;;
    status) status ;;
    stop) "$SYSTEMCTL" stop "$SERVICE"; say "Стенд остановлен." ;;
    start) "$SYSTEMCTL" start "$SERVICE"; wait_health && say "Стенд работает: $HEALTH_URL" \
        || die "стенд не поднялся: journalctl -u $SERVICE -n 40" ;;
    remove) remove ;;
    -h|--help|'') sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "непонятная команда $cmd (см. --help)" ;;
esac
