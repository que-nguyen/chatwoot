#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: bash script/ops/chatwoot_postgres_password_sync.sh [--env-file PATH]

Ensures the Postgres role password matches the value in your env file.

Why this exists:
- Postgres only uses POSTGRES_PASSWORD on first initialization (new volume).
- If you change POSTGRES_PASSWORD later, the DB role keeps the old password.
- Result: rails/migrate fails with "password authentication failed" and compose prints:
  service "migrate" didn't complete successfully: exit 1

This script:
1) Ensures postgres container is running
2) Tests auth over the compose network (host=postgres)
3) If auth fails, updates the role password inside Postgres to match the env file

Options:
  -e, --env-file PATH   Env file used by compose (default: CW_ENV_FILE or .env)
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

compose=(script/ops/chatwoot_compose.sh --env-file "$env_file")

echo "== Postgres password sync =="
echo "env file: $env_file"

postgres_user="$(get_effective_value POSTGRES_USERNAME "postgres")"
postgres_password="$(get_effective_value POSTGRES_PASSWORD "")"
postgres_db="$(get_effective_value POSTGRES_DATABASE "chatwoot_production")"

if [[ -z "$postgres_password" ]]; then
  echo "ERROR: POSTGRES_PASSWORD is missing/empty in env file '$env_file'" >&2
  exit 1
fi

echo "INFO: ensuring postgres is running..." >&2
"${compose[@]}" up -d postgres

postgres_id="$("${compose[@]}" ps -q postgres 2>/dev/null | head -n 1 || true)"
if [[ -z "$postgres_id" ]]; then
  echo "ERROR: postgres container not found (is the stack running?)" >&2
  exit 1
fi

wait_seconds="${CW_PG_SYNC_WAIT_SECONDS:-30}"
deadline="$(( $(date +%s) + wait_seconds ))"
while true; do
  if docker exec "$postgres_id" pg_isready -h postgres -p 5432 -U "$postgres_user" >/dev/null 2>&1; then
    break
  fi
  if [[ "$(date +%s)" -ge "$deadline" ]]; then
    echo "ERROR: postgres not ready after ${wait_seconds}s (container=$postgres_id)" >&2
    exit 1
  fi
  sleep 1
done

auth_out="$(mktemp)"
trap 'rm -f "$auth_out"' EXIT

test_auth() {
  docker exec -e PGPASSWORD="$postgres_password" "$postgres_id" \
    psql -h postgres -U "$postgres_user" -d "$postgres_db" -v ON_ERROR_STOP=1 -c 'SELECT 1;' \
    >"$auth_out" 2>&1
}

if test_auth; then
  echo "PASS Postgres auth OK (user=$postgres_user db=$postgres_db)"
  exit 0
fi

if grep -qi "password authentication failed" "$auth_out"; then
  echo "WARN Postgres role password does not match env file; syncing..." >&2
else
  echo "ERROR: unable to authenticate to Postgres with env file credentials" >&2
  cat "$auth_out" >&2
  exit 1
fi

sql_user="${postgres_user//\"/\"\"}"
sql_password="${postgres_password//\'/\'\'}"

sync_out="$(mktemp)"
trap 'rm -f "$auth_out" "$sync_out"' EXIT

if ! docker exec "$postgres_id" \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "ALTER ROLE \"$sql_user\" WITH LOGIN PASSWORD '$sql_password';" \
  >"$sync_out" 2>&1; then
  if grep -qi "does not exist" "$sync_out"; then
    echo "WARN role '$postgres_user' does not exist; creating login role..." >&2
    docker exec "$postgres_id" \
      psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
      -c "CREATE ROLE \"$sql_user\" WITH LOGIN PASSWORD '$sql_password';" \
      >/dev/null
  else
    echo "ERROR: failed to update Postgres role password" >&2
    cat "$sync_out" >&2
    exit 1
  fi
fi

if test_auth; then
  echo "PASS Postgres role password synced (user=$postgres_user)"
  exit 0
fi

echo "ERROR: password sync applied but auth still failing (check role/db name/permissions)" >&2
cat "$auth_out" >&2
exit 1

