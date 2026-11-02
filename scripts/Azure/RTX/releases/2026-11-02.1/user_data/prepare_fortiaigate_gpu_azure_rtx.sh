#!/usr/bin/env bash
# Azure RTX PRO 6000 48 GB MIG preview preparation only; run the interactive wizard afterward.
# Version 2026-10-31.1. A boot timer resumes after one compute driver reboot.
set -Eeuo pipefail
umask 077
VERSION=2026-11-02.1
CONFIG=${1:-/etc/fortiaigate-prep.json}
STATE=/var/lib/fortiaigate-prep
ROOT=/opt/fortiaigate
LOG=/var/log/fortiaigate-gpu-prep.log
SELF=/usr/local/sbin/prepare_fortiaigate_gpu_azure_rtx.sh
CPU_PREP_URL=https://raw.githubusercontent.com/WEEMR/FortiAIGate/shared-2026-11-02.1/scripts/Home/releases/2026-11-02.1/prepare_fortiaigate_cpu.sh
CPU_PREP_SHA256=db1cf5ca6d2a0519a2b633e6c3fd9991325d288bd064367891506d64c843ffb6
STAGE=starting
WORK=
(( EUID == 0 )) || { printf 'Run Azure GPU preparation as root through cloud-init or sudo.\n' >&2; exit 1; }
[[ $# -le 1 ]] || { printf 'Usage: prepare_fortiaigate_gpu_azure_rtx.sh [CONFIG_JSON]\n' >&2; exit 1; }
command -v python3 >/dev/null
command -v flock >/dev/null
install -d -m 0755 "$STATE"
exec 8>"$STATE/gpu.lock"
flock -n 8 || { printf 'GPU preparation is already running.\n' >&2; exit 75; }
touch "$LOG"
chmod 0640 "$LOG"
exec > >(tee -a "$LOG") 2>&1
failure() {
  local rc=$1 line=${2:-unknown}
  trap - ERR
  printf 'GPU FAILED: stage=%s line=%s exit=%s. See %s\n' "$STAGE" "$line" "$rc" "$LOG" >&2
  printf 'GPU_FAILED stage=%s line=%s exit=%s\n' "$STAGE" "$line" "$rc" >"$STATE/GPU_FAILED"
  chmod 0644 "$STATE/GPU_FAILED"
  rm -f "$STATE/GPU_READY" "$STATE/GPU_RUNNING"
  exit "$rc"
}
cleanup() { if [[ -n "$WORK" && -d "$WORK" ]]; then rm -rf -- "$WORK"; fi; }
trap 'failure "$?" "$LINENO"' ERR
trap cleanup EXIT
trap 'failure 130 "$LINENO"' INT
trap 'failure 143 "$LINENO"' TERM
stage() {
  STAGE=$1
  printf '\n[%s] Azure GPU: %s\n' "$(date -u +%FT%TZ)" "$STAGE"
  printf '%s\n' "$STAGE" >"$STATE/GPU_RUNNING"
  chmod 0644 "$STATE/GPU_RUNNING"
}
retry() {
  local attempt rc
  for attempt in 1 2 3; do
    if "$@"; then return 0; else rc=$?; fi
    (( attempt < 3 )) || return "$rc"
    sleep "$(( attempt * 10 ))"
  done
}
WORK=$(mktemp -d /var/tmp/fortiaigate-azure-gpu-prep.XXXXXXXX)
# IMDS tokens stay in this Python process's memory, never shell arguments,
# config, files, stdout, or tracebacks. Redirects and metadata proxies are off.
cat >"$WORK/azure_support.py" <<'AZURE_SUPPORT'
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request

BUILD = 'V8.0.2-build0055-FORTINET'
COMPONENTS = ('api', 'webui', 'llm-gateway', 'logd', 'license_manager',
              'guardrail', 'guardrail-scanner', 'custom-triton', 'faig-models', 'vllm-server')
INSTALLER = 'FAIG_deploy-docker-compose-cli-' + BUILD + '.tar.gz'
INSTALLER_SHA256 = '100abb31106b848959ec9331e727174aba6b52b42bc26b2af5757dfd339970b7'
IMDS = 'http://169.254.169.254/metadata/'


class PreparationError(Exception):
    pass


def validate_config(config):
    required = {'cloud', 'edition', 'storage_account', 'container', 'release_prefix', 'identity_client_id'}
    if not isinstance(config, dict) or set(config) != required:
        raise PreparationError('Use only the six documented Azure managed-identity configuration fields.')
    if config['cloud'] != 'azure' or config['edition'] != 'gpu':
        raise PreparationError('This preparation requires cloud=azure and edition=gpu.')
    account, container, prefix, identity = (config[k] for k in
        ('storage_account', 'container', 'release_prefix', 'identity_client_id'))
    if not isinstance(account, str) or not re.fullmatch(r'[a-z0-9]{3,24}', account):
        raise PreparationError('Invalid Azure Storage account name.')
    if not isinstance(container, str) or not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{1,61})[a-z0-9]', container) or '--' in container:
        raise PreparationError('Invalid private Blob container name.')
    if not isinstance(prefix, str) or len(prefix) > 512 or not re.fullmatch(r'[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*', prefix) or any(part in ('.', '..') for part in prefix.split('/')):
        raise PreparationError('Invalid release prefix; use safe slash-separated folder names without trailing slash.')
    if not isinstance(identity, str) or not re.fullmatch(r'[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}', identity):
        raise PreparationError('identity_client_id must be the dedicated user-assigned identity client UUID.')
    return 'https://' + account + '.blob.core.windows.net/' + container + '/' + prefix


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        raise PreparationError('Redirected metadata or Blob requests are not permitted.')


class BlobClient:
    def __init__(self, config, opener=None, clock=time.time, sleep=time.sleep, monotonic=time.monotonic):
        self.config = config
        self.base = validate_config(config)
        self.opener = opener or urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        self.clock, self.sleep, self.monotonic = clock, sleep, monotonic
        self.token_value, self.token_expiry = None, 0

    def metadata_json(self, suffix, identity=False):
        url = IMDS + suffix
        for attempt in range(12):
            request = urllib.request.Request(url, headers={'Metadata': 'true'})
            try:
                with self.opener.open(request, timeout=15) as response:
                    data = response.read(65537)
                if len(data) > 65536:
                    raise PreparationError('Oversized Azure metadata response.')
                return json.loads(data)
            except urllib.error.HTTPError as error:
                if error.code not in (400, 404, 410, 429, 500, 502, 503, 504) or attempt == 11:
                    raise PreparationError('Azure metadata request failed (HTTP ' + str(error.code) + ').') from None
            except (OSError, ValueError):
                if attempt == 11:
                    raise PreparationError('Azure metadata could not be read.') from None
            self.sleep(min(5 * (attempt + 1), 30))
        raise PreparationError('Azure metadata is unavailable.')

    def token(self):
        if self.token_value and self.token_expiry > self.clock() + 120:
            return self.token_value
        query = urllib.parse.urlencode({'api-version': '2018-02-01',
            'resource': 'https://storage.azure.com/', 'client_id': self.config['identity_client_id']})
        data = self.metadata_json('identity/oauth2/token?' + query, identity=True)
        token = data.get('access_token') if isinstance(data, dict) else None
        if not isinstance(token, str) or not token or len(token) > 32768 or any(ord(ch) < 33 for ch in token):
            raise PreparationError('Azure managed identity returned an invalid storage token.')
        try:
            expiry = int(data['expires_on'])
        except (ValueError, TypeError, KeyError):
            raise PreparationError('Azure managed identity returned an invalid token expiry.') from None
        if expiry <= self.clock() + 120:
            raise PreparationError('Azure managed identity returned an expired storage token.')
        self.token_value, self.token_expiry = token, expiry
        return token

    def verify_vm_size(self):
        data = self.metadata_json('instance/compute?api-version=2021-02-01&format=json')
        if not isinstance(data, dict) or str(data.get('vmSize', '')).lower() != 'standard_nc72lds_xl_rtxpro6000bse_v6':
            raise PreparationError('This lab requires Standard_NC72lds_xl_RTXPRO6000BSE_v6 with a 48 GB allocation.')

    def request(self, relative, method='GET', etag=None):
        if not re.fullmatch(r'(?:Images|Installer)/[A-Za-z0-9_.-]+', relative):
            raise PreparationError('Invalid release object path.')
        url = self.base + '/' + urllib.parse.quote(relative, safe='/')
        # A newly created container-scoped RBAC assignment can take ten minutes
        # to reach the data plane. Permit fifteen minutes, refreshing only the
        # in-memory token on 401/403; other transient errors keep their own cap.
        deadline, transient_attempts = self.monotonic() + 900, 0
        while True:
            remaining = deadline - self.monotonic()
            if remaining <= 0:
                raise PreparationError('Private Blob access did not become available within fifteen minutes.')
            token = self.token()
            remaining = deadline - self.monotonic()
            if remaining <= 0:
                raise PreparationError('Private Blob access did not become available within fifteen minutes.')
            headers = {'Authorization': 'Bearer ' + token, 'x-ms-version': '2023-11-03'}
            if etag:
                headers['If-Match'] = etag
            request = urllib.request.Request(url, headers=headers, method=method)
            try:
                return self.opener.open(request, timeout=min(120, remaining))
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    return None
                if error.code in (401, 403):
                    self.token_value = None
                    delay = 30
                else:
                    transient_attempts += 1
                    if error.code not in (408, 429, 500, 502, 503, 504) or transient_attempts >= 12:
                        raise PreparationError('Private Blob request failed (HTTP ' + str(error.code) + ').') from None
                    delay = min(5 * transient_attempts, 30)
            except OSError:
                transient_attempts += 1
                if transient_attempts >= 12:
                    raise PreparationError('Private Blob request failed after bounded retries.') from None
                delay = min(5 * transient_attempts, 30)
            remaining = deadline - self.monotonic()
            if remaining > 0:
                self.sleep(min(delay, remaining))

    def head(self, relative):
        response = self.request(relative, 'HEAD')
        if response is None:
            return None
        with response:
            try:
                size = int(response.headers['Content-Length'])
            except (ValueError, TypeError, KeyError):
                raise PreparationError('Blob response did not report a valid content length.') from None
            etag = response.headers.get('ETag')
        if size <= 0 or not etag:
            raise PreparationError('A required Blob object is empty or lacks an ETag.')
        return size, etag

    def download(self, relative, destination, expected):
        size, etag = expected
        for attempt in range(3):
            response = self.request(relative, etag=etag)
            if response is None:
                raise PreparationError('A required Blob object disappeared before download.')
            try:
                count, deadline = 0, time.monotonic() + 3600
                with response, destination.open('wb') as target:
                    while True:
                        if time.monotonic() > deadline:
                            raise PreparationError('Private Blob download exceeded its one-hour limit.')
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        count += len(chunk)
                        if count > size:
                            raise PreparationError('Private Blob download exceeded its expected size.')
                        target.write(chunk)
                if count != size:
                    raise PreparationError('Private Blob download was incomplete.')
                return
            except OSError:
                destination.unlink(missing_ok=True)
                if attempt == 2:
                    raise PreparationError('Private Blob streaming failed after bounded retries.') from None
                self.sleep(10 * (attempt + 1))


def archive_valid(path):
    if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
        return False
    try:
        with tarfile.open(path, 'r:*') as archive:
            count = 0
            for member in archive:
                count += 1
                if count > 100000 or not member.name:
                    return False
            return count > 0
    except (OSError, tarfile.TarError, EOFError):
        return False


def stage_release(config, root, work, client=None):
    client = client or BlobClient(config)
    client.verify_vm_size()
    objects = []
    # Check all eleven source objects before starting any large downloads.
    for component in COMPONENTS:
        stem = 'FAIG_' + component + '-' + BUILD + '.tar'
        candidates = [(name, client.head('Images/' + name)) for name in (stem, stem + '.gz')]
        present = [(name, info) for name, info in candidates if info is not None]
        if len(present) != 1:
            raise PreparationError('Provide exactly one nonempty TAR variant for image ' + component + '.')
        name, info = present[0]
        objects.append(('Images/' + name, info))
    installer = client.head('Installer/' + INSTALLER)
    if installer is None:
        raise PreparationError('The matching build0055 installer archive is missing.')
    objects.append(('Installer/' + INSTALLER, installer))
    for relative, expected in objects:
        destination = root / relative
        directory = destination.parent
        if root.is_symlink() or directory.is_symlink() or destination.is_symlink():
            raise PreparationError('Refusing a symbolic-link release directory or file.')
        directory.mkdir(parents=True, exist_ok=True)
        if relative.startswith('Images/'):
            alternate = destination.with_name(destination.name[:-3] if destination.name.endswith('.gz') else destination.name + '.gz')
            if alternate.exists() or alternate.is_symlink():
                raise PreparationError('Remove the extra local TAR variant before retrying.')
        valid = destination.exists() and destination.stat().st_size == expected[0] and archive_valid(destination)
        if relative.startswith('Installer/'):
            valid = valid and hashlib.sha256(destination.read_bytes()).hexdigest() == INSTALLER_SHA256
        if not valid:
            temporary = work / 'release.part'
            client.download(relative, temporary, expected)
            if not archive_valid(temporary):
                raise PreparationError('A downloaded release file is not a valid TAR archive.')
            if relative.startswith('Installer/') and hashlib.sha256(temporary.read_bytes()).hexdigest() != INSTALLER_SHA256:
                raise PreparationError('The FortiAIGate installer SHA-256 did not match the pinned release.')
            os.chmod(temporary, 0o644)
            os.replace(temporary, destination)
        print('Checked private Azure release archive: ' + destination.name, flush=True)


def write_core_config(config, destination):
    core = {'cloud': 'azure', 'edition': 'gpu', 'release_https_base': validate_config(config)}
    if destination.is_symlink():
        raise PreparationError('Refusing a symbolic-link common preparation configuration.')
    if destination.exists():
        if json.loads(destination.read_text()) != core:
            raise PreparationError('An existing common preparation configuration differs; review before resuming.')
    else:
        with destination.open('x') as target:
            json.dump(core, target, sort_keys=True)
        os.chmod(destination, 0o600)


def main():
    action = sys.argv[1]
    raw = Path(sys.argv[2]).read_bytes()
    config = json.loads(raw)
    validate_config(config)
    if action == 'validate':
        print(hashlib.sha256(raw).hexdigest())
    elif action == 'stage':
        stage_release(config, Path(sys.argv[3]), Path(sys.argv[4]))
    elif action == 'core-config':
        write_core_config(config, Path(sys.argv[3]))
    else:
        raise PreparationError('Unknown Azure preparation action.')


if __name__ == '__main__':
    try:
        main()
    except PreparationError as error:
        print('STOP: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
    except Exception as error:
        # Do not print raw HTTP/IMDS exceptions or response bodies containing tokens.
        print('STOP: Azure preparation failed (' + type(error).__name__ + ').', file=sys.stderr)
        raise SystemExit(1)
AZURE_SUPPORT

install -d -m 0755 /usr/local/libexec
cat >/usr/local/libexec/fortiaigate-azure-rtx.py <<'RTX_MIG_ADAPTER'
#!/usr/bin/env python3
"""Preview adapter: use the real Azure MIG UUID; never emulate GPU facts."""
import csv
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

STATE = Path('/var/lib/fortiaigate-prep')
DATA = Path('/opt/fortiaigate/Installer/faig_deployment_assistant_data')
UUID = r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'


def inventory(csv_text, listing):
    rows = list(csv.reader(csv_text.splitlines()))
    if len(rows) != 1 or len(rows[0]) != 5:
        raise RuntimeError('Expected exactly one allocated RTX PRO 6000 GPU.')
    name, memory, driver, capability, parent = [v.strip() for v in rows[0]]
    if (not re.search(r'RTX\s*PRO?\s*6000.*Blackwell', name, re.I)
            # NVML can report parent framebuffer size rather than the MIG slice.
            # The preparation CUDA kernel separately verifies the usable 48 GB.
            or not memory.isdigit() or not 44000 <= int(memory) <= 103000
            or not re.fullmatch(r'\d+(?:\.\d+)+', driver)
            or int(driver.split('.')[0]) < 595 or capability != '12.0'
            or not re.fullmatch('GPU-' + UUID, parent)):
        raise RuntimeError('Require the 48 GB RTX PRO 6000 Blackwell allocation, GRID R595+ and compute capability 12.0.')
    parents = re.findall(r'\(UUID:\s*(GPU-' + UUID + r')\)', listing)
    devices = re.findall(r'\(UUID:\s*(MIG-' + UUID + r')\)', listing)
    if parents != [parent] or len(devices) != 1:
        raise RuntimeError('Expected one MIG device on the reported parent GPU. Do not substitute the physical GPU UUID.')
    return {'parent_uuid': parent, 'mig_uuid': devices[0]}


def current_inventory():
    facts = subprocess.run(['nvidia-smi', '--query-gpu=name,memory.total,driver_version,compute_cap,uuid',
                            '--format=csv,noheader,nounits'], capture_output=True, text=True, check=True)
    listing = subprocess.run(['nvidia-smi', '-L'], capture_output=True, text=True, check=True)
    return inventory(facts.stdout, listing.stdout)


def rewrite_env(text, parent, mig):
    """Change the five saved device settings only; retain all secrets and licensing."""
    keys = {'FAIG_GPU_DEVICES', 'TRITON_DEVICES', 'VLLM_DEVICES', 'TRITON_DEVICE_0', 'VLLM_DEVICE_0'}
    values = {}
    lines = text.splitlines(keepends=True)
    for line in lines:
        if not line.strip() or line.lstrip().startswith('#') or '=' not in line:
            continue
        key, value = line.rstrip('\r\n').split('=', 1)
        if key in values:
            raise RuntimeError('Duplicate environment setting; review the saved definition.')
        values[key] = value
    if values.get('FAIG_DEPLOY_GPU') != 'true' or not keys.issubset(values):
        raise RuntimeError('Complete the GPU setup wizard first, then exit the assistant.')
    if any(values[key] not in (parent, mig) for key in keys):
        raise RuntimeError('Saved GPU selection differs from this host. No settings were changed.')
    if any(re.fullmatch(r'(?:TRITON|VLLM)_DEVICE_[1-9]\d*', key) and value for key, value in values.items()):
        raise RuntimeError('This preview requires one MIG device shared by both engines.')
    return ''.join((line.split('=', 1)[0] + '=' + mig + '\n')
                   if '=' in line and line.split('=', 1)[0] in keys else line for line in lines)


def bind():
    if os.geteuid() == 0:
        raise RuntimeError('Run fortiaigate-bind-mig as the normal installer user, without sudo.')
    marker = STATE / 'GPU_READY'
    record = STATE / 'AZURE_RTX_DEVICE.json'
    if not marker.is_file() or (STATE / 'GPU_FAILED').exists() or (STATE / 'FAILED').exists():
        raise RuntimeError('GPU host preparation must report READY before binding the device.')
    if record.is_symlink() or record.stat().st_uid != 0 or record.stat().st_mode & 0o022:
        raise RuntimeError('The preparation device record must be root-owned and protected.')
    device = current_inventory()
    if json.loads(record.read_text()) != device:
        raise RuntimeError('The allocated MIG device changed. Review the host before changing the deployment.')
    for path in (DATA, DATA / 'deployment', DATA / 'deployment/.env'):
        if path.is_symlink() or path.stat().st_uid != os.geteuid():
            raise RuntimeError('The installer state must be owned by the connected operator and contain no symbolic links.')
    with (DATA / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        containers = subprocess.run(['sudo', '-n', 'docker', 'ps', '-aq'],
                                     capture_output=True, text=True, check=True)
        if containers.stdout.strip():
            raise RuntimeError('Bind before deploying any containers. Existing workloads were not changed.')
        env = DATA / 'deployment/.env'
        old = env.read_text()
        new = rewrite_env(old, device['parent_uuid'], device['mig_uuid'])
        if new == old:
            print('MIG device is already bound. Regenerate the definition with assistant 2 → 2.')
            return
        backups = DATA / 'backups'
        if backups.is_symlink():
            raise RuntimeError('Refusing a symbolic-link backup directory.')
        backups.mkdir(mode=0o700, exist_ok=True)
        if backups.stat().st_uid != os.geteuid():
            raise RuntimeError('Backup directory belongs to another user.')
        backup = backups / ('before-azure-mig-' + str(time.time_ns()) + '.env')
        with backup.open('x') as target:
            os.chmod(backup, 0o600)
            target.write(old)
        fd, temporary = tempfile.mkstemp(prefix='.mig-env-', dir=env.parent)
        try:
            with os.fdopen(fd, 'w') as target:
                target.write(new); target.flush(); os.fsync(target.fileno())
            os.replace(temporary, env)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
    print('Bound both engines to the real MIG device. The vendor installer and licensing settings were not modified.')
    print('Reopen fortiaigate-install, choose 2 → 2 to regenerate, then import and deploy.')


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['inventory']:
            print(json.dumps(current_inventory(), sort_keys=True))
        elif sys.argv[1:] == ['bind']:
            bind()
        else:
            raise RuntimeError('Use inventory or bind.')
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print('STOP: ' + str(error), file=sys.stderr)
        sys.exit(1)
RTX_MIG_ADAPTER
chmod 0755 /usr/local/libexec/fortiaigate-azure-rtx.py
cat >/usr/local/bin/fortiaigate-bind-mig <<'RTX_BIND_WRAPPER'
#!/bin/sh
exec python3 /usr/local/libexec/fortiaigate-azure-rtx.py bind "$@"
RTX_BIND_WRAPPER
chmod 0755 /usr/local/bin/fortiaigate-bind-mig

stage 'validate the Azure RTX 48 GB preview host and managed-identity configuration'
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 22.04 && "$(dpkg --print-architecture)" == amd64 ]]
[[ "$(nproc)" -ge 72 ]]
[[ -f "$CONFIG" && ! -L "$CONFIG" && "$(stat -c %u "$CONFIG")" == 0 ]]
mode=$(stat -c %a "$CONFIG")
(( (8#$mode & 8#022) == 0 ))
CONFIG_SHA256=$(python3 "$WORK/azure_support.py" validate "$CONFIG")
printf 'gpu\n' >"$STATE/edition"
printf 'gpu\n' >"$STATE/GPU_MODE"
chmod 0644 "$STATE/edition" "$STATE/GPU_MODE"
if [[ -f "$STATE/GPU_READY" ]] && grep -Fxq "version=$VERSION" "$STATE/GPU_READY" && grep -Fxq "config_sha256=$CONFIG_SHA256" "$STATE/GPU_READY"; then
  [[ ! -f "$STATE/GPU_FAILED" && ! -f "$STATE/FAILED" ]]
  rm -f "$STATE/GPU_RUNNING"
  printf 'GPU_READY: Azure preparation already completed. Continue with fortiaigate-install.\n'
  exit 0
fi
[[ ! -f "$ROOT/Installer/faig_deployment_assistant_data/deployment/.env" ]] || { printf 'STOP: an existing application configuration will not be replaced.\n' >&2; false; }
if [[ -f "$STATE/GPU_CONFIG_SHA256" ]]; then
  [[ "$(cat "$STATE/GPU_CONFIG_SHA256")" == "$CONFIG_SHA256" ]] || { printf 'STOP: GPU configuration changed across preparation phases.\n' >&2; false; }
else
  printf '%s\n' "$CONFIG_SHA256" >"$STATE/GPU_CONFIG_SHA256"
fi
# Refuse other workloads before staging files or changing Docker/driver packages.
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    [[ -z "$(docker ps -aq)" ]] || { printf 'STOP: existing Docker containers require a separate fresh GPU host.\n' >&2; false; }
  elif [[ -d /var/lib/docker/containers ]] && find /var/lib/docker/containers -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    printf 'STOP: existing Docker container data needs review.\n' >&2
    false
  fi
fi
rm -f "$STATE/GPU_READY" "$STATE/GPU_FAILED"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l

stage 'stage and inspect all eleven private Azure Blob release archives'
for release_directory in "$ROOT" "$ROOT/Images" "$ROOT/Installer"; do
  [[ ! -L "$release_directory" ]] || { printf 'STOP: refusing a symbolic-link release directory.\n' >&2; false; }
  install -d -o root -g root -m 0755 "$release_directory"
done
python3 "$WORK/azure_support.py" stage "$CONFIG" "$ROOT" "$WORK"
stage 'prepare Docker and shared host tools using the pinned common script'
python3 "$WORK/azure_support.py" core-config "$CONFIG" /etc/fortiaigate-cpu-azure-gpu.json
curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --retry 3 \
  --connect-timeout 15 --max-time 180 "$CPU_PREP_URL" --output "$WORK/prepare_cpu.sh"
printf '%s  %s\n' "$CPU_PREP_SHA256" "$WORK/prepare_cpu.sh" | sha256sum --check
install -m 0700 "$WORK/prepare_cpu.sh" /usr/local/sbin/prepare_fortiaigate_cpu.sh
# All seven core TARs and the checksum-valid installer are already local.
# The common script therefore needs no anonymous access to the private Blob URL.
bash /usr/local/sbin/prepare_fortiaigate_cpu.sh /etc/fortiaigate-cpu-azure-gpu.json

if [[ ! -f "$STATE/GPU_AZURE_DRIVER_INSTALLED" ]]; then
  stage 'install Microsoft GRID 595.58.03 for Azure RTX PRO 6000'
  retry apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 update
  retry apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 install -y \
    ca-certificates curl pciutils build-essential dkms "linux-headers-$(uname -r)"
  lspci -nn | grep -i nvidia
  curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --retry 3 \
    --connect-timeout 15 --max-time 1800 \
    https://download.microsoft.com/download/51239696-ec04-4c02-a6b3-1d9c608fb57c/NVIDIA-Linux-x86_64-595.58.03-grid-azure.run \
    --output "$WORK/nvidia-grid.run"
  sh "$WORK/nvidia-grid.run" --check
  sh "$WORK/nvidia-grid.run" --silent --dkms -M open
  dkms status
  cat /proc/sys/kernel/random/boot_id >"$STATE/GPU_AZURE_DRIVER_BOOT_ID"
  printf 'version=%s\n' "$VERSION" >"$STATE/GPU_AZURE_DRIVER_INSTALLED"
fi

if [[ "$(cat "$STATE/GPU_AZURE_DRIVER_BOOT_ID")" == "$(cat /proc/sys/kernel/random/boot_id)" ]]; then
  stage 'compute driver installed; waiting for the automatic reboot'
  if [[ "$(readlink -f "${BASH_SOURCE[0]}")" != "$SELF" ]]; then install -m 0700 "${BASH_SOURCE[0]}" "$SELF"; fi
  [[ "$CONFIG" == /etc/fortiaigate-prep.json ]] || { printf 'Automatic resume requires /etc/fortiaigate-prep.json.\n' >&2; false; }
  cat >/etc/systemd/system/fortiaigate-gpu-prep.service <<'GPU_SERVICE'
[Unit]
Description=Finish FortiAIGate Azure GPU preparation after the compute driver reboot
Wants=network-online.target
After=network-online.target cloud-final.service docker.service
ConditionPathExists=/var/lib/fortiaigate-prep/GPU_AZURE_DRIVER_INSTALLED
ConditionPathExists=!/var/lib/fortiaigate-prep/GPU_READY

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/sbin/prepare_fortiaigate_gpu_azure_rtx.sh /etc/fortiaigate-prep.json
TimeoutStartSec=3600
Restart=no
GPU_SERVICE
  cat >/etc/systemd/system/fortiaigate-gpu-prep.timer <<'GPU_TIMER'
[Unit]
Description=Resume FortiAIGate Azure GPU preparation after the compute driver reboot

[Timer]
OnBootSec=60s
Unit=fortiaigate-gpu-prep.service

[Install]
WantedBy=timers.target
GPU_TIMER
  systemctl daemon-reload
  systemctl enable fortiaigate-gpu-prep.timer
  if ! systemctl is-active --quiet fortiaigate-gpu-reboot.timer; then
    systemd-run --unit=fortiaigate-gpu-reboot --on-active=15s /bin/systemctl reboot
  fi
  printf 'Preparation resumes after reboot. GPU_READY has not been written.\n'
  exit 0
fi

stage 'verify the real RTX 48 GB allocation and its MIG device'
nvidia-smi
python3 /usr/local/libexec/fortiaigate-azure-rtx.py inventory >"$STATE/AZURE_RTX_DEVICE.json"
chmod 0644 "$STATE/AZURE_RTX_DEVICE.json"
MIG_UUID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mig_uuid"])' "$STATE/AZURE_RTX_DEVICE.json")
curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --retry 3 \
  --connect-timeout 15 --max-time 180 https://nvidia.github.io/libnvidia-container/gpgkey --output "$WORK/nvidia-container.asc"
gpg --batch --yes --dearmor --output "$WORK/nvidia-container-keyring.gpg" "$WORK/nvidia-container.asc"
install -m 0644 "$WORK/nvidia-container-keyring.gpg" /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --retry 3 \
  --connect-timeout 15 --max-time 180 https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  --output "$WORK/nvidia-container-toolkit.list"
sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  "$WORK/nvidia-container-toolkit.list" >/etc/apt/sources.list.d/nvidia-container-toolkit.list
retry apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 update
toolkit=1.20.1-1
retry apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 install -y \
  "nvidia-container-toolkit=$toolkit" "nvidia-container-toolkit-base=$toolkit" \
  "libnvidia-container-tools=$toolkit" "libnvidia-container1=$toolkit"
if [[ -f /etc/docker/daemon.json ]]; then cp -a /etc/docker/daemon.json "$STATE/daemon.json.before-nvidia"; fi
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
stage 'execute a real CUDA kernel on the allocated MIG device'
cat >"$WORK/rtx-check.cu" <<'RTX_CUDA'
#include <cuda_runtime.h>
#include <cstdio>
#define OK(x) do { cudaError_t e=(x); if(e!=cudaSuccess){fprintf(stderr,"CUDA failure: %s\n",cudaGetErrorString(e));return 1;} } while(0)
__global__ void check(int *p) { *p=42; }
int main(){int count=0;OK(cudaGetDeviceCount(&count));if(count!=1)return 2;
cudaDeviceProp prop;OK(cudaGetDeviceProperties(&prop,0));
if(prop.totalGlobalMem < 44ULL*1024*1024*1024 || prop.totalGlobalMem > 51ULL*1024*1024*1024 || prop.major!=12)return 3;
int *p=nullptr,value=0;OK(cudaMalloc(reinterpret_cast<void**>(&p),sizeof(int)));check<<<1,1>>>(p);
OK(cudaGetLastError());OK(cudaDeviceSynchronize());
OK(cudaMemcpy(&value,p,sizeof(int),cudaMemcpyDeviceToHost));OK(cudaFree(p));
if(value!=42)return 4;puts("PASS: RTX MIG device executed a CUDA kernel.");return 0;}
RTX_CUDA
retry docker run --rm --runtime=nvidia --gpus "device=$MIG_UUID" \
  --volume "$WORK/rtx-check.cu:/tmp/check.cu:ro" \
  nvidia/cuda:13.0.2-devel-ubuntu22.04 /bin/bash -c \
  'nvcc -arch=sm_120 /tmp/check.cu -o /tmp/check && /tmp/check'

bash -n "$ROOT/Installer/deploy-docker-compose.sh"
bash "$ROOT/Installer/deploy-docker-compose.sh" --self-test
printf 'version=%s\nconfig_sha256=%s\n' "$VERSION" "$CONFIG_SHA256" >"$STATE/GPU_READY"
chmod 0644 "$STATE/GPU_READY"
rm -f "$STATE/GPU_FAILED" "$STATE/GPU_RUNNING"
systemctl disable fortiaigate-gpu-prep.timer
printf 'GPU_READY: Azure RTX GRID driver, MIG CUDA kernel, container runtime, ten images and installer are prepared.\n'
printf 'Both Triton and vLLM archives are staged. FortiAIGate is not deployed; run fortiaigate-install as your normal operator.\n'
