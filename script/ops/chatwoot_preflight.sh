#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: bash script/ops/chatwoot_preflight.sh [--env-file PATH]

Preflight checks for Chatwoot Docker Compose runbooks:
- Docker + Docker Compose availability
- Required secrets in env file (SECRET_KEY_BASE, POSTGRES_PASSWORD, REDIS_PASSWORD)
- Local port conflicts for CW_WEB_PORT/CW_POSTGRES_PORT/CW_REDIS_PORT

The env file defaults to CW_ENV_FILE or .env.
EOF
}

env_file="${CW_ENV_FILE:-.env}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env-file)
      env_file="${2:-}"
      shift 2
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

check_warn() {
  local message="$1"
  echo "WARN $message" >&2
}

echo "== Chatwoot preflight =="

if command -v docker >/dev/null 2>&1; then
  check_pass "docker installed ($(docker --version 2>/dev/null || true))"
else
  check_fail "docker not found in PATH"
fi

if docker compose version >/dev/null 2>&1; then
  check_pass "docker compose available ($(docker compose version 2>/dev/null | head -n 1 || true))"
else
  check_fail "docker compose not available"
fi

if docker ps >/dev/null 2>&1; then
  check_pass "docker daemon reachable"
else
  check_fail "docker daemon not reachable (check permissions / service status)"
fi

if [[ -f "$env_file" ]]; then
  check_pass "env file found: $env_file"
else
  check_fail "env file not found: $env_file (set CW_ENV_FILE or pass --env-file)"
fi

secret_key_base="$(get_effective_value SECRET_KEY_BASE "")"
if [[ -z "$secret_key_base" ]]; then
  check_fail "SECRET_KEY_BASE is missing/empty"
elif [[ "$secret_key_base" == "replace_with_lengthy_secure_hex" ]]; then
  check_fail "SECRET_KEY_BASE is still placeholder (replace_with_lengthy_secure_hex)"
elif [[ "${#secret_key_base}" -lt 32 ]]; then
  check_fail "SECRET_KEY_BASE is too short (len=${#secret_key_base}, expected >= 32)"
else
  check_pass "SECRET_KEY_BASE present (len=${#secret_key_base})"
fi

postgres_password="$(get_effective_value POSTGRES_PASSWORD "")"
if [[ -z "$postgres_password" ]]; then
  check_fail "POSTGRES_PASSWORD is missing/empty"
else
  check_pass "POSTGRES_PASSWORD present"
fi

redis_password="$(get_effective_value REDIS_PASSWORD "")"
if [[ -z "$redis_password" ]]; then
  check_fail "REDIS_PASSWORD is missing/empty"
else
  check_pass "REDIS_PASSWORD present"
fi

check_port_free() {
  local port="$1"
  local label="$2"

  if [[ -z "$port" ]]; then
    check_warn "$label port is empty; skipping port check"
    return 0
  fi

  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    check_warn "$label port is not numeric: '$port' (skipping port check)"
    return 0
  fi

  if command -v ss >/dev/null 2>&1; then
    if ss -ltn | grep -q -E ":${port}([^0-9]|$)"; then
      check_fail "$label port $port is already in use (set $label to a free port)"
    else
      check_pass "$label port $port is free"
    fi
  else
    check_warn "ss not found; skipping port conflict check for $label ($port)"
  fi
}

web_port="$(get_effective_value CW_WEB_PORT "3000")"
postgres_port="$(get_effective_value CW_POSTGRES_PORT "5432")"
redis_port="$(get_effective_value CW_REDIS_PORT "6379")"

check_port_free "$web_port" "CW_WEB_PORT"
check_port_free "$postgres_port" "CW_POSTGRES_PORT"
check_port_free "$redis_port" "CW_REDIS_PORT"

caddy_domain="$(get_effective_value CADDY_DOMAIN "")"
if [[ -n "$caddy_domain" && "$caddy_domain" == *"://"* ]]; then
  check_warn "CADDY_DOMAIN contains scheme; set only hostname to enable TLS (got '$caddy_domain')"
fi

if [[ "$failed" -ne 0 ]]; then
  echo "Preflight FAILED" >&2
  exit 1
fi

echo "Preflight OK"
