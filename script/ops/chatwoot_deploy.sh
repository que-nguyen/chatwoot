#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: bash script/ops/chatwoot_deploy.sh [options]

Runs a minimal Phase 0 deployment using Docker Compose:
1) Preflight checks
2) docker compose up -d
3) Smoke test (health + web reachability)

Options:
  -e, --env-file PATH        Env file (defaults to CW_ENV_FILE or .env)
  --apply-env-updates        Forward to preflight to align ports/overlays with a running stack
  --skip-smoketest           Skip smoketest step
  --follow-logs              Tail logs after `up -d` (Ctrl-C to stop)
EOF
}

env_file="${CW_ENV_FILE:-.env}"
apply_env_updates=0
skip_smoketest=0
follow_logs=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env-file)
      env_file="${2:-}"
      shift 2
      ;;
    --apply-env-updates)
      apply_env_updates=1
      shift
      ;;
    --skip-smoketest)
      skip_smoketest=1
      shift
      ;;
    --follow-logs)
      follow_logs=1
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

get_effective_value() {
  local key="$1"
  local default="${2:-}"

  if [[ -n "${!key+x}" ]]; then
    printf "%s" "${!key}"
    return 0
  fi

  if [[ -f "$env_file" ]]; then
    read_env_value_from_file "$env_file" "$key" && return 0
  fi

  printf "%s" "$default"
}

echo "== Chatwoot deploy (compose) =="
echo "env file: $env_file"

preflight_args=(--env-file "$env_file")
if [[ "$apply_env_updates" -eq 1 ]]; then
  preflight_args+=(--apply-env-updates)
fi
bash script/ops/chatwoot_preflight.sh "${preflight_args[@]}"

script/ops/chatwoot_compose.sh --env-file "$env_file" up -d

if [[ "$follow_logs" -eq 1 ]]; then
  echo "INFO: Following logs (Ctrl-C to stop)..." >&2
  script/ops/chatwoot_compose.sh --env-file "$env_file" logs -f --tail=200 migrate rails sidekiq postgres redis || true
fi

if [[ "$skip_smoketest" -eq 0 ]]; then
  bash script/ops/chatwoot_smoketest.sh --env-file "$env_file"
else
  echo "INFO: smoketest skipped" >&2
fi

frontend_url="$(get_effective_value FRONTEND_URL "")"
if [[ -n "$frontend_url" ]]; then
  echo "Next: open $frontend_url and create the admin user (Phase 0 verification)"
else
  echo "Next: open the Web UI and create the admin user (Phase 0 verification)"
fi

