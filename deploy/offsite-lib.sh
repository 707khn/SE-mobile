# Общее для deploy/backup-offsite.sh и deploy/restore-test.sh: настройки
# внешнего хранилища и запросы к нему. Подключается через `.`, сам не
# запускается.
#
# Хранилище — любое S3-совместимое (объектное хранилище PS Cloud, Yandex
# Object Storage, MinIO, сам Amazon S3). Запросы подписывает curl
# (--aws-sigv4), поэтому ни aws-cli, ни rclone на сервер ставить не нужно.

OFFSITE_CONFIG=${OFFSITE_CONFIG:-/etc/se-mobile-offsite.env}
if [ -r "$OFFSITE_CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$OFFSITE_CONFIG"
fi
# Адрес хранилища без имени корзины: https://s3.example.kz
OFFSITE_ENDPOINT=${OFFSITE_ENDPOINT:-}
OFFSITE_ENDPOINT=${OFFSITE_ENDPOINT%/}
OFFSITE_BUCKET=${OFFSITE_BUCKET:-}
OFFSITE_ACCESS_KEY=${OFFSITE_ACCESS_KEY:-}
OFFSITE_SECRET_KEY=${OFFSITE_SECRET_KEY:-}
# Регион нужен только для подписи. Большинство хранилищ, кроме Amazon,
# принимают любой, а без явного ждут us-east-1.
OFFSITE_REGION=${OFFSITE_REGION:-us-east-1}
# Папка внутри корзины: в одной корзине могут жить и другие копии.
OFFSITE_PREFIX=${OFFSITE_PREFIX:-se-mobile/}
case $OFFSITE_PREFIX in
    ''|*/) ;;
    *) OFFSITE_PREFIX="$OFFSITE_PREFIX/" ;;
esac

BACKUP_DIR=${BACKUP_DIR:-/var/backups/se-mobile}
BACKUP_RE='^se_mobile_([0-9]{4}-[0-9]{2}-[0-9]{2})\.sql\.gz\.enc$'

offsite_configured() {
    [ -n "$OFFSITE_ENDPOINT" ] && [ -n "$OFFSITE_BUCKET" ] \
        && [ -n "$OFFSITE_ACCESS_KEY" ] && [ -n "$OFFSITE_SECRET_KEY" ]
}

# Запрос к хранилищу. Первым аргументом — путь после корзины (с ?query, если
# нужен), дальше — что добавить curl. Пишет код ответа в stdout; тело — куда
# скажут через -o. Ключ передаётся через конфигурацию curl на stdin, а не
# аргументом: аргументы видны в ps любому пользователю сервера.
s3() {
    local path=$1 user
    shift
    user="$OFFSITE_ACCESS_KEY:$OFFSITE_SECRET_KEY"
    user=${user//\\/\\\\}
    user=${user//\"/\\\"}
    # Нет связи — код 000, а не выход с ошибкой: что делать, решает тот, кто
    # спрашивал, и объясняет s3_error.
    printf 'user = "%s"\n' "$user" \
        | curl -sS --max-time "${S3_MAX_TIME:-120}" --config - \
            --aws-sigv4 "aws:amz:$OFFSITE_REGION:s3" \
            -w '%{http_code}' "$@" \
            "$OFFSITE_ENDPOINT/$OFFSITE_BUCKET/$path" || true
}

# Что лежит в хранилище под нашей папкой: строка «имя размер etag» на
# объект, только копии базы. Длинный список хранилище отдаёт частями.
s3_list() {
    local out=$1 token='' page code
    page=$(mktemp)
    : > "$out"
    while :; do
        local query="list-type=2&prefix=$(s3_quote "$OFFSITE_PREFIX")"
        if [ -n "$token" ]; then
            query="$query&continuation-token=$(s3_quote "$token")"
        fi
        code=$(s3 "?$query" -o "$page")
        if [ "$code" != 200 ]; then
            S3_ERROR=$(s3_error "$code" "$page")
            rm -f "$page"
            return 1
        fi
        token=$(python3 - "$page" "$OFFSITE_PREFIX" "$out" <<'PY'
import re, sys
import xml.etree.ElementTree as ET

page, prefix, out = sys.argv[1:4]
root = ET.parse(page).getroot()
ns = root.tag[:root.tag.index('}') + 1] if root.tag.startswith('{') else ''
with open(out, 'a', encoding='utf-8') as f:
    for item in root.iter(ns + 'Contents'):
        key = item.findtext(ns + 'Key') or ''
        name = key[len(prefix):]
        if not re.fullmatch(r'se_mobile_\d{4}-\d{2}-\d{2}\.sql\.gz\.enc', name):
            continue
        size = item.findtext(ns + 'Size') or '0'
        etag = (item.findtext(ns + 'ETag') or '').strip('"') or '-'
        f.write(f'{name} {size} {etag}\n')
if (root.findtext(ns + 'IsTruncated') or '').lower() == 'true':
    print(root.findtext(ns + 'NextContinuationToken') or '')
PY
        ) || { S3_ERROR="хранилище прислало вместо списка что-то непонятное"; rm -f "$page"; return 1; }
        [ -n "$token" ] || break
    done
    rm -f "$page"
    sort -o "$out" "$out"
}

s3_quote() {
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="-_.~"))' "$1"
}

# Человеческое объяснение ответа хранилища: код и <Code> из тела ошибки.
s3_error() {
    local code=$1 body=$2 what
    what=$(sed -n 's:.*<Code>\(.*\)</Code>.*:\1:p' "$body" 2>/dev/null | head -n 1)
    case $code in
        000) echo "хранилище $OFFSITE_ENDPOINT не отвечает" ;;
        301|307) echo "хранилище отправляет на другой адрес ($what) — проверьте OFFSITE_ENDPOINT и OFFSITE_REGION" ;;
        403) echo "хранилище не принимает ключ ($what) — проверьте OFFSITE_ACCESS_KEY, OFFSITE_SECRET_KEY и права на корзину" ;;
        404) echo "нет корзины $OFFSITE_BUCKET ($what)" ;;
        *) echo "хранилище ответило $code${what:+ ($what)}" ;;
    esac
}
