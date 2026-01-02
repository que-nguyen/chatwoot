#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: bash script/ops/chatwoot_caddy_smoketest.sh [--env-file PATH]

Runs a minimal Phase 2 smoke test (Caddy TLS overlay):
- Compose services running/healthy (via script/ops/chatwoot_healthcheck.sh)
- HTTP proxy reachable via Caddy (Host-based)
- HTTPS proxy reachable via Caddy (SNI via curl --resolve; TLS verified for non-local domains)

Notes:
- Requires Phase 0 stack running and the Caddy overlay started.
- Uses CADDY_DOMAIN (hostname only; no scheme) for TLS; defaults to localhost.

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

echo "== Chatwoot Phase 2 smoketest (Caddy) =="

compose_files_value="$(get_effective_value CW_COMPOSE_FILES "")"
if [[ -z "$compose_files_value" ]]; then
  compose_files_value="docker-compose.production.yaml docker-compose.caddy.yaml"
fi

wait_seconds="$(get_effective_value CW_SMOKETEST_WAIT_SECONDS "60")"
wait_interval_seconds="$(get_effective_value CW_SMOKETEST_WAIT_INTERVAL_SECONDS "3")"
if [[ -z "$wait_seconds" || ! "$wait_seconds" =~ ^[0-9]+$ ]]; then
  wait_seconds="60"
fi
if [[ -z "$wait_interval_seconds" || ! "$wait_interval_seconds" =~ ^[0-9]+$ ]]; then
  wait_interval_seconds="3"
fi

health_out="$(mktemp)"
trap 'rm -f "$health_out"' EXIT

deadline="$(( $(date +%s) + wait_seconds ))"
attempt=0
while true; do
  attempt="$((attempt + 1))"
  if CW_COMPOSE_FILES="$compose_files_value" bash script/ops/chatwoot_healthcheck.sh --env-file "$env_file" >"$health_out" 2>&1; then
    cat "$health_out"
    check_pass "compose services running/healthy"
    break
  fi

  if [[ "$attempt" -eq 1 && "$wait_seconds" -gt 0 ]]; then
    check_warn "compose services not healthy yet; waiting up to ${wait_seconds}s..."
  fi

  if [[ "$wait_seconds" -eq 0 || "$(date +%s)" -ge "$deadline" ]]; then
    cat "$health_out" >&2
    check_fail "compose services unhealthy (see output above)"
    break
  fi

  sleep "$wait_interval_seconds"
done

domain_source="default"
if [[ -n "${CADDY_DOMAIN+x}" ]]; then
  domain_source="env"
elif [[ -f "$env_file" ]] && grep -Eq '^[[:space:]]*CADDY_DOMAIN[[:space:]]*=' "$env_file"; then
  domain_source="file"
fi

domain="$(trim "$(get_effective_value CADDY_DOMAIN "localhost")")"
if [[ -z "$domain" ]]; then
  domain="localhost"
  domain_source="default"
fi

domain_ok=1
if [[ "$domain" == *"://"* ]]; then
  check_fail "CADDY_DOMAIN contains scheme; set only hostname to enable TLS (got '$domain')"
  domain_ok=0
else
  if [[ "$domain_source" == "default" ]]; then
    check_warn "CADDY_DOMAIN not set; defaulting to localhost"
  fi
  check_pass "CADDY_DOMAIN OK ($domain)"
fi

http_port=""
https_port=""

port_line_http="$(
  CW_COMPOSE_FILES="$compose_files_value" \
    script/ops/chatwoot_compose.sh --env-file "$env_file" port caddy 80 2>/dev/null | head -n 1 || true
)"
if [[ "$port_line_http" =~ :([0-9]+)$ ]]; then
  http_port="${BASH_REMATCH[1]}"
fi

port_line_https="$(
  CW_COMPOSE_FILES="$compose_files_value" \
    script/ops/chatwoot_compose.sh --env-file "$env_file" port caddy 443 2>/dev/null | head -n 1 || true
)"
if [[ "$port_line_https" =~ :([0-9]+)$ ]]; then
  https_port="${BASH_REMATCH[1]}"
fi

if [[ -z "$http_port" ]]; then
  http_port="$(get_effective_value CW_CADDY_HTTP_PORT "80")"
fi
if [[ -z "$https_port" ]]; then
  https_port="$(get_effective_value CW_CADDY_HTTPS_PORT "443")"
fi

if [[ -z "$http_port" || ! "$http_port" =~ ^[0-9]+$ ]]; then
  check_warn "Unable to resolve CW_CADDY_HTTP_PORT (compose_port='${port_line_http:-}'); falling back to 80"
  http_port="80"
fi
if [[ -z "$https_port" || ! "$https_port" =~ ^[0-9]+$ ]]; then
  check_warn "Unable to resolve CW_CADDY_HTTPS_PORT (compose_port='${port_line_https:-}'); falling back to 443"
  https_port="443"
fi

if command -v curl >/dev/null 2>&1; then
  if [[ "$domain_ok" -eq 1 ]]; then
    http_code="$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $domain" "http://127.0.0.1:${http_port}/" || true)"
    if [[ "$http_code" =~ ^[23][0-9]{2}$ ]]; then
      check_pass "HTTP proxy reachable (127.0.0.1:${http_port} Host:${domain} -> $http_code)"
    else
      check_fail "HTTP proxy not OK (127.0.0.1:${http_port} Host:${domain} -> $http_code; expected 2xx/3xx)"
    fi

    curl_tls_args=()
    # For localhost Caddy often serves with an internal CA; allow insecure mode.
    if [[ "$domain" == "localhost" || "$domain" == "127.0.0.1" || "$domain" == "::1" || "$domain" == *.localhost ]]; then
      curl_tls_args+=(-k)
    fi

    https_code="$(
      curl "${curl_tls_args[@]}" -sS -o /dev/null -w '%{http_code}' \
        --resolve "${domain}:${https_port}:127.0.0.1" \
        "https://${domain}:${https_port}/" || true
    )"
    if [[ "$https_code" =~ ^[23][0-9]{2}$ ]]; then
      check_pass "HTTPS proxy reachable (${domain}:${https_port} -> $https_code)"
    else
      check_fail "HTTPS proxy not OK (${domain}:${https_port} -> $https_code; expected 2xx/3xx)"
    fi
  fi
else
  check_warn "curl not found; skipping HTTP/HTTPS proxy checks"
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "Smoketest OK"
