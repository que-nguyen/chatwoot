# Docker Compose Runbooks

Các tài liệu trong thư mục này là runbook triển khai/vận hành Chatwoot dựa trên `docker-compose.production.yaml` và các file overlay.

## Runbooks

- Triển khai Chatwoot (prod/staging): `doc/deploy.md`
- Zalo adapter overlay (zca-js): `doc/zalo_adapter.md`
- Caddy overlay (public HTTPS/TLS): `doc/caddy_tls.md`
- Backup/Restore + Upgrade (prod): `doc/backup_restore_upgrade.md`
- Monitoring + Automated Backups (prod): `doc/monitoring_backups.md`
- Status (lần chạy/verify gần nhất, không chứa secrets): `doc/status.md`

## Ghi chú overlay (tránh orphan containers)

Khi bạn chạy thêm overlays, hãy include **đầy đủ** các file compose trong mọi lệnh `docker compose up/pull/logs/down` để tránh orphan containers và thay đổi port mapping ngoài ý muốn.

Tip: dùng wrapper `script/ops/chatwoot_compose.sh` để luôn include đúng `--env-file` + danh sách compose files (set `CW_ENV_FILE` và `CW_COMPOSE_FILES`).

Gợi ý: `script/ops/chatwoot_preflight.sh` sẽ WARN nếu phát hiện service overlay đang chạy (ví dụ `caddy`, `zalo_adapter`) nhưng bạn chưa include file overlay tương ứng trong `CW_COMPOSE_FILES`.

## Quick checks (khuyến nghị)

Sau khi đã tạo `.env` từ `.env.example` và set các biến bắt buộc (xem `doc/deploy.md`):

- Preflight (secrets + port + overlay mismatch):
  - `bash script/ops/chatwoot_preflight.sh`
- Start stack (base hoặc kèm overlays theo `CW_COMPOSE_FILES`):
  - `script/ops/chatwoot_compose.sh up -d`
- Smoke tests:
  - Base stack: `bash script/ops/chatwoot_smoketest.sh`
  - Zalo adapter overlay: `bash script/ops/chatwoot_zalo_smoketest.sh` (nếu có `zalo_adapter`)
  - Caddy overlay: `bash script/ops/chatwoot_caddy_smoketest.sh` (nếu có `caddy`)

## Helper scripts (tuỳ chọn)

- `script/ops/chatwoot_preflight.sh`: check nhanh prerequisite/port/secret trước khi `up -d`
- `script/ops/chatwoot_smoketest.sh`: smoke-test (health + Web UI)
- `script/ops/chatwoot_zalo_smoketest.sh`: smoke-test (adapter health + webhook delivery)
- `script/ops/chatwoot_caddy_smoketest.sh`: smoke-test (Caddy reverse proxy + TLS)
- `script/ops/chatwoot_healthcheck.sh`: check health & exit code (dùng cho cron/systemd alert)
- `script/ops/chatwoot_backup.sh`: backup Postgres + storage (dùng cho cron/systemd)
- `script/ops/chatwoot_restore.sh`: restore Postgres + storage từ backup files (destructive)
- `script/ops/chatwoot_upgrade.sh`: upgrade Chatwoot image tag + smoketest
- `script/ops/chatwoot_systemd_smoketest.sh`: check nhanh systemd timers
- `script/ops/chatwoot_compose.sh`: wrapper `docker compose` dùng đúng env + compose files
