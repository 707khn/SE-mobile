"""Сигналы администратору: что сломалось и что починилось — в Telegram.

Всё, о чём здесь сигналим, приложение и так видит (_system_problems): копии
базы, их вывоз и пробное восстановление, сборки из GitHub, сторож, выкладка,
свежесть проходов и листков. Но видно это было только на экране
«Обновление», то есть почти никогда. Скрипт запускает таймер
se-mobile-alerts (deploy/install-autodeploy.sh), сравнивает список с прошлым
разом и шлёт только перемены: новая беда — один раз, починилось — один раз.

Отправляет deploy/notify.sh — настройки в /etc/se-mobile-alerts.env.
"""

import json
import os
import subprocess
import sys

STATE = os.environ.get('ALERTS_STATE', '/var/lib/se-mobile/alerts/sent.json')
NOTIFY = os.environ.get(
    'NOTIFY', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                           'deploy', 'notify.sh'))


def changes(before, now):
    """Что сказать: [(текст)] — новые и починенные, по ключу."""
    said = []
    for key, item in now.items():
        if key not in before:
            said.append(f'⚠️ {item["title"]}. {item["body"]}'.strip())
    for key, item in before.items():
        if key not in now:
            said.append(f'✅ Исправлено: {item["title"]}')
    return said


def _load():
    try:
        with open(STATE, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save(state):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(state, f, ensure_ascii=False)
    os.replace(tmp, STATE)


def main():
    import app as app_module
    application = app_module.create_app()
    with application.app_context():
        problems = app_module._system_problems()
    now = {p['key']: {'title': p['title'], 'body': p['body']}
           for p in problems}
    for text in changes(_load(), now):
        subprocess.run(['bash', NOTIFY, text], check=False, timeout=60)
    _save(now)
    return 0


if __name__ == '__main__':
    sys.exit(main())
