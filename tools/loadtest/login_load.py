"""Нагрузочная проверка «500 входов за минуту».

Утро понедельника: смена приходит, и все открывают приложение разом. Скрипт
делает то же — N входов за заданное время, каждый с выходом (/logout), чтобы
не копить пропуска, — и печатает, сколько прошло, сколько отказало и за
сколько ответил сервер (медиана, 95-й и худший).

Запускать на самом сервере, мимо nginx: nginx пускает с одного адреса не
больше 4 входов в секунду (deploy/nginx-se-mobile.conf, se_login), и с одной
машины проверялся бы предел nginx, а не приложение.

    python3 login_load.py --url http://127.0.0.1:8000 \\
        --login 2114 --password 'пароль' --count 500 --seconds 60

Нужна учётка с постоянным паролем (не временным): иначе вход отвечает
«смените пароль», и проверка меряет не то. Неверный пароль закроет учётку
после пяти попыток — скрипт останавливается на первой же такой ошибке.
Только стандартная библиотека Python, ставить ничего не надо.
"""

import argparse
import json
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request


def _post(url, body, token=None, timeout=30):
    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method='POST',
                                 headers={'Content-Type': 'application/json'})
    if token:
        req.add_header('Authorization', f'Bearer {token}')
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, json.loads(resp.read() or b'{}')


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--url', default='http://127.0.0.1:8000')
    ap.add_argument('--login', required=True)
    ap.add_argument('--password', required=True)
    ap.add_argument('--count', type=int, default=500)
    ap.add_argument('--seconds', type=float, default=60)
    ap.add_argument('--concurrency', type=int, default=50,
                    help='сколько запросов может висеть одновременно')
    args = ap.parse_args()

    base = args.url.rstrip('/')
    gate = threading.Semaphore(args.concurrency)
    lock = threading.Lock()
    times, errors = [], {}
    stop = threading.Event()

    def one():
        try:
            started = time.monotonic()
            try:
                status, body = _post(f'{base}/login', {
                    'login': args.login, 'password': args.password})
                ok = status == 200 and body.get('message') == 'Success'
                reason = None if ok else f'{status} {body.get("message")}'
            except urllib.error.HTTPError as e:
                ok, reason = False, f'HTTP {e.code}'
            except Exception as e:  # обрыв, таймаут
                ok, reason = False, type(e).__name__
            elapsed = time.monotonic() - started
            with lock:
                if ok:
                    times.append(elapsed)
                else:
                    errors[reason] = errors.get(reason, 0) + 1
                    if reason and ('Failure' in reason or '403' in reason):
                        stop.set()
            if ok and body.get('token'):
                try:
                    _post(f'{base}/logout', {}, token=body['token'])
                except Exception:
                    pass
        finally:
            gate.release()

    interval = args.seconds / max(args.count, 1)
    threads = []
    began = time.monotonic()
    for i in range(args.count):
        if stop.is_set():
            print('Вход отказал (неверный пароль?) — останавливаюсь, чтобы '
                  'не закрыть учётку.', file=sys.stderr)
            break
        target = began + i * interval
        delay = target - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        gate.acquire()
        t = threading.Thread(target=one, daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
    total = time.monotonic() - began

    done = len(times)
    failed = sum(errors.values())
    print(f'Входов: {done} из {len(threads)} за {total:.1f} с, отказов: {failed}')
    if errors:
        for reason, n in sorted(errors.items(), key=lambda x: -x[1]):
            print(f'  {reason}: {n}')
    if times:
        times.sort()
        p95 = times[min(len(times) - 1, int(len(times) * 0.95))]
        print(f'Ответ: медиана {statistics.median(times) * 1000:.0f} мс, '
              f'95% — {p95 * 1000:.0f} мс, худший {times[-1] * 1000:.0f} мс')
    # Цель: ни одного отказа и 95% быстрее двух секунд.
    good = failed == 0 and times and p95 < 2.0
    print('Итог:', 'выдерживает' if good else 'НЕ выдерживает')
    return 0 if good else 1


if __name__ == '__main__':
    sys.exit(main())
