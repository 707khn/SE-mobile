#!/bin/bash
# Выкладка без SSH: забирает свежий main, если его проверки зелёные,
# перезапускает приложение, спрашивает /health и при сбое откатывается.
#
# Раньше каждое серверное исправление ждало, пока кто-нибудь зайдёт по SSH и
# сделает `git pull && systemctl restart se-mobile`. Теперь это делает таймер
# se-mobile-autodeploy раз в пять минут (deploy/install-autodeploy.sh).
#
# Порядок:
#   1. git fetch; main не сдвинулся — выходим.
#   2. Если менялся код сервера (se-mobile-backend/), ждём зелёного
#      «Проверки сервера» (backend.yml) именно на этом коммите. Красный —
#      не выкладываем и шлём сигнал. Правки без кода сервера (приложение,
#      документация) просто подтягиваются, без перезапуска.
#   3. git merge --ff-only; поменялся requirements.txt — pip install.
#   4. systemctl restart se-mobile и до HEALTH_WAIT секунд ждём /health = 200.
#   5. Не дождались — git reset на прежний коммит, pip, перезапуск, сигнал.
#      Неудачный коммит запоминается, и второй раз его не берём: следующая
#      попытка — на следующем коммите в main.
#
# Токен GitHub — тот же, что у fetch-apk (/etc/se-mobile-fetch-apk.env), но
# ему нужно ещё право «Actions: Read-only», см. deploy/README.md,
# «Выкладка без SSH».
set -euo pipefail

CONFIG=${AUTODEPLOY_CONFIG:-/etc/se-mobile-fetch-apk.env}
if [ -r "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG"
fi
APP_DIR=${APP_DIR:-/opt/se-mobile}
BRANCH=${DEPLOY_BRANCH:-main}
REPO=${GITHUB_REPO:-707khn/SE-mobile}
API=${GITHUB_API:-https://api.github.com}
TOKEN=${GITHUB_TOKEN:-}
WORKFLOW=${DEPLOY_WORKFLOW:-backend.yml}
SERVICE=${DEPLOY_SERVICE:-se-mobile}
HEALTH_URL=${HEALTH_URL:-http://127.0.0.1:8000/health}
HEALTH_WAIT=${HEALTH_WAIT:-90}
PIP=${DEPLOY_PIP:-$APP_DIR/venv/bin/pip}
NOTIFY=${NOTIFY:-$APP_DIR/deploy/notify.sh}
STATE_DIR=${AUTODEPLOY_STATE_DIR:-/var/lib/se-mobile/autodeploy}
STATUS="$STATE_DIR/status"
BAD="$STATE_DIR/bad-commit"
LOG="$STATE_DIR/deploys.log"

result=ok
message=
deployed=

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
if ! flock -n 9; then
    echo "Уже идёт другая выкладка — эту пропускаю."
    exit 0
fi

work=$(mktemp -d)
cleanup() {
    rc=$?
    rm -rf "$work"
    if [ "$rc" != 0 ] && [ "$result" = ok ]; then
        result=fail
        message="Выкладка оборвалась с кодом $rc — см. journalctl -u se-mobile-autodeploy"
    fi
    {
        echo "checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "result=$result"
        echo "message=$message"
        echo "commit=$(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || true)"
        echo "deployed=$deployed"
    } > "$STATUS.tmp" 2>/dev/null && chmod 644 "$STATUS.tmp" \
        && mv -f -- "$STATUS.tmp" "$STATUS" || true
}
trap cleanup EXIT

say() { bash "$NOTIFY" "$*" || true; }
log() { echo "$(date -Is) $*" >> "$LOG"; echo "$*"; }

cd "$APP_DIR"
git fetch -q origin "$BRANCH"
current=$(git rev-parse HEAD)
target=$(git rev-parse "origin/$BRANCH")
short=${target:0:7}

if [ "$current" = "$target" ]; then
    exit 0
fi
if [ "$(cat "$BAD" 2>/dev/null || true)" = "$target" ]; then
    result=bad-commit
    message="$short уже откатывали — жду следующего коммита в $BRANCH."
    exit 0
fi
if ! git merge-base --is-ancestor "$current" "$target"; then
    result=fail
    message="На сервере коммит, которого нет в $BRANCH ($(git rev-parse --short HEAD)) — выложите руками."
    [ -e "$STATE_DIR/diverged" ] || { touch "$STATE_DIR/diverged"; say "Выкладка стоит: $message"; }
    exit 0
fi
rm -f "$STATE_DIR/diverged"

changed=$(git diff --name-only "$current" "$target")
backend=$(printf '%s\n' "$changed" | grep -E '^se-mobile-backend/' | grep -vE '^se-mobile-backend/tests/' || true)

if [ -n "$backend" ]; then
    if [ -z "$TOKEN" ]; then
        result=no-token
        message="GITHUB_TOKEN не задан в $CONFIG — без него не узнать, зелёные ли проверки."
        exit 0
    fi
    # Проверки запускаются не на каждом коммите, а на тех, что трогают их
    # пути (см. on.push.paths в backend.yml). Значит, смотрим последний
    # такой коммит до target: на нём и лежит вердикт для этого кода.
    checked=$(git log -1 --first-parent --format=%H "$target" -- \
        se-mobile-backend deploy .github/workflows/backend.yml)
    code=$(curl -sS --max-time 30 -o "$work/runs.json" -w '%{http_code}' \
        -H "Authorization: Bearer $TOKEN" \
        -H 'Accept: application/vnd.github+json' \
        "$API/repos/$REPO/actions/workflows/$WORKFLOW/runs?head_sha=$checked&event=push&per_page=20") \
        || { result=fail; message="GitHub не отвечает — попробую через пять минут."; exit 0; }
    case $code in
        200) ;;
        401) result=fail; message="GitHub не принял токен — заведите новый, впишите в $CONFIG."; exit 0 ;;
        403|404) result=fail; message="GitHub ответил $code: токену нужно право «Actions: Read-only» на $REPO."; exit 0 ;;
        *) result=fail; message="GitHub ответил $code — попробую через пять минут."; exit 0 ;;
    esac
    # Последний запуск проверок на этом коммите: success, failure, … или
    # pending (идёт) и none (ещё не начался).
    verdict=$(python3 - "$work/runs.json" <<'PY'
import json, sys
runs = json.load(open(sys.argv[1])).get('workflow_runs') or []
runs.sort(key=lambda r: r.get('run_started_at') or r.get('created_at') or '', reverse=True)
if not runs:
    print('none')
elif runs[0].get('status') != 'completed':
    print('pending')
else:
    print(runs[0].get('conclusion') or 'unknown')
PY
)
    case $verdict in
        success) ;;
        none|pending)
            result=waiting
            message="Жду проверок сервера на ${checked:0:7}."
            exit 0 ;;
        *)
            result=red
            message="Проверки сервера на ${checked:0:7}: $verdict — не выкладываю $short."
            echo "$target" > "$BAD"
            say "Выкладка $short пропущена: проверки сервера — $verdict."
            exit 0 ;;
    esac
fi

subject=$(git log -1 --format=%s "$target")
git merge --ff-only -q "$target"

rollback() {
    log "откат $short → ${current:0:7}: $1"
    git reset -q --hard "$current"
    "$PIP" install -q -r se-mobile-backend/requirements.txt || true
    systemctl restart "$SERVICE" || true
    echo "$target" > "$BAD"
    result=rolled-back
    message="$short откачен: $1"
    say "Выкладка $short откачена на ${current:0:7}: $1"
    exit 0
}

if printf '%s\n' "$changed" | grep -qx 'se-mobile-backend/requirements.txt'; then
    "$PIP" install -q -r se-mobile-backend/requirements.txt \
        || rollback "pip install не прошёл"
fi

# Файлы, которые не подхватываются сами: их ставят руками.
manual=$(printf '%s\n' "$changed" | grep -E '^deploy/(se-mobile\.service|nginx-se-mobile\.conf|setup\.sh|install-.*\.sh)$' || true)

if [ -z "$backend" ]; then
    deployed="$short"
    log "подтянут $short без перезапуска: $subject"
    [ -z "$manual" ] || say "В $short изменились $(echo $manual) — их ставят руками, см. deploy/README.md."
    exit 0
fi

systemctl restart "$SERVICE" || rollback "systemctl restart не прошёл"

ok=
for _ in $(seq 1 $((HEALTH_WAIT / 3))); do
    sleep 3
    if curl -fsS --max-time 5 -o /dev/null "$HEALTH_URL"; then
        ok=1
        break
    fi
done
[ -n "$ok" ] || rollback "/health не ответил за $HEALTH_WAIT с"

deployed="$short"
log "выложен $short: $subject"
note=""
[ -z "$manual" ] || note=" Изменились $(echo $manual) — их ставят руками."
say "Выложено $short: $subject.$note"
