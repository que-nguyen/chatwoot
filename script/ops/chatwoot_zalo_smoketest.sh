#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: bash script/ops/chatwoot_zalo_smoketest.sh [--env-file PATH]

Runs a minimal Phase 1 smoke test (Zalo adapter overlay):
- Compose services running/healthy (via script/ops/chatwoot_healthcheck.sh)
- Zalo adapter /health reachable from host (http://127.0.0.1:$ZALO_ADAPTER_HOST_PORT/health)
- Rails container can reach adapter service (http://zalo_adapter:3001/health)
- Chatwoot -> adapter webhook delivery (signed when possible)

Notes:
- Requires Phase 0 stack running and the Zalo adapter overlay started.
- Expects the adapter env file (ZALO_ADAPTER_ENV_FILE or ./integrations/zalo_adapter/.env)
  to contain CHATWOOT_INBOX_IDENTIFIER (and optionally CHATWOOT_HMAC_TOKEN).

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

echo "== Chatwoot Phase 1 smoketest (Zalo adapter) =="

compose_files_value="$(get_effective_value CW_COMPOSE_FILES "")"
if [[ -z "$compose_files_value" ]]; then
  compose_files_value="docker-compose.production.yaml docker-compose.zalo-adapter.yaml"
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
  if CW_ENV_FILE="$env_file" CW_COMPOSE_FILES="$compose_files_value" bash script/ops/chatwoot_healthcheck.sh >"$health_out" 2>&1; then
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

adapter_port=""
compose_port_line="$(
  CW_COMPOSE_FILES="$compose_files_value" \
    script/ops/chatwoot_compose.sh --env-file "$env_file" port zalo_adapter 3001 2>/dev/null | head -n 1 || true
)"
if [[ "$compose_port_line" =~ :([0-9]+)$ ]]; then
  adapter_port="${BASH_REMATCH[1]}"
fi

if [[ -z "$adapter_port" ]]; then
  adapter_port="$(get_effective_value ZALO_ADAPTER_HOST_PORT "3002")"
fi

if [[ -z "$adapter_port" || ! "$adapter_port" =~ ^[0-9]+$ ]]; then
  check_warn "Unable to resolve ZALO_ADAPTER_HOST_PORT (compose_port='${compose_port_line:-}'); falling back to 3002"
  adapter_port="3002"
fi

adapter_health_url="http://127.0.0.1:${adapter_port}/health"
http_code=""

if command -v curl >/dev/null 2>&1; then
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' "$adapter_health_url" || true)"
elif command -v python3 >/dev/null 2>&1; then
  http_code="$(
    python3 - "$adapter_health_url" <<'PY' || true
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
  check_warn "curl/python3 not found; skipping host HTTP status check for adapter"
fi

if [[ -n "$http_code" ]]; then
  if [[ "$http_code" == "200" ]]; then
    check_pass "adapter health reachable from host ($adapter_health_url -> $http_code)"
  else
    check_fail "adapter health not OK from host ($adapter_health_url -> $http_code; expected 200)"
  fi
fi

if CW_COMPOSE_FILES="$compose_files_value" \
  script/ops/chatwoot_compose.sh --env-file "$env_file" exec -T rails \
  ruby -rnet/http -ruri -e 'uri = URI("http://zalo_adapter:3001/health"); res = Net::HTTP.get_response(uri); exit(res.is_a?(Net::HTTPSuccess) ? 0 : 1)'; then
  check_pass "rails container can reach adapter service (zalo_adapter:3001)"
else
  check_fail "rails container cannot reach adapter service (zalo_adapter:3001)"
fi

adapter_env_file="$(get_effective_value ZALO_ADAPTER_ENV_FILE "./integrations/zalo_adapter/.env")"
if [[ -f "$adapter_env_file" ]]; then
  check_pass "adapter env file found ($adapter_env_file)"
else
  check_fail "adapter env file not found ($adapter_env_file)"
fi

adapter_inbox_identifier=""
adapter_hmac_token=""
if [[ -f "$adapter_env_file" ]]; then
  adapter_inbox_identifier="$(read_env_value_from_file "$adapter_env_file" CHATWOOT_INBOX_IDENTIFIER || true)"
  adapter_hmac_token="$(read_env_value_from_file "$adapter_env_file" CHATWOOT_HMAC_TOKEN || true)"
fi

if [[ -z "$adapter_inbox_identifier" ]]; then
  check_fail "CHATWOOT_INBOX_IDENTIFIER missing/empty in adapter env file"
else
  check_pass "CHATWOOT_INBOX_IDENTIFIER present in adapter env file"
fi

if [[ -z "$adapter_hmac_token" ]]; then
  check_warn "CHATWOOT_HMAC_TOKEN missing/empty in adapter env file (signature verification will be skipped by adapter)"
else
  check_pass "CHATWOOT_HMAC_TOKEN present in adapter env file"
fi

if [[ -n "$adapter_inbox_identifier" ]]; then
  webhook_test_ruby='identifier = ENV.fetch("SMOKETEST_CHATWOOT_INBOX_IDENTIFIER"); expected = ENV["SMOKETEST_ADAPTER_HMAC_TOKEN"].to_s; channel = Channel::Api.find_by(identifier: identifier); raise("Channel::Api not found for identifier=#{identifier}") unless channel; inbox = channel.inbox; raise("Channel::Api webhook_url is blank") if channel.webhook_url.blank?; if expected.present? && channel.hmac_token != expected; raise("HMAC token mismatch between adapter env and Channel::Api"); end; payload = { event: "message_created", inbox_id: inbox.id, message_type: "outgoing", content: "smoketest", private: false, is_private: false, conversation: { inbox_id: inbox.id, contact_inbox: { source_id: "smoketest" } } }; Webhooks::Trigger.new(channel.webhook_url, payload, :api_inbox_webhook).send(:perform_request); puts "ok"'

  if CW_COMPOSE_FILES="$compose_files_value" \
    script/ops/chatwoot_compose.sh --env-file "$env_file" exec -T \
      -e "SMOKETEST_CHATWOOT_INBOX_IDENTIFIER=$adapter_inbox_identifier" \
      -e "SMOKETEST_ADAPTER_HMAC_TOKEN=$adapter_hmac_token" \
      rails bundle exec rails runner "$webhook_test_ruby"; then
    check_pass "Chatwoot -> adapter webhook delivery OK"
  else
    check_fail "Chatwoot -> adapter webhook delivery failed"
  fi
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "Smoketest OK"
