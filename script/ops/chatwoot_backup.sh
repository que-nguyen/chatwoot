#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

timestamp="$(date +%F-%H%M%S)"

backup_dir="${CW_BACKUP_DIR:-backup}"
keep_days="${CW_BACKUP_KEEP_DAYS:-14}"
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

mkdir -p "$backup_dir"

if [[ -f "$env_file" ]]; then
  cp "$env_file" "$backup_dir/env-$timestamp.env"
else
  echo "WARN: env file not found at '$env_file' (skipping env backup)" >&2
fi

pg_out="$backup_dir/pgdump-$timestamp.sql.gz"
storage_out="$backup_dir/storage-$timestamp.tgz"

echo "Backing up Postgres -> $pg_out"
("${compose[@]}" exec -T postgres sh -lc 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' | gzip > "$pg_out")
if [[ ! -s "$pg_out" ]]; then
  echo "ERROR: Postgres backup is empty: $pg_out" >&2
  exit 1
fi

echo "Backing up storage -> $storage_out"
("${compose[@]}" exec -T rails sh -lc 'tar -czf - -C /app/storage .' > "$storage_out")
if [[ ! -s "$storage_out" ]]; then
  echo "ERROR: Storage backup is empty: $storage_out" >&2
  exit 1
fi

if [[ "${keep_days}" =~ ^[0-9]+$ ]]; then
  echo "Cleaning backups older than ${keep_days} day(s) in '$backup_dir'..."
  find "$backup_dir" -type f -name 'env-*.env' -mtime "+$keep_days" -delete || true
  find "$backup_dir" -type f -name 'pgdump-*.sql.gz' -mtime "+$keep_days" -delete || true
  find "$backup_dir" -type f -name 'storage-*.tgz' -mtime "+$keep_days" -delete || true
else
  echo "WARN: CW_BACKUP_KEEP_DAYS is not a number: '$keep_days' (skipping cleanup)" >&2
fi

echo "Backup complete in '$backup_dir' (timestamp=$timestamp)"
