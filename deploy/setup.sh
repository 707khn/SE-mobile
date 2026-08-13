#!/bin/bash
# Первичная настройка сервера SE-mobile на чистой Ubuntu 24.04 LTS.
#
# Запускать один раз, от root:  sudo bash setup.sh
# Повторный запуск безопасен — всё, что уже сделано, пропускается.
set -euo pipefail

REPO=git@github.com:707khn/SE-mobile.git
APP_DIR=/opt/se-mobile
DB_NAME=se_mobile
DB_USER=se_mobile
DOMAIN=api.se-btrz.com

say() { echo -e "\n\033[1;32m==> $*\033[0m"; }

[ "$EUID" -eq 0 ] || { echo "Запускать от root: sudo bash setup.sh"; exit 1; }

say "Обновление системы"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

say "Установка пакетов"
apt-get install -y -qq \
    python3 python3-venv python3-dev build-essential \
    postgresql postgresql-contrib libpq-dev \
    nginx certbot python3-certbot-nginx \
    git curl ufw

say "Файл подкачки"
# На машине 2 ГБ памяти. Подкачка не ускоряет, но не даёт системе убить
# PostgreSQL или gunicorn при кратковременном всплеске.
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    # Обращаться к диску только когда память действительно кончается.
    sysctl -qw vm.swappiness=10
    grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
    echo "подкачка 2 ГБ включена"
else
    echo "подкачка уже есть"
fi

say "Пользователь приложения"
id semobile &>/dev/null || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin semobile

say "База данных"
DB_PASS_FILE=/etc/se-mobile-db-password
if [ ! -f "$DB_PASS_FILE" ]; then
    # Пароль базы генерируется здесь и больше нигде не появляется: он нужен
    # только приложению на этой же машине.
    openssl rand -base64 24 | tr -d '/+=' > "$DB_PASS_FILE"
    chmod 600 "$DB_PASS_FILE"
fi
DB_PASS=$(cat "$DB_PASS_FILE")

sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 \
    || sudo -u postgres psql -qc "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 \
    || sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
sudo -u postgres psql -qc "ALTER USER $DB_USER WITH PASSWORD '$DB_PASS';"

say "Код приложения"
# Репозиторий приватный, поэтому сервер ходит в него по своему ключу.
# Открытую часть надо один раз добавить в GitHub как Deploy key.
mkdir -p /root/.ssh && chmod 700 /root/.ssh
if [ ! -f /root/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -N "" -C "se-mobile-server" -f /root/.ssh/id_ed25519 >/dev/null
fi
# Без этого git остановится на вопросе «доверяете ли вы github.com».
grep -q '^github.com' /root/.ssh/known_hosts 2>/dev/null \
    || ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts 2>/dev/null

if ! ssh -o BatchMode=yes -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    cat <<KEY

────────────────────────────────────────────────────────────────
 Сервер пока не имеет доступа к репозиторию. Добавьте этот ключ:

 GitHub → репозиторий SE-mobile → Settings → Deploy keys
        → Add deploy key → вставить строку ниже → Add key
        (галочку «Allow write access» НЕ ставить)

$(cat /root/.ssh/id_ed25519.pub)

 После этого запустите setup.sh ещё раз.
────────────────────────────────────────────────────────────────

KEY
    exit 1
fi

if [ -d "$APP_DIR/.git" ]; then
    git -C "$APP_DIR" pull --ff-only
else
    git clone --depth 1 "$REPO" "$APP_DIR"
fi

say "Окружение Python"
[ -d "$APP_DIR/venv" ] || python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -q --upgrade pip
"$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/se-mobile-backend/requirements.txt"

say "Переменные окружения"
if [ ! -f /etc/se-mobile.env ]; then
    cat > /etc/se-mobile.env <<ENV
DATABASE_URL=postgresql://$DB_USER:$DB_PASS@localhost/$DB_NAME

# Пока выключено: установленные сборки приложения пропуск присылать не умеют
# и получили бы отказ на всех экранах. Включить после того, как все
# обновятся и в логах пропадут предупреждения "Unauthenticated request".
REQUIRE_AUTH=0

# Секрет для системы турникета и токен для загрузки расчётных листков.
TURNSTILE_SECRET=$(openssl rand -hex 16)
ADMIN_TOKEN=$(openssl rand -hex 16)

FIREBASE_CREDENTIALS_PATH=/etc/se-mobile-firebase.json
ENV
    chmod 600 /etc/se-mobile.env
    echo "создан /etc/se-mobile.env"
else
    echo "/etc/se-mobile.env уже есть, не трогаю"
fi

chown -R semobile:semobile "$APP_DIR"

say "Служба приложения"
cp "$APP_DIR/deploy/se-mobile.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now se-mobile
sleep 3
systemctl is-active --quiet se-mobile && echo "приложение работает" || {
    echo "приложение не поднялось, смотрите: journalctl -u se-mobile -n 40"; exit 1; }

say "nginx"
cp "$APP_DIR/deploy/nginx-se-mobile.conf" /etc/nginx/sites-available/se-mobile
ln -sf /etc/nginx/sites-available/se-mobile /etc/nginx/sites-enabled/se-mobile
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

say "Резервные копии"
cp "$APP_DIR/deploy/backup.sh" /usr/local/bin/se-mobile-backup
chmod +x /usr/local/bin/se-mobile-backup
cat > /etc/systemd/system/se-mobile-backup.service <<'UNIT'
[Unit]
Description=Копия базы SE-mobile
[Service]
Type=oneshot
User=postgres
ExecStart=/usr/local/bin/se-mobile-backup
UNIT
cat > /etc/systemd/system/se-mobile-backup.timer <<'UNIT'
[Unit]
Description=Копия базы SE-mobile раз в сутки
[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now se-mobile-backup.timer

say "Файрвол"
ufw allow OpenSSH >/dev/null
ufw allow 'Nginx Full' >/dev/null
ufw --force enable >/dev/null
echo "открыты 22, 80, 443"

say "Готово"
cat <<DONE

Проверка: curl -s http://localhost/ | head -c 200

Дальше нужен сертификат. Он выдаётся только на имя, не на адрес,
поэтому сначала пропишите в DNS запись:

    $DOMAIN  A  $(curl -s -4 ifconfig.me || echo '<ваш IP>')

Когда запись разойдётся (проверить: dig +short $DOMAIN), выполните:

    certbot --nginx -d $DOMAIN --agree-tos -m ваша@почта --redirect

После этого приложение будет доступно по https://$DOMAIN

DONE
