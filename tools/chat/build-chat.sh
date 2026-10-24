#!/bin/bash
# Собирает клиент конфиденциального чата SE-chat и кладёт его в пакет
# SE-mobile (assets/sechat) — для вкладки «Чат».
#
#   tools/chat/build-chat.sh <путь к клону SE-chat> [https://адрес-сервера-чата]
#
# Код чата лежит в сборке SE-mobile, а не скачивается с сервера: подменить
# его, взломав сервер чата, нельзя. Поэтому собранные файлы хранятся в
# репозитории и проходят ревью, как любой другой код, а в
# assets/sechat/SOURCE записано, из какого коммита SE-chat они собраны.
#
# С адресом сервера политика безопасности страницы (CSP) разрешает
# соединения только с ним. Тот же адрес передаётся сборке приложения:
#   flutter build apk --release --dart-define=CHAT_URL=https://адрес-сервера-чата
set -euo pipefail

SECHAT=${1:?путь к клону SE-chat}
SERVER=${2:-}
HERE=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$HERE/assets/sechat"

commit=$(git -C "$SECHAT" rev-parse HEAD)
if [ -n "$(git -C "$SECHAT" status --porcelain -- web)" ]; then
    echo "В $SECHAT/web есть незакоммиченные правки — собирайте из коммита." >&2
    exit 1
fi

(
    cd "$SECHAT/web"
    npm ci --no-audit --no-fund
    SECHAT_SERVER_URL="$SERVER" npm run build:embed
)

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$SECHAT/web/dist-embed/." "$OUT/"
{
    echo "SE-chat $commit"
    echo "server ${SERVER:-любой https (CSP не привязан к адресу)}"
} > "$OUT/SOURCE"

echo "Готово: $OUT (SE-chat ${commit:0:7})"
