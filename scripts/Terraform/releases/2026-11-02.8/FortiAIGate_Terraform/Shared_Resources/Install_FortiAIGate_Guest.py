#!/usr/bin/env python3
"""Terraform-only installation worker; the pinned vendor assistant is unchanged."""
import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import pwd
import re
import select
import signal
import ssl
import subprocess
import time
import traceback
import urllib.request


STATE = Path('/var/lib/fortiaigate-terraform-install')
INSTALLER = Path('/opt/fortiaigate/Installer')
DATA = INSTALLER / 'faig_deployment_assistant_data'
DEPLOYMENT = DATA / 'deployment'
PREP = Path('/var/lib/fortiaigate-prep')
LOG = Path('/var/log/fortiaigate-terraform-install.log')
SCRIPT_SHA = '42d958fd3b68229447fb441d98cf00530dbe66655f7c5ea33b062171c02581ae'
ARCHIVE_SHA = '100abb31106b848959ec9331e727174aba6b52b42bc26b2af5757dfd339970b7'
ARCHIVE = 'FAIG_deploy-docker-compose-cli-V8.0.2-build0055-FORTINET.tar.gz'
CORE = ('postgres', 'redis', 'api', 'webui', 'llm-gateway', 'guardrail',
        'policy-guard', 'logd', 'license-manager', 'nginx')
MAIN_PROMPT = r'6\. Exit\s+Choice: '
OPERATIONS_PROMPT = r'7\. Back\s+Choice: '


class InstallError(RuntimeError):
    pass


def validate_config(config):
    if not isinstance(config, dict) or set(config) != {'edition', 'operator', 'gateway_api_port'}:
        raise InstallError('Invalid Terraform installation configuration.')
    if config['edition'] not in ('cpu', 'gpu') or config['operator'] not in ('ubuntu', 'fortiadmin'):
        raise InstallError('Unsupported gateway edition or administrator.')
    port = config['gateway_api_port']
    if type(port) is not int or not 1 <= port <= 65535 or port in (22, 3000, 11434):
        raise InstallError('Invalid gateway API port.')
    return config


def atomic_json(path, value, mode=0o600):
    if path.is_symlink():
        raise InstallError('Refusing a symbolic link in installation state.')
    temporary = path.with_suffix('.tmp')
    with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode), 'w') as stream:
        json.dump(value, stream, sort_keys=True)
        stream.write('\n')
    os.chmod(temporary, mode)
    temporary.replace(path)


def stage(message, percent, status='running'):
    atomic_json(STATE / 'status.json', {'status': status, 'stage': message, 'percent': percent}, 0o644)
    print(f'FortiAIGate installation [{status.upper()}] {percent}%: {message}', flush=True)


def run(command, log, timeout=120, capture=False, check=True):
    result = subprocess.run(command, stdout=subprocess.PIPE if capture else log,
                            stderr=log, text=capture, timeout=timeout)
    if check and result.returncode:
        raise InstallError('A required installation command failed; inspect the private installation log on the VM.')
    return result


def read_env(path):
    if path.is_symlink() or not path.is_file():
        raise InstallError('Expected the vendor-generated deployment environment file.')
    # Parse as data; never source the environment file or return its contents.
    result = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        key, separator, value = line.partition('=')
        if separator:
            if key in result:
                raise InstallError('Duplicate key in the deployment environment file.')
            result[key] = value
    return result


def verify_definition(config):
    values = read_env(DEPLOYMENT / '.env')
    required = {'TAG': '8.0.2-build0055', 'FAIG_DEPLOY_GPU': str(config['edition'] == 'gpu').lower(),
                'HTTPS_PORT': '443', 'FAIG_DEPLOY_PROJECT': 'fortiaigate',
                'FAIG_DEPLOY_BUILD_KIND': 'directory', 'FAIG_DEPLOY_BUILD_DIR': '/opt/fortiaigate/Images'}
    if any(values.get(key) != value for key, value in required.items()):
        raise InstallError('Existing application configuration differs from the requested release/profile; no overwrite was attempted.')
    if any(not values.get(key) for key in ('FAIG_MASTER_KEY', 'CSRF_SECRET_KEY', 'POSTGRES_PASSWORD')):
        raise InstallError('The vendor assistant did not preserve the required locally generated secrets.')
    if config['edition'] == 'gpu':
        selected = values.get('FAIG_GPU_DEVICES', '')
        if not re.fullmatch(r'GPU-[0-9a-fA-F-]+', selected):
            raise InstallError('The GPU deployment must select its one explicit GPU UUID.')
        if any(values.get(key) != selected for key in ('TRITON_DEVICES', 'VLLM_DEVICES')):
            raise InstallError('Triton and vLLM must share the selected single GPU explicitly.')


class Wizard:
    """Drive only the checksum-pinned assistant, without exposing its transcript."""
    def __init__(self, command, log, timeout=5400):
        self.log, self.buffer, self.deadline = log, '', time.monotonic() + timeout
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvp(command[0], command)
        self.finished = False

    def expect(self, patterns, timeout=180):
        if isinstance(patterns, str):
            patterns = [patterns]
        deadline = min(self.deadline, time.monotonic() + timeout)
        while time.monotonic() < deadline:
            for index, pattern in enumerate(patterns):
                match = re.search(pattern, self.buffer)
                if match:
                    self.buffer = self.buffer[match.end():]
                    return index
            if not select.select([self.fd], [], [], min(1, max(0, deadline - time.monotonic())))[0]:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                data = b''
            if not data:
                raise InstallError('The pinned installer exited before the expected step; inspect the private VM log.')
            self.log.write(data)
            self.log.flush()
            self.buffer = (self.buffer + data.decode(errors='replace').replace('\r', ''))[-262144:]
        raise InstallError('The pinned installer did not reach the expected step before its deadline; no alternative answers were guessed.')

    def answer(self, pattern, answer, timeout=180):
        self.expect(pattern, timeout)
        os.write(self.fd, (str(answer) + '\n').encode())

    def finish(self):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.finished = True
                if os.waitstatus_to_exitcode(status):
                    raise InstallError('The vendor installer returned a failure.')
                return
            time.sleep(0.2)
        raise InstallError('The vendor installer did not exit after completing deployment.')

    def close(self):
        if not self.finished:
            try:
                os.killpg(self.pid, signal.SIGTERM)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if os.waitpid(self.pid, os.WNOHANG)[0]:
                        self.finished = True
                        break
                    time.sleep(0.1)
                if not self.finished:
                    os.killpg(self.pid, signal.SIGKILL)
                    os.waitpid(self.pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
        os.close(self.fd)


def configure_wizard(wizard, edition):
    wizard.answer(r'Where are the FortiAIGate images\?[\s\S]*?Choice \[1\]: ', 1)
    wizard.answer(r'Absolute folder containing release image archives: ', '/opt/fortiaigate/Images')
    wizard.answer(r'Release images found[\s\S]*?8\.0\.2[\s\S]*?0055[\s\S]*?Choice \[1\]: ', 1)
    wizard.answer(r'HTTPS port \[443\]: ', 443)
    wizard.answer(r'HTTP redirect port \[8081\]: ', 8081)
    wizard.answer(r'Bind HTTP redirect to 127\.0\.0\.1 only[\s\S]*?Choice \[1\]: ', 1)
    wizard.answer(r'Enable GPU content inspection[\s\S]*?Choice \[[12]\]: ', 1 if edition == 'gpu' else 2)
    if edition == 'gpu':
        wizard.answer(r'GPU numbers, comma separated \[1\]: ', 1)
    wizard.answer(r'LLM gateway memory in GB \(minimum 2\) \[8\]: ', 8 if edition == 'gpu' else 4)
    wizard.answer(r'Log retention storage budget in GB \(minimum 8\) \[16\]: ', 16 if edition == 'gpu' else 8)
    wizard.answer(r'Deployment namespace \[fortiaigate\]: ', 'fortiaigate')
    wizard.answer(r'Use a FortiCare proxy[\s\S]*?Choice \[2\]: ', 2)


def install_with_assistant(config, log):
    account = pwd.getpwnam(config['operator'])
    command = ['runuser', '-u', account.pw_name, '--', 'env', 'HOME=' + account.pw_dir,
               'TERM=dumb', '/bin/bash', str(INSTALLER / 'deploy-docker-compose.sh')]
    wizard = Wizard(command, log)
    try:
        if not (DEPLOYMENT / '.env').exists():
            stage('Configure the pinned CPU/GPU application profile and generate secrets locally', 15)
            configure_wizard(wizard, config['edition'])
        wizard.expect(MAIN_PROMPT)
        verify_definition(config)
        stage('Import and verify the FortiAIGate release images', 35)
        os.write(wizard.fd, b'5\n')
        wizard.answer(OPERATIONS_PROMPT, 1)
        wizard.expect(OPERATIONS_PROMPT, timeout=3600)
        if config['edition'] == 'gpu':
            stage('Verify CUDA with the shipped FortiAIGate GPU image', 55)
            run(['docker', 'run', '--rm', '--runtime=nvidia', '--gpus', 'all', '--entrypoint', 'python3',
                 'fortiaigate/vllm-server:8.0.2-build0055', '-c',
                 'import torch; assert torch.cuda.is_available(); x=torch.ones(1,device="cuda"); assert x.item()==1'], log, timeout=300)
        os.write(wizard.fd, b'7\n')
        wizard.answer(MAIN_PROMPT, 3)
        stage('Create the private recovery archive and start the application containers', 65)
        step = wizard.expect([r'Create it now[\s\S]*?Choice \[1\]: ', r'Type exactly APPLY to continue: '], timeout=1800)
        if step == 0:
            os.write(wizard.fd, b'1\n')
            wizard.expect(r'Type exactly APPLY to continue: ', timeout=300)
        os.write(wizard.fd, b'APPLY\n')
        wizard.answer(MAIN_PROMPT, 6, timeout=1800)
        wizard.finish()
    finally:
        wizard.close()


def application_ready(edition, log):
    names = ['faig-' + name for name in CORE]
    if edition == 'gpu':
        names += ['faig-dlp-scanner', 'faig-triton', 'faig-vllm-server']
    result = run(['docker', 'inspect', '--format',
                  '{{json .Name}}|{{json .State}}|{{index .Config.Labels "com.docker.compose.project"}}',
                  *names], log, capture=True, check=False)
    if result.returncode:
        return False
    rows = result.stdout.splitlines()
    if len(rows) != len(names):
        return False
    for row, expected in zip(rows, names):
        try:
            name, raw, project = row.split('|')
            state = json.loads(raw)
            if json.loads(name) != '/' + expected or project != 'fortiaigate':
                return False
            if state.get('Status') != 'running' or state.get('Restarting'):
                return False
            if expected in ('faig-postgres', 'faig-redis') and state.get('Health', {}).get('Status') != 'healthy':
                return False
        except (ValueError, TypeError):
            return False
    response = run(['curl', '-ksS', '--max-time', '10', '-o', '/dev/null', '-w', '%{http_code}',
                    'https://127.0.0.1/ui'], log, capture=True, check=False, timeout=15)
    return response.returncode == 0 and response.stdout == '200'


def configure_api_alias(port, log):
    # WebUI remains on 443. An optional private API port forwards the unchanged
    # TLS stream; existing security groups/NSGs restrict it to the linked Ollama.
    if port == 443:
        return
    proxy = Path('/lib/systemd/systemd-socket-proxyd')
    if not proxy.is_file():
        raise InstallError('The systemd TCP proxy for the requested private API port is unavailable.')
    root = Path('/etc/systemd/system')
    (root / 'fortiaigate-terraform-api.socket').write_text(
        '[Unit]\nDescription=Terraform private FortiAIGate API listener\n'
        '[Socket]\nListenStream=10.250.20.10:' + str(port) + '\nNoDelay=true\n'
        '[Install]\nWantedBy=sockets.target\n')
    (root / 'fortiaigate-terraform-api.service').write_text(
        '[Unit]\nDescription=Terraform private FortiAIGate TLS forwarding\n'
        'Requires=fortiaigate-terraform-api.socket\nAfter=network-online.target\n'
        '[Service]\nExecStart=' + str(proxy) + ' 127.0.0.1:443\nDynamicUser=yes\nNoNewPrivileges=yes\n')
    run(['systemctl', 'daemon-reload'], log)
    run(['systemctl', 'enable', '--now', 'fortiaigate-terraform-api.socket'], log)


def setup_status():
    # This unauthenticated, read-only endpoint/boolean is used by the shipped
    # build0055 WebUI. Accept the local self-signed certificate only on loopback.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
    with opener.open('https://127.0.0.1/api/v1/setup-status', timeout=10) as response:
        result = json.loads(response.read(8192))
    if not isinstance(result, dict) or type(result.get('needs_setup')) is not bool:
        raise InstallError('The pinned WebUI setup-status contract was not returned.')
    return result['needs_setup']


def install_setup_timer(log):
    if (STATE / 'setup-restart-complete.json').is_file():
        return
    root = Path('/etc/systemd/system')
    (root / 'fortiaigate-terraform-finish-setup.service').write_text(
        '[Unit]\nDescription=Terraform FortiAIGate one-time post-setup API restart\n'
        'After=docker.service\nConditionPathExists=' + str(STATE / 'ready.json') + '\n'
        '[Service]\nType=oneshot\nUMask=0077\nTimeoutStartSec=180\n'
        'ExecStart=/usr/bin/python3 /usr/local/libexec/fortiaigate-terraform-install.py --finish-setup\n')
    (root / 'fortiaigate-terraform-finish-setup.timer').write_text(
        '[Unit]\nDescription=Wait for the operator to complete FortiAIGate WebUI setup\n'
        '[Timer]\nOnBootSec=60\nOnUnitActiveSec=15\nAccuracySec=5\n'
        '[Install]\nWantedBy=timers.target\n')
    run(['systemctl', 'daemon-reload'], log)
    run(['systemctl', 'enable', '--now', 'fortiaigate-terraform-finish-setup.timer'], log)


def finish_setup(log):
    complete = STATE / 'setup-restart-complete.json'
    if complete.exists() or not (STATE / 'ready.json').is_file():
        return
    if setup_status():
        return
    observed = STATE / 'setup-observed.json'
    if not observed.exists():
        atomic_json(observed, {'completed_at': time.time()})
        return
    if time.time() - json.loads(observed.read_text())['completed_at'] < 30:
        return
    started = STATE / 'setup-restart-started.json'
    details = run(['docker', 'inspect', '--format',
                   '{{.Id}}|{{.State.Status}}|{{.State.StartedAt}}|{{index .Config.Labels "com.docker.compose.project"}}',
                   'faig-api'], log, capture=True).stdout.strip().split('|')
    if len(details) != 4 or details[3] != 'fortiaigate':
        raise InstallError('Post-setup API restart ownership check failed.')
    if not started.exists():
        # Record before submitting. If the response is lost, later timer ticks
        # verify health and do not repeatedly restart a live API.
        atomic_json(started, {'requested_at': time.time(), 'container_id': details[0], 'previous_started_at': details[2]})
        run(['docker', 'restart', '--time', '30', 'faig-api'], log, timeout=90)
        return
    request = json.loads(started.read_text())
    if details[0] != request['container_id']:
        raise InstallError('The API container identity changed before the post-setup restart could be verified.')
    if details[1] == 'running' and details[2] != request['previous_started_at'] and not setup_status():
        atomic_json(complete, {'completed_at': time.time()})
        run(['systemctl', 'disable', '--now', 'fortiaigate-terraform-finish-setup.timer'], log)
        print('PASS: first-run WebUI setup detected; the one-time API restart is complete.', flush=True)


def install(config, log):
    stage('Verify prepared host and checksum-pinned vendor installer', 5)
    if any((PREP / name).exists() for name in ('FAILED', 'GPU_FAILED')):
        raise InstallError('Host preparation failed; application installation was not started.')
    marker = 'GPU_READY' if config['edition'] == 'gpu' else 'READY'
    if not (PREP / marker).is_file():
        raise InstallError('Host preparation is not ready for the selected edition.')
    for path, expected in ((INSTALLER / ARCHIVE, ARCHIVE_SHA),
                           (INSTALLER / 'deploy-docker-compose.sh', SCRIPT_SHA)):
        if path.is_symlink() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise InstallError('The vendor installer differs from the reviewed 8.0.2 build0055 release.')
    account = pwd.getpwnam(config['operator'])
    if account.pw_uid == 0:
        raise InstallError('The vendor assistant must run as a non-root administrator.')
    run(['runuser', '-u', account.pw_name, '--', 'sudo', '-n', 'true'], log)
    intent = STATE / 'intent.json'
    if intent.exists():
        if intent.is_symlink() or json.loads(intent.read_text()) != config:
            raise InstallError('A different Terraform application configuration already owns this host.')
    else:
        if (DEPLOYMENT / '.env').exists() or DATA.is_symlink() or (DATA.exists() and any(DATA.iterdir())):
            raise InstallError('Existing assistant state is not owned by this Terraform installer; it was left unchanged.')
        if run(['docker', 'ps', '-aq'], log, capture=True).stdout.strip():
            raise InstallError('Existing containers were found before the first automatic installation; nothing was overwritten.')
        DATA.mkdir(mode=0o700, exist_ok=True)
        os.chown(DATA, account.pw_uid, account.pw_gid)
        os.chmod(DATA, 0o700)
        atomic_json(intent, config)
    if (DEPLOYMENT / '.env').exists():
        verify_definition(config)
    # A retry of an already successful deployment must not regenerate passwords,
    # reapply the vendor stack or interrupt completed WebUI/licensing settings.
    already_ready = (STATE / 'ready.json').is_file()
    if not already_ready:
        install_with_assistant(config, log)
    stage('Verify running application containers, database health and WebUI', 85)
    stable = 0
    for _ in range(180):
        stable = stable + 1 if application_ready(config['edition'], log) else 0
        if stable >= 3:
            break
        time.sleep(10)
    else:
        raise InstallError('Application containers, database health or WebUI did not become ready. Inspect the existing VM; no lab was recreated.')
    configure_api_alias(config['gateway_api_port'], log)
    atomic_json(STATE / 'ready.json', config)
    install_setup_timer(log)
    stage('FortiAIGate application deployed; complete WebUI setup and licensing', 100, 'ready')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', default=str(STATE / 'config.json'))
    parser.add_argument('--finish-setup', action='store_true')
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit('This Terraform installation worker must be started by the cloud management service as root.')
    os.umask(0o077)
    STATE.mkdir(mode=0o755, exist_ok=True)
    if STATE.is_symlink() or LOG.is_symlink():
        raise SystemExit('Refusing a symbolic link for installation state/log.')
    with (STATE / 'worker.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit('The existing Terraform installation worker is still running.')
        with LOG.open('ab', buffering=0) as log:
            os.chmod(LOG, 0o600)
            try:
                if args.finish_setup:
                    finish_setup(log)
                else:
                    install(validate_config(json.loads(Path(args.config).read_text())), log)
            except Exception as error:
                log.write(traceback.format_exc().encode())
                message = str(error) if isinstance(error, InstallError) else 'Installation worker failed; inspect the private VM log.'
                if args.finish_setup:
                    atomic_json(STATE / 'setup-status.json', {'status': 'pending', 'message': message}, 0o644)
                else:
                    stage(message, 0, 'failed')
                return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
