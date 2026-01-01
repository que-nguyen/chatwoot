# Phase 4 — Monitoring + Automated Backups (Docker Compose prod)

Phase này bổ sung 2 thứ tối thiểu để vận hành stack Chatwoot chạy theo `docker-compose.production.yaml`:
- **Backup tự động** (Postgres + storage attachments) theo lịch.
- **Monitoring/alert** tối thiểu dựa trên Docker healthchecks.

## 0) Điều kiện tiên quyết (pass/fail rõ ràng)

### Phase 0 đang chạy ổn định
- PASS nếu service đều `Up` và (sau khi boot) hiển thị `(healthy)`:
  - `docker compose -f docker-compose.production.yaml ps`

### Có thư mục lưu backup (trên host)
- PASS nếu tạo được:
  - `mkdir -p backup`

Khuyến nghị:
- Backup nên được **sync ra offsite** (S3/rclone/restic) để tránh mất dữ liệu khi VPS hỏng disk.

### Có cơ chế chạy theo lịch
- PASS nếu có `cron` hoặc `systemd`:
  - `crontab -l` (cron), hoặc
  - `systemctl --version` (systemd)

## 1) Automated backups

Repo đã có script chạy trên host:
- `script/ops/chatwoot_backup.sh`

Script này sẽ:
- Copy `.env` (nếu file tồn tại) vào `backup/env-*.env`
- Dump Postgres (`pg_dump`) vào `backup/pgdump-*.sql.gz`
- Backup `/app/storage` (attachments) vào `backup/storage-*.tgz`
- (Tuỳ chọn) dọn file cũ theo `CW_BACKUP_KEEP_DAYS`

> Lý do chọn host-script thay vì “backup service container”: tránh mount Docker socket vào container và giữ vận hành đơn giản, dễ audit.

### 1.1 Chạy thử thủ công
```sh
bash script/ops/chatwoot_backup.sh
```

- PASS nếu tạo được các file và size > 0:
  - `ls -lh backup/pgdump-*.sql.gz backup/storage-*.tgz backup/env-*.env`

### 1.2 Tuỳ chọn cấu hình qua env vars
- `CW_BACKUP_DIR` (default: `backup`)
- `CW_BACKUP_KEEP_DAYS` (default: `14`)
- `CW_ENV_FILE` (default: `.env`)
- `CW_COMPOSE_FILES` (default: `docker-compose.production.yaml`)
  - Nếu bạn chạy overlay, set ví dụ:
    - Phase 2 (Caddy): `CW_COMPOSE_FILES="docker-compose.production.yaml docker-compose.caddy.yaml"`
    - Phase 1 (Zalo): `CW_COMPOSE_FILES="docker-compose.production.yaml docker-compose.zalo-adapter.yaml"`

### 1.3 Cron (ví dụ chạy lúc 02:00 mỗi ngày)
Sửa crontab:
```sh
crontab -e
```

Thêm dòng (đổi path cho đúng repo):
```cron
0 2 * * * cd /path/to/chatwoot && CW_BACKUP_KEEP_DAYS=14 bash script/ops/chatwoot_backup.sh >> backup/cron.log 2>&1
```

## 2) Monitoring / alert tối thiểu

Repo đã có script healthcheck chạy trên host:
- `script/ops/chatwoot_healthcheck.sh`

Script này sẽ:
- FAIL nếu có container (trừ `migrate`) không `running`
- FAIL nếu container có healthcheck mà health != `healthy`
- In ra bảng trạng thái và exit code != 0 khi FAIL

### 2.1 Chạy thử
```sh
bash script/ops/chatwoot_healthcheck.sh
echo $?
```

- PASS nếu exit code `0`.

### 2.2 Alert qua webhook (tuỳ chọn)
Set biến môi trường:
- `CW_ALERT_WEBHOOK_URL=...`
- `CW_ALERT_WEBHOOK_MODE=slack|discord` (default: `slack`)
- `CW_ALERT_PREFIX=...` (tuỳ chọn, default: `chatwoot`)

Ví dụ (Discord):
```sh
CW_ALERT_WEBHOOK_MODE=discord CW_ALERT_WEBHOOK_URL="https://..." bash script/ops/chatwoot_healthcheck.sh
```

Gợi ý: chạy script theo lịch (cron/systemd timer) mỗi 1–5 phút để có alert sớm.

## 3) Kết luận

- Khi (1) backup chạy PASS theo lịch và (2) healthcheck PASS/alert hoạt động ⇒ **OPS baseline hoàn tất**.

Refs: `doc/phase_3.md`, `docker-compose.production.yaml`, `script/ops/chatwoot_backup.sh`, `script/ops/chatwoot_healthcheck.sh`

