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

