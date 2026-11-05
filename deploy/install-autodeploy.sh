#!/bin/bash
# Ставит выкладку без SSH (deploy/autodeploy.sh) и сигналы (deploy/alerts.sh):
#
#     sudo bash /opt/se-mobile/deploy/install-autodeploy.sh
#
# Повторный запуск безопасен: настройки не трогаются, службы переписываются.
set -euo pipefail

APP_DIR=${APP_DIR:-/opt/se-mobile}
ALERTS=/etc/se-mobile-alerts.env

if [ "$(id -u)" != 0 ]; then
    echo "Запустите через sudo." >&2
    exit 1
fi

mkdir -p /var/lib/se-mobile/autodeploy /var/lib/se-mobile/alerts

if [ ! -f "$ALERTS" ]; then
    cat > "$ALERTS" <<'ENV'
# Куда слать сигналы — см. deploy/README.md, «Сигналы».
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
# Почта — только если на сервере настроен `mail`.
ALERT_EMAIL=
ENV
    echo "создан $ALERTS — впишите бота Telegram"
fi
chown root:root "$ALERTS"
chmod 600 "$ALERTS"

# Выкладка работает от root: ей нужны git в /opt/se-mobile и перезапуск
# службы. Скрипт берётся прямо из репозитория — после выкладки работает
# уже новый.
cat > /etc/systemd/system/se-mobile-autodeploy.service <<UNIT
[Unit]
Description=Выкладка SE-mobile из main с зелёными проверками
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/bash $APP_DIR/deploy/autodeploy.sh
UNIT
cat > /etc/systemd/system/se-mobile-autodeploy.timer <<'UNIT'
[Unit]
Description=Проверять main раз в пять минут
[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
RandomizedDelaySec=30
[Install]
WantedBy=timers.target
UNIT

cat > /etc/systemd/system/se-mobile-alerts.service <<UNIT
[Unit]
Description=Сигналы SE-mobile в Telegram: копии, сборки, сторож, данные
After=se-mobile.service
[Service]
Type=oneshot
ExecStart=/bin/bash $APP_DIR/deploy/alerts.sh
UNIT
cat > /etc/systemd/system/se-mobile-alerts.timer <<'UNIT'
[Unit]
Description=Проверять, что требует рук, раз в пятнадцать минут
[Timer]
OnBootSec=10min
OnUnitActiveSec=15min
RandomizedDelaySec=60
[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now se-mobile-autodeploy.timer se-mobile-alerts.timer

if grep -q '^TELEGRAM_BOT_TOKEN=.\+' "$ALERTS"; then
    bash "$APP_DIR/deploy/notify.sh" "Сигналы включены — это проверочное сообщение."
    echo "В Telegram ушло проверочное сообщение."
else
    echo "Таймеры стоят. Впишите бота в $ALERTS и проверьте:"
    echo "    sudo bash $APP_DIR/deploy/notify.sh проверка"
fi
echo "Выкладка: systemctl list-timers 'se-mobile-*'; cat /var/lib/se-mobile/autodeploy/status"
