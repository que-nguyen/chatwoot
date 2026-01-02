#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: bash script/ops/chatwoot_systemd_install.sh [options]

Install and enable systemd timers for Chatwoot ops scripts:
- chatwoot-backup.timer (daily backups)
- chatwoot-healthcheck.timer (periodic healthcheck + optional webhook alert)

This script:
1) Installs unit files into /etc/systemd/system/ (or ~/.config/systemd/user/ with --user)
2) Creates /etc/chatwoot/ops.env (or ~/.config/chatwoot/ops.env with --user; only if missing unless --overwrite-env)
3) (Optional) Enables timers

Options:
  --user                  Install user-scope timers (no sudo; requires a user systemd session)
  --env-file PATH          Env file used by ops scripts (default: <repo>/.env)
  --compose-files "FILES"  Space-separated compose files (default: CW_COMPOSE_FILES from env file or docker-compose.production.yaml)
  --backup-dir PATH        Backup dir (default: backup)
  --backup-keep-days N     Retention days (default: 14)
  --alert-webhook-url URL  Optional (Discord/Slack webhook URL)
  --alert-webhook-mode M   Optional: slack|discord (default: slack)
  --alert-prefix TEXT      Optional (default: chatwoot)
  --backup-only            Install/enable only backup timer
  --healthcheck-only       Install/enable only healthcheck timer
  --no-enable              Install units but do not enable timers
  --overwrite-env          Overwrite ops env file (may overwrite webhook config)
  --dry-run                Print actions only
  -h, --help               Show help

Examples:
  bash script/ops/chatwoot_systemd_install.sh
  bash script/ops/chatwoot_systemd_install.sh --compose-files "docker-compose.production.yaml docker-compose.caddy.yaml"
  bash script/ops/chatwoot_systemd_install.sh --user
  bash script/ops/chatwoot_systemd_install.sh --alert-webhook-mode discord --alert-webhook-url "https://..." --alert-prefix "chatwoot-prod"
EOF
}

dry_run=0
enable_timers=1
overwrite_env=0
systemd_scope="system"

install_backup=1
install_healthcheck=1

env_file=""
compose_files=""
backup_dir=""
backup_keep_days=""
alert_webhook_url=""
alert_webhook_mode=""
alert_prefix=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      systemd_scope="user"
      shift
      ;;
    --env-file)
      env_file="${2:-}"
      shift 2
      ;;
    --compose-files)
      compose_files="${2:-}"
      shift 2
      ;;
    --backup-dir)
      backup_dir="${2:-}"
      shift 2
      ;;
    --backup-keep-days)
      backup_keep_days="${2:-}"
      shift 2
      ;;
    --alert-webhook-url)
      alert_webhook_url="${2:-}"
      shift 2
      ;;
    --alert-webhook-mode)
      alert_webhook_mode="${2:-}"
      shift 2
      ;;
    --alert-prefix)
      alert_prefix="${2:-}"
      shift 2
      ;;
    --backup-only)
      install_backup=1
      install_healthcheck=0
      shift
      ;;
    --healthcheck-only)
      install_backup=0
      install_healthcheck=1
      shift
      ;;
    --no-enable)
      enable_timers=0
      shift
      ;;
    --overwrite-env)
      overwrite_env=1
      shift
      ;;
    --dry-run)
      dry_run=1
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

run() {
  echo "+ $*"
  if [[ "$dry_run" -eq 1 ]]; then
    return 0
  fi
  "$@"
}

systemctl_cmd=(systemctl)
repo_root="$ROOT_DIR"
ops_env_path="/etc/chatwoot/ops.env"
systemd_unit_dir="/etc/systemd/system"

if [[ "$systemd_scope" == "user" ]]; then
  config_root="${XDG_CONFIG_HOME:-}"
  if [[ -z "$config_root" ]]; then
    home_dir="${HOME:-}"
    if [[ -z "$home_dir" ]]; then
      echo "ERROR: HOME is not set; cannot resolve user config directory for --user" >&2
      exit 2
    fi
    config_root="$home_dir/.config"
  fi

  ops_env_path="$config_root/chatwoot/ops.env"
  systemd_unit_dir="$config_root/systemd/user"
  systemctl_cmd=(systemctl --user)
fi

sudo_cmd=()
if [[ "$systemd_scope" == "system" && "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    sudo_cmd=(sudo)
  else
    if [[ "$dry_run" -eq 1 ]]; then
      echo "WARN: sudo not found; continuing due to --dry-run (commands will be printed with a sudo prefix)" >&2
      sudo_cmd=(sudo)
    else
      echo "ERROR: must run as root (or install sudo)" >&2
      exit 2
    fi
  fi

  if [[ "$dry_run" -eq 0 && ! -t 0 ]]; then
    if ! sudo -n true >/dev/null 2>&1; then
      echo "ERROR: sudo requires a password and stdin is not a TTY. Re-run as root, configure passwordless sudo, or use --user." >&2
      exit 2
    fi
    sudo_cmd=(sudo -n)
  fi
fi

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf "%s" "$value"
}

read_env_value_from_file() {
  local file="$1"
  local key="$2"
  local line=""
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    return 1
  fi

  local value="${line#*=}"
  value="$(trim "$value")"

  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:-1}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:-1}"
  fi

  printf "%s" "$value"
}

if [[ -z "$env_file" ]]; then
  env_file="${CW_ENV_FILE:-$repo_root/.env}"
fi
if [[ "$env_file" != /* ]]; then
  env_file="$repo_root/$env_file"
fi

if [[ -z "$compose_files" ]]; then
  if [[ -f "$env_file" ]]; then
    compose_files="$(read_env_value_from_file "$env_file" CW_COMPOSE_FILES 2>/dev/null || true)"
  fi
fi
if [[ -z "$compose_files" ]]; then
  compose_files="docker-compose.production.yaml"
fi

backup_dir="${backup_dir:-backup}"
backup_keep_days="${backup_keep_days:-14}"
alert_webhook_mode="${alert_webhook_mode:-slack}"
alert_prefix="${alert_prefix:-chatwoot}"

if ! command -v systemctl >/dev/null 2>&1; then
  if [[ "$dry_run" -eq 1 ]]; then
    echo "WARN: systemctl not found; continuing due to --dry-run (this script requires systemd on the target host)" >&2
  else
    echo "ERROR: systemctl not found; systemd is required to use these timers" >&2
    exit 2
  fi
fi

if [[ "$systemd_scope" == "user" && "$dry_run" -eq 0 ]]; then
  if ! "${systemctl_cmd[@]}" show-environment >/dev/null 2>&1; then
    echo "ERROR: systemctl --user failed (no user systemd session). Try a full login session or use system-scope install (requires root/sudo)." >&2
    exit 2
  fi
fi

units_dir="$repo_root/script/ops/systemd"
if [[ ! -d "$units_dir" ]]; then
  echo "ERROR: systemd units directory not found: $units_dir" >&2
  exit 2
fi

if [[ "$install_backup" -eq 1 ]]; then
  run "${sudo_cmd[@]}" install -D -m 0644 "$units_dir/chatwoot-backup.service" "$systemd_unit_dir/chatwoot-backup.service"
  run "${sudo_cmd[@]}" install -D -m 0644 "$units_dir/chatwoot-backup.timer" "$systemd_unit_dir/chatwoot-backup.timer"
fi

if [[ "$install_healthcheck" -eq 1 ]]; then
  run "${sudo_cmd[@]}" install -D -m 0644 "$units_dir/chatwoot-healthcheck.service" "$systemd_unit_dir/chatwoot-healthcheck.service"
  run "${sudo_cmd[@]}" install -D -m 0644 "$units_dir/chatwoot-healthcheck.timer" "$systemd_unit_dir/chatwoot-healthcheck.timer"
fi

ops_env_dir="$(dirname "$ops_env_path")"
ops_env_dir_mode="0750"
ops_env_file_mode="0640"
if [[ "$systemd_scope" == "user" ]]; then
  ops_env_dir_mode="0700"
  ops_env_file_mode="0600"
fi

run "${sudo_cmd[@]}" install -d -m "$ops_env_dir_mode" "$ops_env_dir"

if [[ -f "$ops_env_path" && "$overwrite_env" -eq 0 ]]; then
  echo "INFO: ops env file already exists; leaving unchanged: $ops_env_path" >&2
  echo "INFO: edit it manually or re-run with --overwrite-env" >&2
else
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# Chatwoot ops env (systemd units)
#
# This file is read by systemd's EnvironmentFile= directive (not bash),
# so keep it to simple KEY=VALUE lines.

CHATWOOT_ROOT=$repo_root
CW_ENV_FILE=$env_file
CW_COMPOSE_FILES="$compose_files"

CW_BACKUP_DIR=$backup_dir
CW_BACKUP_KEEP_DAYS=$backup_keep_days

CW_ALERT_WEBHOOK_MODE=$alert_webhook_mode
CW_ALERT_PREFIX=$alert_prefix
EOF

  if [[ -n "$alert_webhook_url" ]]; then
    printf "CW_ALERT_WEBHOOK_URL=%s\n" "$alert_webhook_url" >>"$tmp"
  else
    printf "# CW_ALERT_WEBHOOK_URL=https://...\n" >>"$tmp"
  fi

  run "${sudo_cmd[@]}" install -m "$ops_env_file_mode" "$tmp" "$ops_env_path"
  rm -f "$tmp"
  if [[ "$dry_run" -eq 1 ]]; then
    if [[ -f "$ops_env_path" ]]; then
      echo "DRY RUN: would overwrite ops env file: $ops_env_path" >&2
    else
      echo "DRY RUN: would write ops env file: $ops_env_path" >&2
    fi
  else
    echo "Wrote ops env file: $ops_env_path" >&2
  fi
fi

run "${sudo_cmd[@]}" "${systemctl_cmd[@]}" daemon-reload

if [[ "$enable_timers" -eq 1 ]]; then
  timers=()
  [[ "$install_backup" -eq 1 ]] && timers+=(chatwoot-backup.timer)
  [[ "$install_healthcheck" -eq 1 ]] && timers+=(chatwoot-healthcheck.timer)

  if [[ "${#timers[@]}" -gt 0 ]]; then
    run "${sudo_cmd[@]}" "${systemctl_cmd[@]}" enable --now "${timers[@]}"
    run "${systemctl_cmd[@]}" list-timers --all | grep -E 'chatwoot-(backup|healthcheck)' || true
  fi
else
  echo "INFO: timers not enabled (--no-enable)" >&2
fi
