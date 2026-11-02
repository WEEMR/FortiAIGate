#!/usr/bin/env bash
# Generated GPU HTTPS entry point. Edit bootstrap.sh.in and release-config.json.
# Download this file, then run bash on the saved file to preserve interactive input.
set -euo pipefail

forti_base=https://raw.githubusercontent.com/WEEMR/FortiAIGate/gpu-__VERSION__/scripts/AWS/GPU
forti_manifest_url=https://raw.githubusercontent.com/WEEMR/FortiAIGate/gpu-2026-11-02.1/scripts/AWS/GPU/releases/2026-11-02.1/manifest.json
forti_expected_release=2026-11-02.1
forti_action=menu
forti_child_arg=${1:-}
export AWS_PAGER="" AWS_CLI_AUTO_PROMPT=off

printf '\nFortiAIGate 8.0.2 — AWS GPU lab\n'
case "$forti_action" in
    menu)
        if (( $# != 0 )); then
            printf 'The GPU menu does not accept arguments. No script was started.\n' >&2; exit 1
        fi
        printf '\n1) Create\n2) Destroy\n3) Connect\n4) Restart / resume (deadline unchanged)\n5) Extend by 8 hours\n6) Remove shared cleanup service (when no labs remain)\n0) Exit\n\n'
        while true; do
            printf 'Choose 1, 2, 3, 4, 5, 6, or 0: '
            if ! read -r forti_choice; then
                printf '\nCancelled. No script was started.\n'; exit 0
            fi
            case "$forti_choice" in
                1) forti_action=create; break ;;
                2) forti_action=destroy; break ;;
                3) forti_action=create; forti_child_arg=--connect; break ;;
                4) forti_action=create; forti_child_arg=--restart; break ;;
                5) forti_action=create; forti_child_arg=--extend; break ;;
                6) forti_action=create; forti_child_arg=--remove-cleanup; break ;;
                0) printf 'Cancelled. No script was started.\n'; exit 0 ;;
                *) printf 'Enter 1, 2, 3, 4, 5, 6, or 0.\n' ;;
            esac
        done
        ;;
    create)
        if (( $# > 1 )); then
            printf 'Use one GPU action at a time. No script was started.\n' >&2; exit 1
        fi
        if (( $# == 1 )); then
            case "$1" in --connect|--restart|--extend|--remove-cleanup) ;;
                *) printf 'Invalid GPU action. No script was started.\n' >&2; exit 1 ;;
            esac
        fi
        ;;
    destroy)
        if (( $# != 0 )); then
            printf 'GPU Destroy does not accept arguments. No script was started.\n' >&2; exit 1
        fi
        ;;
    *) printf 'Invalid GPU action. No script was started.\n' >&2; exit 1 ;;
esac
case "$forti_action" in
    create) forti_script_name=create_fortiaigate_gpu_aws.sh ;;
    destroy) forti_script_name=destroy_fortiaigate_gpu_aws.sh ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
    printf 'Python 3 is unavailable. Open a new AWS CloudShell terminal tab.\n' >&2; exit 1
fi
forti_aws=""
if [[ -n "${FORTIAIGATE_AWS_CLI:-}" ]]; then
    forti_candidates=("$FORTIAIGATE_AWS_CLI")
else
    forti_candidates=("$(command -v aws || true)" /usr/local/bin/aws /usr/bin/aws
        /usr/local/aws-cli/v2/current/bin/aws "$HOME/.local/bin/aws" "$HOME/usr/local/bin/aws")
fi
for forti_candidate in "${forti_candidates[@]}"; do
    [[ -n "$forti_candidate" && -f "$forti_candidate" && -x "$forti_candidate" ]] || continue
    if python3 -c 'import re,subprocess,sys; p=subprocess.run([sys.argv[1],"--version"],capture_output=True,text=True,timeout=10); sys.exit(0 if p.returncode==0 and re.search(r"\baws-cli/2\.[^\s]+",p.stdout+"\n"+p.stderr) else 1)' "$forti_candidate" 2>/dev/null; then
        forti_aws=$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).absolute())' "$forti_candidate")
        break
    fi
done
if [[ -z $forti_aws ]]; then
    printf 'A working AWS CLI v2 could not be found. Open a new AWS CloudShell terminal tab.\n' >&2; exit 1
fi

forti_workspace=$(mktemp -d "${TMPDIR:-/tmp}/fortiaigate-gpu-launch.XXXXXX")
trap 'rm -rf -- "$forti_workspace"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
forti_fetch() {
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --retry 3 --connect-timeout 15 --max-time 180 --max-filesize 1048576 "$1" -o "$2"
}
printf '\nChecking the approved GPU release...\n'
if ! forti_fetch "$forti_manifest_url" "$forti_workspace/manifest.json"; then
    printf 'Release manifest download failed. No script was started.\n' >&2; exit 1
fi
if ! python3 - "$forti_workspace/manifest.json" "$forti_script_name" "$forti_expected_release" > "$forti_workspace/selection" <<'FORTI_MANIFEST_PY'
"""Strict GPU release manifests shared by the publisher and HTTPS bootstraps."""

import datetime
import hashlib
import json
from pathlib import Path
import re
import sys

RELEASE_FILES = (
    'create_fortiaigate_gpu_aws.sh',
    'destroy_fortiaigate_gpu_aws.sh',
    'fortiaigate_gpu_aws_launcher.sh',
    'user_data/prepare_fortiaigate_gpu.sh',
    'user_data/prepare_fortiaigate_cpu.sh',
    'README.txt',
    'required-fortinet-files.txt',
    'FortiAIGate_AWS_GPU_Lab_Scripts.zip',
    'SHA256SUMS',
)
VERSION_PATTERN = r'20\d{2}-\d{2}-\d{2}\.\d{1,4}'
MAX_SCRIPT_BYTES = 1024 * 1024
MAX_MANIFEST_BYTES = 64 * 1024


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate manifest key: ' + key)
        result[key] = value
    return result


def validate_version(version):
    if not isinstance(version, str) or not re.fullmatch(VERSION_PATTERN, version):
        raise ValueError('Invalid GPU release version.')
    datetime.date.fromisoformat(version.split('.', 1)[0])
    return version


def validate_manifest(raw, expected_version=''):
    if len(raw) > MAX_MANIFEST_BYTES:
        raise ValueError('Release manifest exceeds 64 KiB.')
    data = json.loads(raw, object_pairs_hook=unique_keys)
    if (not isinstance(data, dict)
            or set(data) != {'schema_version', 'edition', 'version', 'files'}
            or type(data['schema_version']) is not int or data['schema_version'] != 1
            or data['edition'] != 'gpu'
            or not isinstance(data['files'], dict)
            or set(data['files']) != set(RELEASE_FILES)):
        raise ValueError('Invalid GPU release manifest.')
    validate_version(data['version'])
    if expected_version and data['version'] != expected_version:
        raise ValueError('GPU manifest differs from the expected release version.')
    for entry in data['files'].values():
        if (not isinstance(entry, dict) or set(entry) != {'sha256', 'size'}
                or not isinstance(entry['sha256'], str)
                or not re.fullmatch(r'[0-9a-f]{64}', entry['sha256'])
                or type(entry['size']) is not int
                or not 0 < entry['size'] <= MAX_SCRIPT_BYTES):
            raise ValueError('Invalid file checksum or size in GPU release manifest.')
    return data


def verify_file(raw, entry):
    if len(raw) != entry['size'] or hashlib.sha256(raw).hexdigest() != entry['sha256']:
        raise ValueError('Downloaded file differs from the approved release checksum/size.')


if __name__ == '__main__':
    try:
        manifest = validate_manifest(Path(sys.argv[1]).read_bytes(), sys.argv[3])
        entry = manifest['files'][sys.argv[2]]
        print(manifest['version'], entry['sha256'], entry['size'])
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        sys.exit('GPU release verification failed: ' + str(error))
FORTI_MANIFEST_PY
then
    printf 'No script was started.\n' >&2; exit 1
fi
read -r forti_release forti_sha forti_size < "$forti_workspace/selection"
forti_release_base=${forti_base//__VERSION__/$forti_release}
forti_source="$forti_release_base/releases/$forti_release/$forti_script_name"
forti_download="$forti_workspace/$forti_script_name"
printf 'GPU release: %s\nDownloading: %s\n' "$forti_release" "$forti_source"
if ! forti_fetch "$forti_source" "$forti_download"; then
    printf 'Script download failed. No script was started.\n' >&2; exit 1
fi
if ! python3 - "$forti_download" "$forti_sha" "$forti_size" <<'FORTI_CHECKSUM_PY'
import hashlib,sys
from pathlib import Path
raw=Path(sys.argv[1]).read_bytes()
if len(raw)!=int(sys.argv[3]) or hashlib.sha256(raw).hexdigest()!=sys.argv[2]:
    sys.exit('Script checksum/size verification failed. No script was started.')
FORTI_CHECKSUM_PY
then exit 1; fi
if ! bash -n "$forti_download"; then
    printf 'The downloaded script has a shell syntax error. No script was started.\n' >&2; exit 1
fi
mkdir "$forti_workspace/bin"
ln -s "$forti_aws" "$forti_workspace/bin/aws"
printf 'Verified SHA-256. Running %s\n\n' "$forti_script_name"
if (
    cd "$forti_workspace" || exit 1
    export PATH="$forti_workspace/bin:$PATH"
    export FORTIAIGATE_AWS_CLI="$forti_aws"
    export FORTIAIGATE_SCRIPT_DIR="$forti_workspace"
    if [[ -n $forti_child_arg ]]; then
        bash "$forti_download" "$forti_child_arg"
    else
        bash "$forti_download"
    fi
); then forti_status=0; else forti_status=$?; fi
exit "$forti_status"
