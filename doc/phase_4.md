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
- `CW_ENV_FILE` (default: `.env`) — nên trùng với env file đang dùng cho stack
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

### 1.4 Systemd timer (khuyến nghị trên VPS)
Repo đã có unit templates:
- `script/ops/systemd/chatwoot-backup.service`
- `script/ops/systemd/chatwoot-backup.timer`

Tuỳ chọn nhanh (khuyến nghị): chạy installer trong repo (cài **cả** backup + healthcheck timers):
```sh
bash script/ops/chatwoot_systemd_install.sh --compose-files "docker-compose.production.yaml docker-compose.caddy.yaml"
```

Ghi chú:
- Mặc định installer cài **system-scope** units vào `/etc/systemd/system` và cần root/sudo (phù hợp VPS).
- Nếu bạn không có sudo (local/dev), dùng `--user` để cài **user-scope** units vào `$XDG_CONFIG_HOME/systemd/user` (default: `~/.config/systemd/user`) (env file: `$XDG_CONFIG_HOME/chatwoot/ops.env`, default: `~/.config/chatwoot/ops.env`):
  - `bash script/ops/chatwoot_systemd_install.sh --user`
  - `bash script/ops/chatwoot_systemd_smoketest.sh --user`
  - Lưu ý: user-scope timers chỉ chạy khi user systemd instance đang sống; trên server/headless nếu bạn muốn timer vẫn chạy sau khi logout, hãy dùng system-scope (khuyến nghị) hoặc bật linger (cần sudo): `sudo loginctl enable-linger $USER`.
- Nếu môi trường của bạn chưa có user systemd session (nên `systemctl --user ...` fail), bạn vẫn có thể “cài file trước” rồi enable sau:
  - `bash script/ops/chatwoot_systemd_install.sh --user --no-enable`
  - Sau đó (khi đã có session): `systemctl --user daemon-reload && systemctl --user enable --now chatwoot-backup.timer chatwoot-healthcheck.timer`
- Script sẽ tạo env file nếu chưa có (`/etc/chatwoot/ops.env` hoặc `$XDG_CONFIG_HOME/chatwoot/ops.env` (default: `~/.config/chatwoot/ops.env`) với `--user`); nếu file đã tồn tại, script sẽ không overwrite trừ khi dùng `--overwrite-env`.
- Để chỉ cài backup timer: thêm `--backup-only`.

Cài thủ công (nếu không dùng installer):

1) Copy units lên host:
```sh
sudo cp script/ops/systemd/chatwoot-backup.service /etc/systemd/system/chatwoot-backup.service
sudo cp script/ops/systemd/chatwoot-backup.timer /etc/systemd/system/chatwoot-backup.timer
```

2) Tạo env file cho unit (bắt buộc) để set path + overlay compose / retention:
```sh
sudo install -d -m 0750 /etc/chatwoot
sudoedit /etc/chatwoot/ops.env
```

Tip: có thể bắt đầu từ template trong repo:
```sh
sudo cp /path/to/chatwoot/script/ops/systemd/ops.env.example /etc/chatwoot/ops.env
sudoedit /etc/chatwoot/ops.env
```

Ví dụ nội dung `/etc/chatwoot/ops.env`:
```sh
CHATWOOT_ROOT=/path/to/chatwoot
CW_ENV_FILE=/path/to/chatwoot/.env
CW_COMPOSE_FILES="docker-compose.production.yaml docker-compose.caddy.yaml"
CW_BACKUP_KEEP_DAYS=14
```

3) Enable timer:
```sh
sudo systemctl daemon-reload
sudo systemctl enable --now chatwoot-backup.timer
systemctl list-timers --all | grep chatwoot-backup
```

4) Verify + xem log (khuyến nghị):
```sh
systemctl status chatwoot-backup.timer
sudo systemctl start chatwoot-backup.service
journalctl -u chatwoot-backup.service --since today -f
```

5) Quick verify (tuỳ chọn):
```sh
bash script/ops/chatwoot_systemd_smoketest.sh
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

### 2.3 Systemd timer (mỗi 5 phút)
Repo đã có unit templates:
- `script/ops/systemd/chatwoot-healthcheck.service`
- `script/ops/systemd/chatwoot-healthcheck.timer`

Tuỳ chọn nhanh:
- Nếu bạn **chưa** cài timer nào: dùng installer (cài **cả** backup + healthcheck timers) ở mục (1.4).
- Nếu bạn chỉ muốn cài healthcheck timer:
```sh
bash script/ops/chatwoot_systemd_install.sh --healthcheck-only
```

1) Copy units lên host:
```sh
sudo cp script/ops/systemd/chatwoot-healthcheck.service /etc/systemd/system/chatwoot-healthcheck.service
sudo cp script/ops/systemd/chatwoot-healthcheck.timer /etc/systemd/system/chatwoot-healthcheck.timer
```

2) Tạo `/etc/chatwoot/ops.env` như mục (1.4) để set:
```sh
CHATWOOT_ROOT=/path/to/chatwoot
CW_ENV_FILE=/path/to/chatwoot/.env
CW_COMPOSE_FILES="docker-compose.production.yaml docker-compose.caddy.yaml"
CW_ALERT_WEBHOOK_MODE=discord
CW_ALERT_WEBHOOK_URL=https://...
```

3) Enable timer:
```sh
sudo systemctl daemon-reload
sudo systemctl enable --now chatwoot-healthcheck.timer
systemctl list-timers --all | grep chatwoot-healthcheck
```

4) Verify + xem log (khuyến nghị):
```sh
systemctl status chatwoot-healthcheck.timer
sudo systemctl start chatwoot-healthcheck.service
journalctl -u chatwoot-healthcheck.service --since today -f
```

Quick verify (tuỳ chọn):
```sh
bash script/ops/chatwoot_systemd_smoketest.sh --healthcheck-only
```
Nếu bạn đã cài bằng `--user`, thêm `--user`:
```sh
bash script/ops/chatwoot_systemd_smoketest.sh --user --healthcheck-only
```

## 3) Kết luận

- Khi (1) backup chạy PASS theo lịch và (2) healthcheck PASS/alert hoạt động ⇒ **OPS baseline hoàn tất**.

Refs: `doc/phase_3.md`, `docker-compose.production.yaml`, `script/ops/chatwoot_backup.sh`, `script/ops/chatwoot_healthcheck.sh`
