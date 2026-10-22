"""Сборка из GitHub Releases приезжает на сервер сама — и только целой.

Скрипт deploy/fetch-apk.sh гоняется против поддельного GitHub на
127.0.0.1: тот отдаёт релиз с APK и AAB и, как настоящий, отправляет за
файлом по перенаправлению.
"""

import hashlib
import json
import os
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

SCRIPT = os.path.join(os.path.dirname(__file__), '..', '..', 'deploy',
                      'fetch-apk.sh')

pytestmark = pytest.mark.skipif(
    not (shutil.which('bash') and shutil.which('curl')),
    reason='нужны bash и curl')

APK = b'PK\x03\x04 fake apk ' * 1000
NAME = 'se-mobile-1.20.0+60.apk'


class _GitHub(BaseHTTPRequestHandler):
    release = None
    status = 200
    seen_tokens = []

    def log_message(self, *args):
        pass

    def _send(self, status, body=b'', headers=()):
        self.send_response(status)
        for key, value in headers:
            self.send_header(key, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.seen_tokens.append(self.headers.get('Authorization'))
        if self.path == '/repos/test/repo/releases/latest':
            if self.status != 200:
                return self._send(self.status, b'{}')
            return self._send(200, json.dumps(self.release).encode())
        if self.path == '/assets/2':
            if self.headers.get('Accept') != 'application/octet-stream':
                return self._send(415)
            return self._send(302, headers=[('Location', '/blob/apk')])
        if self.path == '/blob/apk':
            return self._send(200, APK)
        return self._send(404)


@pytest.fixture
def github():
    server = ThreadingHTTPServer(('127.0.0.1', 0), _GitHub)
    base = f'http://127.0.0.1:{server.server_port}'
    _GitHub.status = 200
    _GitHub.seen_tokens = []
    _GitHub.release = {'assets': [
        {'name': 'se-mobile-play-1.20.0+60.aab', 'state': 'uploaded',
         'url': f'{base}/assets/1', 'size': 10, 'digest': 'sha256:00'},
        {'name': NAME, 'state': 'uploaded', 'url': f'{base}/assets/2',
         'size': len(APK),
         'digest': 'sha256:' + hashlib.sha256(APK).hexdigest()},
    ]}
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield base
    server.shutdown()


@pytest.fixture
def dirs(tmp_path):
    apk_dir, state = tmp_path / 'www', tmp_path / 'state'
    apk_dir.mkdir()
    return apk_dir, state


def _run(github, dirs, token='test-token'):
    apk_dir, state = dirs
    env = {k: v for k, v in os.environ.items()
           if 'proxy' not in k.lower()}
    env.update({
        'FETCH_APK_CONFIG': '/nonexistent',
        'GITHUB_TOKEN': token,
        'GITHUB_API': github,
        'GITHUB_REPO': 'test/repo',
        'APK_DIR': str(apk_dir),
        'FETCH_APK_STATE_DIR': str(state),
        'NO_PROXY': '*',
    })
    return subprocess.run(['bash', SCRIPT], env=env, capture_output=True,
                          text=True, timeout=60)


def _apks(apk_dir):
    return sorted(p.name for p in apk_dir.iterdir())


def test_new_build_arrives_whole(github, dirs):
    apk_dir, state = dirs
    (apk_dir / 'se-mobile-1.15.2+25.apk').write_bytes(b'old')
    done = _run(github, dirs)
    assert done.returncode == 0, done.stderr
    assert _apks(apk_dir) == ['se-mobile-1.15.2+25.apk', NAME]
    assert (apk_dir / NAME).read_bytes() == APK
    assert oct((apk_dir / NAME).stat().st_mode & 0o777) == '0o644'
    assert (state / 'last-build').read_text().strip() == '60'
    assert set(_GitHub.seen_tokens[:2]) == {'Bearer test-token'}


def test_nothing_new_means_nothing_happens(github, dirs):
    apk_dir, _ = dirs
    assert _run(github, dirs).returncode == 0
    mtime = (apk_dir / NAME).stat().st_mtime_ns
    again = _run(github, dirs)
    assert again.returncode == 0 and again.stdout == ''
    assert (apk_dir / NAME).stat().st_mtime_ns == mtime


def test_removed_build_does_not_come_back(github, dirs):
    # Откат: плохую сборку убрали из папки — таймер не должен вернуть её.
    apk_dir, _ = dirs
    assert _run(github, dirs).returncode == 0
    (apk_dir / NAME).unlink()
    assert _run(github, dirs).returncode == 0
    assert _apks(apk_dir) == []


def test_keeps_three_latest(github, dirs):
    apk_dir, _ = dirs
    for build in (21, 22, 23, 24):
        (apk_dir / f'se-mobile-1.15.0+{build}.apk').write_bytes(b'old')
    assert _run(github, dirs).returncode == 0
    assert _apks(apk_dir) == ['se-mobile-1.15.0+23.apk',
                              'se-mobile-1.15.0+24.apk', NAME]


def test_damaged_download_is_not_offered(github, dirs):
    apk_dir, state = dirs
    _GitHub.release['assets'][1]['digest'] = 'sha256:' + '0' * 64
    done = _run(github, dirs)
    assert done.returncode == 1
    assert 'Контрольная сумма' in done.stderr
    assert _apks(apk_dir) == []
    assert not (state / 'last-build').exists()


def test_expired_token_is_named(github, dirs):
    _GitHub.status = 401
    done = _run(github, dirs)
    assert done.returncode == 1
    assert 'не принял токен' in done.stderr


def test_without_token_quietly_waits(github, dirs):
    apk_dir, _ = dirs
    done = _run(github, dirs, token='')
    assert done.returncode == 0
    assert 'GITHUB_TOKEN не задан' in done.stdout
    assert _apks(apk_dir) == []
    assert _GitHub.seen_tokens == []
