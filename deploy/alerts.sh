#!/bin/bash
# Раз в пятнадцать минут: что на сервере требует рук — в Telegram.
# Сам список считает приложение (то же, что колокольчик администратора и
# экран «Обновление»), здесь его только запускают с настройками сервера.
set -euo pipefail
APP_DIR=${APP_DIR:-/opt/se-mobile}
set -a
# shellcheck disable=SC1091
. /etc/se-mobile.env
set +a
cd "$APP_DIR/se-mobile-backend"
exec "$APP_DIR/venv/bin/python" alerts.py
