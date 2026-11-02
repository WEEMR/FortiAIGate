#!/usr/bin/env bash
# Version: 2026-11-02.1
set -euo pipefail
forti_base="${FORTIAIGATE_GPU_AZURE_SCRIPTS_URL:-https://raw.githubusercontent.com/WEEMR/FortiAIGate/azure-rtx-2026-11-02.1/scripts/Azure/RTX/releases/2026-11-02.1}"
forti_base="${forti_base%/}"
case "$forti_base" in https://?*) ;; *) printf 'Use an HTTPS scripts URL.\n' >&2; exit 1 ;; esac
command -v az >/dev/null 2>&1 || { printf 'Use Azure CloudShell Bash.\n' >&2; exit 1; }
printf '\nFortiAIGate Azure GPU lab · 2026-11-02.1\n\n1) Create\n2) Destroy\n3) Connect with SSH\n4) Repair SSH / HTTPS access\n5) Restart / resume (new 2 hours)\n6) Extend by 2 hours\n0) Exit\n\n'
forti_action=run
while true; do
  read -r -p 'Choose 1, 2, 3, 4, 5, 6, or 0: ' forti_choice || exit 0
  case "$forti_choice" in
    1) forti_script=create_fortiaigate_gpu_azure.sh; forti_sha=e862f2b6ed89f5c75fd8fd8f9e4d72d0785a7570a5b5a11f168153475442b20b; break ;;
    2) forti_script=destroy_fortiaigate_gpu_azure.sh; forti_sha=3b21b0e8e7b392235bc666e0761af0a1486bde58e095592c57054107e2c171de; break ;;
    3) forti_script=create_fortiaigate_gpu_azure.sh; forti_sha=e862f2b6ed89f5c75fd8fd8f9e4d72d0785a7570a5b5a11f168153475442b20b; forti_action=connect; break ;;
    4) forti_script=create_fortiaigate_gpu_azure.sh; forti_sha=e862f2b6ed89f5c75fd8fd8f9e4d72d0785a7570a5b5a11f168153475442b20b; forti_action=repair-access; break ;;
    5) forti_script=create_fortiaigate_gpu_azure.sh; forti_sha=e862f2b6ed89f5c75fd8fd8f9e4d72d0785a7570a5b5a11f168153475442b20b; forti_action=restart; break ;;
    6) forti_script=create_fortiaigate_gpu_azure.sh; forti_sha=e862f2b6ed89f5c75fd8fd8f9e4d72d0785a7570a5b5a11f168153475442b20b; forti_action=extend; break ;;
    0) exit 0 ;;
    *) printf 'Enter 1, 2, 3, 4, or 0.\n' ;;
  esac
done
forti_dir=$(mktemp -d "${TMPDIR:-/tmp}/fortiaigate-azure-gpu-launch.XXXXXXXX")
trap 'rm -rf -- "$forti_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '\nDownloading %s\n' "$forti_script"
curl --fail --location --show-error --retry 3 --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 300 \
  "$forti_base/$forti_script" --output "$forti_dir/$forti_script"
printf '%s  %s\n' "$forti_sha" "$forti_dir/$forti_script" | sha256sum -c -
bash -n "$forti_dir/$forti_script"
if [[ "$forti_action" == connect ]]; then
  bash "$forti_dir/$forti_script" --connect
elif [[ "$forti_action" == repair-access ]]; then
  bash "$forti_dir/$forti_script" --repair-access
elif [[ "$forti_action" == restart ]]; then
  bash "$forti_dir/$forti_script" --restart
elif [[ "$forti_action" == extend ]]; then
  bash "$forti_dir/$forti_script" --extend
else
  bash "$forti_dir/$forti_script"
fi
