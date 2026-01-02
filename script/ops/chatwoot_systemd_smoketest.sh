#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: bash script/ops/chatwoot_systemd_smoketest.sh [options]

Runs a minimal Phase 4 smoke test for systemd timers:
- chatwoot-backup.timer enabled + active
- chatwoot-healthcheck.timer enabled + active

Options:
  --backup-only            Check only chatwoot-backup.timer
  --healthcheck-only       Check only chatwoot-healthcheck.timer
  -h, --help               Show help

Tip:
  If a timer is missing/disabled, install it with:
    bash script/ops/chatwoot_systemd_install.sh
EOF
}

check_backup=1
check_healthcheck=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-only)
      check_backup=1
      check_healthcheck=0
      shift
      ;;
    --healthcheck-only)
      check_backup=0
      check_healthcheck=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

failed=0

check_pass() {
  local message="$1"
  echo "PASS $message"
}

check_fail() {
  local message="$1"
  echo "FAIL $message" >&2
  failed=1
}

echo "== Chatwoot systemd smoketest =="

if ! command -v systemctl >/dev/null 2>&1; then
  check_fail "systemctl not found (systemd is required on the target host)"
else
  timers=()
  [[ "$check_backup" -eq 1 ]] && timers+=(chatwoot-backup.timer)
  [[ "$check_healthcheck" -eq 1 ]] && timers+=(chatwoot-healthcheck.timer)

  for timer in "${timers[@]}"; do
    enabled_state="$(systemctl is-enabled "$timer" 2>&1 || true)"
    if [[ "$enabled_state" == "enabled" ]]; then
      check_pass "$timer enabled"
    else
      check_fail "$timer not enabled (state: ${enabled_state:-unknown})"
    fi

    active_state="$(systemctl is-active "$timer" 2>&1 || true)"
    if [[ "$active_state" == "active" ]]; then
      check_pass "$timer active"
    else
      check_fail "$timer not active (state: ${active_state:-unknown})"
    fi
  done

  echo
  echo "== Timers (systemctl list-timers) =="
  systemctl list-timers --all --no-pager | grep -E 'chatwoot-(backup|healthcheck)\\.timer' || true
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "Smoketest OK"

