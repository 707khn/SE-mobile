"""Выкладка без SSH (deploy/autodeploy.sh) и сигналы (alerts.py).

Скрипт гоняется по-настоящему: свой git-репозиторий вместо GitHub, а
systemctl, curl и pip подменены. Проверяется то, ради чего он написан:
красные проверки не выкладываются, неответивший /health откатывается, и
неудачный коммит второй раз не берётся.
"""

import json
import os
import stat
import subprocess

import pytest

import app as app_module

SCRIPT = os.path.join(os.path.dirname(__file__), '..', '..', 'deploy',
                      'autodeploy.sh')


def _git(cwd, *args):
    subprocess.run(['git', *args], cwd=cwd, check=True, capture_output=True,
                   env=dict(os.environ, GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t',
                            GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t'))


def _exe(path, text):
    path.write_text(text, encoding='utf-8')
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


@pytest.fixture
def world(tmp_path):
    origin = tmp_path / 'origin.git'
    seed = tmp_path / 'seed'
    server = tmp_path / 'server'
    subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main', str(origin)], check=True)
    seed.mkdir()
    _git(seed, 'init', '-q', '-b', 'main')
    (seed / 'se-mobile-backend').mkdir()
    (seed / 'se-mobile-backend' / 'app.py').write_text('v1\n')
    _git(seed, 'add', '-A')
    _git(seed, 'commit', '-qm', 'v1')
    _git(seed, 'remote', 'add', 'origin', str(origin))
    _git(seed, 'push', '-q', 'origin', 'main')
    subprocess.run(['git', 'clone', '-q', str(origin), str(server)], check=True)

    bin_ = tmp_path / 'bin'
    bin_.mkdir()
    calls = tmp_path / 'calls'
    # curl: GitHub отвечает содержимым файла runs.json, /health — по флагу.
    _exe(bin_ / 'curl', f'''#!/bin/bash
out=; url=
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift ;; http*) url=$1 ;; esac; shift
done
echo "curl $url" >> {calls}
case "$url" in
  *health*) [ -e {tmp_path}/healthy ] || exit 7; exit 0 ;;
  *) cp {tmp_path}/runs.json "$out"; printf 200 ;;
esac
''')
    _exe(bin_ / 'systemctl', f'#!/bin/bash\necho "systemctl $*" >> {calls}\n')
    _exe(bin_ / 'sleep', '#!/bin/bash\n')
    _exe(tmp_path / 'pip', f'#!/bin/bash\necho "pip $*" >> {calls}\n')
    _exe(tmp_path / 'notify.sh', f'#!/bin/bash\necho "notify $*" >> {calls}\n')

    def push(name, conclusion='success', path='se-mobile-backend/app.py'):
        target = seed / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(name + '\n')
        _git(seed, 'add', '-A')
        _git(seed, 'commit', '-qm', name)
        _git(seed, 'push', '-q', 'origin', 'main')
        sha = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=seed, check=True,
                             capture_output=True, text=True).stdout.strip()
        runs = [] if conclusion is None else [{
            'status': 'completed', 'conclusion': conclusion,
            'run_started_at': '2026-11-05T00:00:00Z', 'head_sha': sha}]
        (tmp_path / 'runs.json').write_text(json.dumps({'workflow_runs': runs}))
        return sha

    def run(healthy=True):
        flag = tmp_path / 'healthy'
        if healthy:
            flag.touch()
        elif flag.exists():
            flag.unlink()
        if calls.exists():
            calls.unlink()
        env = dict(os.environ, PATH=f'{bin_}:{os.environ["PATH"]}',
                   APP_DIR=str(server), GITHUB_TOKEN='t',
                   AUTODEPLOY_CONFIG='/nonexistent',
                   AUTODEPLOY_STATE_DIR=str(tmp_path / 'state'),
                   DEPLOY_PIP=str(tmp_path / 'pip'),
                   NOTIFY=str(tmp_path / 'notify.sh'), HEALTH_WAIT='6')
        done = subprocess.run(['bash', SCRIPT], env=env, capture_output=True,
                              text=True, timeout=60)
        assert done.returncode == 0, done.stderr
        status = dict(line.split('=', 1) for line in
                      (tmp_path / 'state' / 'status').read_text().splitlines()
                      if '=' in line)
        head = (server / 'se-mobile-backend' / 'app.py').read_text().strip()
        said = calls.read_text() if calls.exists() else ''
        return status, head, said

    return push, run


def test_green_main_is_deployed(world):
    push, run = world
    push('v2')
    status, head, said = run()
    assert head == 'v2' and status['result'] == 'ok'
    assert 'systemctl restart se-mobile' in said and 'notify Выложено' in said
    # Второй раз — нечего делать.
    status, head, said = run()
    assert 'systemctl' not in said


def test_red_checks_are_not_deployed(world):
    push, run = world
    push('v2', conclusion='failure')
    status, head, said = run()
    assert head == 'v1' and status['result'] == 'red'
    assert 'systemctl' not in said and 'notify' in said


def test_waits_for_checks_still_running(world):
    push, run = world
    push('v2', conclusion=None)
    status, head, _ = run()
    assert head == 'v1' and status['result'] == 'waiting'


def test_dead_health_rolls_back_and_remembers(world):
    push, run = world
    push('v2')
    status, head, said = run(healthy=False)
    assert head == 'v1' and status['result'] == 'rolled-back'
    assert said.count('systemctl restart se-mobile') == 2
    assert 'откачена' in said
    # Тот же коммит второй раз не берём.
    status, head, said = run()
    assert head == 'v1' and status['result'] == 'bad-commit'
    # А следующий — берём.
    push('v3')
    status, head, _ = run()
    assert head == 'v3' and status['result'] == 'ok'


def test_app_only_change_needs_no_restart(world):
    push, run = world
    push('ui', conclusion=None, path='lib/main.dart')
    status, head, said = run()
    assert status['result'] == 'ok' and 'systemctl' not in said
    assert 'actions/workflows' not in said


def test_alert_changes_are_said_once():
    import alerts
    before = {}
    now = {'backup': {'title': 'Копий базы нет', 'body': 'Ни разу.'}}
    said = alerts.changes(before, now)
    assert len(said) == 1 and 'Копий базы нет' in said[0]
    assert alerts.changes(now, now) == []
    fixed = alerts.changes(now, {})
    assert len(fixed) == 1 and 'Исправлено' in fixed[0]


def test_autodeploy_problem_reaches_the_admin(tmp_path, monkeypatch):
    status = tmp_path / 'status'
    status.write_text('checked_at=2999-01-01T00:00:00Z\nresult=rolled-back\n'
                      'message=abc1234 откачен: /health не ответил\n')
    monkeypatch.setattr(app_module, '_AUTODEPLOY_STATUS', str(status))
    assert 'откачен' in app_module._autodeploy_state()['problem']
    status.write_text('checked_at=2999-01-01T00:00:00Z\nresult=ok\n')
    assert app_module._autodeploy_state()['problem'] is None
    monkeypatch.setattr(app_module, '_AUTODEPLOY_STATUS', str(tmp_path / 'нет'))
    assert app_module._autodeploy_state()['problem'] is None
