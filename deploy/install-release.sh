#!/bin/bash
# Ставит команды обновления, отката и тестового стенда:
#
#     sudo bash /opt/se-mobile/deploy/install-release.sh
#
# se-mobile-release, se-mobile-rollback и se-mobile-staging ложатся копиями
# в /usr/local/bin, а не запускаются из репозитория: откат подменяет файлы
# репозитория на старые, и в коммите полугодовой давности этих скриптов
# может не быть вовсе. Свежие копии se-mobile-release кладёт сам после
# каждого удачного обновления. Повторный запуск безопасен.
set -euo pipefail

APP_DIR=${APP_DIR:-/opt/se-mobile}
BIN=${BIN:-/usr/local/bin}

if [ "$(id -u)" != 0 ]; then
    echo "Запустите через sudo." >&2
    exit 1
fi

install -m 755 "$APP_DIR/deploy/release.sh" "$BIN/se-mobile-release"
install -m 755 "$APP_DIR/deploy/staging.sh" "$BIN/se-mobile-staging"
# Откат — та же программа: по имени, которым её позвали, она понимает, что
# делать.
ln -sfn se-mobile-release "$BIN/se-mobile-rollback"
mkdir -p /var/lib/se-mobile/release

echo "Поставлены se-mobile-release, se-mobile-rollback, se-mobile-staging."
echo "Что сейчас стоит: se-mobile-rollback --list"
