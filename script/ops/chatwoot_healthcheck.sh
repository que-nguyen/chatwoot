#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

env_file="${CW_ENV_FILE:-.env}"

compose_files=()
if [[ -n "${CW_COMPOSE_FILES:-}" ]]; then
  # shellcheck disable=SC2206
  compose_files=(${CW_COMPOSE_FILES})
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
  compose+=(-f "$file")
done

container_ids="$("${compose[@]}" ps -q || true)"
if [[ -z "$container_ids" ]]; then
  echo "No containers found. Is the stack running? (compose files: ${compose_files[*]})" >&2
  exit 2
fi

printf "%-16s %-28s %-12s %-12s\n" "SERVICE" "CONTAINER" "STATUS" "HEALTH"

failed=0
details=()

while IFS= read -r id; do
  [[ -z "$id" ]] && continue

  line="$(
    docker inspect -f $'{{ index .Config.Labels "com.docker.compose.service" }}\t{{.Name}}\t{{.State.Status}}\t{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}\t{{.State.ExitCode}}' "$id"
  )"

  IFS=$'\t' read -r service name status health exit_code <<< "$line"
  name="${name#/}"

  printf "%-16s %-28s %-12s %-12s\n" "$service" "$name" "$status" "$health"

  if [[ "$service" == "migrate" ]]; then
    if [[ "$status" == "exited" && "$exit_code" == "0" ]]; then
      continue
    fi
    if [[ "$status" == "running" ]]; then
      continue
    fi
    failed=1
    details+=("migrate=$status(exit=$exit_code)")
    continue
  fi

  if [[ "$status" != "running" ]]; then
    failed=1
    details+=("${service}=$status")
    continue
  fi

  if [[ "$health" != "none" && "$health" != "healthy" ]]; then
    failed=1
    details+=("${service}.health=$health")
  fi
done <<< "$container_ids"

if [[ "$failed" -eq 0 ]]; then
  exit 0
fi

message_prefix="${CW_ALERT_PREFIX:-chatwoot}"
message="[$message_prefix] stack unhealthy on $(hostname): ${details[*]}"

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf "%s" "$value"
}

if [[ -n "${CW_ALERT_WEBHOOK_URL:-}" ]]; then
  if command -v curl >/dev/null 2>&1; then
    mode="$(printf "%s" "${CW_ALERT_WEBHOOK_MODE:-slack}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$mode" == "discord" ]]; then
      payload="{\"content\":\"$(json_escape "$message")\"}"
    else
      payload="{\"text\":\"$(json_escape "$message")\"}"
    fi

    curl -fsS -X POST -H "Content-Type: application/json" --data "$payload" "$CW_ALERT_WEBHOOK_URL" || true
  else
    echo "WARN: curl not found; skipping webhook alert" >&2
  fi
fi

echo "$message" >&2
exit 1
