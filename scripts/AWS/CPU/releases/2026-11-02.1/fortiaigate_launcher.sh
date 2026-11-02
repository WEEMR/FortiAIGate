#!/usr/bin/env bash
# Generated CPU HTTPS entry point. Edit bootstrap.sh.in and release-config.json.
# Download this file, then run bash on the saved file to preserve interactive input.
set -euo pipefail

forti_base=https://raw.githubusercontent.com/WEEMR/FortiAIGate/cpu-2026-11-02.1/scripts/AWS/CPU/releases/2026-11-02.1
forti_manifest_url=https://raw.githubusercontent.com/WEEMR/FortiAIGate/cpu-2026-11-02.1/scripts/AWS/CPU/releases/2026-11-02.1/manifest.json
forti_expected_release=2026-11-02.1
forti_action=menu
export AWS_PAGER="" AWS_CLI_AUTO_PROMPT=off

printf '\nFortiAIGate CPU\n'
if [[ $forti_action == menu ]]; then
    printf '\n1) Create\n2) Destroy\n0) Exit\n\n'
    while true; do
        printf 'Choose 1 or 2 (0 to exit): '
        if ! read -r forti_choice; then
            printf '\nCancelled. No script was started.\n'; exit 0
        fi
        case "$forti_choice" in
            1) forti_action=create; break ;;
            2) forti_action=destroy; break ;;
            0) printf 'Cancelled. No script was started.\n'; exit 0 ;;
            *) printf 'Enter 1, 2, or 0.\n' ;;
        esac
    done
fi
case "$forti_action" in
    create) forti_script_name=create_fortiaigate_vpc.sh ;;
    destroy) forti_script_name=destroy_fortiaigate_vpc.sh ;;
    *) printf 'Invalid CPU action. No script was started.\n' >&2; exit 1 ;;
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

forti_workspace=$(mktemp -d "${TMPDIR:-/tmp}/fortiaigate-launch.XXXXXX")
trap 'rm -rf -- "$forti_workspace"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
forti_fetch() {
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --retry 3 --connect-timeout 15 --max-time 180 --max-filesize 1048576 "$1" -o "$2"
}
printf '\nChecking the approved CPU release...\n'
if ! forti_fetch "$forti_manifest_url" "$forti_workspace/manifest.json"; then
    printf 'Release manifest download failed. No script was started.\n' >&2; exit 1
fi
if ! python3 - "$forti_workspace/manifest.json" "$forti_script_name" "$forti_expected_release" > "$forti_workspace/selection" <<'FORTI_MANIFEST_PY'
"""Manifest validation shared by the publisher and embedded S3 bootstraps."""

import hashlib
import json
from pathlib import Path
import re
import sys

RELEASE_FILES = (
    'create_fortiaigate_vpc.sh', 'destroy_fortiaigate_vpc.sh',
    'fortiaigate_launcher.sh', 'user_data/prepare_fortiaigate_cpu.sh',
)
VERSION_PATTERN = r'20\d{2}-\d{2}-\d{2}\.\d{1,4}'
MAX_SCRIPT_BYTES = 1024 * 1024


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate manifest key: ' + key)
        result[key] = value
    return result


def validate_manifest(raw, expected_version=''):
    if len(raw) > 65536:
        raise ValueError('Release manifest exceeds 64 KiB.')
    data = json.loads(raw, object_pairs_hook=unique_keys)
    if (not isinstance(data, dict)
            or set(data) != {'schema_version', 'edition', 'version', 'files'}
            or type(data['schema_version']) is not int or data['schema_version'] != 1
            or data['edition'] != 'cpu'
            or not isinstance(data['version'], str)
            or not re.fullmatch(VERSION_PATTERN, data['version'])
            or (expected_version and data['version'] != expected_version)
            or not isinstance(data['files'], dict)
            or set(data['files']) != set(RELEASE_FILES)):
        raise ValueError('Invalid CPU release manifest or unexpected release version.')
    for entry in data['files'].values():
        if (not isinstance(entry, dict) or set(entry) != {'sha256', 'size'}
                or not isinstance(entry['sha256'], str)
                or not re.fullmatch(r'[0-9a-f]{64}', entry['sha256'])
                or type(entry['size']) is not int
                or not 0 < entry['size'] <= MAX_SCRIPT_BYTES):
            raise ValueError('Invalid script checksum or size in release manifest.')
    return data


def verify_file(raw, entry):
    if len(raw) != entry['size'] or hashlib.sha256(raw).hexdigest() != entry['sha256']:
        raise ValueError('Downloaded file differs from the approved release checksum/size.')


if __name__ == '__main__':
    try:
        manifest = validate_manifest(Path(sys.argv[1]).read_bytes(), sys.argv[3])
        entry = manifest['files'][sys.argv[2]]
        print(manifest['version'], entry['sha256'], entry['size'])
    except (OSError, ValueError, KeyError, IndexError) as error:
        sys.exit('Release verification failed: ' + str(error))
FORTI_MANIFEST_PY
then
    printf 'No script was started.\n' >&2; exit 1
fi
read -r forti_release forti_sha forti_size < "$forti_workspace/selection"
forti_release_base="${forti_base//__VERSION__/$forti_release}"
forti_source="$forti_release_base/$forti_script_name"
forti_download="$forti_workspace/$forti_script_name"
printf 'CPU release: %s\nDownloading: %s\n' "$forti_release" "$forti_source"
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
    bash "$forti_download"
); then forti_status=0; else forti_status=$?; fi
exit "$forti_status"
