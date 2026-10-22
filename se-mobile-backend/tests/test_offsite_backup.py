"""Копии базы уезжают с сервера, и из них правда можно восстановиться.

deploy/backup-offsite.sh гоняется против поддельного S3-хранилища на
127.0.0.1: тот хранит объекты в памяти, отдаёт список частями и, как
настоящее, сверяет Content-MD5. deploy/restore-test.sh — против настоящего
PostgreSQL, когда проверки идут на нём.
"""

import base64
import hashlib
import os
import shutil
import subprocess
import threading
from datetime import date, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from xml.sax.saxutils import escape

import pytest

import app as app_module

DEPLOY = os.path.join(os.path.dirname(__file__), '..', '..', 'deploy')
OFFSITE = os.path.join(DEPLOY, 'backup-offsite.sh')
RESTORE = os.path.join(DEPLOY, 'restore-test.sh')

scripts = pytest.mark.skipif(
    not all(shutil.which(t) for t in ('bash', 'curl', 'openssl', 'flock')),
    reason='нужны bash, curl, openssl и flock')


class _S3(BaseHTTPRequestHandler):
    objects = {}
    page_size = 3
    deny_delete = False
    seen_auth = []

    def log_message(self, *args):
        pass

    def _send(self, status, body=b'', headers=()):
        self.send_response(status)
        for key, value in headers:
            self.send_header(key, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def _key(self):
        path = urlsplit(self.path).path
        bucket, _, key = path.lstrip('/').partition('/')
        assert bucket == 'backups'
        return key

    def _signed(self):
        auth = self.headers.get('Authorization') or ''
        self.seen_auth.append(auth)
        return auth.startswith('AWS4-HMAC-SHA256 Credential=AKTEST/')

    def do_GET(self):
        if not self._signed():
            return self._send(403, b'<Error><Code>AccessDenied</Code></Error>')
        key = self._key()
        if key:
            if key not in self.objects:
                return self._send(404, b'<Error><Code>NoSuchKey</Code></Error>')
            return self._send(200, self.objects[key])
        query = parse_qs(urlsplit(self.path).query)
        prefix = query.get('prefix', [''])[0]
        start = int(query.get('continuation-token', ['0'])[0])
        keys = sorted(k for k in self.objects if k.startswith(prefix))
        page = keys[start:start + self.page_size]
        more = start + self.page_size < len(keys)
        items = ''.join(
            f'<Contents><Key>{escape(k)}</Key><Size>{len(self.objects[k])}</Size>'
            f'<ETag>"{hashlib.md5(self.objects[k]).hexdigest()}"</ETag></Contents>'
            for k in page)
        body = ('<?xml version="1.0" encoding="UTF-8"?>'
                '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                f'<IsTruncated>{"true" if more else "false"}</IsTruncated>'
                f'{items}'
                + (f'<NextContinuationToken>{start + self.page_size}'
                   '</NextContinuationToken>' if more else '')
                + '</ListBucketResult>')
        return self._send(200, body.encode())

    def do_HEAD(self):
        if not self._signed():
            return self._send(403)
        key = self._key()
        if key not in self.objects:
            return self._send(404)
        data = self.objects[key]
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('ETag', f'"{hashlib.md5(data).hexdigest()}"')
        self.end_headers()

    def do_PUT(self):
        if not self._signed():
            return self._send(403, b'<Error><Code>AccessDenied</Code></Error>')
        length = int(self.headers.get('Content-Length') or 0)
        data = self.rfile.read(length)
        md5 = base64.b64encode(hashlib.md5(data).digest()).decode()
        if self.headers.get('Content-MD5') != md5:
            return self._send(400, b'<Error><Code>BadDigest</Code></Error>')
        self.objects[self._key()] = data
        return self._send(200)

    def do_DELETE(self):
        if not self._signed():
            return self._send(403)
        if self.deny_delete:
            return self._send(403, b'<Error><Code>AccessDenied</Code></Error>')
        self.objects.pop(self._key(), None)
        return self._send(204)


@pytest.fixture
def s3():
    server = ThreadingHTTPServer(('127.0.0.1', 0), _S3)
    _S3.objects = {}
    _S3.deny_delete = False
    _S3.seen_auth = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f'http://127.0.0.1:{server.server_port}', _S3
    server.shutdown()


@pytest.fixture
def place(tmp_path):
    backups = tmp_path / 'backups'
    backups.mkdir()
    state = tmp_path / 'state'
    return backups, state


def _config(tmp_path, endpoint, **extra):
    path = tmp_path / 'offsite.env'
    fields = {'OFFSITE_ENDPOINT': endpoint, 'OFFSITE_BUCKET': 'backups',
              'OFFSITE_ACCESS_KEY': 'AKTEST',
              'OFFSITE_SECRET_KEY': 'secret/with+odd"chars\\',
              'OFFSITE_PREFIX': 'se-mobile'}
    fields.update(extra)
    path.write_text(''.join(f"{k}='{v}'\n" for k, v in fields.items()),
                    encoding='utf-8')
    return path


def _run(script, config, backups, state, *args, **env_extra):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('OFFSITE_', 'RESTORE_'))}
    env.update({'OFFSITE_CONFIG': str(config), 'BACKUP_DIR': str(backups),
                'OFFSITE_STATE_DIR': str(state / 'offsite'),
                'RESTORE_STATE_DIR': str(state / 'restore'),
                'TMPDIR': str(state)})
    env.update(env_extra)
    return subprocess.run(['bash', script, *args], env=env,
                          capture_output=True, text=True, timeout=120)


def _status(path):
    return dict(line.split('=', 1)
                for line in path.read_text(encoding='utf-8').splitlines()
                if '=' in line)


def _copy(backups, day, data=None):
    path = backups / f'se_mobile_{day.isoformat()}.sql.gz.enc'
    path.write_bytes(data if data is not None else os.urandom(4096))
    return path


@scripts
def test_copies_leave_the_server_and_arrive_whole(tmp_path, place, s3):
    endpoint, store = s3
    backups, state = place
    today = date.today()
    copies = [_copy(backups, today - timedelta(days=n)) for n in range(5)]
    config = _config(tmp_path, endpoint)

    done = _run(OFFSITE, config, backups, state)
    assert done.returncode == 0, done.stderr
    assert sorted(store.objects) == sorted(
        f'se-mobile/{c.name}' for c in copies)
    for c in copies:
        assert store.objects[f'se-mobile/{c.name}'] == c.read_bytes()
    status = _status(state / 'offsite' / 'status')
    assert status['result'] == 'ok' and status['uploaded'] == '5'
    # Пять объектов при трёх на страницу — список собран из двух частей.
    assert status['remote_count'] == '5'
    assert status['remote_newest'] == copies[0].name
    # Секрет не уходит в открытую: только подпись.
    assert all('secret' not in a for a in store.seen_auth)

    # Второй раз увозить нечего.
    again = _run(OFFSITE, config, backups, state)
    assert again.returncode == 0, again.stderr
    assert _status(state / 'offsite' / 'status')['uploaded'] == '0'


@scripts
def test_old_copies_are_trimmed_but_the_last_week_stays(tmp_path, place, s3):
    endpoint, store = s3
    backups, state = place
    today = date.today()
    _copy(backups, today)
    for n in range(100, 110):
        store.objects[f'se-mobile/se_mobile_{(today - timedelta(days=n)).isoformat()}'
                      '.sql.gz.enc'] = b'old'
    store.objects['se-mobile/чужое.txt'] = b'not ours'
    config = _config(tmp_path, endpoint, OFFSITE_KEEP_DAYS='90')

    done = _run(OFFSITE, config, backups, state)
    assert done.returncode == 0, done.stderr
    ours = [k for k in store.objects if k.endswith('.sql.gz.enc')]
    # Старше 90 дней — все, но семь последних не трогаются ни при каком сроке.
    assert len(ours) == 7
    assert 'se-mobile/чужое.txt' in store.objects


@scripts
def test_no_right_to_delete_is_not_a_failure(tmp_path, place, s3):
    """Старое может чистить само хранилище, а ключ сервера — только писать."""
    endpoint, store = s3
    backups, state = place
    today = date.today()
    _copy(backups, today)
    for n in range(100, 110):
        store.objects[f'se-mobile/se_mobile_{(today - timedelta(days=n)).isoformat()}'
                      '.sql.gz.enc'] = b'old'
    store.deny_delete = True

    done = _run(OFFSITE, _config(tmp_path, endpoint), backups, state)
    assert done.returncode == 0, done.stderr
    assert 'Удалять из хранилища нельзя' in done.stdout


@scripts
def test_not_configured_is_shown_not_failed(tmp_path, place):
    backups, state = place
    _copy(backups, date.today())
    done = _run(OFFSITE, tmp_path / 'нет-такого.env', backups, state)
    assert done.returncode == 0
    status = _status(state / 'offsite' / 'status')
    assert status['result'] == 'not-configured'
    assert 'только на сервере' in status['message']


@scripts
def test_wrong_key_is_named(tmp_path, place, s3):
    endpoint, _ = s3
    backups, state = place
    _copy(backups, date.today())
    config = _config(tmp_path, endpoint, OFFSITE_ACCESS_KEY='WRONG')
    done = _run(OFFSITE, config, backups, state)
    assert done.returncode == 1
    status = _status(state / 'offsite' / 'status')
    assert status['result'] == 'fail'
    assert 'не принимает ключ' in status['message']


@scripts
def test_stalled_daily_copy_is_reported(tmp_path, place, s3):
    """Увезти вчерашнее мало: если свежей копии нет — встало копирование."""
    endpoint, _ = s3
    backups, state = place
    old = _copy(backups, date.today() - timedelta(days=3))
    stamp = old.stat().st_mtime - 3 * 86400
    os.utime(old, (stamp, stamp))
    done = _run(OFFSITE, _config(tmp_path, endpoint), backups, state)
    assert done.returncode == 1
    status = _status(state / 'offsite' / 'status')
    assert status['result'] == 'stale'
    assert 'копирование встало' in status['message']


@scripts
def test_unreachable_storage_is_named(tmp_path, place):
    backups, state = place
    _copy(backups, date.today())
    config = _config(tmp_path, 'http://127.0.0.1:9')
    done = _run(OFFSITE, config, backups, state, S3_MAX_TIME='5')
    assert done.returncode == 1
    assert 'не отвечает' in _status(state / 'offsite' / 'status')['message']


# --- пробное восстановление: нужен настоящий PostgreSQL ---------------------

_DB_URL = os.environ.get('DATABASE_URL', '')
postgres = pytest.mark.skipif(
    not _DB_URL.startswith('postgresql')
    or not all(shutil.which(t) for t in ('psql', 'pg_dump', 'createdb',
                                         'dropdb', 'gzip', 'openssl')),
    reason='нужен PostgreSQL и его клиенты')


def _pg_env():
    url = urlsplit(_DB_URL)
    return {'PGHOST': url.hostname or 'localhost',
            'PGPORT': str(url.port or 5432),
            'PGUSER': url.username or 'postgres',
            'PGPASSWORD': url.password or '',
            'RESTORE_PG_AS': '',
            'RESTORE_LIVE_DB': url.path.lstrip('/'),
            'RESTORE_TEST_DB': 'se_mobile_restore_ci'}


def _encrypted_dump(backups, key, day):
    env = {**os.environ, **_pg_env()}
    path = backups / f'se_mobile_{day.isoformat()}.sql.gz.enc'
    subprocess.run(
        'pg_dump "$RESTORE_LIVE_DB" | gzip -9 | openssl enc -aes-256-cbc '
        f'-pbkdf2 -iter 200000 -pass "file:{key}" > "{path}"',
        shell=True, check=True, env=env, executable='/bin/bash',
        timeout=120)
    return path


def _databases():
    env = {**os.environ, **_pg_env()}
    out = subprocess.run(['psql', '-X', '-At', '-d', env['RESTORE_LIVE_DB'],
                          '-c', 'SELECT datname FROM pg_database'],
                         env=env, capture_output=True, text=True, check=True)
    return out.stdout.split()


@pytest.fixture
def key(tmp_path):
    path = tmp_path / 'backup-key'
    path.write_text(base64.b64encode(os.urandom(48)).decode() + '\n')
    return path


@postgres
@scripts
def test_restore_from_offsite_copy(app, tmp_path, place, s3, key):
    endpoint, store = s3
    backups, state = place
    copy = _encrypted_dump(backups, key, date.today())
    store.objects[f'se-mobile/{copy.name}'] = copy.read_bytes()
    copy.unlink()

    done = _run(RESTORE, _config(tmp_path, endpoint), backups, state,
                '--key', str(key), **_pg_env())
    assert done.returncode == 0, done.stdout + done.stderr
    status = _status(state / 'restore' / 'status')
    assert status['result'] == 'ok'
    assert status['source'] == 'offsite' and status['key'] == 'external'
    assert int(status['tables']) > 0
    # Пробная база за собой не остаётся, расшифрованный дамп — тоже.
    assert 'se_mobile_restore_ci' not in _databases()
    assert not list(state.glob('se-mobile-restore.*'))


@postgres
@scripts
def test_restore_with_the_wrong_key_fails_loudly(app, tmp_path, place, key):
    backups, state = place
    _encrypted_dump(backups, key, date.today())
    other = tmp_path / 'other-key'
    other.write_text('совсем другой ключ\n')

    done = _run(RESTORE, tmp_path / 'нет.env', backups, state,
                '--local', '--key', str(other), **_pg_env())
    assert done.returncode == 1
    status = _status(state / 'restore' / 'status')
    assert status['result'] == 'fail'
    assert 'не расшифровывается' in status['message']
    assert 'se_mobile_restore_ci' not in _databases()


@postgres
@scripts
def test_restore_of_a_truncated_copy_fails(app, tmp_path, place, key):
    backups, state = place
    copy = _encrypted_dump(backups, key, date.today())
    data = copy.read_bytes()
    copy.write_bytes(data[:len(data) // 2])

    done = _run(RESTORE, tmp_path / 'нет.env', backups, state,
                '--local', '--key', str(key), **_pg_env())
    assert done.returncode == 1
    assert _status(state / 'restore' / 'status')['result'] == 'fail'


# --- что видит администратор ------------------------------------------------

def _write(tmp_path, name, **fields):
    path = tmp_path / name
    path.write_text(''.join(f'{k}={v}\n' for k, v in fields.items()),
                    encoding='utf-8')
    return str(path)


def _stamp(**delta):
    from datetime import datetime, timezone
    return (datetime.now(timezone.utc) - timedelta(**delta)) \
        .strftime('%Y-%m-%dT%H:%M:%SZ')


def test_offsite_state_all_good(tmp_path, monkeypatch):
    monkeypatch.setattr(app_module, '_OFFSITE_STATUS', _write(
        tmp_path, 'offsite', checked_at=_stamp(hours=2), result='ok',
        remote_count='31', remote_newest='se_mobile_2026-10-22.sql.gz.enc'))
    state = app_module._offsite_state()
    assert state['problem'] == '' and state['count'] == 31


def test_offsite_state_names_the_problem(tmp_path, monkeypatch):
    monkeypatch.setattr(app_module, '_OFFSITE_STATUS', _write(
        tmp_path, 'offsite', checked_at=_stamp(hours=2),
        result='not-configured',
        message='Хранилище не настроено — копии лежат только на сервере.'))
    assert 'только на сервере' in app_module._offsite_state()['problem']

    monkeypatch.setattr(app_module, '_OFFSITE_STATUS', _write(
        tmp_path, 'offsite', checked_at=_stamp(days=3), result='ok'))
    assert 'не запускался' in app_module._offsite_state()['problem']

    monkeypatch.setattr(app_module, '_OFFSITE_STATUS',
                        str(tmp_path / 'нет-такого'))
    assert 'не увозятся' in app_module._offsite_state()['problem']


def test_restore_test_state(tmp_path, monkeypatch):
    monkeypatch.setattr(app_module, '_RESTORE_TEST_STATUS',
                        str(tmp_path / 'нет-такого'))
    assert 'ни разу' in app_module._restore_test_state()['problem']

    monkeypatch.setattr(app_module, '_RESTORE_TEST_STATUS', _write(
        tmp_path, 'restore', checked_at=_stamp(days=10), result='ok',
        source='offsite', key='server'))
    state = app_module._restore_test_state()
    assert state['problem'] == '' and state['days_ago'] == 10

    monkeypatch.setattr(app_module, '_RESTORE_TEST_STATUS', _write(
        tmp_path, 'restore', checked_at=_stamp(days=120), result='ok'))
    assert 'пора повторить' in app_module._restore_test_state()['problem']

    monkeypatch.setattr(app_module, '_RESTORE_TEST_STATUS', _write(
        tmp_path, 'restore', checked_at=_stamp(days=1), result='fail',
        message='Копия не расшифровывается ключом.'))
    assert 'не расшифровывается' in app_module._restore_test_state()['problem']
