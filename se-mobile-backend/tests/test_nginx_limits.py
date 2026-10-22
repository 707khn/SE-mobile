"""Пределы частоты в deploy/nginx-se-mobile.conf — на настоящем nginx.

Конфиг никто не проверял до боевого сервера: опечатка в нём — это
«Ошибка подключения к серверу» у всех сразу, а слишком тесный предел —
отказ одиннадцатому вошедшему с общего заводского адреса. Здесь nginx
запускается с этим самым файлом перед заглушкой приложения, и все запросы
идут с одного адреса — как с заводского NAT.

Нет nginx на машине — проверки пропускаются; в CI он ставится.
"""

import json
import re
import shutil
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

NGINX = shutil.which('nginx') or (
    '/usr/sbin/nginx' if Path('/usr/sbin/nginx').exists() else None)
pytestmark = pytest.mark.skipif(NGINX is None, reason='nginx не установлен')

CONF = Path(__file__).resolve().parents[2] / 'deploy' / 'nginx-se-mobile.conf'


def _free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class _App(BaseHTTPRequestHandler):
    """Заглушка gunicorn: отвечает 200 на всё, загрузки — с задержкой."""

    def _answer(self):
        length = int(self.headers.get('Content-Length') or 0)
        if length:
            self.rfile.read(length)
        if 'import-excel' in self.path:
            time.sleep(float(self.headers.get('X-Test-Delay') or 0))
        body = b'{"message": "Success"}'
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = _answer

    def log_message(self, *args):
        pass


@pytest.fixture(scope='module')
def nginx(tmp_path_factory):
    tmp = tmp_path_factory.mktemp('nginx')
    app = ThreadingHTTPServer(('127.0.0.1', 0), _App)
    threading.Thread(target=app.serve_forever, daemon=True).start()

    apk_dir = tmp / 'apk'
    apk_dir.mkdir()
    (apk_dir / 'se-mobile-1.0.0+1.apk').write_bytes(b'apk')

    port = _free_port()
    site = CONF.read_text(encoding='utf-8')
    site = site.replace('127.0.0.1:8000', f'127.0.0.1:{app.server_port}')
    site = site.replace('alias /var/www/se-mobile/;', f'alias {apk_dir}/;')
    site = re.sub(r'listen \[::\]:80;\n', '', site)
    site = site.replace('listen 80;', f'listen 127.0.0.1:{port};')
    (tmp / 'site.conf').write_text(site, encoding='utf-8')
    (tmp / 'nginx.conf').write_text(f'''
daemon off;
master_process off;
pid {tmp}/nginx.pid;
error_log {tmp}/error.log;
events {{ worker_connections 512; }}
http {{
    access_log off;
    client_body_temp_path {tmp}/body;
    proxy_temp_path {tmp}/proxy;
    fastcgi_temp_path {tmp}/fastcgi;
    uwsgi_temp_path {tmp}/uwsgi;
    scgi_temp_path {tmp}/scgi;
    include {tmp}/site.conf;
}}
''', encoding='utf-8')

    args = [NGINX, '-e', str(tmp / 'error.log'), '-p', str(tmp),
            '-c', str(tmp / 'nginx.conf')]
    check = subprocess.run(args + ['-t'], capture_output=True, text=True)
    assert check.returncode == 0, check.stderr

    proc = subprocess.Popen(args, stderr=subprocess.PIPE)
    base = f'http://127.0.0.1:{port}'
    for _ in range(100):
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.2):
                break
        except OSError:
            time.sleep(0.05)
    try:
        yield base
    finally:
        proc.terminate()
        proc.wait(timeout=10)
        app.shutdown()


def _hit(url, method='GET', headers=None, data=None):
    req = urllib.request.Request(url, method=method, headers=headers or {},
                                 data=data)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def _many(url, count, method='GET'):
    with ThreadPoolExecutor(max_workers=20) as pool:
        return list(pool.map(lambda _: _hit(url, method, data=b'{}'),
                             range(count)))


def _statuses(url, count, method='GET'):
    return [status for status, _, _ in _many(url, count, method)]


def test_morning_shift_logs_in_from_one_address(nginx):
    """Сто входов разом с одного адреса проходят; поток сверх — 429 JSON."""
    statuses = _statuses(f'{nginx}/login', 100, 'POST')
    assert statuses.count(200) == 100

    refused = [r for r in _many(f'{nginx}/login', 60, 'POST') if r[0] == 429]
    assert refused
    _, headers, body = refused[0]
    assert headers['Retry-After'] == '10'
    assert json.loads(body) == {'message': 'Failure', 'error': 'rate_limited',
                                'retry_after': 10}


def test_ordinary_requests_are_not_limited(nginx):
    """Остальное приложение (главная, проходы, меню) пределов не имеет."""
    assert set(_statuses(f'{nginx}/api/home', 300, 'POST')) == {200}


def test_no_more_than_two_uploads_at_once_from_one_address(nginx):
    """Третья одновременная загрузка не занимает последний процесс gunicorn."""
    url = f'{nginx}/api/directory/import-excel'
    with ThreadPoolExecutor(max_workers=3) as pool:
        statuses = list(pool.map(
            lambda _: _hit(url, 'POST', headers={'X-Test-Delay': '1'},
                           data=b'x')[0],
            range(3)))
    assert sorted(statuses) == [200, 200, 429]


def test_uploads_burst_then_slow_down(nginx):
    url = f'{nginx}/api/menu/import-excel'
    # Одну-две загрузки из запаса уже потратила проверка выше.
    statuses = [_hit(url, 'POST', data=b'x')[0] for _ in range(25)]
    assert statuses[:15] == [200] * 15
    assert 429 in statuses


def test_whole_shift_downloads_the_apk(nginx):
    """Двести скачиваний сборки разом с общего адреса проходят."""
    url = f'{nginx}/app/se-mobile-1.0.0+1.apk'
    assert set(_statuses(url, 200)) == {200}

    refused = [r for r in _many(url, 40) if r[0] == 429]
    assert refused
    _, headers, body = refused[0]
    assert headers['Retry-After'] == '60'
    assert 'Повторите через минуту' in body.decode('utf-8')


def test_crash_reports_burst_then_slow_down(nginx):
    """Сборка с ошибкой: отчёты полсмены разом проходят, бесконечный цикл — нет."""
    url = f'{nginx}/api/crash'
    assert set(_statuses(url, 300, 'POST')) == {200}
    assert 429 in _statuses(url, 60, 'POST')


def test_crash_report_body_is_small(nginx):
    status, _, _ = _hit(f'{nginx}/api/crash', 'POST', data=b'x' * 40000)
    assert status == 413
