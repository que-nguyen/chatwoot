#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: bash script/ops/chatwoot_restore.sh [--env-file PATH] [options] --yes

Restores a Chatwoot Docker Compose stack from backup files.

Required:
  --yes                   Confirm you understand this overwrites data

Options:
  -e, --env-file PATH     Env file used for compose rendering (default: CW_ENV_FILE or .env)
  --pgdump PATH           Postgres dump file (.sql or .sql.gz) (default: latest backup/pgdump-*.sql.gz)
  --storage PATH          Storage archive (.tgz) (default: latest backup/storage-*.tgz)
  --skip-db               Skip Postgres restore
  --skip-storage          Skip storage restore
  --no-reset-db           Don't DROP/CREATE schema before restore (default: reset schema)
  --clear-storage         Remove existing /app/storage contents before restore (destructive)
  -h, --help              Show this help

Examples:
  bash script/ops/chatwoot_restore.sh --yes --pgdump backup/pgdump-2026-01-02-000000.sql.gz --storage backup/storage-2026-01-02-000000.tgz
  bash script/ops/chatwoot_restore.sh --yes --skip-storage --pgdump backup/pgdump-2026-01-02-000000.sql.gz
EOF
}

env_file="${CW_ENV_FILE:-.env}"
pgdump=""
storage=""
skip_db=0
skip_storage=0
reset_db=1
clear_storage=0
confirmed=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env-file)
      env_file="${2:-}"
      shift 2
      ;;
    --pgdump)
      pgdump="${2:-}"
      shift 2
      ;;
    --storage)
      storage="${2:-}"
      shift 2
      ;;
    --skip-db)
      skip_db=1
      shift
      ;;
    --skip-storage)
      skip_storage=1
      shift
      ;;
    --no-reset-db)
      reset_db=0
      shift
      ;;
    --clear-storage)
      clear_storage=1
      shift
      ;;
    --yes)
      confirmed=1
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

if [[ "$confirmed" -ne 1 ]]; then
  echo "ERROR: missing required --yes (restore overwrites data)" >&2
  usage >&2
  exit 2
fi

if [[ "$skip_db" -eq 1 && "$skip_storage" -eq 1 ]]; then
  echo "ERROR: nothing to restore (both --skip-db and --skip-storage set)" >&2
  exit 2
fi

latest_file() {
  local pattern="$1"
  ls -1t $pattern 2>/dev/null | head -n 1 || true
}

if [[ -z "$pgdump" && "$skip_db" -eq 0 ]]; then
  pgdump="$(latest_file "backup/pgdump-*.sql.gz")"
fi

if [[ -z "$storage" && "$skip_storage" -eq 0 ]]; then
  storage="$(latest_file "backup/storage-*.tgz")"
fi

if [[ "$skip_db" -eq 0 ]]; then
  if [[ -z "$pgdump" ]]; then
    echo "ERROR: missing --pgdump and no backup/pgdump-*.sql.gz found" >&2
    exit 1
  fi
  if [[ ! -f "$pgdump" ]]; then
    echo "ERROR: pgdump file not found: $pgdump" >&2
    exit 1
  fi
  if [[ ! -s "$pgdump" ]]; then
    echo "ERROR: pgdump file is empty: $pgdump" >&2
    exit 1
  fi
fi

if [[ "$skip_storage" -eq 0 ]]; then
  if [[ -z "$storage" ]]; then
    echo "ERROR: missing --storage and no backup/storage-*.tgz found" >&2
    exit 1
  fi
  if [[ ! -f "$storage" ]]; then
    echo "ERROR: storage file not found: $storage" >&2
    exit 1
  fi
  if [[ ! -s "$storage" ]]; then
    echo "ERROR: storage file is empty: $storage" >&2
    exit 1
  fi
fi

compose=(script/ops/chatwoot_compose.sh --env-file "$env_file")

echo "INFO: ensuring postgres/redis are running..." >&2
"${compose[@]}" up -d postgres redis

echo "INFO: stopping app services (rails/sidekiq)..." >&2
"${compose[@]}" stop rails sidekiq || true

if [[ "$skip_db" -eq 0 ]]; then
  echo "INFO: restoring Postgres from $pgdump" >&2
  if [[ "$reset_db" -eq 1 ]]; then
    echo "INFO: resetting public schema before restore..." >&2
    "${compose[@]}" exec -T postgres sh -lc \
      'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"'
  fi

  restore_cmd=()
  if [[ "$pgdump" == *.gz ]]; then
    if ! command -v gunzip >/dev/null 2>&1; then
      echo "ERROR: gunzip not found but pgdump ends with .gz: $pgdump" >&2
      exit 1
    fi
    restore_cmd=(gunzip -c "$pgdump")
  else
    restore_cmd=(cat "$pgdump")
  fi

  "${restore_cmd[@]}" | "${compose[@]}" exec -T postgres sh -lc \
    'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1'
fi

if [[ "$skip_storage" -eq 0 ]]; then
  echo "INFO: restoring storage from $storage" >&2

  if [[ "$clear_storage" -eq 1 ]]; then
    echo "INFO: clearing /app/storage before restore..." >&2
    "${compose[@]}" run --rm --no-deps -T --entrypoint sh rails -lc 'rm -rf /app/storage/*'
  fi

  cat "$storage" | "${compose[@]}" run --rm --no-deps -T --entrypoint sh rails -lc \
    'mkdir -p /app/storage && tar -xzf - -C /app/storage'
fi

echo "INFO: starting stack..." >&2
"${compose[@]}" up -d

echo "Restore complete"
