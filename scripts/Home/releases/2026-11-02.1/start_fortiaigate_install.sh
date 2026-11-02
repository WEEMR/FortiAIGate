#!/usr/bin/env bash
# Download the reviewed wait helper and keep the operator's terminal attached.
set -euo pipefail
umask 077

if (( $# > 1 )); then
  printf 'Usage: bash faig-start.sh [TIMEOUT_SECONDS]\n' >&2
  exit 2
fi
start_timeout=${1:-1800}
if [[ ! "$start_timeout" =~ ^[1-9][0-9]{0,4}$ ]] || (( start_timeout > 86400 )); then
  printf 'Timeout must be a whole number from 1 to 86400 seconds.\n' >&2
  exit 2
fi
(( EUID != 0 )) || { printf 'Run this command as your normal Ubuntu SSM/SSH user, without sudo.\n' >&2; exit 1; }
[[ -t 0 ]] || { printf 'An interactive terminal is required. Save start.sh, then run it with bash.\n' >&2; exit 1; }

wait_url=https://raw.githubusercontent.com/WEEMR/FortiAIGate/shared-2026-11-02.1/scripts/Home/releases/2026-11-02.1/wait_fortiaigate_install.sh
wait_sha256=3b9b166b370ab476f7fd7ee44e9e61773a2bf50bff3ea1e8b74be64417d89308
wait_download=$(mktemp "${TMPDIR:-/tmp}/faig-wait.XXXXXXXX")
trap 'rm -f -- "$wait_download"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! curl --fail --location --silent --show-error \
  --proto '=https' --proto-redir '=https' \
  --connect-timeout 15 --max-time 120 --retry 2 --retry-max-time 120 \
  --output "$wait_download" "$wait_url"; then
  printf 'Could not download the preparation wait helper. Installation was not started.\n' >&2
  exit 1
fi
if ! printf '%s  %s\n' "$wait_sha256" "$wait_download" | sha256sum --check --status; then
  printf 'The preparation wait helper failed its SHA-256 check. Installation was not started. Download start.sh again before retrying.\n' >&2
  exit 1
fi
/bin/bash "$wait_download" "$start_timeout"
