#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: script/ops/chatwoot_compose.sh [--env-file PATH] <docker compose args...>

Wrapper around `docker compose` that:
- Uses the right `--env-file` (defaults to CW_ENV_FILE or .env)
- Includes the compose files from CW_COMPOSE_FILES (can be set in env or env file)

Examples:
  script/ops/chatwoot_compose.sh up -d
  script/ops/chatwoot_compose.sh --env-file .env.production up -d
  CW_COMPOSE_FILES="docker-compose.production.yaml docker-compose.caddy.yaml" script/ops/chatwoot_compose.sh ps
EOF
}

env_file="${CW_ENV_FILE:-.env}"
if [[ $# -gt 0 ]]; then
  case "$1" in
    -e|--env-file)
      env_file="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
  esac
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

compose_files=()
compose_files_value="$(get_effective_value CW_COMPOSE_FILES "")"
if [[ -n "$compose_files_value" ]]; then
  # shellcheck disable=SC2206
  compose_files=(${compose_files_value})
else
  compose_files=(docker-compose.production.yaml)
fi

compose=(docker compose)
if [[ -f "$env_file" ]]; then
  compose+=(--env-file "$env_file")
else
  echo "WARN: env file not found at '$env_file' (docker compose will rely on exported env vars)" >&2
fi

for file in "${compose_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "ERROR: compose file not found: $file" >&2
    exit 2
  fi
  compose+=(-f "$file")
done

exec "${compose[@]}" "$@"
