"""Обновление, откат и тестовый стенд: deploy/release.sh и deploy/staging.sh.

release.sh гоняется против настоящего git: «GitHub» — голый репозиторий во
временной папке, сервер — неполный клон из него, как на машине
(git clone --depth 1). systemctl и pip подменены записью в журнал, а /health
отвечает маленький сервер на 127.0.0.1: 503, если в поставленном коде лежит
файл BROKEN, иначе 200. Так видно главное — что сломанное обновление
откатывается само, а откат находит прежний коммит.

staging.sh refresh-db — против настоящего PostgreSQL, когда проверки идут на
нём.
"""

import base64
import os
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

import pytest

DEPLOY = os.path.join(os.path.dirname(__file__), '..', '..', 'deploy')
RELEASE = os.path.join(DEPLOY, 'release.sh')
STAGING = os.path.join(DEPLOY, 'staging.sh')

scripts = pytest.mark.skipif(
    not all(shutil.which(t) for t in ('bash', 'git', 'curl', 'flock')),
    reason='нужны bash, git, curl и flock')

REQ = 'se-mobile-backend/requirements.txt'


def _git(cwd, *args):
    return subprocess.run(
        ['git', '-C', str(cwd), '-c', 'user.name=t', '-c', 'user.email=t@t',
         '-c', 'init.defaultBranch=main', *args],
        check=True, capture_output=True, text=True).stdout.strip()


class Origin:
    """«GitHub»: голый репозиторий и рабочая копия, из которой в него пишут."""

    def __init__(self, root):
        self.bare = root / 'origin.git'
        self.work = root / 'author'
        subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main',
                        str(self.bare)], check=True)
        # GitHub отдаёт коммит по хешу; локальный git — только с этим.
        _git(self.bare, 'config', 'uploadpack.allowAnySHA1InWant', 'true')
        subprocess.run(['git', 'clone', '-q', str(self.bare), str(self.work)],
                       check=True, capture_output=True)
        _git(self.work, 'checkout', '-q', '-B', 'main')
        self.url = 'file://' + str(self.bare)

    def commit(self, message, files=None, tag=None, branch='main'):
        if _git(self.work, 'symbolic-ref', '--short', 'HEAD') != branch:
            _git(self.work, 'checkout', '-q', branch)
        for name, text in (files or {}).items():
            path = self.work / name
            if text is None:
                path.unlink()
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        _git(self.work, 'add', '-A')
        _git(self.work, 'commit', '-q', '--allow-empty', '-m', message)
        sha = _git(self.work, 'rev-parse', 'HEAD')
        if tag:
            _git(self.work, 'tag', '-a', tag, '-m', tag)
        _git(self.work, 'push', '-q', '--follow-tags', 'origin', branch)
        return sha


class _Health(BaseHTTPRequestHandler):
    app_dir = None

    def log_message(self, *args):
        pass

    def do_GET(self):
        broken = os.path.exists(os.path.join(
            self.app_dir, 'se-mobile-backend', 'BROKEN'))
        self.send_response(503 if broken else 200)
        self.send_header('Content-Length', '0')
        self.end_headers()


@pytest.fixture
def server(tmp_path):
    origin = Origin(tmp_path)
    first = origin.commit('первый', {REQ: 'flask==3.0.0\n',
                                     'se-mobile-backend/app.py': 'v1\n'},
                          tag='v1.0.0-1')
    app_dir = tmp_path / 'opt' / 'se-mobile'
    subprocess.run(['git', 'clone', '-q', '--depth', '1', origin.url,
                    str(app_dir)], check=True, capture_output=True)

    bin_dir = tmp_path / 'bin'
    bin_dir.mkdir()
    calls = tmp_path / 'calls.log'
    for name in ('systemctl', 'pip'):
        tool = bin_dir / name
        tool.write_text(f'#!/bin/bash\necho "{name} $*" >> "{calls}"\n')
        tool.chmod(0o755)
    venv = tmp_path / 'venv'
    (venv / 'bin').mkdir(parents=True)
    shutil.copy(bin_dir / 'pip', venv / 'bin' / 'pip')

    handler = type('Health', (_Health,), {'app_dir': str(app_dir)})
    httpd = ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('RELEASE_', 'APP_DIR', 'VENV', 'SERVICE'))}
    env.update({
        'APP_DIR': str(app_dir),
        'VENV': str(venv),
        'SYSTEMCTL': str(bin_dir / 'systemctl'),
        'HEALTH_URL': f'http://127.0.0.1:{httpd.server_port}/health',
        'HEALTH_WAIT': '6',
        'RELEASE_STATE_DIR': str(tmp_path / 'state'),
        'RELEASE_LOCK': str(tmp_path / 'release.lock'),
        'APP_OWNER': 'нет-такого',
        'GIT_CONFIG_COUNT': '1',
        'GIT_CONFIG_KEY_0': 'protocol.file.allow',
        'GIT_CONFIG_VALUE_0': 'always',
    })

    class Server:
        pass

    s = Server()
    s.origin, s.dir, s.env, s.calls = origin, app_dir, env, calls
    s.history = tmp_path / 'state' / 'history.log'
    s.first = first
    s.head = lambda: _git(app_dir, 'rev-parse', 'HEAD')
    s.run = lambda *args, script=RELEASE, **extra: subprocess.run(
        ['bash', script, *args], env={**env, **extra},
        capture_output=True, text=True, timeout=120)
    s.restarts = lambda: (calls.read_text().count('systemctl restart')
                          if calls.exists() else 0)
    s.pip_runs = lambda: (calls.read_text().count('pip install')
                          if calls.exists() else 0)
    yield s
    httpd.shutdown()


@scripts
def test_release_takes_fresh_main_and_restarts(server):
    second = server.origin.commit('второй', {'se-mobile-backend/app.py': 'v2\n'})

    done = server.run()
    assert done.returncode == 0, done.stdout + done.stderr
    assert server.head() == second
    assert server.restarts() == 1
    # Зависимости не менялись — pip не звали.
    assert server.pip_runs() == 0
    line = server.history.read_text().split()
    assert line[1:4] == ['release', server.first, second]
    # Прежние команды из README продолжают работать: стоим на ветке main.
    assert _git(server.dir, 'rev-parse', '--abbrev-ref', 'HEAD') == 'main'


@scripts
def test_nothing_new_means_no_restart(server):
    done = server.run()
    assert done.returncode == 0, done.stderr
    assert 'Ничего не делаю' in done.stdout
    assert server.restarts() == 0


@scripts
def test_rollback_returns_what_was_there_and_walks_further_back(server):
    second = server.origin.commit('второй', {'se-mobile-backend/app.py': 'v2\n'})
    assert server.run().returncode == 0
    third = server.origin.commit('третий', {'se-mobile-backend/app.py': 'v3\n'})
    assert server.run().returncode == 0
    assert server.head() == third

    done = server.run('--rollback')
    assert done.returncode == 0, done.stdout + done.stderr
    assert server.head() == second

    # Второй откат подряд — ещё на шаг назад, а не обратно на третий.
    done = server.run('--rollback')
    assert done.returncode == 0, done.stdout + done.stderr
    assert server.head() == server.first

    # Дальше журнал не помнит — просим метку, а не гадаем.
    done = server.run('--rollback')
    assert done.returncode == 1
    assert '--list' in done.stderr


@scripts
def test_rollback_by_the_name_it_is_called(server, tmp_path):
    server.origin.commit('второй', {'se-mobile-backend/app.py': 'v2\n'})
    assert server.run().returncode == 0
    link = tmp_path / 'se-mobile-rollback'
    link.symlink_to(os.path.abspath(RELEASE))
    done = server.run(script=str(link))
    assert done.returncode == 0, done.stdout + done.stderr
    assert server.head() == server.first


@scripts
def test_release_to_an_old_tag_missing_from_the_shallow_clone(server):
    server.origin.commit('второй', {'se-mobile-backend/app.py': 'v2\n'},
                         tag='v1.0.1-2')
    tagged = server.origin.commit('третий', {'se-mobile-backend/app.py': 'v3\n'})
    assert server.run().returncode == 0
    assert server.head() == tagged

    # Первого коммита в клоне уже может и не быть — его достают из «GitHub».
    done = server.run('--rollback', 'v1.0.0-1')
    assert done.returncode == 0, done.stdout + done.stderr
    assert server.head() == server.first
    assert ' rollback ' in server.history.read_text()


@scripts
def test_broken_release_is_rolled_back_by_itself(server):
    server.origin.commit('сломанный', {'se-mobile-backend/BROKEN': 'да\n'})

    done = server.run()
    assert done.returncode == 1
    assert 'вернул' in done.stderr
    assert server.head() == server.first
    assert server.restarts() == 2
    history = server.history.read_text()
    assert ' failed ' in history and ' auto-back ' in history


@scripts
def test_staging_keeps_the_broken_code_to_look_at(server):
    broken = server.origin.commit('сломанный', {'se-mobile-backend/BROKEN': 'да\n'})
    done = server.run(AUTO_ROLLBACK='0')
    assert done.returncode == 1
    assert server.head() == broken


@scripts
def test_dependencies_are_installed_only_when_they_change(server):
    server.origin.commit('новая библиотека',
                         {REQ: 'flask==3.0.0\nopenpyxl>=3.1,<4\n'})
    assert server.run().returncode == 0
    assert server.pip_runs() == 1
    # И назад — тоже: старый код со старыми зависимостями.
    assert server.run('--rollback').returncode == 0
    assert server.pip_runs() == 2


@scripts
def test_feature_branch_by_name(server):
    branch_sha = server.origin.commit('ветка', {'se-mobile-backend/app.py': 'b\n'},
                                      branch='main')
    _git(server.origin.work, 'checkout', '-q', '-b', 'feature/x')
    feature = server.origin.commit('на ветке', {'se-mobile-backend/app.py': 'f\n'},
                                   branch='feature/x')
    done = server.run('feature/x')
    assert done.returncode == 0, done.stdout + done.stderr
    assert server.head() == feature != branch_sha


@scripts
def test_local_edits_on_the_server_stop_the_release(server):
    server.origin.commit('второй', {'se-mobile-backend/app.py': 'v2\n'})
    (server.dir / 'se-mobile-backend' / 'app.py').write_text('правка руками\n')
    # Неотслеживаемое (venv рядом с кодом) не мешает.
    (server.dir / 'venv').mkdir()

    done = server.run()
    assert done.returncode == 1
    assert 'несохранённые правки' in done.stderr
    assert server.head() == server.first
    assert server.restarts() == 0


@scripts
def test_unknown_ref_is_named(server):
    done = server.run('v9.9.9-99')
    assert done.returncode == 1
    assert 'не нашёл' in done.stderr
    assert server.restarts() == 0


@scripts
def test_list_shows_history_and_tags(server):
    server.origin.commit('второй', {'se-mobile-backend/app.py': 'v2\n'},
                         tag='v1.0.1-2')
    assert server.run().returncode == 0
    done = server.run('--list')
    assert done.returncode == 0, done.stderr
    assert 'второй' in done.stdout
    assert 'v1.0.0-1' in done.stdout and 'v1.0.1-2' in done.stdout


# --- тестовый стенд ----------------------------------------------------------

def _staging(tmp_path, *args, **extra):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('STAGING_', 'LIVE_'))}
    env.update({'STAGING_STATE_DIR': str(tmp_path / 'staging-state'),
                'TMPDIR': str(tmp_path)})
    env.update(extra)
    return subprocess.run(['bash', STAGING, *args], env=env,
                          capture_output=True, text=True, timeout=180)


@scripts
def test_staging_env_points_at_its_own_database_and_sends_no_push(tmp_path):
    live = tmp_path / 'se-mobile.env'
    live.write_text(
        '# комментарий\n'
        'DATABASE_URL=postgresql://se_mobile:pa55@127.0.0.1/se_mobile\n'
        'REQUIRE_AUTH=0\n'
        'ADMIN_TOKEN=abc\n'
        'FIREBASE_CREDENTIALS_PATH=/etc/se-mobile-firebase.json\n')
    staged = tmp_path / 'se-mobile-staging.env'

    done = _staging(tmp_path, 'env', LIVE_ENV=str(live), STAGING_ENV=str(staged))
    assert done.returncode == 0, done.stdout + done.stderr
    lines = staged.read_text().splitlines()
    assert 'DATABASE_URL=postgresql://se_mobile:pa55@127.0.0.1/se_mobile_staging' in lines
    # Остальное — как на рабочем, проверка пропуска в том числе.
    assert 'REQUIRE_AUTH=0' in lines and 'ADMIN_TOKEN=abc' in lines
    assert not any('firebase.json' in line for line in lines)
    assert oct(staged.stat().st_mode & 0o777) == '0o600'


@scripts
def test_staging_never_drops_the_live_database(tmp_path):
    done = _staging(tmp_path, 'refresh-db', STAGING_DB='se_mobile',
                    LIVE_DB='se_mobile')
    assert done.returncode == 1
    assert 'совпадает с рабочей' in done.stderr


_DB_URL = os.environ.get('DATABASE_URL', '')
postgres = pytest.mark.skipif(
    not _DB_URL.startswith('postgresql')
    or not all(shutil.which(t) for t in ('psql', 'pg_dump', 'createdb',
                                         'dropdb', 'gzip', 'openssl')),
    reason='нужен PostgreSQL и его клиенты')


@postgres
@scripts
def test_staging_database_comes_from_the_nightly_copy(app, tmp_path):
    from models import db, Employee, FcmToken

    url = urlsplit(_DB_URL)
    live_db = url.path.lstrip('/')
    pg = {'PGHOST': url.hostname or 'localhost',
          'PGPORT': str(url.port or 5432),
          'PGUSER': url.username or 'postgres',
          'PGPASSWORD': url.password or ''}

    with app.app_context():
        employee = Employee.query.first()
        assert employee is not None
        token = FcmToken(employee_id=employee.employee_id,
                         token='staging-ci-token')
        db.session.add(token)
        db.session.commit()
        employees = Employee.query.count()

    key = tmp_path / 'backup-key'
    key.write_text(base64.b64encode(os.urandom(48)).decode() + '\n')
    backups = tmp_path / 'backups'
    backups.mkdir()
    try:
        subprocess.run(
            f'pg_dump "{live_db}" | gzip -9 | openssl enc -aes-256-cbc '
            f'-pbkdf2 -iter 200000 -pass "file:{key}" '
            f'> "{backups}/se_mobile_2026-10-21.sql.gz.enc"',
            shell=True, check=True, env={**os.environ, **pg},
            executable='/bin/bash', timeout=120)
    finally:
        with app.app_context():
            FcmToken.query.filter_by(token='staging-ci-token').delete()
            db.session.commit()

    systemctl = tmp_path / 'systemctl'
    systemctl.write_text('#!/bin/bash\n[ "$1" != is-active ]\n')
    systemctl.chmod(0o755)

    done = _staging(tmp_path, 'refresh-db', **pg,
                    STAGING_PG_AS='', LIVE_DB=live_db,
                    STAGING_DB='se_mobile_staging_ci',
                    STAGING_DB_OWNER=pg['PGUSER'],
                    BACKUP_DIR=str(backups), BACKUP_KEY=str(key),
                    SYSTEMCTL=str(systemctl))
    try:
        assert done.returncode == 0, done.stdout + done.stderr
        assert 'se_mobile_2026-10-21' in (tmp_path / 'staging-state' / 'db').read_text()

        def count(table):
            return int(subprocess.run(
                ['psql', '-X', '-At', '-d', 'se_mobile_staging_ci', '-c',
                 f'SELECT count(*) FROM {table}'],
                env={**os.environ, **pg}, capture_output=True, text=True,
                check=True).stdout)

        assert count('employees') == employees
        # Токены телефонов на стенд не попадают: уведомлениям некуда уйти.
        assert count('fcm_tokens') == 0
        # Расшифрованный дамп за собой не остаётся.
        assert not list(tmp_path.glob('se-mobile-staging.*'))
    finally:
        subprocess.run(['dropdb', '--if-exists', 'se_mobile_staging_ci'],
                       env={**os.environ, **pg}, check=False)
