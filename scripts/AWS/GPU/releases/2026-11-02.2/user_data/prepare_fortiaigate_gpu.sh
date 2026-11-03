#!/usr/bin/env bash
# AWS L40S host preparation only; the operator runs the FortiAIGate wizard later.
# Version 2026-10-31.6. A persistent systemd service resumes after one driver reboot.
set -Eeuo pipefail
umask 077
VERSION=2026-11-02.1
CONFIG=${1:-/etc/fortiaigate-prep.json}
STATE=/var/lib/fortiaigate-prep
ROOT=/opt/fortiaigate
LOG=/var/log/fortiaigate-gpu-prep.log
SELF=/usr/local/sbin/prepare_fortiaigate_gpu.sh
CPU_PREP_URL=https://raw.githubusercontent.com/WEEMR/FortiAIGate/gpu-2026-11-02.2/scripts/AWS/GPU/releases/2026-11-02.2/user_data/prepare_fortiaigate_cpu.sh
CPU_PREP_SHA256=db1cf5ca6d2a0519a2b633e6c3fd9991325d288bd064367891506d64c843ffb6
BUILD=V8.0.2-build0055-FORTINET
STAGE=starting
WORK=
((EUID == 0)) || { printf 'Run GPU preparation as root through cloud-init or sudo.\n' >&2; exit 1; }
[[ $# -le 1 ]] || { printf 'Usage: prepare_fortiaigate_gpu.sh [CONFIG_JSON]\n' >&2; exit 1; }
command -v python3 >/dev/null
command -v flock >/dev/null
install -d -m 0755 "$STATE"
exec 8>"$STATE/gpu.lock"
flock -n 8 || { printf 'GPU preparation is already running.\n' >&2; exit 75; }
if [[ ! -f "$STATE/GPU_PREP_STARTED_AT" ]]; then
  date -u +%FT%TZ >"$STATE/GPU_PREP_STARTED_AT"
  chmod 0644 "$STATE/GPU_PREP_STARTED_AT"
fi
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
  printf '\n[%s] GPU: %s\n' "$(date -u +%FT%TZ)" "$STAGE"
  printf '%s\n' "$STAGE" >"$STATE/GPU_RUNNING"
  chmod 0644 "$STATE/GPU_RUNNING"
}
retry() {
  local attempt rc
  for attempt in 1 2 3; do
    if "$@"; then return 0; else rc=$?; fi
    ((attempt < 3)) || return "$rc"
    sleep "$((attempt * 10))"
  done
}
# Install the status/transfer helper before expensive preparation starts. It is
# embedded in this checksum-pinned script; there is no extra network dependency.
install -d -m 0755 /usr/local/libexec
cat >/usr/local/libexec/fortiaigate-gpu-transfer.py <<'GPU_TRANSFER_PROGRESS_PY'
"""Read-only GPU status snapshots and AWS CLI transfer progress, stdlib only.

The preparation shell embeds this reviewed source in its own download. Nothing
is imported from S3 or pip, and the progress JSON never grants readiness.
"""
import datetime
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import time

AWS = '/usr/local/bin/aws'
STATE = Path('/var/lib/fortiaigate-prep')
BUILD = 'V8.0.2-build0055-FORTINET'
COMPONENTS = ('custom-triton', 'faig-models', 'vllm-server')
PROGRESS_FILE = 'GPU_DOWNLOAD_PROGRESS.json'
UNITS = {'B':1,'Byte':1,'Bytes':1,'KiB':1024,'MiB':1024**2,'GiB':1024**3,
         'TiB':1024**4,'KB':1000,'MB':1000**2,'GB':1000**3,'TB':1000**4}
PROGRESS = re.compile(r'Completed\s+([0-9]+(?:\.[0-9]+)?)\s*(Bytes|Byte|KiB|MiB|GiB|TiB|KB|MB|GB|TB|B)\s*/\s*([0-9]+(?:\.[0-9]+)?)\s*(Bytes|Byte|KiB|MiB|GiB|TiB|KB|MB|GB|TB|B)(?:\s*\(([0-9]+(?:\.[0-9]+)?)\s*(Bytes|Byte|KiB|MiB|GiB|TiB|KB|MB|GB|TB|B)/s\))?')


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00','Z')


def atomic_progress(state, value):
    """Never leave a partial JSON document for the CloudShell status probe."""
    state = Path(state)
    if state.is_symlink() or not state.is_dir():
        raise RuntimeError('Progress state must be a real preparation directory.')
    target = state / PROGRESS_FILE
    if target.is_symlink():
        raise RuntimeError('Refusing a symbolic-link progress file.')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile('w', dir=state, prefix='.gpu-progress-', delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(value, stream, separators=(',',':'))
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(0o644)
        os.replace(temporary, target)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def parse_progress(line, expected_size):
    """AWS CLI supplies real transferred bytes; its human units are rounded."""
    match = PROGRESS.search(line)
    if not match:
        return None
    done = min(expected_size, max(0, int(float(match[1])*UNITS[match[2]])))
    rate = int(float(match[5])*UNITS[match[6]]) if match[5] else None
    return done, rate


def safe_name(value):
    return isinstance(value,str) and value.isprintable() and 0 < len(value) <= 240


def read_text(path):
    try:
        return Path(path).read_text()[:240].strip()
    except FileNotFoundError:
        return ''


def transfer_snapshot(state):
    try:
        value = json.loads((Path(state)/PROGRESS_FILE).read_text())
    except (FileNotFoundError, ValueError):
        return None
    if (not isinstance(value,dict) or value.get('status') not in ('downloading','checking','complete','failed')
            or not safe_name(value.get('file_name')) or '/' in value['file_name']
            or value.get('component_count') != 3
            or type(value.get('component_index')) is not int or not 1 <= value['component_index'] <= 3
            or type(value.get('bytes_downloaded')) is not int or type(value.get('total_bytes')) is not int
            or not 0 <= value['bytes_downloaded'] <= value['total_bytes'] or value['total_bytes'] <= 0):
        return None
    rate = value.get('rate_bytes_per_second')
    if rate is not None and (type(rate) is not int or rate < 0):
        return None
    # Return only documented fields, never arbitrary text from command output.
    fields = ('status','file_name','component_index','component_count','bytes_downloaded',
              'total_bytes','rate_bytes_per_second','updated_at')
    return {key:value.get(key) for key in fields}


def status_snapshot(state=STATE):
    state = Path(state)
    started = read_text(state/'GPU_PREP_STARTED_AT')
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', started):
        started = None
    base = {'status':'pending','stage':'waiting for GPU preparation to start','percent':1,
            'download':None,'started_at':started,'updated_at':stamp(),
            'progress_kind':'estimated_host_preparation'}
    def failed():
        for name in ('GPU_FAILED','FAILED'):
            if (state/name).is_file():
                text = read_text(state/name)
                return text if safe_name(text) else 'host preparation failed; inspect its log'
        return None
    error = failed()
    if error:
        return {**base,'status':'failed','stage':error}
    if (state/'GPU_READY').is_file():
        return {**base,'status':'ready','stage':'GPU host preparation completed; ready for the interactive installer','percent':100}
    phase = read_text(state/'GPU_RUNNING')
    if not safe_name(phase):
        return base
    stage, percent = phase, 3
    if phase == 'prepare Docker, AWS CLI and the core release files':
        core = read_text(state/'RUNNING')
        if safe_name(core):
            stage = core
        percent = {
            'validate host and configuration':5,
            'repair signed Docker repository':10,
            'install and verify Docker and Compose':20,
            'install and verify AWS CLI v2':27,
            'download and check the CPU release archives':32,
            'install the interactive handoff':34,
        }.get(core,5)
    elif phase == 'download and check the three additional GPU images':
        percent = 35
        value = transfer_snapshot(state)
        if value:
            base['download'] = value
            fraction = value['bytes_downloaded']/value['total_bytes']
            # Byte progress is real. This overall phase bar is deliberately
            # labelled estimated: driver compilation/reboot time is unknown.
            percent = 35 + int(40*((value['component_index']-1)+fraction)/3)
            stage = ('Checking ' if value['status']=='checking' else 'Downloaded ' if value['status']=='complete' else 'Downloading ') + value['file_name']
            if value['status']=='failed':
                return {**base,'status':'failed','stage':'GPU image download failed: '+value['file_name'],'percent':min(99,percent)}
    elif phase == 'install the pinned R580 NVIDIA compute driver':
        percent = 75
    elif phase == 'driver installed; waiting for the automatic reboot':
        percent = 85
    elif phase == 'verify the loaded L40S driver and configure the NVIDIA container runtime':
        percent = 90
    elif phase == 'verify Docker GPU access with a CUDA container':
        percent = 95
    elif phase == 'verify the Deployment Assistant self-test':
        percent = 98
    # Resuming after reboot rechecks already completed core/image stages.
    if (state/'GPU_DRIVER_INSTALLED').is_file():
        percent = max(percent,85)
    error = failed()
    if error:
        return {**base,'status':'failed','stage':error,'percent':min(99,percent)}
    return {**base,'status':'running','stage':stage,'percent':min(99,max(1,percent))}


def head_size(bucket, key, region, aws=AWS):
    command = [aws,'s3api','head-object','--bucket',bucket,'--key',key,'--region',region,
               '--output','json','--no-cli-pager','--cli-connect-timeout','15','--cli-read-timeout','120']
    result = subprocess.run(command, capture_output=True, text=True, timeout=180)
    if result.returncode:
        if any(code in result.stderr for code in ('(404)','(NoSuchKey)','(NotFound)')):
            return None
        raise RuntimeError('S3 metadata check failed; verify read access to the configured release prefix.')
    value = json.loads(result.stdout).get('ContentLength')
    if type(value) is not int or value <= 0:
        raise RuntimeError('A GPU image has an empty or invalid S3 object size.')
    return value


def check_tar(path):
    result = subprocess.run(['tar','-tf',str(path)], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, timeout=3600)
    return result.returncode == 0


def download_cli(uri, destination, region, expected_size, update, aws=AWS, timeout_seconds=3600):
    """Consume AWS CLI progress without printing source URLs or error payloads."""
    command = [aws,'s3','cp',uri,str(destination),'--region',region,'--no-cli-pager',
               '--color','off','--cli-connect-timeout','15','--cli-read-timeout','120']
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True)
    deadline = time.monotonic()+timeout_seconds
    buffer = b''
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while selector.get_map():
            remaining = deadline-time.monotonic()
            if remaining <= 0:
                raise RuntimeError('GPU image transfer exceeded its one-hour limit.')
            for key,_ in selector.select(timeout=min(1,remaining)):
                chunk = os.read(key.fileobj.fileno(),8192)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                buffer += chunk
                parts = re.split(br'[\r\n]',buffer)
                buffer = parts.pop()
                # Ignore verbose errors entirely; only known progress fields
                # enter the status document and stdout remains concise.
                for part in parts:
                    value = parse_progress(part.decode('utf-8',errors='replace'),expected_size)
                    if value: update(*value)
                if len(buffer)>65536:
                    buffer = buffer[-4096:]
        value = parse_progress(buffer.decode('utf-8',errors='replace'),expected_size)
        if value: update(*value)
        try: code = process.wait(timeout=max(1,deadline-time.monotonic()))
        except subprocess.TimeoutExpired as error:
            raise RuntimeError('GPU image transfer exceeded its one-hour limit.') from error
        if code:
            raise RuntimeError('S3 GPU image transfer failed; verify the release object and instance-role read access.')
    finally:
        selector.close()
        if process.poll() is None:
            try: os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait()
        process.stdout.close()
    if not Path(destination).is_file() or Path(destination).stat().st_size != expected_size:
        raise RuntimeError('Downloaded GPU image size differs from its S3 metadata.')


def download_images(release, region, state, work, images, aws=AWS):
    match = re.fullmatch(r's3://([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])/([A-Za-z0-9_./-]+)',release.rstrip('/'))
    if (not match or any(p in ('','.','..') for p in match[2].split('/'))
            or not re.fullmatch(r'[a-z]{2}(?:-gov)?-[a-z]+-\d',region)):
        raise ValueError('Invalid GPU release location.')
    bucket,prefix = match.groups()
    state,work,images = map(Path,(state,work,images))
    if any(p.is_symlink() or not p.is_dir() for p in (state,work,images)):
        raise RuntimeError('GPU preparation paths must be real directories.')
    for index,component in enumerate(COMPONENTS,1):
        base = 'FAIG_'+component+'-'+BUILD+'.tar'
        variants = [images/base,images/(base+'.gz')]
        if any(p.is_symlink() for p in variants) or all(p.exists() for p in variants):
            raise RuntimeError('Keep only one regular GPU image archive variant per component.')
        chosen = next((p for p in variants if p.is_file() and p.stat().st_size and check_tar(p)),None)
        if chosen:
            size = chosen.stat().st_size
            atomic_progress(state,{'status':'complete','file_name':chosen.name,'component_index':index,
                'component_count':3,'bytes_downloaded':size,'total_bytes':size,
                'rate_bytes_per_second':None,'updated_at':stamp()})
            print('Reused verified GPU image: '+chosen.name,flush=True)
            continue
        name,size = None,None
        for candidate in (base,base+'.gz'):
            value = head_size(bucket,prefix+'/Images/'+candidate,region,aws)
            if value is not None:
                name,size = candidate,value
                break
        if name is None:
            raise RuntimeError('Required GPU image is missing: '+base+'[.gz]')
        record = {'status':'downloading','file_name':name,'component_index':index,'component_count':3,
                  'bytes_downloaded':0,'total_bytes':size,'rate_bytes_per_second':None,'updated_at':stamp()}
        def update(done,rate):
            record.update(bytes_downloaded=done,rate_bytes_per_second=rate,updated_at=stamp())
            atomic_progress(state,record)
        atomic_progress(state,record)
        temporary = work/'gpu-image'
        if temporary.is_symlink():
            raise RuntimeError('Refusing a symbolic-link GPU download destination.')
        temporary.unlink(missing_ok=True)
        print('Downloading GPU image %s/3: %s (%s bytes)' % (index,name,size),flush=True)
        try:
            download_cli(release.rstrip('/')+'/Images/'+name,temporary,region,size,update,aws)
            record.update(status='checking',bytes_downloaded=size,rate_bytes_per_second=None,updated_at=stamp())
            atomic_progress(state,record)
            if not check_tar(temporary):
                raise RuntimeError('Downloaded GPU image is not a readable TAR archive.')
            destination = images/name
            if destination.is_symlink():
                raise RuntimeError('Refusing a symbolic-link GPU image destination.')
            temporary.chmod(0o644)
            os.replace(temporary,destination)
            # Only a structurally invalid alternate can reach this branch: a
            # valid existing archive was reused above, and two variants refuse
            # before transfer. Remove that invalid alternate after the verified
            # replacement is safely in place so a retry does not see duplicates.
            for alternate in variants:
                if alternate.name != name and alternate.exists():
                    alternate.unlink()
            record.update(status='complete',updated_at=stamp())
            atomic_progress(state,record)
            print('Checked GPU image: '+name,flush=True)
        except BaseException:
            record.update(status='failed',rate_bytes_per_second=None,updated_at=stamp())
            atomic_progress(state,record)
            temporary.unlink(missing_ok=True)
            raise


def main():
    if sys.argv[1:] == ['status']:
        print(json.dumps(status_snapshot(),separators=(',',':')))
        return
    if len(sys.argv) == 7 and sys.argv[1] == 'download':
        if os.geteuid()!=0:
            raise RuntimeError('GPU image preparation must run as root.')
        download_images(*sys.argv[2:])
        return
    raise ValueError('Use status or download RELEASE_URI REGION STATE WORK IMAGES.')


if __name__=='__main__':
    try:
        main()
    except (RuntimeError,ValueError,OSError,subprocess.SubprocessError) as error:
        print('GPU progress: '+str(error),file=sys.stderr)
        sys.exit(1)
GPU_TRANSFER_PROGRESS_PY
chmod 0755 /usr/local/libexec/fortiaigate-gpu-transfer.py
cat >/usr/local/bin/fortiaigate-gpu-progress <<'GPU_PROGRESS_WRAPPER'
#!/bin/sh
exec python3 /usr/local/libexec/fortiaigate-gpu-transfer.py status
GPU_PROGRESS_WRAPPER
chmod 0755 /usr/local/bin/fortiaigate-gpu-progress

stage 'validate GPU preparation configuration'
[[ -f "$CONFIG" && ! -L "$CONFIG" && "$(stat -c %u "$CONFIG")" == 0 ]]
mode=$(stat -c %a "$CONFIG")
(( (8#$mode & 8#022) == 0 ))
config_values=$(python3 - "$CONFIG" <<'CONFIG_PY'
import hashlib,json,re,sys
raw=open(sys.argv[1],'rb').read(); c=json.loads(raw)
if c.get('cloud')!='aws' or c.get('edition')!='gpu': raise SystemExit('This GPU preparation targets AWS with edition=gpu.')
uri=c.get('release_s3_uri',''); region=c.get('region','us-east-1')
if not isinstance(uri,str) or not re.fullmatch(r's3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]/[A-Za-z0-9_./-]+/?',uri): raise SystemExit('Invalid S3 release URI.')
if any(x in ('','.','..') for x in uri.rstrip('/').split('/')[3:]): raise SystemExit('Invalid S3 prefix.')
if not isinstance(region,str) or not re.fullmatch(r'[a-z]{2}(?:-gov)?-[a-z]+-\d',region): raise SystemExit('Invalid S3 region.')
print(uri.rstrip('/')); print(region); print(hashlib.sha256(raw).hexdigest())
CONFIG_PY
)
mapfile -t values <<<"$config_values"
RELEASE=${values[0]}; REGION=${values[1]}; CONFIG_SHA256=${values[2]}
printf 'gpu\n' >"$STATE/edition"
printf 'gpu\n' >"$STATE/GPU_MODE"
chmod 0644 "$STATE/edition" "$STATE/GPU_MODE"
if [[ -f "$STATE/GPU_READY" ]] && grep -Fxq "version=$VERSION" "$STATE/GPU_READY" && grep -Fxq "config_sha256=$CONFIG_SHA256" "$STATE/GPU_READY"; then
  rm -f "$STATE/GPU_RUNNING"
  printf 'GPU_READY: preparation already completed. Continue with fortiaigate-install.\n'
  exit 0
fi
[[ ! -f "$ROOT/Installer/faig_deployment_assistant_data/deployment/.env" ]] || { printf 'STOP: an application configuration already exists; GPU preparation will not replace it.\n' >&2; false; }
if [[ -f "$STATE/GPU_CONFIG_SHA256" ]]; then
  [[ "$(cat "$STATE/GPU_CONFIG_SHA256")" == "$CONFIG_SHA256" ]] || { printf 'STOP: GPU preparation configuration changed across phases. Review it before resuming.\n' >&2; false; }
else
  printf '%s\n' "$CONFIG_SHA256" >"$STATE/GPU_CONFIG_SHA256"
fi
rm -f "$STATE/GPU_READY" "$STATE/GPU_FAILED"
WORK=$(mktemp -d /var/tmp/fortiaigate-gpu-prep.XXXXXXXX)
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l AWS_PAGER='' AWS_CLI_AUTO_PROMPT=off

stage 'prepare Docker, AWS CLI and the core release files'
[[ "$CPU_PREP_SHA256" =~ ^[0-9a-f]{64}$ ]] || { printf 'STOP: CPU preparation checksum was not finalized.\n' >&2; false; }
curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 --retry 3 \
  --connect-timeout 15 --max-time 180 "$CPU_PREP_URL" --output "$WORK/prepare_cpu.sh"
printf '%s  %s\n' "$CPU_PREP_SHA256" "$WORK/prepare_cpu.sh" | sha256sum --check
install -m 0700 "$WORK/prepare_cpu.sh" /usr/local/sbin/prepare_fortiaigate_cpu.sh
bash /usr/local/sbin/prepare_fortiaigate_cpu.sh "$CONFIG"

stage 'download and check the three additional GPU images'
python3 /usr/local/libexec/fortiaigate-gpu-transfer.py download \
  "$RELEASE" "$REGION" "$STATE" "$WORK" "$ROOT/Images"

if [[ ! -f "$STATE/GPU_DRIVER_INSTALLED" ]]; then
  stage 'install the pinned R580 NVIDIA compute driver'
  . /etc/os-release
  [[ "$ID" == ubuntu && "$VERSION_ID" == 22.04 && "$(dpkg --print-architecture)" == amd64 ]]
  [[ "$(nproc)" -ge 8 ]]
  retry apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 update
  retry apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 install -y \
    ca-certificates curl pciutils build-essential dkms "linux-headers-$(uname -r)"
  lspci -nn | grep -i nvidia
  curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 180 \
    https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb \
    --output "$WORK/cuda-keyring.deb"
  dpkg -i "$WORK/cuda-keyring.deb"
  retry apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 update
  retry apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 install -y nvidia-driver-pinning-580
  retry apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 install -y nvidia-open-580
  dkms status
  cat /proc/sys/kernel/random/boot_id >"$STATE/GPU_DRIVER_BOOT_ID"
  printf 'version=%s\n' "$VERSION" >"$STATE/GPU_DRIVER_INSTALLED"
fi

if [[ "$(cat "$STATE/GPU_DRIVER_BOOT_ID")" == "$(cat /proc/sys/kernel/random/boot_id)" ]]; then
  stage 'driver installed; waiting for the automatic reboot'
  # Install a stable root-owned copy; the resume service never executes /tmp input.
  if [[ "$(readlink -f "${BASH_SOURCE[0]}")" != "$SELF" ]]; then install -m 0700 "${BASH_SOURCE[0]}" "$SELF"; fi
  # The config path is fixed to avoid shell interpolation in a privileged unit.
  [[ "$CONFIG" == /etc/fortiaigate-prep.json ]] || { printf 'Automatic resume requires /etc/fortiaigate-prep.json.\n' >&2; false; }
  cat >/etc/systemd/system/fortiaigate-gpu-prep.service <<'GPU_SERVICE'
[Unit]
Description=Finish FortiAIGate GPU host preparation after the driver reboot
Wants=network-online.target
After=network-online.target cloud-final.service docker.service
ConditionPathExists=/var/lib/fortiaigate-prep/GPU_DRIVER_INSTALLED
ConditionPathExists=!/var/lib/fortiaigate-prep/GPU_READY

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/sbin/prepare_fortiaigate_gpu.sh /etc/fortiaigate-prep.json
TimeoutStartSec=3600
Restart=no
GPU_SERVICE
  # cloud-final itself runs after multi-user.target. A boot timer avoids
  # ordering this service before multi-user while also requiring cloud-final.
  cat >/etc/systemd/system/fortiaigate-gpu-prep.timer <<'GPU_TIMER'
[Unit]
Description=Resume FortiAIGate GPU preparation after the driver reboot

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
  printf 'GPU preparation will resume automatically after reboot. Do not start the installer yet.\n'
  exit 0
fi

stage 'verify the loaded L40S driver and configure the NVIDIA container runtime'
nvidia-smi
[[ "$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)" -eq 1 ]]
nvidia-smi --query-gpu=name --format=csv,noheader | grep -Fx 'NVIDIA L40S'
gpu_memory=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits)
[[ "$gpu_memory" =~ ^[0-9]+$ ]]
test "$gpu_memory" -ge 44000
driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader)
[[ "${driver%%.*}" -ge 580 ]]
curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 180 \
  https://nvidia.github.io/libnvidia-container/gpgkey --output "$WORK/nvidia-container.asc"
gpg --batch --yes --dearmor --output "$WORK/nvidia-container-keyring.gpg" "$WORK/nvidia-container.asc"
install -m 0644 "$WORK/nvidia-container-keyring.gpg" /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 180 \
  https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list --output "$WORK/nvidia-container-toolkit.list"
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
stage 'verify Docker GPU access with a CUDA container'
retry docker run --rm --runtime=nvidia --gpus all nvidia/cuda:13.0.2-base-ubuntu22.04 nvidia-smi
stage 'verify the Deployment Assistant self-test'
bash -n "$ROOT/Installer/deploy-docker-compose.sh"
bash "$ROOT/Installer/deploy-docker-compose.sh" --self-test
systemctl disable fortiaigate-gpu-prep.timer
printf 'version=%s\nconfig_sha256=%s\n' "$VERSION" "$CONFIG_SHA256" >"$STATE/GPU_READY"
chmod 0644 "$STATE/GPU_READY"
rm -f "$STATE/GPU_FAILED" "$STATE/GPU_RUNNING"
printf 'GPU_READY: L40S driver, Docker GPU runtime and all ten image archives are prepared.\n'
printf 'FortiAIGate is not deployed. Connect as your normal operator and run fortiaigate-install.\n'
