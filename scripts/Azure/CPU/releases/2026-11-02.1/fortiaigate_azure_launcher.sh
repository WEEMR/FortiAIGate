#!/usr/bin/env bash
# Generated Azure CPU launcher. Edit launcher.sh.in and release-config.json.
set -euo pipefail
readonly forti_version=2026-11-02.1
readonly forti_create_sha=7a50513566aeaab5f9ab281297cf6ab40719a297adbaf3e79d54f72bb14d9329
readonly forti_create_size=44884
readonly forti_destroy_sha=9ef2f39dee9bd0631848f6209578bc35a8c45b1a1651202984da8a3509dcb1f3
readonly forti_destroy_size=31299
forti_base="${FORTIAIGATE_AZURE_SCRIPTS_URL:-https://raw.githubusercontent.com/WEEMR/FortiAIGate/azure-cpu-2026-11-02.1/scripts/Azure/CPU/releases/2026-11-02.1}"
forti_base="${forti_base%/}"
case "$forti_base" in https://?*) ;; *) printf 'Use an HTTPS scripts URL.\n' >&2; exit 1 ;; esac
command -v az >/dev/null 2>&1 || { printf 'Run this in Azure CloudShell Bash.\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'Python 3 is required.\n' >&2; exit 1; }
printf '\nFortiAIGate Azure CPU lab · %s\n\n1) Create\n2) Destroy\n3) Connect with SSH\n4) Repair SSH / HTTPS access\n0) Exit\n\n' "$forti_version"
forti_action=run
while true; do
    read -r -p 'Choose 1, 2, 3, 4, or 0: ' forti_choice || exit 0
    case "$forti_choice" in
        1) forti_script=create_fortiaigate_azure.sh; break ;;
        2) forti_script=destroy_fortiaigate_azure.sh; break ;;
        3) forti_script=create_fortiaigate_azure.sh; forti_action=connect; break ;;
        4) forti_script=create_fortiaigate_azure.sh; forti_action=repair-access; break ;;
        0) exit 0 ;;
        *) printf 'Enter 1, 2, 3, 4, or 0.\n' ;;
    esac
done
if [[ "$forti_script" == create_fortiaigate_azure.sh ]]; then
    forti_sha="$forti_create_sha"; forti_size="$forti_create_size"
else
    forti_sha="$forti_destroy_sha"; forti_size="$forti_destroy_size"
fi
forti_dir=$(mktemp -d "${TMPDIR:-/tmp}/fortiaigate-azure-launch.XXXXXX")
trap 'rm -rf -- "$forti_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '\nDownloading %s\n' "$forti_script"
curl --fail --location --show-error --retry 3 --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 15 --max-time 180 --max-filesize 1048576 \
    "$forti_base/$forti_script" --output "$forti_dir/$forti_script"
python3 - "$forti_dir/$forti_script" "$forti_sha" "$forti_size" <<'FORTI_SHA_PY'
import hashlib,sys
from pathlib import Path
raw=Path(sys.argv[1]).read_bytes()
if len(raw)!=int(sys.argv[3]) or hashlib.sha256(raw).hexdigest()!=sys.argv[2]:
    sys.exit('Script checksum/size verification failed. Nothing was run.')
FORTI_SHA_PY
bash -n "$forti_dir/$forti_script"
if ! grep -Fqx "SCRIPT_VERSION = \"$forti_version\"" "$forti_dir/$forti_script"; then
    printf 'Version mismatch: expected %s. Nothing was run.\n' "$forti_version" >&2
    exit 1
fi
if [[ "$forti_action" == connect ]]; then
    bash "$forti_dir/$forti_script" --connect
elif [[ "$forti_action" == repair-access ]]; then
    bash "$forti_dir/$forti_script" --repair-access
else
    bash "$forti_dir/$forti_script"
fi
