#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: bash script/ops/chatwoot_upgrade.sh [--env-file PATH] --tag TAG [options]

Upgrades the Chatwoot image in the Docker Compose stack (Phase 3).

Options:
  -e, --env-file PATH     Env file used for compose rendering (default: CW_ENV_FILE or .env)
  --tag TAG               Chatwoot image tag to deploy (sets CW_IMAGE_TAG for this run)
  --apply-env-tag         Write CW_IMAGE_TAG=<tag> into the env file (host-side helper var)
  --skip-backup           Skip pre-upgrade backup (default: run backup if stack is running)
  --skip-pull             Skip pulling images (useful for local tags / airgapped environments)
  --pull-all              Pull all services (default: only rails/sidekiq/migrate)
  --skip-smoketest        Skip post-upgrade smoketest (default: run Phase 0 smoketest)
  -h, --help              Show this help

Examples:
  bash script/ops/chatwoot_upgrade.sh --tag 4.9.1
  bash script/ops/chatwoot_upgrade.sh --env-file .env.production --tag 4.9.1
  bash script/ops/chatwoot_upgrade.sh --tag 4.9.1 --apply-env-tag
  bash script/ops/chatwoot_upgrade.sh --tag local --skip-pull
EOF
}

env_file="${CW_ENV_FILE:-.env}"
tag=""
apply_env_tag=0
skip_backup=0
skip_pull=0
pull_all=0
skip_smoketest=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env-file)
      env_file="${2:-}"
      shift 2
      ;;
    --tag)
      tag="${2:-}"
      shift 2
      ;;
    --apply-env-tag)
      apply_env_tag=1
      shift
      ;;
    --skip-backup)
      skip_backup=1
      shift
      ;;
    --skip-pull)
      skip_pull=1
      shift
      ;;
    --pull-all)
      pull_all=1
      shift
      ;;
    --skip-smoketest)
      skip_smoketest=1
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

if [[ -z "$tag" ]]; then
  echo "ERROR: missing required --tag" >&2
  usage >&2
  exit 2
fi

if [[ "$tag" =~ [[:space:]] ]]; then
  echo "ERROR: --tag must not contain whitespace (got '$tag')" >&2
  exit 2
fi

apply_env_updates_to_file() {
  local file="$1"
  local key="$2"
  local value="$3"

  local env_dir=""
  env_dir="$(dirname "$file")"
  if [[ ! -d "$env_dir" ]]; then
    echo "ERROR: env directory does not exist: $env_dir" >&2
    exit 1
  fi

  local env_base=""
  env_base="$(basename "$file")"
  local tmp=""
  tmp="$(mktemp -p "$env_dir" ".${env_base}.tmp.XXXXXX")"

  if [[ -f "$file" ]]; then
    grep -Ev "^[[:space:]]*${key}[[:space:]]*=" "$file" >"$tmp" || true
    chmod --reference="$file" "$tmp" || true
  else
    : >"$tmp"
  fi

  printf "\n%s=%s\n" "$key" "$value" >>"$tmp"
  mv "$tmp" "$file"
}

if [[ "$apply_env_tag" -eq 1 ]]; then
  if [[ ! -f "$env_file" ]]; then
    echo "ERROR: cannot apply CW_IMAGE_TAG to missing env file: $env_file" >&2
    exit 1
  fi
  apply_env_updates_to_file "$env_file" "CW_IMAGE_TAG" "$tag"
  echo "INFO: wrote CW_IMAGE_TAG=$tag to $env_file" >&2
fi

compose=(script/ops/chatwoot_compose.sh --env-file "$env_file")

container_ids="$("${compose[@]}" ps -q 2>/dev/null || true)"
if [[ -n "$container_ids" && "$skip_backup" -eq 0 ]]; then
  echo "INFO: running pre-upgrade backup (set --skip-backup to disable)..." >&2
  CW_ENV_FILE="$env_file" bash script/ops/chatwoot_backup.sh
fi

if [[ "$skip_pull" -eq 1 ]]; then
  echo "INFO: skipping image pulls (--skip-pull) (CW_IMAGE_TAG=$tag)..." >&2
else
  if [[ "$pull_all" -eq 1 ]]; then
    echo "INFO: pulling all services (CW_IMAGE_TAG=$tag)..." >&2
    CW_IMAGE_TAG="$tag" "${compose[@]}" pull
  else
    echo "INFO: pulling Chatwoot services (rails/sidekiq/migrate) (CW_IMAGE_TAG=$tag)..." >&2
    CW_IMAGE_TAG="$tag" "${compose[@]}" pull rails sidekiq migrate
  fi
fi

echo "INFO: applying upgrade (CW_IMAGE_TAG=$tag)..." >&2
CW_IMAGE_TAG="$tag" "${compose[@]}" up -d

if [[ "$skip_smoketest" -eq 0 ]]; then
  echo "INFO: running post-upgrade smoketest..." >&2
  bash script/ops/chatwoot_smoketest.sh --env-file "$env_file"
fi

echo "Upgrade complete (CW_IMAGE_TAG=$tag)"
