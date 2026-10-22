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

APK_RE='^se-mobile-[0-9]+\.[0-9]+\.[0-9]+\+([0-9]+)\.apk$'

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
cleanup() {
    rc=$?
    rm -rf "$work"
    if [ -n "$partial" ]; then rm -f -- "$partial"; fi
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

# Имя, номер сборки, адрес, размер и контрольная сумма APK из релиза. В том
# же релизе лежит AAB для Google Play — он телефонам не нужен.
asset=$(python3 - "$work/release.json" <<'PY'
import json, re, sys

try:
    release = json.load(open(sys.argv[1], encoding='utf-8'))
except ValueError:
    sys.exit(1)
if not isinstance(release, dict):
    sys.exit(1)
for a in release.get('assets') or []:
    found = re.fullmatch(r'se-mobile-\d+\.\d+\.\d+\+(\d+)\.apk', a.get('name') or '')
    if found and a.get('state') == 'uploaded':
        digest = (a.get('digest') or '').removeprefix('sha256:') or '-'
        print(a['name'], found.group(1), a['url'], a['size'], digest)
        break
PY
) || fail "GitHub прислал вместо описания релиза что-то непонятное —" \
          "попробую через десять минут."
if [ -z "$asset" ]; then
    message="В последнем релизе нет APK — жду следующего."
    echo "$message" >&2
    exit 0
fi
read -r name build url size digest <<<"$asset"

# Новее ли она того, что уже есть: и в папке, и среди забранного раньше.
have=0
if [ -r "$STATE_DIR/last-build" ]; then
    have=$(tr -dc '0-9' < "$STATE_DIR/last-build")
    have=${have:-0}
fi
for file in "$APK_DIR"/se-mobile-*.apk; do
    [ -e "$file" ] || continue
    if [[ $(basename "$file") =~ $APK_RE ]] && (( BASH_REMATCH[1] > have )); then
        have=${BASH_REMATCH[1]}
    fi
done
if (( build <= have )); then
    exit 0
fi

echo "Забираю $name из GitHub Releases"
# Сначала под временным именем: сервер видит только файлы вида
# se-mobile-1.2.3+4.apk, и недокачанный телефонам не попадёт.
partial="$APK_DIR/.download-$build"
# Место проверяем заранее: оборванный на полном диске файл ничего не
# портит, но и причину curl назовёт невнятно.
free=$(df -Pk "$APK_DIR" 2>/dev/null | awk 'NR == 2 {print $4}') || free=
if [ -n "$free" ] && (( free * 1024 < size + 50 * 1024 * 1024 )); then
    fail "На диске под $APK_DIR осталось $((free / 1024)) МБ, а сборка" \
         "$name весит $((size / 1024 / 1024)) МБ — освободите место."
fi

rc=0
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

chmod 644 "$partial"
mv -f -- "$partial" "$APK_DIR/$name"
partial=
echo "$build" > "$STATE_DIR/last-build"
message="Забрана $name"
echo "Готово: $APK_DIR/$name, телефоны увидят обновление"

# Старые сборки — кроме последних $KEEP.
for file in "$APK_DIR"/se-mobile-*.apk; do
    [ -e "$file" ] || continue
    if [[ $(basename "$file") =~ $APK_RE ]]; then
        echo "${BASH_REMATCH[1]} $file"
    fi
done | sort -rn | tail -n +$((KEEP + 1)) | while read -r _ old; do
    rm -f -- "$old"
    echo "Убрана старая сборка $(basename "$old")"
done
