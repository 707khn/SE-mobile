#!/bin/bash
# Забирает новую сборку приложения из GitHub Releases и кладёт её туда,
# откуда её скачивают телефоны.
#
# Раньше APK переносили руками: скачать из Releases на компьютер, scp на
# сервер, mv в /var/www/se-mobile. Шаг забывали, а scp обрывался на середине:
# сборка 1.16.17 лежала в Releases, а телефонам сервер предлагал 1.15.2.
# Теперь это делает таймер раз в десять минут.
#
# Берётся только сборка новее всех, что уже забирались. Убрали плохую сборку
# из папки — обратно она не вернётся, а следующая приедет как обычно. Чтобы
# забрать её заново, удалите файл $STATE_DIR/last-build.
set -euo pipefail

CONFIG=${FETCH_APK_CONFIG:-/etc/se-mobile-fetch-apk.env}
if [ -r "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG"
fi
REPO=${GITHUB_REPO:-707khn/SE-mobile}
API=${GITHUB_API:-https://api.github.com}
APK_DIR=${APK_DIR:-/var/www/se-mobile}
STATE_DIR=${FETCH_APK_STATE_DIR:-/var/lib/se-mobile/fetch-apk}
# Сколько сборок держать в папке: предыдущие — чтобы было куда откатиться.
KEEP=${APK_KEEP:-3}
TOKEN=${GITHUB_TOKEN:-}
# Веб-версия — распакованной: её отдаёт nginx по адресу /web/ (см.
# deploy/nginx-se-mobile.conf). Внутри той же папки, что и сборки, — туда
# служба таймера уже может писать.
WEB_DIR=${WEB_DIR:-$APK_DIR/web}

APK_RE='^se-mobile-[0-9]+\.[0-9]+\.[0-9]+\+([0-9]+)\.apk$'
WINDOWS_RE='^SemEng-windows-[0-9]+\.[0-9]+\.[0-9]+\+([0-9]+)\.zip$'
WEB_RE='^se-mobile-web-[0-9]+\.[0-9]+\.[0-9]+\+([0-9]+)\.zip$'

# Чем кончился последний запуск — для экрана «Обновление» в приложении.
# Журнал systemd читает только root, и истёкший токен две недели краснел бы
# там, никем не замеченный: телефонам просто перестали бы приезжать сборки.
# Сервер читает этот файл и показывает причину администратору.
STATUS="$STATE_DIR/status"
result=ok
message=
token_expires=

mkdir -p "$STATE_DIR" || {
    echo "Не могу создать $STATE_DIR — некуда записать, что уже забрано." >&2
    exit 1
}

# Таймер не запустит второй экземпляр, а человек из консоли — запросто.
# Двое качали бы в один и тот же .download-N и портили друг другу файл.
exec 9>"$STATE_DIR/lock"
if ! flock -n 9; then
    echo "Уже идёт другой запуск — этот пропускаю."
    exit 0
fi

work=$(mktemp -d)
partial=
unpacking=
cleanup() {
    rc=$?
    rm -rf "$work"
    if [ -n "$partial" ]; then rm -f -- "$partial"; fi
    if [ -n "$unpacking" ]; then rm -rf -- "$unpacking"; fi
    # Упали не там, где ждали (set -e) — всё равно сказать, что упали.
    if [ "$rc" != 0 ] && [ "$result" = ok ]; then
        result=fail
        message="Запуск оборвался с кодом $rc — см. journalctl -u se-mobile-fetch-apk"
    fi
    {
        echo "checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "result=$result"
        echo "message=$message"
        echo "token_expires=$token_expires"
    } > "$STATUS.tmp" 2>/dev/null && chmod 644 "$STATUS.tmp" \
        && mv -f -- "$STATUS.tmp" "$STATUS" || true
}
trap cleanup EXIT

# Ошибка: в журнал и в отметку о запуске, одним и тем же текстом.
fail() {
    result=fail
    message=$*
    echo "$*" >&2
    exit 1
}

# Не настроено — не ошибка: таймер ставится вместе с сервером, а токен
# заводят потом. Иначе он краснел бы каждые десять минут.
if [ -z "$TOKEN" ]; then
    result=no-token
    message="GITHUB_TOKEN не задан в $CONFIG — новые сборки не забираются."
    echo "$message См. deploy/README.md, «Сборка приезжает на сервер сама»."
    exit 0
fi

code=$(curl -sS --max-time 30 -o "$work/release.json" -D "$work/headers" \
    -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    "$API/repos/$REPO/releases/latest") \
    || fail "GitHub не отвечает — попробую через десять минут."

# Срок токена GitHub называет сам — в каждом ответе. Узнать его заранее
# лучше, чем по первому 401.
token_expires=$(sed -n 's/^github-authentication-token-expiration: *//Ip' \
    "$work/headers" | tr -d '\r' | tail -n 1)

case $code in
    200) ;;
    401) fail "GitHub не принял токен: истёк срок или его отозвали." \
              "Заведите новый и впишите в $CONFIG." ;;
    403|404) fail "GitHub ответил $code: у токена нет доступа к $REPO" \
                  "(нужно «Contents: Read-only») или релизов ещё нет." ;;
    *) fail "GitHub ответил $code — попробую через десять минут." ;;
esac

# Что взять из релиза: APK и архив версии для компьютера — по строке на
# каждый: вид, имя, номер сборки, адрес, размер и контрольная сумма. В том же
# релизе лежит AAB для Google Play — он серверу не нужен.
assets=$(python3 - "$work/release.json" <<'PY'
import json, re, sys

try:
    release = json.load(open(sys.argv[1], encoding='utf-8'))
except ValueError:
    sys.exit(1)
if not isinstance(release, dict):
    sys.exit(1)
kinds = (
    ('apk', r'se-mobile-\d+\.\d+\.\d+\+(\d+)\.apk'),
    ('windows', r'SemEng-windows-\d+\.\d+\.\d+\+(\d+)\.zip'),
    ('web', r'se-mobile-web-\d+\.\d+\.\d+\+(\d+)\.zip'),
)
for kind, pattern in kinds:
    for a in release.get('assets') or []:
        found = re.fullmatch(pattern, a.get('name') or '')
        if found and a.get('state') == 'uploaded':
            digest = (a.get('digest') or '').removeprefix('sha256:') or '-'
            print(kind, a['name'], found.group(1), a['url'], a['size'], digest)
            break
PY
) || fail "GitHub прислал вместо описания релиза что-то непонятное —" \
          "попробую через десять минут."

# Забирает сборку одного вида, если она новее всех, что уже есть: и в
# папке, и среди забранного раньше.
take() {
    local kind=$1 name=$2 build=$3 url=$4 size=$5 digest=$6
    local re glob last who
    case $kind in
        apk)
            re=$APK_RE; glob='se-mobile-*.apk'
            last="$STATE_DIR/last-build"; who='телефоны' ;;
        windows)
            re=$WINDOWS_RE; glob='SemEng-windows-*.zip'
            last="$STATE_DIR/last-build-windows"; who='компьютеры' ;;
        web)
            re=$WEB_RE; glob='se-mobile-web-*.zip'
            last="$STATE_DIR/last-build-web"; who='браузеры (/web/)' ;;
    esac

    local have=0 file
    if [ -r "$last" ]; then
        have=$(tr -dc '0-9' < "$last")
        have=${have:-0}
    fi
    for file in "$APK_DIR"/$glob; do
        [ -e "$file" ] || continue
        if [[ $(basename "$file") =~ $re ]] && (( BASH_REMATCH[1] > have )); then
            have=${BASH_REMATCH[1]}
        fi
    done
    if (( build <= have )); then
        return 0
    fi

    echo "Забираю $name из GitHub Releases"
    # Сначала под временным именем: сервер видит только файлы вида
    # se-mobile-1.2.3+4.apk, и недокачанный телефонам не попадёт.
    partial="$APK_DIR/.download-$kind-$build"
    # Место проверяем заранее: оборванный на полном диске файл ничего не
    # портит, но и причину curl назовёт невнятно.
    local free
    free=$(df -Pk "$APK_DIR" 2>/dev/null | awk 'NR == 2 {print $4}') || free=
    if [ -n "$free" ] && (( free * 1024 < size + 50 * 1024 * 1024 )); then
        fail "На диске под $APK_DIR осталось $((free / 1024)) МБ, а сборка" \
             "$name весит $((size / 1024 / 1024)) МБ — освободите место."
    fi

    local rc=0
    curl -fsS -L --max-time 900 --retry 2 \
        -H "Authorization: Bearer $TOKEN" \
        -H 'Accept: application/octet-stream' \
        -o "$partial" "$url" || rc=$?
    case $rc in
        0) ;;
        22) fail "GitHub не отдал файл $name (ошибка HTTP) — попробую через" \
                 "десять минут." ;;
        23) fail "Не удалось записать $partial — нет места или прав на $APK_DIR." ;;
        28) fail "$name не скачался за пятнадцать минут — попробую ещё." ;;
        *) fail "$name не скачался (curl, код $rc) — попробую через десять минут." ;;
    esac

    local got sum
    got=$(stat -c %s "$partial")
    if [ "$got" != "$size" ]; then
        fail "Скачалось $got байт вместо $size — файл не беру."
    fi
    if [ "$digest" != "-" ]; then
        sum=$(sha256sum "$partial" | cut -d' ' -f1)
        if [ "$sum" != "$digest" ]; then
            fail "Контрольная сумма не сходится ($sum, а в релизе $digest) —" \
                 "файл не беру."
        fi
    fi

    # Веб-версию — сначала разложить: не разложилась — архив не берём, и
    # следующий запуск попробует снова, а в /web/ остаётся прежняя.
    if [ "$kind" = web ]; then
        publish_web "$partial" "$name" "$build"
    fi

    chmod 644 "$partial"
    mv -f -- "$partial" "$APK_DIR/$name"
    partial=
    echo "$build" > "$last"
    message="${message:+$message; }Забрана $name"
    echo "Готово: $APK_DIR/$name, $who увидят обновление"

    # Старые сборки — кроме последних $KEEP.
    for file in "$APK_DIR"/$glob; do
        [ -e "$file" ] || continue
        if [[ $(basename "$file") =~ $re ]]; then
            echo "${BASH_REMATCH[1]} $file"
        fi
    done | sort -rn | tail -n +$((KEEP + 1)) | while read -r _ old; do
        rm -f -- "$old"
        echo "Убрана старая сборка $(basename "$old")"
    done
}

# Раскладывает архив веб-версии в $WEB_DIR/<сборка> и переключает на неё
# $WEB_DIR/current. Переключение — одно переименование ссылки: открывший
# страницу в эту секунду получит либо прежнюю сборку целиком, либо новую.
publish_web() {
    local zip=$1 name=$2 build=$3
    mkdir -p "$WEB_DIR" || fail "Не могу создать $WEB_DIR для веб-версии."
    unpacking="$WEB_DIR/.unpack-$build"
    rm -rf -- "$unpacking"
    # zipfile из питона сам отбрасывает в именах «..» и начальный «/»: из
    # архива ничего не выйдет за пределы папки.
    python3 -m zipfile -e "$zip" "$unpacking" \
        || fail "Архив $name не распаковался — веб-версию не меняю."
    [ -f "$unpacking/index.html" ] \
        || fail "В архиве $name нет index.html — веб-версию не меняю."
    chmod -R u=rwX,go=rX "$unpacking"
    rm -rf -- "${WEB_DIR:?}/$build"
    mv -- "$unpacking" "$WEB_DIR/$build"
    unpacking=
    ln -sfn "$build" "$WEB_DIR/.current-$build"
    mv -Tf -- "$WEB_DIR/.current-$build" "$WEB_DIR/current"

    # Прежние сборки — кроме последних $KEEP: на них можно вернуться,
    # переставив current руками.
    local dir
    for dir in "$WEB_DIR"/*/; do
        dir=${dir%/}
        if [[ $(basename "$dir") =~ ^[0-9]+$ ]] && [ ! -L "$dir" ]; then
            echo "$(basename "$dir") $dir"
        fi
    done | sort -rn | tail -n +$((KEEP + 1)) | while read -r _ old; do
        rm -rf -- "$old"
        echo "Убрана старая веб-версия $(basename "$old")"
    done
}

if ! grep -q '^apk ' <<<"$assets"; then
    message="В последнем релизе нет APK — жду следующего."
    echo "$message" >&2
fi
# Архива для компьютера в релизе может и не быть: он собирается не с каждой
# версией. Тогда на сервере остаётся прежний.
while read -r kind name build url size digest; do
    [ -n "$kind" ] || continue
    take "$kind" "$name" "$build" "$url" "$size" "$digest"
done <<<"$assets"
