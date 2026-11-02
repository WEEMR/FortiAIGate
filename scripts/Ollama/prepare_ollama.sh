#!/usr/bin/env bash
# Ollama lab backend. Run on a separate Ubuntu host, never the FortiAIGate host.
# Official images/releases checked 2026-11-01; no floating image tags.
set -Eeuo pipefail
set +x
umask 077
VERSION=2026-11-01.2
OLLAMA_IMAGE=ollama/ollama:0.40.13
WEBUI_IMAGE=ghcr.io/open-webui/open-webui:v0.12.5
BASE_MODEL=llama3.2:1b
LAB_DIR=/opt/ollama-lab
STATE_DIR=/var/lib/ollama-lab
BIND_ADDRESS=127.0.0.1
BROWSER_URL=

usage() {
  cat <<'HELP'
Usage: sudo bash prepare_ollama.sh --install [--bind-address PRIVATE_IPV4] [--webui-url http://PUBLIC_IPV4:3000]
Installs a separate, CPU-powered Ollama backend and preloads llama-lab.
The model API defaults to loopback. A cloud launcher may bind a private IPv4
only when its firewall permits port 11434 solely from FortiAIGate.
Open WebUI also binds that private address on port 3000. Restrict browser
ingress to your public IPv4 /32 before using a non-loopback bind address.
After provisioning, run: sudo ollama-lab configure
HELP
}
[[ ${1:-} == --help ]] && { usage; exit 0; }
[[ ${1:-} == --install ]] || { usage >&2; exit 2; }
shift
while (($#)); do
  case "$1" in
    --bind-address) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; BIND_ADDRESS=$2; shift 2 ;;
    --webui-url) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; BROWSER_URL=$2; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo 'Run with sudo on the separate Ubuntu Ollama host.' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'Python 3 is required on the Ubuntu host.' >&2; exit 1; }
python3 - "$BIND_ADDRESS" "$BROWSER_URL" <<'PY'
import ipaddress, sys, urllib.parse
address = ipaddress.ip_address(sys.argv[1])
if address.version != 4 or not (address.is_private and not address.is_unspecified and not address.is_link_local):
    raise SystemExit('Bind address must be a private or loopback IPv4, never 0.0.0.0 or a public IP.')
if sys.argv[2]:
    url = sys.argv[2]
    parsed = urllib.parse.urlsplit(url)
    if (any(ord(c) < 33 for c in url) or parsed.scheme != 'http' or not parsed.hostname
            or parsed.port != 3000 or parsed.username or parsed.password
            or parsed.path not in ('', '/') or parsed.query or parsed.fragment or ';' in url):
        raise SystemExit('Use a browser URL such as http://SERVER_PUBLIC_IPV4:3000.')
    browser_address = ipaddress.ip_address(parsed.hostname)
    if browser_address.version != 4 or browser_address.is_unspecified or browser_address.is_multicast or browser_address.is_link_local:
        raise SystemExit('The browser URL must use a reachable IPv4 address.')
PY
# shellcheck disable=SC1091
source /etc/os-release
[[ $ID == ubuntu && ($VERSION_ID == 22.04 || $VERSION_ID == 24.04) ]] || { echo 'Use Ubuntu 22.04 or 24.04 LTS.' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo 'This lab installer requires an amd64 host.' >&2; exit 1; }
install -d -m 700 "$LAB_DIR" "$STATE_DIR"
exec 9>"$STATE_DIR/install.lock"
flock -n 9 || { echo 'Another Ollama installation is in progress.' >&2; exit 1; }
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
stage() {
  python3 - "$STATE_DIR/status.json" "$1" "$2" "$3" "${4:-running}" "$STARTED_AT" <<'PY'
import datetime, json, os, sys
path, stage, percent, message, state, started = sys.argv[1:]
data = dict(stage=stage, percent=int(percent), message=message, state=state,
            started_at=started, updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
            gateway_pending=state != 'configured')
tmp = path + '.tmp'
with open(tmp, 'w') as f: json.dump(data, f)
os.replace(tmp, path)
PY
  printf '[%3s%%] %s\n' "$2" "$3"
}
trap 'result=$?; if ((result != 0)); then set +e; stage failed 0 "Installation failed. Review cloud-init logs; rerun the installer to resume." failed; fi' EXIT
stage preflight 3 'Checking the separate Ubuntu host'
[[ ! -d /opt/fortiaigate/Installer ]] || { echo 'Use a separate host; FortiAIGate was detected here.' >&2; exit 1; }
python3 - <<'PY'
import shutil
from pathlib import Path
memory_kib = int(next(line.split()[1] for line in Path('/proc/meminfo').read_text().splitlines() if line.startswith('MemTotal:')))
if memory_kib < 3500000: raise SystemExit('At least 4 GiB RAM is needed; 8 GiB is recommended.')
if shutil.disk_usage('/opt').free < 16 * 1024**3: raise SystemExit('At least 16 GiB free disk space is needed.')
PY
export DEBIAN_FRONTEND=noninteractive
stage docker 10 'Preparing Docker Engine from the official signed repository'
if ! command -v docker >/dev/null; then
  timeout 300 apt-get -o DPkg::Lock::Timeout=120 update
  timeout 300 apt-get -o DPkg::Lock::Timeout=120 install -y ca-certificates curl
  install -d -m 755 /etc/apt/keyrings
  curl --fail --silent --show-error --location --retry 3 --max-time 60 \
    https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/ollama-lab-docker.asc
  chmod a+r /etc/apt/keyrings/ollama-lab-docker.asc
  # Avoid introducing a duplicate source on a partially prepared Docker host.
  if ! python3 - <<'PY'
from pathlib import Path
paths = [Path('/etc/apt/sources.list'), *Path('/etc/apt/sources.list.d').glob('*.list'), *Path('/etc/apt/sources.list.d').glob('*.sources')]
raise SystemExit(0 if any(p.is_file() and 'download.docker.com/linux/ubuntu' in p.read_text() for p in paths) else 1)
PY
  then
    printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/ollama-lab-docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' "$VERSION_CODENAME" > /etc/apt/sources.list.d/ollama-lab-docker.list
  fi
  timeout 300 apt-get -o DPkg::Lock::Timeout=120 update
  timeout 600 apt-get -o DPkg::Lock::Timeout=120 install -y docker-ce docker-ce-cli containerd.io
fi
systemctl enable --now docker
timeout 30 docker info >/dev/null
stage runtime 18 'Writing the Ollama lab runtime and status commands'
cat > "$LAB_DIR/runtime.py" <<'OLLAMA_RUNTIME'
#!/usr/bin/env python3
"""Small, dependency-free control plane; never prints credentials."""
import datetime
import fcntl
import getpass
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path('/opt/ollama-lab')
STATE = Path('/var/lib/ollama-lab')
MODEL = 'llama-lab'
MODEL_CONTAINER = 'ollama-lab-model'
WEBUI_CONTAINER = 'ollama-lab-webui'
LABEL = 'com.fortinetpslab.ollama-lab'
WEBUI_IMAGE = 'ghcr.io/open-webui/open-webui:v0.12.5'


def save_private(path, content):
    path = Path(path)
    tmp = path.with_name(path.name + '.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as stream:
        stream.write(content)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def update_state(stage, percent, message, state):
    path = STATE / 'status.json'
    data = json.loads(path.read_text()) if path.exists() else {}
    data.update(stage=stage, percent=percent, message=message, state=state,
                updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                gateway_pending=state != 'configured')
    save_private(path, json.dumps(data))


def run(args, timeout=120, capture=True):
    result = subprocess.run(args, check=False, text=True, capture_output=capture, timeout=timeout)
    if result.returncode:
        raise RuntimeError('Docker operation failed. Run sudo ollama-lab logs for diagnostics.')
    return result.stdout or ''


def validate_gateway(value):
    value = value.strip().rstrip('/')
    if any(ord(c) < 33 for c in value) or len(value) > 2048:
        raise ValueError('Use a gateway URL without whitespace or control characters.')
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in ('http', 'https') or not parsed.hostname:
        raise ValueError('Use the FortiAIGate OpenAI-compatible base URL, including http:// or https://.')
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError('The gateway URL must not contain credentials, query parameters or fragments.')
    if parsed.port == 11434:
        raise ValueError('Port 11434 is the Ollama backend. Enter the FortiAIGate gateway URL instead.')
    if not parsed.path:
        value += '/v1'
    if ';' in value:
        raise ValueError('Use a single gateway URL.')
    return value


def validate_secret(value):
    if not value or len(value) > 4096 or any(ord(c) < 33 or ord(c) > 126 for c in value):
        raise ValueError('The virtual key must contain printable characters without whitespace.')
    if ';' in value:
        raise ValueError('Enter one virtual key.')
    return value


def validate_browser_url(value):
    value = value.strip().rstrip('/')
    parsed = urllib.parse.urlsplit(value)
    if (any(ord(c) < 33 for c in value) or parsed.scheme != 'http' or not parsed.hostname
            or parsed.port != 3000 or parsed.username or parsed.password or parsed.path
            or parsed.query or parsed.fragment or ';' in value):
        raise ValueError('Use a browser URL such as http://SERVER_PUBLIC_IPV4:3000.')
    if parsed.hostname != 'localhost':
        address = ipaddress.ip_address(parsed.hostname)
        if address.version != 4 or address.is_unspecified or address.is_multicast or address.is_link_local:
            raise ValueError('The browser URL must use a reachable IPv4 address.')
    return 'http://' + parsed.hostname + ':3000'


def request_json(url, payload=None, key=None, ca=None, timeout=180):
    headers = {'Accept': 'application/json'}
    if key:
        headers['Authorization'] = 'Bearer ' + key
    encoded = None
    if payload is not None:
        headers['Content-Type'] = 'application/json'
        encoded = json.dumps(payload).encode()
    request = urllib.request.Request(url, data=encoded, headers=headers)
    context = ssl.create_default_context(cafile=str(ca) if ca else None)
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f'Gateway returned HTTP {error.code}; check the provider, model alias and virtual-key permissions.') from None
    except (urllib.error.URLError, TimeoutError, ssl.SSLError):
        raise RuntimeError('Connection failed; check routes, gateway URL, TLS certificate trust and security groups.') from None


def gateway_test(url, key, ca=None):
    response = request_json(url.rstrip('/') + '/chat/completions', {
        'model': MODEL, 'messages': [{'role': 'user', 'content': 'Reply with one short greeting.'}],
        'max_tokens': 32, 'temperature': 0, 'stream': False,
    }, key=key, ca=ca)
    choices = response.get('choices') if isinstance(response, dict) else None
    if not isinstance(choices, list) or not choices or not isinstance(choices[0].get('message'), dict):
        raise RuntimeError('Gateway did not return an OpenAI-compatible chat completion for llama-lab.')


def verify_administrator(email, password):
    try:
        account = request_json('http://127.0.0.1:3000/api/v1/auths/signin',
                               {'email': email, 'password': password}, timeout=30)
    except RuntimeError:
        raise RuntimeError('Open WebUI started but administrator login failed; rerun Configure with the correct account credentials.') from None
    if not isinstance(account, dict) or account.get('role') != 'admin' or not account.get('token'):
        raise RuntimeError('Open WebUI administrator creation could not be verified; bootstrap credentials were retained for retry.')


def env_text(values):
    for key, value in values.items():
        if not re.fullmatch(r'[A-Z][A-Z0-9_]*', key) or '\n' in value or '\r' in value or '\x00' in value:
            raise ValueError('Invalid environment setting.')
    # Docker --env-file treats values literally: no shell expansion or sourcing.
    return ''.join(key + '=' + value + '\n' for key, value in values.items())


def read_env():
    path = ROOT / 'gateway.env'
    if not path.exists():
        raise RuntimeError('Gateway configuration is pending. Run sudo ollama-lab configure.')
    return dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)


def managed_container(name):
    result = subprocess.run(['docker', 'inspect', '--format', '{{json .Config.Labels}}', name],
                            text=True, capture_output=True, timeout=30)
    if result.returncode:
        return False
    labels = json.loads(result.stdout) or {}
    if labels.get(LABEL) != 'true':
        raise RuntimeError('A container with this name is not managed by Ollama lab; it was preserved.')
    return True


def start_webui():
    env = read_env()
    if env.get('ENABLE_OLLAMA_API') != 'false' or env.get('ENABLE_DIRECT_CONNECTIONS') != 'false':
        raise RuntimeError('Gateway-only configuration is required. Run sudo ollama-lab configure again.')
    bind_file = ROOT / 'bind-address'
    bind = ipaddress.ip_address(bind_file.read_text().strip() if bind_file.exists() else '127.0.0.1')
    if bind.version != 4 or not bind.is_private or bind.is_unspecified or bind.is_link_local or bind.is_multicast:
        raise ValueError('Open WebUI must bind a private or loopback IPv4 address.')
    if managed_container(WEBUI_CONTAINER):
        run(['docker', 'rm', '-f', WEBUI_CONTAINER])
    args = ['docker', 'run', '-d', '--name', WEBUI_CONTAINER, '--label', LABEL + '=true',
            '--restart', 'unless-stopped', '--publish', '127.0.0.1:3000:8080',
            '--env-file', str(ROOT / 'gateway.env'), '--volume', 'ollama-lab-webui:/app/backend/data',
            '--log-opt', 'max-size=10m', '--log-opt', 'max-file=3',
            '--health-cmd', "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/ready', timeout=5)\"",
            '--health-interval', '20s', '--health-start-period', '120s', '--health-timeout', '10s', '--health-retries', '6']
    if not bind.is_loopback:
        args += ['--publish', str(bind) + ':3000:8080']
    if (ROOT / 'gateway-ca-bundle.crt').exists():
        args += ['--volume', str(ROOT / 'gateway-ca-bundle.crt') + ':/etc/ollama-lab/gateway-ca-bundle.crt:ro']
    args += [WEBUI_IMAGE]
    run(args)
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen('http://127.0.0.1:3000/ready', timeout=5) as response:
                if response.status == 200:
                    return
        except (urllib.error.URLError, TimeoutError):
            pass
        time.sleep(5)
    raise RuntimeError('Open WebUI did not become healthy within 10 minutes. Run sudo ollama-lab logs.')


def configure():
    if not sys.stdin.isatty():
        raise RuntimeError('Configure needs an interactive SSH terminal; keys are entered hidden and never supplied in user-data.')
    print('Configure Open WebUI → FortiAIGate → Ollama (llama-lab).')
    print('First configure the FortiAIGate provider/model and virtual key using the website steps.')
    url = validate_gateway(input('FortiAIGate OpenAI-compatible base URL: '))
    key = validate_secret(getpass.getpass('FortiAIGate virtual key (hidden): '))
    cert_path = input('Gateway CA certificate PEM path (Enter for system trust): ').strip()
    ca_path = None
    ca_text = None
    if cert_path:
        source = Path(cert_path).expanduser()
        if not source.is_file() or source.stat().st_size > 1024 * 1024:
            raise ValueError('Choose a readable PEM CA certificate smaller than 1 MiB.')
        ca_text = source.read_text()
        if '-----BEGIN CERTIFICATE-----' not in ca_text or 'PRIVATE KEY' in ca_text:
            raise ValueError('Supply only a CA certificate PEM, never a private key.')
        context = ssl.create_default_context()
        context.load_verify_locations(cadata=ca_text)
        ca_path = ROOT / 'gateway-ca-bundle.crt'
        system_ca = Path(ssl.get_default_verify_paths().cafile or '/etc/ssl/certs/ca-certificates.crt')
        save_private(ca_path, system_ca.read_text() + '\n' + ca_text)
    previous = read_env() if (ROOT / 'gateway.env').exists() else {}
    browser_file = ROOT / 'browser-url'
    default_browser = browser_file.read_text().strip() if browser_file.exists() else previous.get('WEBUI_URL', 'http://localhost:3000')
    browser_url = validate_browser_url(input('Open WebUI browser URL [' + default_browser + ']: ') or default_browser)
    print('Testing a chat completion through FortiAIGate; this may take a few minutes on first use...')
    gateway_test(url, key, ca=ca_path)
    values = {
        'OPENAI_API_BASE_URL': url, 'OPENAI_API_BASE_URLS': url,
        'OPENAI_API_KEY': key, 'OPENAI_API_KEYS': key,
        'ENABLE_OPENAI_API': 'true', 'ENABLE_OLLAMA_API': 'false',
        'ENABLE_DIRECT_CONNECTIONS': 'false', 'ENABLE_PERSISTENT_CONFIG': 'false',
        'ENABLE_OAUTH_PERSISTENT_CONFIG': 'false', 'ENABLE_SIGNUP': 'false',
        'WEBUI_AUTH': 'true', 'DEFAULT_MODELS': MODEL, 'WEBUI_URL': browser_url,
        'CORS_ALLOW_ORIGIN': browser_url,
        'WEBUI_SESSION_COOKIE_SECURE': 'false', 'WEBUI_AUTH_COOKIE_SECURE': 'false',
        'ENABLE_VERSION_UPDATE_CHECK': 'false', 'HF_HUB_OFFLINE': '1',
        'RAG_EMBEDDING_MODEL_AUTO_UPDATE': 'false', 'WHISPER_MODEL_AUTO_UPDATE': 'false',
        'SCARF_NO_ANALYTICS': 'true', 'DO_NOT_TRACK': 'true', 'ANONYMIZED_TELEMETRY': 'false',
        'WEBUI_SECRET_KEY': previous.get('WEBUI_SECRET_KEY', secrets.token_urlsafe(48)),
    }
    if ca_path:
        values['SSL_CERT_FILE'] = '/etc/ollama-lab/gateway-ca-bundle.crt'
        values['REQUESTS_CA_BUNDLE'] = values['SSL_CERT_FILE']
    else:
        (ROOT / 'gateway-ca-bundle.crt').unlink(missing_ok=True)
    first_setup = not (ROOT / 'administrator-created').exists()
    if first_setup:
        email = input('Email for your first Open WebUI administrator: ').strip()
        if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', email):
            raise ValueError('Enter a valid administrator email address.')
        password = getpass.getpass('New Open WebUI administrator password (12+ characters, hidden): ')
        if len(password) < 12 or len(password.encode()) > 72 or any(c in password for c in '\r\n\x00'):
            raise ValueError('Use a 12+ character password, at most 72 UTF-8 bytes, without control characters.')
        if password != getpass.getpass('Confirm administrator password (hidden): '):
            raise ValueError('The passwords did not match.')
        values.update(WEBUI_ADMIN_EMAIL=email, WEBUI_ADMIN_PASSWORD=password, WEBUI_ADMIN_NAME='Llama Lab Admin')
    save_private(ROOT / 'gateway.env', env_text(values))
    save_private(browser_file, browser_url + '\n')
    update_state('webui', 95, 'Starting Open WebUI with gateway-only routing', 'configuring')
    start_webui()
    # The account is now in the persistent DB; remove the bootstrap password from
    # the environment file and recreate the container so it is no longer in Docker metadata.
    if 'WEBUI_ADMIN_PASSWORD' in values:
        verify_administrator(values['WEBUI_ADMIN_EMAIL'], values['WEBUI_ADMIN_PASSWORD'])
        save_private(ROOT / 'administrator-created', 'Administrator initialized in the persistent Open WebUI database.\n')
        for name in ('WEBUI_ADMIN_EMAIL', 'WEBUI_ADMIN_PASSWORD', 'WEBUI_ADMIN_NAME'):
            values.pop(name, None)
        save_private(ROOT / 'gateway.env', env_text(values))
        start_webui()
    update_state('configured', 100, 'Ollama and Open WebUI ready; chat routes through FortiAIGate', 'configured')
    print('PASS: gateway chat completion and Open WebUI health checks succeeded.')
    print('Browser: ' + browser_url + ' | Sign in with your administrator email; select llama-lab.')
    print('For remote access, allow TCP 3000 only from your public IPv4 /32. No SSH tunnel is required.')
    print('Check FortiAIGate traffic logs to verify this request; verify scanning and a blocking policy separately.')


def status():
    path = STATE / 'status.json'
    if path.exists():
        data = json.loads(path.read_text())
        print(f"[{data['percent']}%] {data['state']}: {data['message']}")
    for name in (MODEL_CONTAINER, WEBUI_CONTAINER):
        result = subprocess.run(['docker', 'inspect', '--format', '{{.State.Status}}', name],
                                capture_output=True, text=True, timeout=30)
        print(name + ': ' + (result.stdout.strip() if result.returncode == 0 else 'not started'))
    print('Gateway configuration: ' + ('saved (key hidden)' if (ROOT / 'gateway.env').exists() else 'pending: sudo ollama-lab configure'))
    if (ROOT / 'gateway.env').exists():
        print('Open WebUI browser URL: ' + read_env().get('WEBUI_URL', 'not configured'))


def verify():
    # Model listing through the container avoids host bind-address assumptions.
    listing = run(['docker', 'exec', MODEL_CONTAINER, 'ollama', 'list'])
    if not any(line.split()[0] in ('llama-lab', 'llama-lab:latest') for line in listing.splitlines()[1:] if line.split()):
        raise RuntimeError('The llama-lab model alias is missing.')
    print('PASS: llama-lab is installed in Ollama.')
    env = read_env()
    ca = ROOT / 'gateway-ca-bundle.crt'
    gateway_test(env['OPENAI_API_BASE_URL'], env['OPENAI_API_KEY'], ca=ca if ca.exists() else None)
    print('PASS: chat completion travelled through the configured FortiAIGate gateway.')
    print('Verify the request in FortiAIGate traffic logs; a successful reply does not prove guardrail enforcement.')


def logs():
    # Docker logs only, never inspect/config/environment output; redact configured
    # key if an upstream error happened to echo it. Keep diagnostics bounded.
    key = read_env().get('OPENAI_API_KEY', '') if (ROOT / 'gateway.env').exists() else ''
    for name in (MODEL_CONTAINER, WEBUI_CONTAINER):
        result = subprocess.run(['docker', 'logs', '--tail', '100', name], capture_output=True, text=True, timeout=30)
        output = result.stdout + result.stderr
        if key:
            output = output.replace(key, '[virtual key hidden]')
        print('--- ' + name + ' ---')
        print(output)


def main():
    if os.geteuid() != 0:
        raise SystemExit('Run sudo ollama-lab ' + (sys.argv[1] if len(sys.argv) > 1 else 'status'))
    command = sys.argv[1] if len(sys.argv) == 2 else 'help'
    if command not in {'status', 'configure', 'verify', 'logs'}:
        print('Usage: sudo ollama-lab {status|configure|verify|logs}')
        return 2
    os.umask(0o077)
    lock_acquired = False
    try:
        lock = None
        if command == 'configure':
            lock = open(STATE / 'install.lock', 'a')
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                lock_acquired = True
            except BlockingIOError:
                raise RuntimeError('Another installation or configuration is running; wait for it to finish.') from None
        globals()[command]()
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        if command == 'configure' and lock_acquired:
            update_state('configure', 100, 'Gateway configuration needs attention; rerun sudo ollama-lab configure', 'ready')
        print('ERROR: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
OLLAMA_RUNTIME
chmod 700 "$LAB_DIR/runtime.py"
cat > /usr/local/bin/ollama-lab <<'RUNTIME_ENTRY'
#!/usr/bin/env bash
set -euo pipefail
set +x
[[ $EUID -eq 0 ]] || { echo "Run sudo ollama-lab ${1:-status}" >&2; exit 1; }
exec python3 /opt/ollama-lab/runtime.py "$@"
RUNTIME_ENTRY
chmod 755 /usr/local/bin/ollama-lab
printf '%s\n' "$VERSION" > "$LAB_DIR/version"
stage images 25 'Downloading pinned Ollama and Open WebUI container images'
timeout 1800 docker pull "$OLLAMA_IMAGE"
stage images 40 'Ollama image ready; downloading Open WebUI'
timeout 1800 docker pull "$WEBUI_IMAGE"
for volume in ollama-lab-models ollama-lab-webui; do
  if docker volume inspect "$volume" >/dev/null 2>&1; then
    [[ $(docker volume inspect --format '{{ index .Labels "com.fortinetpslab.ollama-lab" }}' "$volume") == true ]] || { echo "Volume $volume is unmanaged; it was preserved." >&2; exit 1; }
  else
    docker volume create --label com.fortinetpslab.ollama-lab=true "$volume" >/dev/null
  fi
done
stage model_server 55 'Starting the private Ollama model API'
if docker container inspect ollama-lab-model >/dev/null 2>&1; then
  [[ $(docker inspect --format '{{ index .Config.Labels "com.fortinetpslab.ollama-lab" }}' ollama-lab-model) == true ]] || { echo 'An unmanaged Ollama container was preserved.' >&2; exit 1; }
  docker rm -f ollama-lab-model >/dev/null
fi
ports=(--publish 127.0.0.1:11434:11434)
[[ $BIND_ADDRESS == 127.0.0.1 ]] || ports+=(--publish "$BIND_ADDRESS:11434:11434")
docker run -d --name ollama-lab-model --label com.fortinetpslab.ollama-lab=true \
  --restart unless-stopped "${ports[@]}" --volume ollama-lab-models:/root/.ollama \
  --env OLLAMA_HOST=0.0.0.0:11434 --env OLLAMA_NUM_PARALLEL=1 --env OLLAMA_MAX_LOADED_MODELS=1 --env OLLAMA_CONTEXT_LENGTH=2048 \
  --log-opt max-size=10m --log-opt max-file=3 \
  --health-cmd 'ollama list >/dev/null' --health-interval 20s --health-timeout 10s --health-retries 6 \
  "$OLLAMA_IMAGE" >/dev/null
ready=false
for attempt in {1..60}; do
  if timeout 10 docker exec ollama-lab-model ollama list >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
[[ $ready == true ]] || { echo 'Ollama did not start within 2 minutes.' >&2; false; }
stage model_download 65 'Downloading Llama 3.2 1B (about 1.3 GB); Docker shows transfer progress below'
timeout 1800 docker exec ollama-lab-model ollama pull "$BASE_MODEL"
stage model_alias 85 'Creating the llama-lab test model alias'
timeout 30 docker exec ollama-lab-model ollama cp "$BASE_MODEL" llama-lab
stage model_test 90 'Checking a real model response; first CPU inference may take a few minutes'
python3 - <<'PY'
import json, urllib.request
body = json.dumps(dict(model='llama-lab', messages=[dict(role='user', content='Say hello in three words.')], stream=False, options=dict(num_predict=16, num_ctx=2048))).encode()
request = urllib.request.Request('http://127.0.0.1:11434/api/chat', body, {'Content-Type':'application/json'})
with urllib.request.urlopen(request, timeout=300) as response:
    result = json.load(response)
if not isinstance(result.get('message'), dict) or not result['message'].get('content'):
    raise SystemExit('Ollama did not return a model response.')
PY
printf '%s\n' "$BIND_ADDRESS" > "$LAB_DIR/bind-address"
if [[ -n $BROWSER_URL ]]; then
  printf '%s\n' "$BROWSER_URL" > "$LAB_DIR/browser-url"
fi
stage ready 100 'llama-lab is ready. Configure FortiAIGate, then run sudo ollama-lab configure.' ready
trap - EXIT
printf '\nModel API: http://%s:11434/v1\nModel name: llama-lab\n' "$BIND_ADDRESS"
printf 'Next, from an interactive SSH terminal on this host: sudo ollama-lab configure\n'
printf 'Status: sudo ollama-lab status\nDiagnostics: sudo ollama-lab logs\n'
