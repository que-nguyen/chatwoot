#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage: bash DEPLOY.sh [options]

One-shot Phase 0 deployment helper for Chatwoot (Docker Compose):
- Creates an env file (defaults to .env.production) from .env.example if missing
- Generates required secrets if missing/placeholder:
  - SECRET_KEY_BASE, POSTGRES_PASSWORD, REDIS_PASSWORD
- Runs: preflight -> docker compose up -d -> smoketest

Options:
  -e, --env-file PATH        Env file to create/use (default: .env.production)
  --frontend-url URL         Override FRONTEND_URL in env file
  --image-tag TAG            Set CW_IMAGE_TAG in env file (recommended for prod)
  --strict, --strict-production
                             Enforce safer production defaults (fails fast)
  --follow-logs              Tail logs after `up -d` (Ctrl-C to stop)
  --skip-smoketest           Skip smoketest step
  --verify-restart           Restart stack and re-run smoketest (persist check)
  -h, --help                 Show help
EOF
}

env_file=".env.production"
frontend_url=""
image_tag=""
strict_production=0
follow_logs=0
skip_smoketest=0
verify_restart=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env-file)
      env_file="${2:-}"
      shift 2
      ;;
    --frontend-url)
      frontend_url="${2:-}"
      shift 2
      ;;
    --image-tag)
      image_tag="${2:-}"
      shift 2
      ;;
    --strict|--strict-production)
      strict_production=1
      shift
      ;;
    --follow-logs)
      follow_logs=1
      shift
      ;;
    --skip-smoketest)
      skip_smoketest=1
      shift
      ;;
    --verify-restart)
      verify_restart=1
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

if [[ -z "$env_file" ]]; then
  echo "ERROR: --env-file is required" >&2
  exit 2
fi

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

get_file_value() {
  local key="$1"
  local default="${2:-}"

  if [[ -f "$env_file" ]] && read_env_value_from_file "$env_file" "$key"; then
    return 0
  fi

  printf "%s" "$default"
}

random_hex() {
  local bytes="$1"

  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$bytes" <<'PY'
import secrets
import sys

bytes_len = int(sys.argv[1])
print(secrets.token_hex(bytes_len))
PY
    return 0
  fi

  if [[ -r /dev/urandom ]] && command -v hexdump >/dev/null 2>&1; then
    hexdump -vn "$bytes" -e '/1 "%02x"' /dev/urandom
    return 0
  fi

  echo "ERROR: unable to generate random hex (need openssl/python3/hexdump)" >&2
  return 1
}

set_env_value() {
  local key="$1"
  local value="$2"
  local file="$3"

  local tmp=""
  tmp="$(mktemp)"

  awk -v k="$key" -v v="$value" '
    {
      if ($0 ~ "^[[:space:]]*" k "[[:space:]]*=") {
        print k "=" v
        next
      }
      print $0
    }
    END {
      if (NR == 0) {
        print k "=" v
      }
    }
  ' "$file" >"$tmp"

  if ! grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$tmp"; then
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi

  mv "$tmp" "$file"
}

ensure_env_file() {
  if [[ -f "$env_file" ]]; then
    return 0
  fi

  if [[ ! -f ".env.example" ]]; then
    echo "ERROR: .env.example not found in repo root" >&2
    exit 2
  fi

  umask 077
  cp .env.example "$env_file"
  chmod 600 "$env_file" || true
  echo "INFO: created $env_file from .env.example"
}

ensure_required_secrets() {
  local secret_key_base=""
  secret_key_base="$(get_file_value SECRET_KEY_BASE "")"
  if [[ -z "$secret_key_base" || "$secret_key_base" == "replace_with_lengthy_secure_hex" ]]; then
    if [[ -n "${SECRET_KEY_BASE:-}" && "${SECRET_KEY_BASE:-}" != "replace_with_lengthy_secure_hex" ]]; then
      echo "INFO: writing SECRET_KEY_BASE from environment"
      set_env_value SECRET_KEY_BASE "$SECRET_KEY_BASE" "$env_file"
    else
      echo "INFO: generating SECRET_KEY_BASE"
      set_env_value SECRET_KEY_BASE "$(random_hex 64)" "$env_file"
    fi
  fi

  local postgres_password=""
  postgres_password="$(get_file_value POSTGRES_PASSWORD "")"
  if [[ -z "$postgres_password" ]]; then
    if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
      echo "INFO: writing POSTGRES_PASSWORD from environment"
      set_env_value POSTGRES_PASSWORD "$POSTGRES_PASSWORD" "$env_file"
    else
      echo "INFO: generating POSTGRES_PASSWORD"
      set_env_value POSTGRES_PASSWORD "$(random_hex 24)" "$env_file"
    fi
  fi

  local redis_password=""
  redis_password="$(get_file_value REDIS_PASSWORD "")"
  if [[ -z "$redis_password" ]]; then
    if [[ -n "${REDIS_PASSWORD:-}" ]]; then
      echo "INFO: writing REDIS_PASSWORD from environment"
      set_env_value REDIS_PASSWORD "$REDIS_PASSWORD" "$env_file"
    else
      echo "INFO: generating REDIS_PASSWORD"
      set_env_value REDIS_PASSWORD "$(random_hex 24)" "$env_file"
    fi
  fi
}

ensure_sane_defaults() {
  if [[ -n "$frontend_url" ]]; then
    set_env_value FRONTEND_URL "$frontend_url" "$env_file"
  else
    local current_frontend_url=""
    current_frontend_url="$(get_file_value FRONTEND_URL "")"
    if [[ -z "$current_frontend_url" && -n "${FRONTEND_URL:-}" ]]; then
      set_env_value FRONTEND_URL "$FRONTEND_URL" "$env_file"
      current_frontend_url="$FRONTEND_URL"
    fi
    if [[ -z "$current_frontend_url" ]]; then
      local web_port=""
      web_port="$(get_file_value CW_WEB_PORT "")"
      if [[ -z "$web_port" ]]; then
        web_port="${CW_WEB_PORT:-3000}"
      fi
      set_env_value FRONTEND_URL "http://127.0.0.1:${web_port}/" "$env_file"
    fi
  fi

  if [[ -n "$image_tag" ]]; then
    set_env_value CW_IMAGE_TAG "$image_tag" "$env_file"
  else
    local current_image_tag=""
    current_image_tag="$(get_file_value CW_IMAGE_TAG "")"
    if [[ -z "$current_image_tag" && -n "${CW_IMAGE_TAG:-}" ]]; then
      set_env_value CW_IMAGE_TAG "$CW_IMAGE_TAG" "$env_file"
      current_image_tag="$CW_IMAGE_TAG"
    fi
    if [[ -z "$current_image_tag" && -f VERSION_CW ]]; then
      local version=""
      version="$(trim "$(cat VERSION_CW || true)")"
      if [[ -n "$version" ]]; then
        echo "INFO: setting CW_IMAGE_TAG=$version (from VERSION_CW)"
        set_env_value CW_IMAGE_TAG "$version" "$env_file"
      fi
    fi
  fi
}

echo "== Chatwoot one-shot deploy (Phase 0) =="
echo "env file: $env_file"

ensure_env_file
ensure_required_secrets
ensure_sane_defaults

deploy_args=(--env-file "$env_file")
if [[ "$strict_production" -eq 1 ]]; then
  deploy_args+=(--strict-production)
fi
if [[ "$follow_logs" -eq 1 ]]; then
  deploy_args+=(--follow-logs)
fi
if [[ "$skip_smoketest" -eq 1 ]]; then
  deploy_args+=(--skip-smoketest)
fi

bash script/ops/chatwoot_deploy.sh "${deploy_args[@]}"

if [[ "$verify_restart" -eq 1 ]]; then
  echo "== Restart verification =="
  script/ops/chatwoot_compose.sh --env-file "$env_file" down
  script/ops/chatwoot_compose.sh --env-file "$env_file" up -d
  bash script/ops/chatwoot_smoketest.sh --env-file "$env_file"
fi

final_frontend_url="$(get_file_value FRONTEND_URL "")"
if [[ -n "$final_frontend_url" ]]; then
  echo "Next: open $final_frontend_url and create the admin user"
else
  echo "Next: open the Web UI and create the admin user"
fi
