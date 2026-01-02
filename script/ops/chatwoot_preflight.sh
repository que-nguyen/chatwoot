#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: bash script/ops/chatwoot_preflight.sh [--env-file PATH] [--apply-env-updates]

Preflight checks for Chatwoot Docker Compose runbooks:
- Docker + Docker Compose availability
- Required secrets in env file (SECRET_KEY_BASE, POSTGRES_PASSWORD, REDIS_PASSWORD)
- Local port conflicts for CW_WEB_PORT/CW_POSTGRES_PORT/CW_REDIS_PORT
- Optional overlay checks (when CW_COMPOSE_FILES includes overlay YAMLs):
  - Caddy: CW_CADDY_HTTP_PORT/CW_CADDY_HTTPS_PORT
  - Zalo adapter: ZALO_ADAPTER_HOST_PORT and ZALO_ADAPTER_ENV_FILE presence

The env file defaults to CW_ENV_FILE or .env.

Options:
  --apply-env-updates  If the stack is already running with different host ports,
                      write safe variables into the env file to match the running stack:
                      - CW_*_PORT, ZALO_ADAPTER_HOST_PORT
                      - CW_COMPOSE_FILES (recommended overlays if detected)
EOF
}

env_file="${CW_ENV_FILE:-.env}"
apply_env_updates=0
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
suggested_env_updates=()

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

apply_env_updates_to_file() {
  local file="$1"
  shift
  local updates=("$@")

  if [[ "${#updates[@]}" -eq 0 ]]; then
    return 0
  fi

  local env_dir=""
  env_dir="$(dirname "$file")"
  if [[ ! -d "$env_dir" ]]; then
    check_fail "env directory does not exist: $env_dir"
    return 1
  fi

  local env_base=""
  env_base="$(basename "$file")"
  local tmp=""
  tmp="$(mktemp -p "$env_dir" ".${env_base}.tmp.XXXXXX")"

  local keys=()
  local update=""
  for update in "${updates[@]}"; do
    keys+=("${update%%=*}")
  done

  local pattern=""
  pattern="^[[:space:]]*($(IFS='|'; printf "%s" "${keys[*]}"))[[:space:]]*="

  if [[ -f "$file" ]]; then
    grep -Ev "$pattern" "$file" >"$tmp" || true
    chmod --reference="$file" "$tmp" || true
  else
    : >"$tmp"
  fi

  printf "\n" >>"$tmp" || true
  for update in "${updates[@]}"; do
    printf "%s\n" "$update" >>"$tmp"
  done

  mv "$tmp" "$file"
}

compose_files=()
compose_files_value="$(get_effective_value CW_COMPOSE_FILES "")"
if [[ -n "$compose_files_value" ]]; then
  # shellcheck disable=SC2206
  compose_files=($compose_files_value)
else
  compose_files=(docker-compose.production.yaml)
fi

use_zalo_adapter=0
use_caddy=0
for file in "${compose_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    check_fail "compose file not found: $file (CW_COMPOSE_FILES='${compose_files_value:-}' )"
    continue
  fi

  case "$file" in
    *docker-compose.zalo-adapter.yaml) use_zalo_adapter=1 ;;
    *docker-compose.caddy.yaml) use_caddy=1 ;;
  esac
done

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

frontend_url="$(get_effective_value FRONTEND_URL "")"
if [[ -z "$frontend_url" ]]; then
  check_fail "FRONTEND_URL is missing/empty"
else
  check_pass "FRONTEND_URL present"
  if [[ "$frontend_url" == *"0.0.0.0"* ]]; then
    check_warn "FRONTEND_URL contains 0.0.0.0 (not suitable for links/emails); use 127.0.0.1/localhost for local or your public domain in production"
  fi
fi

check_port_free() {
  local port="$1"
  local label="$2"
  local allow_in_use_port="${3:-}"

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
      if [[ -n "$allow_in_use_port" && "$port" == "$allow_in_use_port" ]]; then
        check_pass "$label port $port is already bound by the running Chatwoot stack"
      else
        check_fail "$label port $port is already in use (set $label to a free port)"
      fi
    else
      check_pass "$label port $port is free"
    fi
  else
    check_warn "ss not found; skipping port conflict check for $label ($port)"
  fi
}

compose_files_for_docker=()
for file in "${compose_files[@]}"; do
  if [[ -f "$file" ]]; then
    compose_files_for_docker+=("$file")
  fi
done

compose=(docker compose)
if [[ -f "$env_file" ]]; then
  compose+=(--env-file "$env_file")
fi
for file in "${compose_files_for_docker[@]}"; do
  compose+=(-f "$file")
done

resolve_running_host_port() {
  local service="$1"
  local container_port="$2"
  local line=""

  line="$("${compose[@]}" port "$service" "$container_port" 2>/dev/null | head -n 1 || true)"
  if [[ "$line" =~ :([0-9]+)$ ]]; then
    printf "%s" "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

detect_running_services() {
  "${compose[@]}" ps --services 2>/dev/null || true
}

running_services="$(detect_running_services)"
running_has_caddy=0
running_has_zalo_adapter=0
missing_caddy_compose=0
missing_zalo_adapter_compose=0

if grep -qx "caddy" <<<"$running_services"; then
  running_has_caddy=1
fi
if grep -qx "zalo_adapter" <<<"$running_services"; then
  running_has_zalo_adapter=1
fi

if [[ "$running_has_caddy" -eq 1 && "$use_caddy" -eq 0 ]]; then
  missing_caddy_compose=1
  check_warn "Detected running service 'caddy' but CW_COMPOSE_FILES does not include docker-compose.caddy.yaml (include it to avoid orphan containers)"
  use_caddy=1
fi

if [[ "$running_has_zalo_adapter" -eq 1 && "$use_zalo_adapter" -eq 0 ]]; then
  missing_zalo_adapter_compose=1
  check_warn "Detected running service 'zalo_adapter' but CW_COMPOSE_FILES does not include docker-compose.zalo-adapter.yaml (include it to avoid orphan containers)"
  use_zalo_adapter=1
fi

has_production_compose=0
for file in "${compose_files[@]}"; do
  if [[ "$file" == *docker-compose.production.yaml ]]; then
    has_production_compose=1
    break
  fi
done

if [[ -n "$compose_files_value" && "$has_production_compose" -eq 0 ]]; then
  check_warn "CW_COMPOSE_FILES does not include docker-compose.production.yaml (runbooks assume it; include it to avoid missing core services)"
fi

needs_compose_files_update=0
if [[ "$missing_caddy_compose" -eq 1 || "$missing_zalo_adapter_compose" -eq 1 ]]; then
  needs_compose_files_update=1
fi
if [[ -n "$compose_files_value" && "$has_production_compose" -eq 0 ]]; then
  needs_compose_files_update=1
fi

if [[ "$needs_compose_files_update" -eq 1 ]]; then
  recommended_compose_files=()

  add_compose_file() {
    local candidate="$1"
    local existing=""

    [[ -z "$candidate" ]] && return 0

    for existing in "${recommended_compose_files[@]}"; do
      if [[ "$existing" == "$candidate" ]]; then
        return 0
      fi
    done

    recommended_compose_files+=("$candidate")
  }

  if [[ -f docker-compose.production.yaml ]]; then
    add_compose_file "docker-compose.production.yaml"
  fi
  for file in "${compose_files[@]}"; do
    add_compose_file "$file"
  done

  if [[ "$running_has_zalo_adapter" -eq 1 && -f docker-compose.zalo-adapter.yaml ]]; then
    add_compose_file "docker-compose.zalo-adapter.yaml"
  fi
  if [[ "$running_has_caddy" -eq 1 && -f docker-compose.caddy.yaml ]]; then
    add_compose_file "docker-compose.caddy.yaml"
  fi

  recommended_compose_files_value="${recommended_compose_files[*]}"
  if [[ -n "$recommended_compose_files_value" ]]; then
    suggested_env_updates+=("CW_COMPOSE_FILES=\"$recommended_compose_files_value\"")
  fi
fi

web_port="$(get_effective_value CW_WEB_PORT "3000")"
postgres_port="$(get_effective_value CW_POSTGRES_PORT "5432")"
redis_port="$(get_effective_value CW_REDIS_PORT "6379")"

running_web_port="$(resolve_running_host_port rails 3000 || true)"
running_postgres_port="$(resolve_running_host_port postgres 5432 || true)"
running_redis_port="$(resolve_running_host_port redis 6379 || true)"

if [[ -n "$running_web_port" && "$web_port" =~ ^[0-9]+$ && "$web_port" != "$running_web_port" ]]; then
  if [[ "$apply_env_updates" -eq 1 ]]; then
    check_warn "CW_WEB_PORT=$web_port does not match the running stack (rails=$running_web_port); will set CW_WEB_PORT=$running_web_port"
    web_port="$running_web_port"
  else
    check_fail "CW_WEB_PORT=$web_port does not match the running stack (rails=$running_web_port); set CW_WEB_PORT=$running_web_port to avoid accidental recreate/port conflicts"
  fi
  suggested_env_updates+=("CW_WEB_PORT=$running_web_port")
fi
if [[ -n "$running_postgres_port" && "$postgres_port" =~ ^[0-9]+$ && "$postgres_port" != "$running_postgres_port" ]]; then
  if [[ "$apply_env_updates" -eq 1 ]]; then
    check_warn "CW_POSTGRES_PORT=$postgres_port does not match the running stack (postgres=$running_postgres_port); will set CW_POSTGRES_PORT=$running_postgres_port"
    postgres_port="$running_postgres_port"
  else
    check_fail "CW_POSTGRES_PORT=$postgres_port does not match the running stack (postgres=$running_postgres_port); set CW_POSTGRES_PORT=$running_postgres_port to avoid accidental recreate/port conflicts"
  fi
  suggested_env_updates+=("CW_POSTGRES_PORT=$running_postgres_port")
fi
if [[ -n "$running_redis_port" && "$redis_port" =~ ^[0-9]+$ && "$redis_port" != "$running_redis_port" ]]; then
  if [[ "$apply_env_updates" -eq 1 ]]; then
    check_warn "CW_REDIS_PORT=$redis_port does not match the running stack (redis=$running_redis_port); will set CW_REDIS_PORT=$running_redis_port"
    redis_port="$running_redis_port"
  else
    check_fail "CW_REDIS_PORT=$redis_port does not match the running stack (redis=$running_redis_port); set CW_REDIS_PORT=$running_redis_port to avoid accidental recreate/port conflicts"
  fi
  suggested_env_updates+=("CW_REDIS_PORT=$running_redis_port")
fi

check_port_free "$web_port" "CW_WEB_PORT" "$running_web_port"
check_port_free "$postgres_port" "CW_POSTGRES_PORT" "$running_postgres_port"
check_port_free "$redis_port" "CW_REDIS_PORT" "$running_redis_port"

if [[ "$use_caddy" -eq 1 ]]; then
  caddy_http_port="$(get_effective_value CW_CADDY_HTTP_PORT "80")"
  caddy_https_port="$(get_effective_value CW_CADDY_HTTPS_PORT "443")"

  running_caddy_http_port="$(resolve_running_host_port caddy 80 || true)"
  running_caddy_https_port="$(resolve_running_host_port caddy 443 || true)"

  if [[ -n "$running_caddy_http_port" && "$caddy_http_port" =~ ^[0-9]+$ && "$caddy_http_port" != "$running_caddy_http_port" ]]; then
    if [[ "$apply_env_updates" -eq 1 ]]; then
      check_warn "CW_CADDY_HTTP_PORT=$caddy_http_port does not match the running stack (caddy=$running_caddy_http_port); will set CW_CADDY_HTTP_PORT=$running_caddy_http_port"
      caddy_http_port="$running_caddy_http_port"
    else
      check_fail "CW_CADDY_HTTP_PORT=$caddy_http_port does not match the running stack (caddy=$running_caddy_http_port); set CW_CADDY_HTTP_PORT=$running_caddy_http_port to avoid accidental recreate/port conflicts"
    fi
    suggested_env_updates+=("CW_CADDY_HTTP_PORT=$running_caddy_http_port")
  fi
  if [[ -n "$running_caddy_https_port" && "$caddy_https_port" =~ ^[0-9]+$ && "$caddy_https_port" != "$running_caddy_https_port" ]]; then
    if [[ "$apply_env_updates" -eq 1 ]]; then
      check_warn "CW_CADDY_HTTPS_PORT=$caddy_https_port does not match the running stack (caddy=$running_caddy_https_port); will set CW_CADDY_HTTPS_PORT=$running_caddy_https_port"
      caddy_https_port="$running_caddy_https_port"
    else
      check_fail "CW_CADDY_HTTPS_PORT=$caddy_https_port does not match the running stack (caddy=$running_caddy_https_port); set CW_CADDY_HTTPS_PORT=$running_caddy_https_port to avoid accidental recreate/port conflicts"
    fi
    suggested_env_updates+=("CW_CADDY_HTTPS_PORT=$running_caddy_https_port")
  fi

  check_port_free "$caddy_http_port" "CW_CADDY_HTTP_PORT" "$running_caddy_http_port"
  check_port_free "$caddy_https_port" "CW_CADDY_HTTPS_PORT" "$running_caddy_https_port"
fi

if [[ "$use_zalo_adapter" -eq 1 ]]; then
  zalo_host_port="$(get_effective_value ZALO_ADAPTER_HOST_PORT "3002")"
  running_zalo_port="$(resolve_running_host_port zalo_adapter 3001 || true)"

  if [[ -n "$running_zalo_port" && "$zalo_host_port" =~ ^[0-9]+$ && "$zalo_host_port" != "$running_zalo_port" ]]; then
    if [[ "$apply_env_updates" -eq 1 ]]; then
      check_warn "ZALO_ADAPTER_HOST_PORT=$zalo_host_port does not match the running stack (zalo_adapter=$running_zalo_port); will set ZALO_ADAPTER_HOST_PORT=$running_zalo_port"
      zalo_host_port="$running_zalo_port"
    else
      check_fail "ZALO_ADAPTER_HOST_PORT=$zalo_host_port does not match the running stack (zalo_adapter=$running_zalo_port); set ZALO_ADAPTER_HOST_PORT=$running_zalo_port to avoid accidental recreate/port conflicts"
    fi
    suggested_env_updates+=("ZALO_ADAPTER_HOST_PORT=$running_zalo_port")
  fi

  check_port_free "$zalo_host_port" "ZALO_ADAPTER_HOST_PORT" "$running_zalo_port"

  zalo_env_file="$(get_effective_value ZALO_ADAPTER_ENV_FILE "./integrations/zalo_adapter/.env")"
  if [[ -f "$zalo_env_file" ]]; then
    check_pass "Zalo adapter env file found: $zalo_env_file"
  else
    check_fail "Zalo adapter env file not found: $zalo_env_file (set ZALO_ADAPTER_ENV_FILE or create the default file)"
  fi
fi

caddy_domain="$(get_effective_value CADDY_DOMAIN "")"
if [[ "$use_caddy" -eq 1 ]]; then
  if [[ -z "$caddy_domain" ]]; then
    check_warn "CADDY_DOMAIN is missing/empty; Caddy will default to localhost (auto-HTTPS with internal CA). Set CADDY_DOMAIN to your public domain in production"
  elif [[ "$caddy_domain" == *"://"* ]]; then
    check_warn "CADDY_DOMAIN contains scheme; set only hostname to enable TLS (got '$caddy_domain')"
  fi

  force_ssl="$(get_effective_value FORCE_SSL "")"
  force_ssl="$(printf "%s" "$force_ssl" | tr '[:upper:]' '[:lower:]')"
  if [[ -n "$caddy_domain" && "$caddy_domain" != "localhost" && "$caddy_domain" != "127.0.0.1" ]]; then
    if [[ "$force_ssl" != "true" ]]; then
      check_warn "FORCE_SSL is not true; recommended FORCE_SSL=true when serving Chatwoot behind TLS (Phase 2)"
    fi
    if [[ -n "$frontend_url" && "$frontend_url" != https://* ]]; then
      check_warn "FRONTEND_URL is not https while Caddy is enabled; recommended to set FRONTEND_URL=https://$caddy_domain in production"
    fi
  fi
fi

if [[ "${#suggested_env_updates[@]}" -gt 0 ]]; then
  echo
  echo "Suggested env updates (paste into your env file to match the running stack):"
  for line in "${suggested_env_updates[@]}"; do
    echo "  $line"
  done
  if [[ "$apply_env_updates" -eq 1 ]]; then
    if [[ -f "$env_file" ]]; then
      apply_env_updates_to_file "$env_file" "${suggested_env_updates[@]}"
      check_pass "Applied env updates to $env_file"
    else
      check_fail "Cannot apply env updates because env file not found: $env_file"
    fi
  fi
fi

if [[ "$failed" -ne 0 ]]; then
  echo "Preflight FAILED" >&2
  exit 1
fi

echo "Preflight OK"
