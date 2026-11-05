#!/bin/bash
# Сигнал человеку: в Telegram и/или на почту — что настроено.
#
#     bash /opt/se-mobile/deploy/notify.sh "Текст сигнала"
#
# Раньше всё, что видели сторож, копии и выкладка, лежало в журналах и на
# экране «Обновление», а туда заглядывают, когда уже позвонили. Теперь каждый
# из них зовёт этот скрипт при поломке и при починке — один раз, а не каждые
# две минуты.
#
# Настройки — /etc/se-mobile-alerts.env (только root), см. deploy/README.md,
# «Сигналы»:
#     TELEGRAM_BOT_TOKEN=123456:ABC...   бот от @BotFather
#     TELEGRAM_CHAT_ID=123456789         кому слать (человек или группа)
#     ALERT_EMAIL=admin@example.kz       нужен настроенный `mail` (необязательно)
#
# Не настроено — молчит и выходит с нулём: сигнал не повод ломать то, что
# его посылает. То же при недоступном Telegram — только пишет в stderr.
set -u

CONFIG=${ALERTS_CONFIG:-/etc/se-mobile-alerts.env}
if [ -r "$CONFIG" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG"
fi
TELEGRAM_API=${TELEGRAM_API:-https://api.telegram.org}

text="[SE-mobile $(hostname -s 2>/dev/null || echo server)] $*"
[ -n "$*" ] || exit 0

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -fsS --max-time 15 -o /dev/null \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$text" \
        "$TELEGRAM_API/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        || echo "Telegram не принял сигнал: $text" >&2
fi

if [ -n "${ALERT_EMAIL:-}" ] && command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$text" | mail -s "SE-mobile: ${text:0:80}" "$ALERT_EMAIL" \
        || echo "Письмо не ушло: $text" >&2
fi
exit 0
