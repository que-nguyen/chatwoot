#!/usr/bin/env bash
set -euo pipefail

umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: bash script/ops/chatwoot_backup.sh [options]

Runs a host-side backup for the Chatwoot Docker Compose stack:
- Copies the env file (if present)
- Dumps Postgres (pg_dump) to backup/pgdump-*.sql.gz
- Archives /app/storage to backup/storage-*.tgz
- Cleans up old backups (optional)

Options:
  -e, --env-file PATH     Env file used by compose and backed up (default: CW_ENV_FILE or .env)
  --backup-dir PATH       Output directory (default: CW_BACKUP_DIR or backup)
  --keep-days N           Retention days (default: CW_BACKUP_KEEP_DAYS or 14)
  -h, --help              Show help
EOF
}

timestamp="$(date +%F-%H%M%S)"

backup_dir="${CW_BACKUP_DIR:-backup}"
keep_days="${CW_BACKUP_KEEP_DAYS:-14}"
env_file="${CW_ENV_FILE:-.env}"
env_file_explicit=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env-file)
      env_file="${2:-}"
      env_file_explicit=1
      shift 2
      ;;
    --backup-dir)
      backup_dir="${2:-}"
      shift 2
      ;;
    --keep-days)
      keep_days="${2:-}"
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

if [[ "$env_file_explicit" -eq 1 ]]; then
  export CW_ENV_FILE="$env_file"
fi

compose=(script/ops/chatwoot_compose.sh --env-file "$env_file")

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
