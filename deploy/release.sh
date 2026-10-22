#!/bin/bash
# Обновление и откат сервера одной командой.
#
#     sudo se-mobile-release                 свежий main из GitHub
#     sudo se-mobile-release v1.16.18-51     метка, ветка или полный хеш коммита
#     sudo se-mobile-rollback                вернуть то, что стояло до последнего
#                                            обновления
#     sudo se-mobile-rollback v1.16.17-50    вернуть конкретную метку
#     sudo se-mobile-rollback --list         что и когда ставили, последние метки
#
# Раньше обновлялись так: git pull && systemctl restart. Вернуть прежнее после
# неудачного обновления было нечем — какой коммит стоял до pull, нигде не
# записано, а клон на сервере неполный (--depth 1), и `git log` его не
# покажет. Теперь каждое переключение записано в журнал, и откат — это
# переключение на запись назад.
#
# После перезапуска скрипт ждёт, пока /health ответит 200 (сервер жив вместе с
# базой). Не дождался — сам возвращает прежний коммит и выходит с ошибкой:
# пятьсот человек не должны сидеть на сломанном сервере, пока кто-то читает
# журнал.
#
# Базу откат НЕ возвращает. Новые колонки, которые добавил _migrate_schema,
# остаются; старый код их просто не видит. Если обновление испортило данные —
# восстановление из копии, см. deploy/README.md, «Копии зашифрованы».
#
# Тот же скрипт ставит код на тестовый стенд (deploy/staging.sh) — с другими
# APP_DIR, SERVICE и HEALTH_URL.
set -euo pipefail

APP_DIR=${APP_DIR:-/opt/se-mobile}
VENV=${VENV:-$APP_DIR/venv}
SERVICE=${SERVICE:-se-mobile}
HEALTH_URL=${HEALTH_URL:-http://127.0.0.1:8000/health}
# Сколько секунд ждать ответа после перезапуска. При старте приложение
# сверяет схему базы и досеивает выгрузки — на 2 ГБ это до полуминуты.
HEALTH_WAIT=${HEALTH_WAIT:-90}
STATE_DIR=${RELEASE_STATE_DIR:-/var/lib/se-mobile/release}
HISTORY="$STATE_DIR/history.log"
LOCK=${RELEASE_LOCK:-/run/lock/se-mobile-release.lock}
# Вернуть прежний коммит, если новый не поднялся. На стенде выключено:
# там как раз хотят увидеть, что сломалось.
AUTO_ROLLBACK=${AUTO_ROLLBACK:-1}
# Локальная ветка, на которую ставится код. Остаётся main, чтобы прежние
# команды из README (git pull перед install-*.sh) продолжали работать.
BRANCH=${RELEASE_BRANCH:-main}
SYSTEMCTL=${SYSTEMCTL:-systemctl}
OWNER=${APP_OWNER:-semobile}

say() { echo "==> $*"; }
die() { echo "Ошибка: $*" >&2; exit 1; }

usage() {
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
}

git_() { git -C "$APP_DIR" "$@"; }

short() { git_ rev-parse --short=10 "$1" 2>/dev/null || echo "${1:0:10}"; }

subject() { git_ log -1 --format=%s "$1" 2>/dev/null || true; }

have_commit() { git_ cat-file -e "$1^{commit}" 2>/dev/null; }

# Достать коммит, если его нет в неполном клоне. Глубина 1: история нам не
# нужна, а без --depth git в неполном клоне тянет её всю.
ensure_commit() {
    have_commit "$1" && return 0
    git_ fetch -q --depth 1 origin "$1" \
        || die "коммита $1 нет ни на сервере, ни в GitHub."
    have_commit "$1" || die "коммит $1 не скачался."
}

# Во что превращается то, что написали в командной строке: ветка, метка или
# хеш. Печатает полный хеш.
resolve() {
    local ref=$1 sha
    if [ -z "$ref" ]; then
        git_ fetch -q origin "$BRANCH" || die "GitHub недоступен: git fetch не прошёл."
        git_ rev-parse "refs/remotes/origin/$BRANCH"
        return
    fi
    if git_ ls-remote --exit-code -q origin "refs/heads/$ref" >/dev/null 2>&1; then
        git_ fetch -q origin "refs/heads/$ref" || die "ветка $ref не скачалась."
        git_ rev-parse FETCH_HEAD
        return
    fi
    # У метки с подписью свой объект; нужен коммит, на который она указывает
    # (строка с ^{}), — он идёт в ответе последним.
    sha=$(git_ ls-remote origin "refs/tags/$ref" "refs/tags/$ref^{}" 2>/dev/null \
        | tail -n 1 | cut -f1)
    if [ -n "$sha" ]; then
        ensure_commit "$sha"
        echo "$sha"
        return
    fi
    if sha=$(git_ rev-parse -q --verify "$ref^{commit}" 2>/dev/null); then
        echo "$sha"
        return
    fi
    if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
        ensure_commit "$ref"
        echo "$ref"
        return
    fi
    die "не нашёл «$ref»: это не ветка и не метка в GitHub, и такого коммита" \
        "нет на сервере. Коммит из GitHub указывайте полным хешем (40 знаков)."
}

# Куда откатываться без аргумента: коммит, с которого в последний раз
# обновились на тот, что стоит сейчас. Откаты в поиске не участвуют, поэтому
# второй откат подряд уходит ещё на шаг назад, а не возвращает только что
# откаченное.
previous_of() {
    [ -f "$HISTORY" ] || return 1
    awk -v cur="$1" '$2 == "release" && $4 == cur {prev = $3} END {
        if (prev == "") exit 1; print prev }' "$HISTORY"
}

record() {   # действие откуда куда что-просили
    mkdir -p "$STATE_DIR"
    echo "$(date -Is) $1 $2 $3 ${4:--}" >> "$HISTORY"
}

health() {
    local waited=0
    while (( waited < HEALTH_WAIT )); do
        if curl -fsS -o /dev/null --max-time 5 "$HEALTH_URL" 2>/dev/null; then
            return 0
        fi
        sleep 3
        waited=$(( waited + 3 ))
    done
    return 1
}

# Поставить коммит и перезапустить. Зависимости переставляются, только если
# поменялся requirements.txt: pip на каждом обновлении — лишняя минута
# простоя и лишний шанс, что PyPI недоступен.
switch_to() {
    local from=$1 to=$2 req=se-mobile-backend/requirements.txt
    git_ checkout -q -B "$BRANCH" "$to"
    if ! git_ diff --quiet "$from" "$to" -- "$req" 2>/dev/null; then
        say "Поменялись зависимости — pip install"
        "$VENV/bin/pip" install -q -r "$APP_DIR/$req"
    fi
    if [ "$(id -u)" = 0 ] && id "$OWNER" >/dev/null 2>&1; then
        chown -R "$OWNER:$OWNER" "$APP_DIR"
    fi
    say "Перезапускаю $SERVICE"
    "$SYSTEMCTL" restart "$SERVICE"
}

refresh_tools() {
    local bin=$1 src name
    for name in release staging; do
        src="$APP_DIR/deploy/$name.sh"
        [ -f "$src" ] || continue
        cp "$src" "$bin/.se-mobile-$name.new"
        chmod 755 "$bin/.se-mobile-$name.new"
        mv -f "$bin/.se-mobile-$name.new" "$bin/se-mobile-$name"
    done
}

list() {
    echo "Сейчас стоит: $(short HEAD)  $(subject HEAD)"
    echo
    if [ -s "$HISTORY" ]; then
        echo "Последние переключения (время, что, откуда, куда, что просили):"
        tail -n 15 "$HISTORY" | while read -r when what from to asked; do
            printf '  %s  %-8s %s → %s  %s\n' "${when%+*}" "$what" \
                "${from:0:10}" "${to:0:10}" "$asked"
        done
    else
        echo "Журнал переключений пуст: обновлений через se-mobile-release ещё не было."
    fi
    echo
    echo "Последние метки в GitHub (по одной на сборку приложения):"
    git_ ls-remote --tags --refs origin 'v*' 2>/dev/null \
        | sed 's#.*refs/tags/##' | sort -V | tail -n 8 | sed 's/^/  /' \
        || echo "  GitHub недоступен"
}

main() {
    local mode=release asked=
    case $(basename "$0") in *rollback*) mode=rollback ;; esac
    while [ $# -gt 0 ]; do
        case $1 in
            --rollback) mode=rollback ;;
            --list) mode=list ;;
            -h|--help) usage; exit 0 ;;
            -*) die "непонятный параметр $1 (см. --help)" ;;
            *) [ -z "$asked" ] || die "лишний параметр $1"; asked=$1 ;;
        esac
        shift
    done

    [ -d "$APP_DIR/.git" ] || die "$APP_DIR — не git-репозиторий."
    if [ "$mode" = list ]; then
        list
        return
    fi

    mkdir -p "$(dirname "$LOCK")" "$STATE_DIR"
    exec 9>"$LOCK"
    flock -n 9 || die "уже идёт другое обновление или откат."

    # Правки руками прямо на сервере checkout бы молча затёр. Неотслеживаемые
    # файлы (venv) не мешают.
    if [ -n "$(git_ status --porcelain --untracked-files=no)" ]; then
        git_ status --short --untracked-files=no >&2
        die "в $APP_DIR есть несохранённые правки (выше). Уберите их" \
            "(git -C $APP_DIR stash) или перенесите в репозиторий."
    fi

    local current target action
    current=$(git_ rev-parse HEAD)
    if [ "$mode" = rollback ] && [ -z "$asked" ]; then
        target=$(previous_of "$current") || die "не знаю, что стояло до" \
            "$(short "$current"): в журнале нет обновления на этот коммит." \
            "Укажите метку: se-mobile-rollback v… (список — se-mobile-rollback --list)."
        ensure_commit "$target"
        asked=previous
    else
        target=$(resolve "$asked")
    fi
    action=$mode

    if [ "$target" = "$current" ]; then
        say "Уже стоит $(short "$current") — $(subject "$current"). Ничего не делаю."
        return 0
    fi

    say "Было:  $(short "$current")  $(subject "$current")"
    say "Будет: $(short "$target")  $(subject "$target")"
    switch_to "$current" "$target"

    if health; then
        record "$action" "$current" "$target" "${asked:-$BRANCH}"
        say "Готово: $HEALTH_URL отвечает. Вернуть прежнее: se-mobile-rollback"
        # Сами скрипты тоже могли обновиться — кладём свежие на место. Только
        # при обновлении рабочего сервера: при откате копия была бы старше, а
        # на стенде стоит непроверенная ветка.
        if [ "$mode" = release ] && [ "$SERVICE" = se-mobile ] \
                && [ "$(basename "$0")" = se-mobile-release ]; then
            refresh_tools "$(dirname "$0")"
        fi
        return 0
    fi

    echo "$SERVICE не ответил за $HEALTH_WAIT с. Последние строки журнала:" >&2
    journalctl -u "$SERVICE" -n 25 --no-pager -o cat >&2 2>/dev/null || true
    record failed "$current" "$target" "${asked:-$BRANCH}"
    if [ "$AUTO_ROLLBACK" != 1 ]; then
        die "оставляю $(short "$target") как есть (AUTO_ROLLBACK=$AUTO_ROLLBACK)."
    fi

    say "Возвращаю прежний $(short "$current")"
    switch_to "$target" "$current"
    if health; then
        record auto-back "$target" "$current" "${asked:-$BRANCH}"
        die "$(short "$target") не поднялся, вернул $(short "$current") — он отвечает."
    fi
    die "не поднялся ни новый $(short "$target"), ни прежний $(short "$current")." \
        "Скорее всего, дело не в коде: проверьте базу (systemctl status postgresql)" \
        "и журнал (journalctl -u $SERVICE -n 50)."
}

# Всё тело — в функции: при откате checkout подменяет файлы репозитория, и
# bash, дочитывающий скрипт по ходу, иначе дочитал бы уже другой файл.
main "$@"
exit
