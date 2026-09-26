#!/bin/bash
# Сторож: раз в две минуты спрашивает сервер, жив ли он вместе с базой.
#
# Двенадцатого сентября приложение отвечало, а база лежала. Процесс был на
# месте, systemd считал службу исправной, и сбой прожил ВОСЕМЬ ДНЕЙ — ровно
# до первой жалобы сотрудника. Пятьсот человек всё это время не могли войти.
#
# Сторож не заменяет присмотра со стороны: если упадёт вся машина, некому
# будет и написать. Но два самых частых случая он закрывает сам — лежит база
# при живом приложении и приложение, переставшее отвечать, — и, главное,
# ведёт журнал: сколько и когда сервер не работал, видно потом, а не со слов.
set -u

HEALTH_URL=${HEALTH_URL:-http://127.0.0.1:8000/health}

# Имя, по которому ходят телефоны. Приложение может быть живо, а до него не
# дойти: 26 сентября из конфига nginx пропала секция 443 — файл из
# репозитория скопировали поверх того, куда certbot дописал сертификат.
# Сервер отвечал на 127.0.0.1, сторож был доволен, а все телефоны видели
# «Ошибка подключения к серверу». Пустое значение выключает эту проверку.
PUBLIC_HOST=${PUBLIC_HOST-api.se-btrz.com}
STATE_DIR=${WATCHDOG_STATE_DIR:-/var/lib/se-mobile/watchdog}
OUTAGES="$STATE_DIR/outages.log"
FAILS="$STATE_DIR/consecutive-failures"
LAST_RESTART="$STATE_DIR/last-restart"

# Перезапускаем не чаще раза в пятнадцать минут. Сторож, дёргающий службу
# каждые две минуты, вредит больше самого сбоя: база не успевает подняться,
# а в журнале не разобрать, что было причиной.
COOLDOWN=${WATCHDOG_COOLDOWN:-900}

# Две неудачи подряд, а не одна: одиночная бывает от чего угодно — сборщик
# мусора, долгий запрос, перезапуск по обновлению.
NEEDED=${WATCHDOG_FAILURES:-2}

mkdir -p "$STATE_DIR" || {
    echo "Не могу создать $STATE_DIR — сторож бесполезен. Создайте папку и" \
         "дайте на неё права: mkdir -p $STATE_DIR" >&2
    exit 1
}

now=$(date +%s)
HTTPS_DOWN="$STATE_DIR/https-down"

# Дойдут ли телефоны: nginx, порт 443, сертификат. Спрашиваем через
# 127.0.0.1 (--resolve), а не через внешний адрес: запрос машины к самой
# себе по внешнему IP в облаке часто не проходит и без всякой поломки.
# Перезапуск приложения тут не поможет, поэтому только записываем — и только
# при смене состояния, а не каждые две минуты.
check_https() {
    [ -n "$PUBLIC_HOST" ] || return 0
    local outside
    if outside=$(curl -fsS --max-time 10 \
            --resolve "$PUBLIC_HOST:443:127.0.0.1" \
            "https://$PUBLIC_HOST/health" 2>&1); then
        if [ -e "$HTTPS_DOWN" ]; then
            rm -f "$HTTPS_DOWN"
            echo "$(date -Is) https://$PUBLIC_HOST снова отвечает" >> "$OUTAGES"
        fi
    elif [ ! -e "$HTTPS_DOWN" ]; then
        touch "$HTTPS_DOWN"
        echo "$(date -Is) приложение живо, но https://$PUBLIC_HOST не отвечает — телефоны не войдут: $outside" >> "$OUTAGES"
        echo "https://$PUBLIC_HOST не отвечает: $outside" >&2
    fi
}

answer=$(curl -fsS --max-time 10 "$HEALTH_URL" 2>&1)
code=$?

if [ $code -eq 0 ]; then
    previous=$(cat "$FAILS" 2>/dev/null || echo 0)
    if [ "$previous" -ge "$NEEDED" ]; then
        echo "$(date -Is) восстановился после $previous неудач подряд" >> "$OUTAGES"
        echo "Сервер отвечает снова"
    fi
    echo 0 > "$FAILS"
    check_https
    exit 0
fi

previous=$(cat "$FAILS" 2>/dev/null || echo 0)
fails=$((previous + 1))
echo "$fails" > "$FAILS"
echo "$(date -Is) не отвечает ($fails подряд): $answer" >> "$OUTAGES"
echo "Сервер не отвечает ($fails подряд): $answer" >&2

[ "$fails" -lt "$NEEDED" ] && exit 0

since=$(cat "$LAST_RESTART" 2>/dev/null || echo 0)
if [ $((now - since)) -lt "$COOLDOWN" ]; then
    echo "Перезапуск был $(( (now - since) / 60 )) мин назад — жду" >&2
    exit 0
fi
echo "$now" > "$LAST_RESTART"

# Сначала база: чаще всего лежит именно она, а приложение без неё отвечает
# пятьсот третьим и само собой не поправится.
PG_UNIT=$(systemctl list-units --all --plain --no-legend 'postgresql@*' \
    | awk '{print $1}' | head -1)
if [ -n "$PG_UNIT" ] && ! systemctl is-active --quiet "$PG_UNIT"; then
    echo "$(date -Is) перезапускаю $PG_UNIT" >> "$OUTAGES"
    echo "База лежит — перезапускаю $PG_UNIT" >&2
    systemctl restart "$PG_UNIT" || true
    sleep 15
fi

echo "$(date -Is) перезапускаю se-mobile" >> "$OUTAGES"
echo "Перезапускаю se-mobile" >&2
systemctl restart se-mobile || true
