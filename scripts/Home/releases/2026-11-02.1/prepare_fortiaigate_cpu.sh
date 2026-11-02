#!/usr/bin/env bash
# CPU host preparation only. The operator configures and deploys FortiAIGate later.
# Version 2026-10-31.1. Run as root through cloud-init on fresh Ubuntu 22.04 amd64.
set -Eeuo pipefail
umask 077

VERSION=2026-10-31.1
CONFIG=/etc/fortiaigate-prep.json
HOME_RELEASE=
if [[ "${1:-}" == --home ]]; then
  [[ $# == 2 ]] || { printf 'Usage: sudo bash prepare_fortiaigate_cpu.sh --home HTTPS_RELEASE_FOLDER\n' >&2; exit 1; }
  HOME_RELEASE=$2
elif [[ $# -gt 1 ]]; then
  printf 'Usage: prepare_fortiaigate_cpu.sh [CONFIG_JSON]\n' >&2
  exit 1
elif [[ $# == 1 ]]; then
  CONFIG=$1
fi
STATE=/var/lib/fortiaigate-prep
ROOT=/opt/fortiaigate
DATA_ROOT=$ROOT/Installer/faig_deployment_assistant_data
LOG=/var/log/fortiaigate-prep.log
BUILD=V8.0.2-build0055-FORTINET
INSTALLER=FAIG_deploy-docker-compose-cli-$BUILD.tar.gz
INSTALLER_SHA256=100abb31106b848959ec9331e727174aba6b52b42bc26b2af5757dfd339970b7
STAGE=starting
WORK=

if ((EUID != 0)); then
  printf 'Run this host-preparation script as root through cloud-init or sudo.\n' >&2
  exit 1
fi
command -v python3 >/dev/null || { printf 'Python 3 is required on the base Ubuntu image.\n' >&2; exit 1; }
command -v flock >/dev/null || { printf 'flock is required on the base Ubuntu image.\n' >&2; exit 1; }
if [[ -n "$HOME_RELEASE" ]]; then
  python3 - "$CONFIG" "$HOME_RELEASE" <<'HOME_CONFIG'
import json,os,pathlib,sys,urllib.parse
p=pathlib.Path(sys.argv[1])
u=urllib.parse.urlsplit(sys.argv[2])
if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment or any(ord(ch)<32 for ch in sys.argv[2]):
    raise SystemExit('Use a public HTTPS release folder URL, without credentials/query/fragment.')
config={'cloud':'home','release_https_base':sys.argv[2].rstrip('/')}
if p.exists() or p.is_symlink():
    if p.is_symlink() or json.loads(p.read_text())!=config:
        raise SystemExit('An existing configuration differs. Review /etc/fortiaigate-prep.json before changing it.')
else:
    with p.open('x') as f: json.dump(config,f)
    os.chmod(p,0o600)
HOME_CONFIG
fi
install -d -m 0755 "$STATE"
exec 9>"$STATE/lock"
flock -n 9 || { printf 'Host preparation is already running. Check fortiaigate-prep-status.\n' >&2; exit 75; }
touch "$LOG"
chmod 0640 "$LOG"
exec > >(tee -a "$LOG") 2>&1

failure() {
  local rc=$1 line=${2:-unknown}
  trap - ERR
  printf 'FAILED: stage=%s line=%s exit=%s. See %s\n' "$STAGE" "$line" "$rc" "$LOG" >&2
  printf 'FAILED stage=%s line=%s exit=%s\n' "$STAGE" "$line" "$rc" >"$STATE/FAILED"
  chmod 0644 "$STATE/FAILED"
  rm -f "$STATE/READY" "$STATE/RUNNING"
  exit "$rc"
}
cleanup() { if [[ -n "$WORK" && -d "$WORK" ]]; then rm -rf -- "$WORK"; fi; }
trap 'failure "$?" "$LINENO"' ERR
trap cleanup EXIT
trap 'failure 130 "$LINENO"' INT
trap 'failure 143 "$LINENO"' TERM

stage() {
  STAGE=$1
  printf '\n[%s] %s\n' "$(date -u +%FT%TZ)" "$STAGE"
  printf '%s\n' "$STAGE" >"$STATE/RUNNING"
  chmod 0644 "$STATE/RUNNING"
}
retry() {
  local attempt rc
  for attempt in 1 2 3; do
    if "$@"; then return 0; else rc=$?; fi
    if ((attempt == 3)); then return "$rc"; fi
    printf 'Retrying command after a transient failure (%s/3)...\n' "$attempt" >&2
    sleep "$((attempt * 10))"
  done
}

# Install the read-only status helper early, so cloud-init progress is observable.
cat > /usr/local/bin/fortiaigate-prep-status <<'STATUS'
#!/usr/bin/env bash
set -euo pipefail
state=/var/lib/fortiaigate-prep
if [[ -f "$state/GPU_MODE" ]] || { [[ -f "$state/edition" ]] && [[ "$(cat "$state/edition")" == gpu ]]; }; then
  if [[ -f "$state/GPU_FAILED" ]]; then cat "$state/GPU_FAILED"; printf 'Read: sudo tail -n 100 /var/log/fortiaigate-gpu-prep.log\n'; exit 1; fi
  if [[ -f "$state/FAILED" ]]; then cat "$state/FAILED"; printf 'Read: sudo tail -n 100 /var/log/fortiaigate-prep.log\n'; exit 1; fi
  if [[ -f "$state/GPU_READY" ]]; then printf 'READY: GPU host preparation completed. FortiAIGate is not deployed yet.\n'; exit 0; fi
  if [[ -f "$state/GPU_RUNNING" ]]; then printf 'RUNNING: '; cat "$state/GPU_RUNNING"; exit 2; fi
  if [[ -f "$state/RUNNING" ]]; then printf 'RUNNING: '; cat "$state/RUNNING"; exit 2; fi
  printf 'PENDING: GPU host preparation has not completed.\n'
  exit 2
fi
if [[ -f "$state/FAILED" ]]; then cat "$state/FAILED"; printf 'Read: sudo tail -n 100 /var/log/fortiaigate-prep.log\n'; exit 1; fi
if [[ -f "$state/READY" ]]; then printf 'READY: host tools and release files are prepared. FortiAIGate is not deployed yet.\n'; exit 0; fi
if [[ -f "$state/RUNNING" ]]; then printf 'RUNNING: '; cat "$state/RUNNING"; exit 2; fi
printf 'PENDING: host preparation has not started.\n'
exit 2
STATUS
chmod 0755 /usr/local/bin/fortiaigate-prep-status

stage 'validate host and configuration'
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 22.04 ]]
[[ "$(dpkg --print-architecture)" == amd64 ]]
[[ -f "$CONFIG" && ! -L "$CONFIG" ]]
[[ "$(stat -c %u "$CONFIG")" == 0 ]]
config_mode=$(stat -c %a "$CONFIG")
(( (8#$config_mode & 8#022) == 0 ))
config_values=$(python3 - "$CONFIG" <<'PY'
import hashlib,json,re,sys,urllib.parse
raw=open(sys.argv[1],'rb').read()
c=json.loads(raw)
if not isinstance(c,dict): raise SystemExit('Configuration must be a JSON object.')
edition=c.get('edition','cpu')
if edition not in ('cpu','gpu'): raise SystemExit('edition must be cpu or gpu.')
cloud=c.get('cloud')
if cloud not in ('aws','azure','home'): raise SystemExit('cloud must be aws, azure or home.')
region=c.get('region','us-east-1')
if not isinstance(region,str) or not re.fullmatch(r'[a-z]{2}(?:-gov)?-[a-z]+-\d',region): raise SystemExit('Invalid S3 region.')
key='release_s3_uri' if cloud=='aws' else 'release_https_base'
base=c.get(key,'')
if not isinstance(base,str) or not base or len(base)>2048 or any(ord(ch)<32 for ch in base): raise SystemExit('Invalid release location.')
if cloud=='aws':
    if not re.fullmatch(r's3://[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]/[A-Za-z0-9_./-]+/?',base): raise SystemExit('Use an s3://bucket/release-prefix/ URI.')
    if any(x in ('','..','.') for x in base.rstrip('/').split('/')[3:]): raise SystemExit('Invalid S3 prefix.')
else:
    u=urllib.parse.urlsplit(base)
    if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment: raise SystemExit('Use a public HTTPS release folder URL without credentials/query/fragment.')
print(cloud)
print(region)
print(base.rstrip('/'))
print(edition)
print(hashlib.sha256(raw).hexdigest())
PY
)
mapfile -t values <<<"$config_values"
CLOUD=${values[0]}
REGION=${values[1]}
RELEASE=${values[2]}
EDITION=${values[3]}
CONFIG_SHA256=${values[4]}
printf '%s\n' "$EDITION" >"$STATE/edition"
chmod 0644 "$STATE/edition"

# Re-running a completed preparation never imports, deploys or changes the app.
if [[ -f "$STATE/READY" ]] && grep -Fxq "version=$VERSION" "$STATE/READY" && grep -Fxq "config_sha256=$CONFIG_SHA256" "$STATE/READY"; then
  rm -f "$STATE/RUNNING"
  printf 'Common host preparation already completed. Check fortiaigate-prep-status before continuing.\n'
  exit 0
fi
[[ ! -f "$DATA_ROOT/deployment/.env" ]] || { printf 'STOP: an application configuration already exists. Host preparation will not replace an existing deployment.\n' >&2; false; }
# Refuse to upgrade/reconfigure Docker around unrelated containers, including
# stopped ones. A fresh-cloud first boot has none; no workloads are removed.
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    existing_containers=$(docker ps -aq)
    [[ -z "$existing_containers" ]] || { printf 'STOP: existing Docker containers found. This preparation path requires a fresh host.\n' >&2; false; }
  elif [[ -d /var/lib/docker/containers ]] && find /var/lib/docker/containers -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    printf 'STOP: Docker has existing container data and its daemon is unavailable. Review the host before preparation.\n' >&2
    false
  fi
fi
rm -f "$STATE/READY" "$STATE/FAILED"
WORK=$(mktemp -d /var/tmp/fortiaigate-prep.XXXXXXXX)
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l AWS_PAGER='' AWS_CLI_AUTO_PROMPT=off

stage 'repair signed Docker repository'
backup="$STATE/apt-source-backups/$(date -u +%Y%m%dT%H%M%SZ)"
for name in docker.list docker.sources; do
  file="/etc/apt/sources.list.d/$name"
  if [[ -f "$file" ]]; then install -d -m 0700 "$backup"; mv -- "$file" "$backup/"; fi
done
retry apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 update
retry apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 install -y ca-certificates curl unzip jq openssl python3 gnupg less groff util-linux
install -m 0755 -d /etc/apt/keyrings
curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 120 \
  https://download.docker.com/linux/ubuntu/gpg --output "$WORK/docker.asc"
grep -q '^-----BEGIN PGP PUBLIC KEY BLOCK-----' "$WORK/docker.asc"
install -m 0644 "$WORK/docker.asc" /etc/apt/keyrings/docker.asc
printf '%s\n' 'Types: deb' 'URIs: https://download.docker.com/linux/ubuntu' 'Suites: jammy' \
  'Components: stable' 'Architectures: amd64' 'Signed-By: /etc/apt/keyrings/docker.asc' \
  >/etc/apt/sources.list.d/docker.sources
retry apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 update

stage 'install and verify Docker and Compose'
retry apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 install -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
systemctl is-active --quiet docker
docker version
compose_version=$(docker compose version --short | sed 's/^v//' | cut -d- -f1)
dpkg --compare-versions "$compose_version" ge 2.23.1
retry docker run --rm hello-world

stage 'install and verify AWS CLI v2'
curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 900 \
  https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip --output "$WORK/awscliv2.zip"
unzip -q "$WORK/awscliv2.zip" -d "$WORK"
if [[ -d /usr/local/aws-cli/v2 ]]; then "$WORK/aws/install" --update; else "$WORK/aws/install"; fi
/usr/local/bin/aws --version
# Never configure AWS access keys. AWS uses its EC2 role; Azure fetches public HTTPS objects.

stage 'download and check the CPU release archives'
install -d -m 0755 "$ROOT/Images" "$ROOT/Installer"
download_file() {
  local relative=$1 destination=$2 temp="$WORK/download"
  rm -f "$temp"
  if [[ "$CLOUD" == aws ]]; then
    if ! /usr/local/bin/aws s3 cp "$RELEASE/$relative" "$temp" --region "$REGION" \
      --only-show-errors --no-progress --cli-connect-timeout 15 --cli-read-timeout 60; then
      rm -f "$temp"; return 1
    fi
  else
    if ! curl --fail --location --show-error --retry 3 --connect-timeout 15 --max-time 1800 \
      "$RELEASE/$relative" --output "$temp"; then rm -f "$temp"; return 1; fi
  fi
  if [[ ! -s "$temp" ]]; then rm -f "$temp"; return 1; fi
  chmod 0644 "$temp"
  mv -f -- "$temp" "$destination"
}
for component in api webui llm-gateway logd license_manager guardrail guardrail-scanner; do
  base="FAIG_$component-$BUILD.tar"
  chosen=
  for candidate in "$base" "$base.gz"; do
    dest="$ROOT/Images/$candidate"
    if [[ -s "$dest" ]] && tar -tf "$dest" >/dev/null 2>&1; then chosen="$dest"; break; fi
  done
  if [[ -z "$chosen" ]]; then
    for candidate in "$base" "$base.gz"; do
      dest="$ROOT/Images/$candidate"
      if download_file "Images/$candidate" "$dest"; then
        tar -tf "$dest" >/dev/null
        chosen="$dest"
        break
      fi
    done
  fi
  [[ -n "$chosen" ]] || { printf 'Missing required image: %s[.gz]\n' "$base" >&2; false; }
  printf 'Checked image: %s\n' "$(basename "$chosen")"
done
installer="$ROOT/Installer/$INSTALLER"
if [[ ! -s "$installer" ]] || ! printf '%s  %s\n' "$INSTALLER_SHA256" "$installer" | sha256sum --check --status; then
  download_file "Installer/$INSTALLER" "$installer"
fi
printf '%s  %s\n' "$INSTALLER_SHA256" "$installer" | sha256sum --check
# Extract only these reviewed members, never the image TAR contents.
tar --no-same-owner --no-same-permissions -xzf "$installer" -C "$ROOT/Installer" deploy-docker-compose.sh USER-GUIDE.md
chown root:root "$ROOT/Installer/deploy-docker-compose.sh" "$ROOT/Installer/USER-GUIDE.md"
chmod 0755 "$ROOT/Installer/deploy-docker-compose.sh"
chmod 0644 "$ROOT/Installer/USER-GUIDE.md"
bash -n "$ROOT/Installer/deploy-docker-compose.sh"
"$ROOT/Installer/deploy-docker-compose.sh" --self-test

docker_root=$(docker info --format '{{.DockerRootDir}}')
free_kib=$(df -Pk "$docker_root" | awk 'NR==2 {print $4}')
(( free_kib >= 60 * 1024 * 1024 )) || { printf 'STOP: Docker needs at least 60 GiB free after staging.\n' >&2; false; }

stage 'install the interactive handoff'
cat > /usr/local/bin/fortiaigate-install <<'HANDOFF'
#!/usr/bin/env bash
# Configure and deploy interactively as the connected non-root operator.
set -euo pipefail
(( EUID != 0 )) || { printf 'Run fortiaigate-install as your normal SSM/SSH or home Ubuntu user, without sudo.\n' >&2; exit 1; }
[[ -t 0 ]] || { printf 'An interactive terminal is required.\n' >&2; exit 1; }
fortiaigate-prep-status
state=/opt/fortiaigate/Installer/faig_deployment_assistant_data
[[ ! -L "$state" ]] || { printf 'Refusing a symbolic-link state directory.\n' >&2; exit 1; }
if [[ ! -d "$state" ]]; then
  sudo install -d -m 0700 -o "$(id -un)" -g "$(id -gn)" "$state"
fi
[[ -O "$state" ]] || { printf 'Assistant state belongs to a different operator. Review ownership before continuing.\n' >&2; exit 1; }
cd /opt/fortiaigate/Installer
exec /bin/bash ./deploy-docker-compose.sh --data-root "$state"
HANDOFF
chmod 0755 /usr/local/bin/fortiaigate-install
printf 'version=%s\nconfig_sha256=%s\n' "$VERSION" "$CONFIG_SHA256" >"$STATE/READY"
chmod 0644 "$STATE/READY"
rm -f "$STATE/FAILED" "$STATE/RUNNING"
printf '\nPASS: common host tools, seven core images and installer are prepared. No FortiAIGate images were imported or deployed.\n'
printf 'After fortiaigate-prep-status reports READY, connect as the non-root operator and run: fortiaigate-install\n'
