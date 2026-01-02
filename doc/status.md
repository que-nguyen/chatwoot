# Runbook status

Last verified: 2026-01-02

## Checks executed (local host)

- Preflight: `bash script/ops/chatwoot_preflight.sh` (OK)
  - WARN: `CW_IMAGE_TAG` not pinned (effective tag: `latest`)
  - WARN: `CADDY_DOMAIN` unset (defaults to `localhost`, internal CA)
- Phase 0 smoketest: `bash script/ops/chatwoot_smoketest.sh` (OK)
- Phase 1 smoketest (Zalo adapter): `bash script/ops/chatwoot_zalo_smoketest.sh` (OK)
- Phase 2 smoketest (Caddy): `bash script/ops/chatwoot_caddy_smoketest.sh` (OK)
- Backup: `bash script/ops/chatwoot_backup.sh` (OK)
- Phase 3 restore rehearsal: `bash script/ops/chatwoot_restore.sh --yes --pgdump backup/pgdump-2026-01-02-114815.sql.gz --storage backup/storage-2026-01-02-114815.tgz` (OK)
- Phase 3 upgrade rehearsal: `bash script/ops/chatwoot_upgrade.sh --tag latest` (OK)
- Phase 4 systemd install (user): `bash script/ops/chatwoot_systemd_install.sh --user` (OK)
- Phase 4 systemd smoketest (user): `bash script/ops/chatwoot_systemd_smoketest.sh --user` (OK)

## Host port mapping (observed)

- Chatwoot Web (`rails:3000`) → `127.0.0.1:3001`
- Postgres (`postgres:5432`) → `127.0.0.1:5434`
- Redis (`redis:6379`) → `127.0.0.1:6380`
- Caddy (`80/443`) → `8081/8443`
- Zalo adapter (`zalo_adapter:3001`) → `127.0.0.1:3002`

## Next

- Phase 4 (VPS): install/enable system-scope systemd timers (requires root/sudo): `bash script/ops/chatwoot_systemd_install.sh` + `bash script/ops/chatwoot_systemd_smoketest.sh`
