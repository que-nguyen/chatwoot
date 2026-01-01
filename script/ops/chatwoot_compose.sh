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
  if [[ ! -f "$file" ]]; then
    echo "ERROR: compose file not found: $file" >&2
    exit 2
  fi
  compose+=(-f "$file")
done

exec "${compose[@]}" "$@"
