# Установка сервера SE-mobile

Инструкция для чистого сервера PS Cloud с Ubuntu 24.04 LTS.
Всё делается с компьютера с Windows, из PowerShell.

Сервер: `85.202.192.168` (Астана, kz-ast-1)
Адрес приложения после настройки: `https://api.se-btrz.com`

---

## Шаг 1. Проверить вход

```powershell
ssh ubuntu@85.202.192.168
```

При первом подключении спросит, доверяете ли вы серверу — ответьте `yes`.
Должно появиться приглашение вида `ubuntu@se-mobile:~$`.

**Если пишет `Permission denied (publickey)`** — ключ не подошёл. Проверьте,
что в PS Cloud загружена именно публичная часть:

```powershell
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub
```

**Если висит без ответа** — сервер ещё не запустился (первый старт занимает
пару минут) или в группе безопасности закрыт порт 22.

---

## Шаг 2. Настроить сервер

Одной командой, находясь на сервере:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone --depth 1 https://github.com/707khn/SE-mobile.git /tmp/se-mobile
sudo bash /tmp/se-mobile/deploy/setup.sh
```

Займёт 5–10 минут. Скрипт ставит и настраивает:

| Что | Зачем |
|---|---|
| Файл подкачки 2 ГБ | На машине 2 ГБ памяти; не даёт системе убить PostgreSQL при всплеске |
| PostgreSQL | База; пароль генерируется сам и лежит в `/etc/se-mobile-db-password` |
| Python + gunicorn | Приложение, три процесса |
| nginx | Принимает запросы снаружи и передаёт приложению |
| systemd | Автозапуск при перезагрузке и перезапуск при падении |
| Суточные копии | `pg_dump` в 03:30, хранятся 30 дней в `/var/backups/se-mobile` |
| ufw | Открыты только 22, 80 и 443 |

Повторный запуск скрипта безопасен: сделанное пропускается, файл
`/etc/se-mobile.env` не перезаписывается.

Проверка, что приложение отвечает:

```bash
curl -s http://localhost/ | head -c 200
```

Должно вернуть `{"status": "ok", "service": "SE-mobile API", ...}`.

---

## Шаг 3. Прописать имя в DNS

**Это делаете вы, у регистратора домена `se-btrz.com`.** Сертификат
выдаётся на имя, а не на адрес, поэтому без этой записи HTTPS не включить.

Добавьте запись:

```
api.se-btrz.com.   A   85.202.192.168
```

Разойдётся обычно за 10–30 минут, иногда до суток. Проверить с сервера:

```bash
dig +short api.se-btrz.com
```

Когда команда покажет `85.202.192.168` — переходите дальше.

---

## Шаг 4. Получить сертификат

```bash
sudo certbot --nginx -d api.se-btrz.com --agree-tos -m ваша@почта --redirect
```

Certbot сам допишет настройки в nginx и включит перенаправление с
`http://` на `https://`. Продлевается автоматически, вмешательства не
требует.

Проверка снаружи, из PowerShell:

```powershell
curl.exe https://api.se-btrz.com/
```

---

## Шаг 5. Перенести данные с Render

На старом сервере (Render) снимите копию базы и перенесите её сюда.
Строку подключения возьмите в панели Render → база → *External Database URL*.

С компьютера с Windows, если установлен PostgreSQL-клиент:

```powershell
pg_dump "СТРОКА_ПОДКЛЮЧЕНИЯ_RENDER" > render.sql
scp render.sql ubuntu@85.202.192.168:/tmp/
```

Затем на сервере:

```bash
sudo systemctl stop se-mobile
sudo -u postgres psql se_mobile < /tmp/render.sql
sudo systemctl start se-mobile
```

Сверить, что всё доехало:

```bash
sudo -u postgres psql se_mobile -c "
  SELECT 'сотрудники' AS таблица, count(*) FROM employees
  UNION ALL SELECT 'листки', count(*) FROM payslips
  UNION ALL SELECT 'проходы', count(*) FROM access_records
  UNION ALL SELECT 'учётные записи', count(*) FROM user_accounts;"
```

Числа должны совпасть с тем, что показывает Render.

---

## Шаг 6. Переключить приложение

В `lib/utils/variables.dart` поменять адрес:

```dart
static const String baseUrl = 'https://api.se-btrz.com';
```

Собрать APK и **раздать всем**. Только после того, как обновятся все,
включать проверку доступа (см. ниже).

Не забыть про два места, которые ходят на сервер помимо приложения:

- **мини-программа загрузки меню** на компьютере с 1С — поменять адрес в
  `tools/menu-upload/settings.txt`;
- **система турникета** — она шлёт события на `/api/turnstile`; новый
  секрет лежит в `/etc/se-mobile.env` в строке `TURNSTILE_SECRET`.

---

## Шаг 7. Включить проверку доступа

Пока в `/etc/se-mobile.env` стоит `REQUIRE_AUTH=0`, сервер принимает запросы
без пропуска — иначе старые сборки приложения отвалились бы разом.

Посмотреть, остались ли такие запросы:

```bash
sudo journalctl -u se-mobile --since "24 hours ago" | grep -c "Unauthenticated request"
```

Когда счётчик станет нулевым несколько дней подряд — значит все обновились:

```bash
sudo sed -i 's/REQUIRE_AUTH=0/REQUIRE_AUTH=1/' /etc/se-mobile.env
sudo systemctl restart se-mobile
```

С этого момента расчётные листки и всё остальное закрыты для всех, кроме
владельца, его начальника и администратора.

---

## Повседневное

| Задача | Команда |
|---|---|
| Обновить приложение | `cd /opt/se-mobile && sudo git pull && sudo systemctl restart se-mobile` |
| Посмотреть логи | `sudo journalctl -u se-mobile -f` |
| Состояние служб | `systemctl status se-mobile nginx postgresql` |
| Снять копию сейчас | `sudo systemctl start se-mobile-backup` |
| Список копий | `ls -lh /var/backups/se-mobile` |
| Восстановить из копии | `sudo systemctl stop se-mobile && zcat /var/backups/se-mobile/ФАЙЛ.sql.gz \| sudo -u postgres psql se_mobile && sudo systemctl start se-mobile` |

**Восстановление стоит отрепетировать заранее**, а не в тот день, когда оно
понадобится: копия, которую ни разу не разворачивали, — это надежда, а не
резерв.

---

## Где что лежит

```
/opt/se-mobile/            код (git-репозиторий)
/opt/se-mobile/venv/       окружение Python
/etc/se-mobile.env         настройки и секреты (доступ только root)
/etc/se-mobile-db-password пароль базы
/var/backups/se-mobile/    суточные копии
/etc/nginx/sites-available/se-mobile
/etc/systemd/system/se-mobile.service
```
