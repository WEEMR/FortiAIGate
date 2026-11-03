#!/usr/bin/env bash
# Read-only status wait used by SSM / Azure CustomScript when progress display is disabled.
set -euo pipefail
edition=${1:?cpu, gpu or ollama required}
case "$edition" in
  cpu) status_dir=/var/lib/fortiaigate-prep; marker=READY ;;
  gpu) status_dir=/var/lib/fortiaigate-prep; marker=GPU_READY ;;
  ollama) status_dir=/var/lib/ollama-lab; marker=READY ;;
  *) printf 'Unknown preparation edition: %s\n' "$edition" >&2; exit 2 ;;
esac
for ((attempt=0;attempt<540;attempt++)); do
  if [[ "$edition" == ollama && -f "$status_dir/status.json" ]]; then
    state=$(python3 -c 'import json; print(json.load(open("/var/lib/ollama-lab/status.json")).get("state", ""))' 2>/dev/null || true)
    if [[ "$state" == failed ]]; then cat "$status_dir/status.json" >&2; exit 1; fi
    if [[ "$state" == ready || "$state" == configured ]]; then printf 'PASS: Ollama model backend ready; gateway configuration may still be pending.\n'; exit 0; fi
  fi
  if [[ -f "$status_dir/FAILED" ]]; then cat "$status_dir/FAILED" >&2; exit 1; fi
  if [[ "$edition" == gpu && -f "$status_dir/GPU_FAILED" ]]; then cat "$status_dir/GPU_FAILED" >&2; exit 1; fi
  if [[ -f "$status_dir/$marker" ]]; then printf 'PASS: %s preparation READY.\n' "$edition"; exit 0; fi
  sleep 10
done
printf 'STOP: %s preparation did not become ready within 90 minutes.\n' "$edition" >&2
exit 124
