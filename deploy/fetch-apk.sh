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

# Не настроено — не ошибка: таймер ставится вместе с сервером, а токен
# заводят потом. Иначе он краснел бы каждые десять минут.
if [ -z "$TOKEN" ]; then
    echo "GITHUB_TOKEN не задан в $CONFIG — новые сборки не забираются." \
         "См. deploy/README.md, «Сборка приезжает на сервер сама»."
    exit 0
fi

APK_RE='^se-mobile-[0-9]+\.[0-9]+\.[0-9]+\+([0-9]+)\.apk$'

work=$(mktemp -d)
partial=
cleanup() {
    rm -rf "$work"
    if [ -n "$partial" ]; then rm -f -- "$partial"; fi
}
trap cleanup EXIT

code=$(curl -sS --max-time 30 -o "$work/release.json" -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    "$API/repos/$REPO/releases/latest") || {
    echo "GitHub не отвечает — попробую через десять минут." >&2
    exit 1
}
case $code in
    200) ;;
    401) echo "GitHub не принял токен: истёк срок или его отозвали." \
              "Заведите новый и впишите в $CONFIG." >&2
         exit 1 ;;
    403|404) echo "GitHub ответил $code: у токена нет доступа к $REPO" \
                  "(нужно «Contents: Read-only») или релизов ещё нет." >&2
             exit 1 ;;
    *) echo "GitHub ответил $code — попробую через десять минут." >&2
       exit 1 ;;
esac

# Имя, номер сборки, адрес, размер и контрольная сумма APK из релиза. В том
# же релизе лежит AAB для Google Play — он телефонам не нужен.
asset=$(python3 - "$work/release.json" <<'PY'
import json, re, sys

release = json.load(open(sys.argv[1], encoding='utf-8'))
for a in release.get('assets') or []:
    found = re.fullmatch(r'se-mobile-\d+\.\d+\.\d+\+(\d+)\.apk', a.get('name') or '')
    if found and a.get('state') == 'uploaded':
        digest = (a.get('digest') or '').removeprefix('sha256:') or '-'
        print(a['name'], found.group(1), a['url'], a['size'], digest)
        break
PY
)
if [ -z "$asset" ]; then
    echo "В последнем релизе нет APK — жду следующего." >&2
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
curl -fsS -L --max-time 900 --retry 2 \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/octet-stream' \
    -o "$partial" "$url"

got=$(stat -c %s "$partial")
if [ "$got" != "$size" ]; then
    echo "Скачалось $got байт вместо $size — файл не беру." >&2
    exit 1
fi
if [ "$digest" != "-" ]; then
    sum=$(sha256sum "$partial" | cut -d' ' -f1)
    if [ "$sum" != "$digest" ]; then
        echo "Контрольная сумма не сходится ($sum, а в релизе $digest) —" \
             "файл не беру." >&2
        exit 1
    fi
fi

chmod 644 "$partial"
mv -f -- "$partial" "$APK_DIR/$name"
partial=
mkdir -p "$STATE_DIR"
echo "$build" > "$STATE_DIR/last-build"
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
