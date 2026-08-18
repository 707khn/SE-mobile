#!/bin/bash
# Переносит меню столовой со старой базы (Neon) на этот сервер.
#
# Только меню: всё остальное сидеры создают одинаково с обеих сторон, а
# проходов турникета здесь даже больше — полный дамп их бы затёр.
#
# Запуск:  sudo bash deploy/menu-migrate.sh
set -euo pipefail

say()  { echo -e "\n\033[1;32m==> $*\033[0m"; }
fail() { echo -e "\n\033[1;31mОстановлено: $*\033[0m"; exit 1; }

[ "$EUID" -eq 0 ] || fail "запускать от root: sudo bash deploy/menu-migrate.sh"

# Строку подключения берём из аргумента, из файла или спрашиваем.
SRC="${1:-}"
if [ -z "$SRC" ] && [ -f /tmp/neon.txt ]; then
    SRC=$(tr -d '\r\n' < /tmp/neon.txt)
    echo "Строка подключения взята из /tmp/neon.txt"
fi
if [ -z "$SRC" ]; then
    echo "Вставьте строку подключения к старой базе и нажмите Enter."
    echo "(она видна на экране — так проще заметить, если что-то потерялось)"
    read -r SRC
fi

case "$SRC" in
    postgres://*|postgresql://*) ;;
    *) fail "строка не похожа на подключение к PostgreSQL: '${SRC:0:30}...'" ;;
esac
echo "Источник: ${SRC#*@}"

WORK=$(mktemp -d)
chmod 755 "$WORK"
trap 'rm -rf "$WORK"' EXIT

say "Проверяю, что меню здесь ещё нет"
HAVE=$(sudo -u postgres psql -tAq se_mobile -c \
    "SELECT (SELECT count(*) FROM menu_dates) + (SELECT count(*) FROM menu_items);")
if [ "$HAVE" != "0" ]; then
    fail "в локальной базе уже есть меню ($HAVE строк). Очистите его или перенесите вручную."
fi
echo "локально пусто, продолжаю"

say "Забираю меню со старой базы"
psql "$SRC" -q -c \
    "\copy (SELECT id, date FROM menu_dates ORDER BY id) TO '$WORK/dates.csv' CSV"
psql "$SRC" -q -c \
    "\copy (SELECT id, menu_date_id, category, name, price, portion FROM menu_items ORDER BY id) TO '$WORK/items.csv' CSV"

DAYS=$(wc -l < "$WORK/dates.csv")
DISHES=$(wc -l < "$WORK/items.csv")
echo "дней: $DAYS, блюд: $DISHES"
[ "$DISHES" -gt 0 ] || fail "на старой базе меню не найдено — переносить нечего"

say "Загружаю сюда"
sudo -u postgres psql -q se_mobile -c \
    "\copy menu_dates (id, date) FROM '$WORK/dates.csv' CSV"
sudo -u postgres psql -q se_mobile -c \
    "\copy menu_items (id, menu_date_id, category, name, price, portion) FROM '$WORK/items.csv' CSV"

say "Сдвигаю счётчики"
# Идентификаторы перенесены как есть, поэтому автонумерацию надо подвинуть,
# иначе следующая загрузка меню упрётся в занятый номер.
sudo -u postgres psql -q se_mobile -c "
    SELECT setval(pg_get_serial_sequence('menu_dates','id'),
                  GREATEST((SELECT COALESCE(max(id),1) FROM menu_dates), 1));
    SELECT setval(pg_get_serial_sequence('menu_items','id'),
                  GREATEST((SELECT COALESCE(max(id),1) FROM menu_items), 1));"

say "Что получилось"
sudo -u postgres psql se_mobile -c "
    SELECT d.date AS дата, count(i.id) AS блюд
    FROM menu_dates d LEFT JOIN menu_items i ON i.menu_date_id = d.id
    GROUP BY d.date ORDER BY d.date;"

GOT=$(sudo -u postgres psql -tAq se_mobile -c "SELECT count(*) FROM menu_items;")
if [ "$GOT" = "$DISHES" ]; then
    say "Готово: перенесено $GOT блюд из $DISHES"
else
    fail "перенеслось $GOT из $DISHES — расхождение, разберитесь до отключения старой базы"
fi
