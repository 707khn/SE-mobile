"""Сборка из GitHub Releases приезжает на сервер сама — и только целой.

Скрипт deploy/fetch-apk.sh гоняется против поддельного GitHub на
127.0.0.1: тот отдаёт релиз с APK и AAB и, как настоящий, отправляет за
файлом по перенаправлению.
"""

import hashlib
import io
import json
import os
import shutil
import subprocess
import threading
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

SCRIPT = os.path.join(os.path.dirname(__file__), '..', '..', 'deploy',
                      'fetch-apk.sh')

pytestmark = pytest.mark.skipif(
    not (shutil.which('bash') and shutil.which('curl')),
    reason='нужны bash и curl')

APK = b'PK\x03\x04 fake apk ' * 1000
NAME = 'se-mobile-1.20.0+60.apk'
ZIP = b'PK\x03\x04 fake windows zip ' * 500
ZIP_NAME = 'SemEng-windows-1.20.0+60.zip'
WEB_NAME = 'se-mobile-web-1.20.0+60.zip'


def _web_zip(files):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as z:
        for name, data in files.items():
            z.writestr(name, data)
    return buf.getvalue()


WEB = _web_zip({'index.html': '<html>web 60</html>',
                'main.dart.js': 'void 0;',
                'icons/Icon-192.png': 'png'})


class _GitHub(BaseHTTPRequestHandler):
    release = None
    status = 200
    body = None
    asset_status = 200
    expires = None
    seen_tokens = []
    web = WEB

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
            headers = []
            if self.expires:
                headers.append(('GitHub-Authentication-Token-Expiration',
                                self.expires))
            if self.status != 200:
                return self._send(self.status, b'{}', headers)
            body = self.body or json.dumps(self.release).encode()
            return self._send(200, body, headers)
        if self.path == '/assets/2':
            if self.headers.get('Accept') != 'application/octet-stream':
                return self._send(415)
            if self.asset_status != 200:
                return self._send(self.asset_status)
            return self._send(302, headers=[('Location', '/blob/apk')])
        if self.path == '/blob/apk':
            return self._send(200, APK)
        if self.path == '/assets/3':
            return self._send(302, headers=[('Location', '/blob/zip')])
        if self.path == '/blob/zip':
            return self._send(200, ZIP)
        if self.path == '/assets/4':
            return self._send(302, headers=[('Location', '/blob/web')])
        if self.path == '/blob/web':
            return self._send(200, self.web)
        return self._send(404)


@pytest.fixture
def github():
    server = ThreadingHTTPServer(('127.0.0.1', 0), _GitHub)
    base = f'http://127.0.0.1:{server.server_port}'
    _GitHub.status = 200
    _GitHub.body = None
    _GitHub.asset_status = 200
    _GitHub.expires = None
    _GitHub.seen_tokens = []
    _GitHub.web = WEB
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


def _status(dirs):
    _, state = dirs
    lines = (state / 'status').read_text(encoding='utf-8').splitlines()
    return dict(line.split('=', 1) for line in lines)


def test_success_is_recorded_for_the_admin_screen(github, dirs):
    _GitHub.expires = '2027-01-21 00:00:00 UTC'
    assert _run(github, dirs).returncode == 0
    status = _status(dirs)
    assert status['result'] == 'ok'
    assert NAME in status['message']
    assert status['token_expires'] == '2027-01-21 00:00:00 UTC'
    assert status['checked_at'].endswith('Z')


def test_failure_is_recorded_with_the_same_words(github, dirs):
    _GitHub.status = 401
    assert _run(github, dirs).returncode == 1
    status = _status(dirs)
    assert status['result'] == 'fail'
    assert 'не принял токен' in status['message']


def test_missing_token_is_recorded(github, dirs):
    assert _run(github, dirs, token='').returncode == 0
    assert _status(dirs)['result'] == 'no-token'


def test_broken_download_is_named_and_leaves_nothing(github, dirs):
    apk_dir, state = dirs
    _GitHub.asset_status = 500
    done = _run(github, dirs)
    assert done.returncode == 1
    assert 'не отдал файл' in done.stderr
    assert _apks(apk_dir) == []
    assert not list(apk_dir.glob('.download-*'))
    assert not (state / 'last-build').exists()
    assert _status(dirs)['result'] == 'fail'


def test_garbage_instead_of_release_is_named(github, dirs):
    # Прокси или страница-заглушка вместо GitHub: 200, а внутри не JSON.
    _GitHub.body = b'<html>captive portal</html>'
    done = _run(github, dirs)
    assert done.returncode == 1
    assert 'непонятное' in done.stderr
    assert 'Traceback' not in done.stderr


@pytest.mark.skipif(not shutil.which('flock'), reason='нужен flock')
def test_second_run_waits_for_the_first(github, dirs):
    apk_dir, state = dirs
    state.mkdir()
    holder = subprocess.Popen(['flock', str(state / 'lock'), 'sleep', '5'])
    try:
        import time
        for _ in range(50):
            done = subprocess.run(['flock', '-n', str(state / 'lock'),
                                   'true'])
            if done.returncode != 0:
                break
            time.sleep(0.05)
        done = _run(github, dirs)
        assert done.returncode == 0
        assert 'Уже идёт' in done.stdout
        assert _apks(apk_dir) == []
    finally:
        holder.kill()
        holder.wait()


def test_server_understands_what_the_script_wrote(github, dirs, monkeypatch):
    # Файл пишет bash, читает Flask: формат должен сходиться у обоих.
    import app as app_module
    _, state = dirs
    _GitHub.status = 401
    _run(github, dirs)
    monkeypatch.setattr(app_module, '_FETCH_APK_STATUS', str(state / 'status'))
    seen = app_module._fetch_apk_state()
    assert seen['result'] == 'fail'
    assert seen['problem'].startswith('GitHub не принял токен')


def _with_windows(github):
    _GitHub.release['assets'].append(
        {'name': ZIP_NAME, 'state': 'uploaded', 'url': f'{github}/assets/3',
         'size': len(ZIP),
         'digest': 'sha256:' + hashlib.sha256(ZIP).hexdigest()})


def test_windows_archive_arrives_next_to_apk(github, dirs):
    """Версия для компьютера едет тем же путём, со своим счётом сборок."""
    apk_dir, state = dirs
    _with_windows(github)
    done = _run(github, dirs)
    assert done.returncode == 0, done.stderr
    assert _apks(apk_dir) == [ZIP_NAME, NAME]
    assert (apk_dir / ZIP_NAME).read_bytes() == ZIP
    assert (state / 'last-build-windows').read_text().strip() == '60'
    assert 'компьютеры' in done.stdout
    assert f'Забрана {NAME}; Забрана {ZIP_NAME}' in (state / 'status').read_text()

    # Второй раз — ничего: обе уже есть.
    again = _run(github, dirs)
    assert again.returncode == 0 and again.stdout == ''


def test_release_without_windows_keeps_the_old_archive(github, dirs):
    """Архив собирается не с каждой версией: релиз без него — не повод
    убирать прежний."""
    apk_dir, _ = dirs
    (apk_dir / 'SemEng-windows-1.19.0+59.zip').write_bytes(b'old')
    assert _run(github, dirs).returncode == 0
    assert _apks(apk_dir) == ['SemEng-windows-1.19.0+59.zip', NAME]


def test_windows_archive_only_is_named_and_still_taken(github, dirs):
    apk_dir, state = dirs
    _GitHub.release['assets'] = [a for a in _GitHub.release['assets']
                                 if not a['name'].endswith('.apk')]
    _with_windows(github)
    done = _run(github, dirs)
    assert done.returncode == 0, done.stderr
    assert 'нет APK' in done.stderr
    assert _apks(apk_dir) == [ZIP_NAME]


def _with_web(github, data=None):
    if data is not None:
        _GitHub.web = data
    _GitHub.release['assets'].append(
        {'name': WEB_NAME, 'state': 'uploaded', 'url': f'{github}/assets/4',
         'size': len(_GitHub.web),
         'digest': 'sha256:' + hashlib.sha256(_GitHub.web).hexdigest()})


def test_web_version_is_unpacked_and_switched_to(github, dirs):
    """Веб-версия приезжает тем же путём и раскладывается для nginx."""
    apk_dir, state = dirs
    _with_web(github)
    done = _run(github, dirs)
    assert done.returncode == 0, done.stderr
    web = apk_dir / 'web'
    assert (web / 'current').is_symlink()
    assert os.readlink(web / 'current') == '60'
    assert (web / 'current' / 'index.html').read_text() == '<html>web 60</html>'
    assert (web / 'current' / 'icons' / 'Icon-192.png').exists()
    assert oct((web / '60' / 'index.html').stat().st_mode & 0o777) == '0o644'
    assert (state / 'last-build-web').read_text().strip() == '60'
    assert WEB_NAME in _apks(apk_dir)
    # Ни временных папок, ни ссылок рядом.
    assert sorted(p.name for p in web.iterdir()) == ['60', 'current']

    again = _run(github, dirs)
    assert again.returncode == 0 and again.stdout == ''


def test_web_version_keeps_three_latest(github, dirs):
    apk_dir, _ = dirs
    web = apk_dir / 'web'
    for build in ('55', '56', '57', '58'):
        (web / build).mkdir(parents=True)
    os.symlink('58', web / 'current')
    _with_web(github)
    assert _run(github, dirs).returncode == 0
    assert sorted(p.name for p in web.iterdir()) == ['57', '58', '60', 'current']
    assert os.readlink(web / 'current') == '60'


def test_broken_web_archive_leaves_the_old_version(github, dirs):
    """Архив без index.html не выкладывается, и следующий запуск
    попробует снова, а не сочтёт сборку забранной."""
    apk_dir, state = dirs
    web = apk_dir / 'web'
    (web / '59').mkdir(parents=True)
    (web / '59' / 'index.html').write_text('old')
    os.symlink('59', web / 'current')
    _with_web(github, _web_zip({'readme.txt': 'nothing here'}))
    done = _run(github, dirs)
    assert done.returncode == 1
    assert 'нет index.html' in done.stderr
    assert (web / 'current' / 'index.html').read_text() == 'old'
    assert sorted(p.name for p in web.iterdir()) == ['59', 'current']
    assert WEB_NAME not in _apks(apk_dir)
    assert not (state / 'last-build-web').exists()
