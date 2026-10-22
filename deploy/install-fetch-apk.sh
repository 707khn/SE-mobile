#!/bin/bash
# Ставит таймер, который забирает новые сборки из GitHub Releases
# (deploy/fetch-apk.sh). Отдельно от setup.sh, чтобы на работающем сервере
# не прогонять установку целиком:
#
#     sudo bash /opt/se-mobile/deploy/install-fetch-apk.sh
#
# Повторный запуск безопасен: токен не трогается, службы переписываются.
set -euo pipefail

APP_DIR=${APP_DIR:-/opt/se-mobile}
CONFIG=/etc/se-mobile-fetch-apk.env

if [ "$(id -u)" != 0 ]; then
    echo "Запустите через sudo." >&2
    exit 1
fi

mkdir -p /var/www/se-mobile /var/lib/se-mobile/fetch-apk

if [ ! -f "$CONFIG" ]; then
    cat > "$CONFIG" <<'ENV'
# Токен GitHub только на чтение релизов — см. deploy/README.md,
# «Сборка приезжает на сервер сама». Впишите после знака равенства.
GITHUB_TOKEN=
ENV
    echo "создан $CONFIG — впишите в него токен"
fi
# Токен открывает репозиторий: читать его может только root.
chown root:root "$CONFIG"
chmod 600 "$CONFIG"

# Скрипт запускается прямо из репозитория, а не из копии в /usr/local/bin:
# после git pull работает новый, и копию не надо помнить обновлять.
cat > /etc/systemd/system/se-mobile-fetch-apk.service <<UNIT
[Unit]
Description=Новая сборка SE-mobile из GitHub Releases
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash $APP_DIR/deploy/fetch-apk.sh
# Писать — только в папку сборок и в свою отметку.
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=/var/www/se-mobile /var/lib/se-mobile/fetch-apk
UNIT
cat > /etc/systemd/system/se-mobile-fetch-apk.timer <<'UNIT'
[Unit]
Description=Проверять новую сборку SE-mobile раз в десять минут
[Timer]
OnBootSec=5min
OnUnitActiveSec=10min
RandomizedDelaySec=60
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now se-mobile-fetch-apk.timer

if grep -q '^GITHUB_TOKEN=.\+' "$CONFIG"; then
    echo "Проверяю сейчас:"
    systemctl start se-mobile-fetch-apk.service || true
    journalctl -u se-mobile-fetch-apk --since '-2min' --no-pager -o cat | tail -5
else
    echo "Таймер стоит. Впишите токен в $CONFIG и запустите:"
    echo "    sudo systemctl start se-mobile-fetch-apk && journalctl -u se-mobile-fetch-apk -n 5 -o cat"
fi
