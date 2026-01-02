# Runbook status

Last verified: 2026-01-02

## Checks executed (local host)

- Preflight: `bash script/ops/chatwoot_preflight.sh --env-file .env` (OK)
  - WARN: `CW_IMAGE_TAG` not pinned (effective tag: `latest`)
  - WARN: `CADDY_DOMAIN` unset (defaults to `localhost`, internal CA)
  - NOTE: `ufw` status may require sudo; ensure required ports are allowed (especially `80/443` when using Caddy)
- Preflight (strict production): `bash script/ops/chatwoot_preflight.sh --env-file .env --strict-production` (FAIL)
  - FAIL: `CW_IMAGE_TAG` not pinned (effective tag: `latest`)
  - FAIL: `CADDY_DOMAIN` missing/empty while Caddy overlay is enabled
  - NOTE: once `CADDY_DOMAIN` is set to a public hostname, strict mode will also require `FORCE_SSL=true` and `FRONTEND_URL=https://$CADDY_DOMAIN`
- Smoketest (base stack): `bash script/ops/chatwoot_smoketest.sh --env-file .env` (OK)
- Smoketest (Zalo adapter overlay): `bash script/ops/chatwoot_zalo_smoketest.sh --env-file .env` (OK)
- Smoketest (Caddy overlay): `bash script/ops/chatwoot_caddy_smoketest.sh --env-file .env` (OK)
- Backup: `bash script/ops/chatwoot_backup.sh --env-file .env` (OK)
- Restore rehearsal: `COMPOSE_PROJECT_NAME=chatwoot-rehearsal bash script/ops/chatwoot_restore.sh --env-file .env.rehearsal --yes --pgdump backup/pgdump-2026-01-02-114815.sql.gz --storage backup/storage-2026-01-02-114815.tgz` (OK)
- Upgrade rehearsal: `COMPOSE_PROJECT_NAME=chatwoot-rehearsal bash script/ops/chatwoot_upgrade.sh --env-file .env.rehearsal --tag latest` (OK)
- Systemd timers install (user): `bash script/ops/chatwoot_systemd_install.sh --env-file .env --user` (OK)
- Systemd timers smoketest (user): `bash script/ops/chatwoot_systemd_smoketest.sh --user` (OK)

## Host port mapping (observed)

- Chatwoot Web (`rails:3000`) → `127.0.0.1:3001`
- Postgres (`postgres:5432`) → `127.0.0.1:5434`
- Redis (`redis:6379`) → `127.0.0.1:6380`
- Caddy (`80/443`) → `8081/8443`
- Zalo adapter (`zalo_adapter:3001`) → `127.0.0.1:3002`

## Next

- VPS: install/enable system-scope systemd timers (requires root/sudo): `bash script/ops/chatwoot_systemd_install.sh` + `bash script/ops/chatwoot_systemd_smoketest.sh`
- Production hardening: pin `CW_IMAGE_TAG`, set `CADDY_DOMAIN` (+ `FORCE_SSL=true` and `FRONTEND_URL=https://$CADDY_DOMAIN`), confirm firewall rules, then re-run strict preflight until OK
