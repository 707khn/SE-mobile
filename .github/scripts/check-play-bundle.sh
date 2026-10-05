#!/bin/bash
# Пропустит ли Google Play этот .aab — по тем признакам, за которые он
# отклоняет без разговоров. Смотрим итоговый манифест: он собирается из
# манифеста приложения и всех плагинов, и разрешение, которого нет у нас,
# может принести любой из них.
#
# В .aab манифест лежит в protobuf, строки в нём — обычный UTF-8, так что
# хватает unzip и grep.
set -euo pipefail

AAB=${1:?путь к .aab}
EXPECTED_PACKAGE=${2:-com.sebtrz.mobile}
manifest=$(unzip -p "$AAB" base/manifest/AndroidManifest.xml | tr -c '[:print:]' '\n')

fail=0
# Строки в protobuf идут подряд с байтами разметки, и рядом с именем может
# оказаться печатный символ — поэтому ищем имя целиком, но не всю строку.
escaped=${EXPECTED_PACKAGE//./\\.}
if ! grep -qE "(^|[^A-Za-z0-9_.])${escaped}([^A-Za-z0-9_.]|$)" <<<"$manifest"; then
    echo "::error::В $AAB нет пакета $EXPECTED_PACKAGE — собрано без --dart-define=STORE=play?"
    echo "Похожие на имя пакета строки в манифесте:"
    grep -oE '[a-z][a-z0-9_]*(\.[a-z0-9_]+){2,}' <<<"$manifest" | sort -u | head -20 | sed 's/^/  /'
    fail=1
fi
for permission in QUERY_ALL_PACKAGES MANAGE_EXTERNAL_STORAGE REQUEST_INSTALL_PACKAGES \
                  READ_EXTERNAL_STORAGE WRITE_EXTERNAL_STORAGE USE_EXACT_ALARM; do
    if grep -q "android.permission.$permission" <<<"$manifest"; then
        echo "::error::В $AAB есть android.permission.$permission — Google Play такое без особого обоснования отклоняет."
        fail=1
    fi
done
echo "Разрешения в сборке:"
grep -o 'android\.permission\.[A-Z_]*' <<<"$manifest" | sort -u | sed 's/^/  /'
exit $fail
