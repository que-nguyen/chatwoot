#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: bash script/ops/chatwoot_smoketest.sh [--env-file PATH]

Runs a minimal smoke test:
- Compose services running/healthy (via script/ops/chatwoot_healthcheck.sh)
- Web UI reachable from host (HTTP 2xx/3xx)

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

echo "== Chatwoot smoketest =="

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
  if bash script/ops/chatwoot_healthcheck.sh --env-file "$env_file" >"$health_out" 2>&1; then
    cat "$health_out"
    check_pass "compose services running/healthy"
    break
  fi

  if [[ "$attempt" -eq 1 && "$wait_seconds" -gt 0 ]]; then
    check_warn "compose services not healthy yet; waiting up to ${wait_seconds}s..."
  fi

  if [[ "$wait_seconds" -eq 0 || "$(date +%s)" -ge "$deadline" ]]; then
    cat "$health_out" >&2
    check_fail "compose services unhealthy (see output above; try: docker compose ps/logs)"
    break
  fi

  sleep "$wait_interval_seconds"
done

web_port=""
compose_port_line="$(CW_ENV_FILE="$env_file" script/ops/chatwoot_compose.sh port rails 3000 2>/dev/null | head -n 1 || true)"
if [[ "$compose_port_line" =~ :([0-9]+)$ ]]; then
  web_port="${BASH_REMATCH[1]}"
fi

if [[ -z "$web_port" ]]; then
  web_port="$(get_effective_value CW_WEB_PORT "3003")"
fi

if [[ -z "$web_port" || ! "$web_port" =~ ^[0-9]+$ ]]; then
  check_warn "Unable to resolve CW_WEB_PORT (compose_port='${compose_port_line:-}'); falling back to 3003"
  web_port="3003"
fi

url="http://127.0.0.1:${web_port}/"
http_code=""

if command -v curl >/dev/null 2>&1; then
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' "$url" || true)"
elif command -v python3 >/dev/null 2>&1; then
  http_code="$(
    python3 - "$url" <<'PY' || true
import sys
import urllib.error
import urllib.request

url = sys.argv[1]
try:
  with urllib.request.urlopen(url, timeout=5) as resp:
    print(resp.getcode())
except urllib.error.HTTPError as e:
  print(e.code)
except Exception:
  pass
PY
  )"
else
  check_warn "curl/python3 not found; falling back to TCP check only"
fi

if [[ -n "$http_code" ]]; then
  if [[ "$http_code" =~ ^[23][0-9]{2}$ ]]; then
    check_pass "Web UI reachable ($url -> $http_code)"
  else
    check_fail "Web UI not reachable/OK ($url -> $http_code; expected 2xx/3xx)"
  fi
else
  if command -v nc >/dev/null 2>&1 && nc -z -w 2 127.0.0.1 "$web_port" >/dev/null 2>&1; then
    check_warn "Web UI TCP port reachable ($url), but HTTP status check was skipped"
  else
    check_fail "Web UI not reachable on $url"
  fi
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "Smoketest OK"
