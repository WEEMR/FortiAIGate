#!/usr/bin/env bash
# Wait in the operator's terminal, then open the interactive Deployment Assistant.
# Run the saved file with bash; do not pipe this script to bash or run with sudo.
set -euo pipefail

usage() {
  printf 'Usage: bash wait_fortiaigate_install.sh [TIMEOUT_SECONDS]\nDefault: 1800 seconds; valid range: 1-86400.\n' >&2
}
if (( $# > 1 )); then usage; exit 2; fi
wait_timeout=${1:-1800}
if [[ ! "$wait_timeout" =~ ^[1-9][0-9]{0,4}$ ]] || (( wait_timeout > 86400 )); then
  usage
  exit 2
fi
(( EUID != 0 )) || { printf 'Run this command as your normal Ubuntu SSM/SSH user, without sudo.\n' >&2; exit 1; }
[[ -t 0 ]] || { printf 'An interactive terminal is required. Save this script, then run it with bash.\n' >&2; exit 1; }

status_helper=/usr/local/bin/fortiaigate-prep-status
install_helper=/usr/local/bin/fortiaigate-install
trap 'printf "\nWaiting cancelled. Host preparation continues in the background.\n" >&2; exit 130' INT
trap 'printf "\nWaiting stopped. Host preparation continues in the background.\n" >&2; exit 143' TERM
wait_started=$SECONDS

while :; do
  wait_detail='Waiting for the host preparation helpers to be installed.'
  if [[ -x "$status_helper" ]]; then
    if wait_detail=$("$status_helper" 2>&1); then
      if [[ "$wait_detail" != READY:* ]]; then
        printf 'Preparation returned an unexpected readiness response:\n%s\nInstallation was not started.\n' "$wait_detail" >&2
        exit 1
      fi
      if [[ -x "$install_helper" ]]; then
        printf '%s\nPreparation completed after %s seconds. Starting the interactive installer...\n' "$wait_detail" "$(( SECONDS - wait_started ))"
        exec "$install_helper"
      fi
      wait_detail='Files are ready; waiting for the installation helper to be installed.'
    else
      wait_status=$?
      case "$wait_status" in
        1)
          printf '%s\nPreparation failed. Installation was not started.\n' "$wait_detail" >&2
          exit 1
          ;;
        2) ;; # The status helper reports PENDING/RUNNING until CPU or GPU is ready.
        *)
          printf 'Could not check preparation (exit %s):\n%s\nInstallation was not started.\n' "$wait_status" "$wait_detail" >&2
          exit 1
          ;;
      esac
    fi
  fi

  wait_elapsed=$(( SECONDS - wait_started ))
  if (( wait_elapsed >= wait_timeout )); then
    printf 'Timed out after %s seconds. Installation was not started.\nCheck: fortiaigate-prep-status\nLogs: sudo tail -n 100 /var/log/fortiaigate-prep.log\nFor GPU: sudo tail -n 100 /var/log/fortiaigate-gpu-prep.log\nAfter resolving the issue, run this command again.\n' "$wait_elapsed" >&2
    exit 124
  fi
  printf 'Please wait... %s seconds elapsed.\n%s\n' "$wait_elapsed" "$wait_detail"
  wait_remaining=$(( wait_timeout - wait_elapsed ))
  wait_interval=10
  if (( wait_remaining < wait_interval )); then wait_interval=$wait_remaining; fi
  sleep "$wait_interval"
done
