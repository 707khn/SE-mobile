"""Связка с конфиденциальным чатом SE-chat: отключение уволенных.

Чат — отдельная система на отдельном сервере, и этот сервер о переписке не
знает ничего. Единственное, что он умеет сказать чату, — «этот сотрудник
больше не работает»: тогда чат сразу гасит его сессии и уведомления, и
уволенный не дочитает переписку с телефона, который унёс с собой.

Служебный токен чата даёт только это (см. SE-chat docs/DEPLOY.md). Учётные
записи сопоставляются по логину: в чате сотрудник заведён под тем же
логином, что и здесь (табельный номер).

Настройка — в /etc/se-mobile.env:
    CHAT_SERVICE_URL=https://chat.se-btrz.com
    CHAT_SERVICE_TOKEN=…
Без них отключение работает как раньше, только здесь.
"""
import json
import logging
import os
import urllib.error
import urllib.request

_TIMEOUT_SECONDS = 5


def _settings():
    url = os.environ.get('CHAT_SERVICE_URL', '').strip().rstrip('/')
    token = os.environ.get('CHAT_SERVICE_TOKEN', '').strip()
    return url, token


def offboard(login, initiated_by=''):
    """Сообщает чату об увольнении. Возвращает, что вышло.

    'disabled' — отключён сейчас, 'already' — уже был, 'unknown' — в чате
    его нет, 'privileged' — в чате он администратор или офицер ИБ (таких
    чат по служебному токену не отключает), 'not_configured' — связка не
    настроена, 'failed' — чат не ответил или отказал. Исключений не бросает: отключение здесь важнее и
    должно пройти, даже если чат недоступен, — а администратору ответ
    подскажет отключить человека в чате вручную.
    """
    url, token = _settings()
    if not url or not token:
        return 'not_configured'
    if not url.startswith('https://'):
        logging.error('CHAT_SERVICE_URL должен быть https: %s', url)
        return 'failed'

    body = json.dumps({'username': login, 'initiated_by': initiated_by or ''}).encode()
    request = urllib.request.Request(
        f'{url}/api/service/offboard', data=body, method='POST',
        headers={'Authorization': f'Bearer {token}',
                 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(request, timeout=_TIMEOUT_SECONDS) as response:
            status = json.loads(response.read() or b'{}').get('status')
    except urllib.error.HTTPError as e:
        if e.code == 409:
            logging.warning('В чате %r — администратор, отключать вручную', login)
            return 'privileged'
        logging.warning('Чат отказал в отключении %r: HTTP %s', login, e.code)
        return 'failed'
    except Exception as e:      # сеть, DNS, сертификат, мусор в ответе
        logging.warning('Чат недоступен при отключении %r: %s', login, e)
        return 'failed'
    return status if status in ('disabled', 'already', 'unknown') else 'failed'
