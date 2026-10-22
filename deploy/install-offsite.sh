#!/bin/bash
# Ставит таймеры для копии вне сервера (deploy/backup-offsite.sh, каждую
# ночь после копирования) и пробного восстановления (deploy/restore-test.sh,
# раз в квартал). Отдельно от setup.sh, чтобы на работающем сервере не
# прогонять установку целиком:
#
#     sudo bash /opt/se-mobile/deploy/install-offsite.sh
#
# Повторный запуск безопасен: настройки хранилища не трогаются, службы
# переписываются.
set -euo pipefail

APP_DIR=${APP_DIR:-/opt/se-mobile}
CONFIG=/etc/se-mobile-offsite.env

if [ "$(id -u)" != 0 ]; then
    echo "Запустите через sudo." >&2
    exit 1
fi

mkdir -p /var/lib/se-mobile/offsite /var/lib/se-mobile/restore-test

if [ ! -f "$CONFIG" ]; then
    cat > "$CONFIG" <<'ENV'
# Внешнее хранилище для копий базы — см. deploy/README.md, «Копия вне
# сервера». Подойдёт любое S3-совместимое: объектное хранилище PS Cloud,
# Yandex Object Storage, MinIO. Впишите после знаков равенства.
#
# Адрес хранилища без имени корзины, например https://s3.example.kz
OFFSITE_ENDPOINT=
OFFSITE_BUCKET=
OFFSITE_ACCESS_KEY=
OFFSITE_SECRET_KEY=
# Регион — если хранилище его требует; большинство принимает любой.
OFFSITE_REGION=us-east-1
# Папка внутри корзины.
OFFSITE_PREFIX=se-mobile/
# Сколько дней хранить копии в хранилище. 0 — не удалять самим (тогда
# настройте правило жизненного цикла в самом хранилище).
OFFSITE_KEEP_DAYS=90
ENV
    echo "создан $CONFIG — впишите в него адрес и ключи хранилища"
fi
# Ключи открывают все копии в хранилище: читать их может только root.
chown root:root "$CONFIG"
chmod 600 "$CONFIG"

# Скрипты запускаются прямо из репозитория: после git pull работает новый.
cat > /etc/systemd/system/se-mobile-offsite.service <<UNIT
[Unit]
Description=Копии базы SE-mobile во внешнее хранилище
Wants=network-online.target
After=network-online.target se-mobile-backup.service
[Service]
Type=oneshot
ExecStart=/bin/bash $APP_DIR/deploy/backup-offsite.sh
Nice=10
IOSchedulingClass=idle
# Копии только читаем, писать — только свою отметку.
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=/var/lib/se-mobile/offsite
UNIT
cat > /etc/systemd/system/se-mobile-offsite.timer <<'UNIT'
[Unit]
Description=Увозить копии базы SE-mobile с сервера каждую ночь
[Timer]
# Копия делается в 03:30 и занимает минуты.
OnCalendar=*-*-* 04:15:00
RandomizedDelaySec=10min
Persistent=true
[Install]
WantedBy=timers.target
UNIT

cat > /etc/systemd/system/se-mobile-restore-test.service <<UNIT
[Unit]
Description=Пробное восстановление базы SE-mobile из копии
Wants=network-online.target
After=network-online.target postgresql.service
[Service]
Type=oneshot
ExecStart=/bin/bash $APP_DIR/deploy/restore-test.sh
Nice=10
IOSchedulingClass=idle
UNIT
cat > /etc/systemd/system/se-mobile-restore-test.timer <<'UNIT'
[Unit]
Description=Пробное восстановление базы SE-mobile раз в квартал
[Timer]
# 15 января, апреля, июля и октября, до начала рабочего дня.
OnCalendar=*-01,04,07,10-15 05:00:00
Persistent=true
[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now se-mobile-offsite.timer se-mobile-restore-test.timer

if grep -q '^OFFSITE_SECRET_KEY=.\+' "$CONFIG"; then
    echo "Увожу копии сейчас:"
    systemctl start se-mobile-offsite.service || true
    journalctl -u se-mobile-offsite --since '-5min' --no-pager -o cat | tail -5
else
    echo "Таймеры стоят. Впишите хранилище в $CONFIG и запустите:"
    echo "    sudo systemctl start se-mobile-offsite && journalctl -u se-mobile-offsite -n 5 -o cat"
fi
