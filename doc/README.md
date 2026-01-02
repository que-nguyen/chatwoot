# Runbook Docker Compose (theo phase)

Các tài liệu trong thư mục này là runbook triển khai/vận hành Chatwoot theo từng phase, dựa trên `docker-compose.production.yaml` và các file overlay.

## Phases

- **Phase 0**: Triển khai Chatwoot (prod/staging) bằng Docker Compose  
  File: `doc/phase_0.md`
- **Phase 1**: Kết nối Zalo Web ↔ Chatwoot bằng Zalo Adapter (zca-js)  
  File: `doc/phase_1.md`
- **Phase 2**: Public access + TLS cho Chatwoot bằng Caddy (overlay)  
  File: `doc/phase_2.md`
- **Phase 3**: Backup/Restore + Upgrade Chatwoot (prod)  
  File: `doc/phase_3.md`
- **Phase 4**: Monitoring + Automated Backups (prod)  
  File: `doc/phase_4.md`

## Ghi chú overlay (tránh orphan containers)

Khi bạn chạy thêm Phase 1/2 (overlay), hãy include **đầy đủ** các file compose trong mọi lệnh `docker compose up/pull/logs/down` để tránh orphan containers và thay đổi port mapping ngoài ý muốn.

Tip: dùng wrapper `script/ops/chatwoot_compose.sh` để luôn include đúng `--env-file` + danh sách compose files (set `CW_ENV_FILE` và `CW_COMPOSE_FILES`).

Gợi ý: `script/ops/chatwoot_preflight.sh` sẽ WARN nếu phát hiện service overlay đang chạy (ví dụ `caddy`, `zalo_adapter`) nhưng bạn chưa include file overlay tương ứng trong `CW_COMPOSE_FILES`.

## Helper scripts (tuỳ chọn)

- `script/ops/chatwoot_preflight.sh`: check nhanh prerequisite/port/secret trước khi `up -d`
- `script/ops/chatwoot_smoketest.sh`: smoke-test Phase 0 (health + Web UI)
- `script/ops/chatwoot_zalo_smoketest.sh`: smoke-test Phase 1 (adapter health + webhook delivery)
- `script/ops/chatwoot_caddy_smoketest.sh`: smoke-test Phase 2 (Caddy reverse proxy + TLS)
- `script/ops/chatwoot_healthcheck.sh`: check health & exit code (dùng cho cron/systemd alert)
- `script/ops/chatwoot_backup.sh`: backup Postgres + storage (dùng cho cron/systemd)
- `script/ops/chatwoot_compose.sh`: wrapper `docker compose` dùng đúng env + compose files
