# Backup/Restore + Upgrade Chatwoot (Docker Compose prod)

Tài liệu này là runbook **sao lưu/khôi phục** và **nâng cấp** cho stack chạy theo `docker-compose.production.yaml`.

## 0) Điều kiện tiên quyết (pass/fail rõ ràng)

### Điều kiện: stack đang chạy ổn định
- PASS nếu service đều `Up` và (sau khi boot) hiển thị `(healthy)`:
  - `docker compose -f docker-compose.production.yaml ps`

### Đủ dung lượng để lưu backup
- PASS nếu còn đủ disk (tuỳ dữ liệu attachments):
  - `df -h`

### Có thư mục lưu backup (trên host)
- PASS nếu tạo được:
  - `mkdir -p backup`

## 0.1) Rehearsal (khuyến nghị trước khi làm trên prod)

Mục tiêu: tập restore/upgrade trên một stack “tách biệt” để tránh ảnh hưởng prod.

**Nguyên tắc tách biệt:**
- Dùng **project name khác** (`COMPOSE_PROJECT_NAME`) để tách volumes/networks.
- Dùng **host ports khác** để tránh conflict.
- Dùng **env file khác** (ví dụ `.env.rehearsal`) để tái lập được.

Ví dụ tạo rehearsal env file (không commit):
```sh
cp .env .env.rehearsal
```

Trong `.env.rehearsal`, set tối thiểu (ví dụ):
```sh
COMPOSE_PROJECT_NAME=chatwoot-rehearsal
CW_WEB_PORT=3010
CW_POSTGRES_PORT=5440
CW_REDIS_PORT=6385
CW_CADDY_HTTP_PORT=8085
CW_CADDY_HTTPS_PORT=8445
ZALO_ADAPTER_HOST_PORT=3005
```

Start rehearsal stack:
```sh
bash script/ops/chatwoot_deploy.sh --env-file .env.rehearsal
```

Khi chạy backup/restore/upgrade rehearsal, luôn chỉ rõ `--env-file .env.rehearsal`
(và/hoặc export `COMPOSE_PROJECT_NAME=chatwoot-rehearsal` nếu bạn không đặt biến này trong file).

## 1) Backup (khuyến nghị theo thứ tự)

Tuỳ chọn (tái lập được): dùng host script trong repo:
- `bash script/ops/chatwoot_backup.sh`

Script này sẽ backup:
- `.env` (nếu tồn tại)
- Postgres dump (`pg_dump`)
- `/app/storage` (attachments)
- dọn backup cũ theo `CW_BACKUP_KEEP_DAYS`

### 1.1 Backup cấu hình `.env` (quan trọng)
> `.env` chứa secret. **Không commit**, lưu ở nơi an toàn.

- `cp .env "backup/env-$(date +%F-%H%M%S).env"`

### 1.2 Backup Postgres (SQL dump)
- PASS nếu tạo được file `.sql.gz` và size > 0:
```sh
docker compose -f docker-compose.production.yaml exec -T postgres \
  sh -lc 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  | gzip > "backup/pgdump-$(date +%F-%H%M%S).sql.gz"
```

### 1.3 Backup storage (attachments)
> Volume `storage_data` được mount vào `rails` tại `/app/storage`.

- PASS nếu tạo được file `.tgz` và size > 0:
```sh
docker compose -f docker-compose.production.yaml exec -T rails \
  sh -lc 'tar -czf - -C /app/storage .' \
  > "backup/storage-$(date +%F-%H%M%S).tgz"
```

## 2) Restore (khôi phục)

> CẢNH BÁO: restore sẽ ghi đè dữ liệu. Khuyến nghị làm trên môi trường staging trước.

Tuỳ chọn (khuyến nghị, tái lập được): dùng script:
- `bash script/ops/chatwoot_restore.sh --yes --pgdump backup/pgdump-....sql.gz --storage backup/storage-....tgz`

### 2.1 Stop app layer (giữ DB/Redis)
```sh
docker compose -f docker-compose.production.yaml stop rails sidekiq
```

### 2.2 Restore Postgres từ dump
Tuỳ chọn A (restore trực tiếp, có thể fail nếu schema/constraints xung đột):
```sh
gunzip -c backup/pgdump-*.sql.gz | docker compose -f docker-compose.production.yaml exec -T postgres \
  sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Tuỳ chọn B (reset schema trước khi restore; sẽ xoá toàn bộ data trong DB):
```sh
docker compose -f docker-compose.production.yaml exec -T postgres sh -lc \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"'

gunzip -c backup/pgdump-*.sql.gz | docker compose -f docker-compose.production.yaml exec -T postgres \
  sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1'
```

### 2.3 Restore storage (attachments)
```sh
cat backup/storage-*.tgz | docker compose -f docker-compose.production.yaml run --rm --no-deps -T --entrypoint sh rails -lc \
  'mkdir -p /app/storage && tar -xzf - -C /app/storage'
```

### 2.4 Start lại stack
```sh
docker compose -f docker-compose.production.yaml up -d
```

PASS nếu Web UI truy cập được:
- `curl -fsS -o /dev/null -w '%{http_code}\\n' "http://127.0.0.1:${CW_WEB_PORT:-6000}/"`
- Ghi chú: nếu bạn override `CW_WEB_PORT`, hãy `export CW_WEB_PORT=...` hoặc thay port trực tiếp trong URL.

## 3) Upgrade (nâng cấp)

### 3.1 Chuẩn bị
- Luôn backup theo mục (1) trước khi upgrade.
- Nên **pin version** bằng `CW_IMAGE_TAG` trong `.env` (hoặc export khi chạy compose).

Tuỳ chọn (tái lập được): dùng script:
- `bash script/ops/chatwoot_upgrade.sh --tag latest`

Ghi chú:
- Nếu bạn build image local (ví dụ `chatwoot/chatwoot:local`), dùng `--skip-pull` để tránh `docker compose pull` fail:
  - `bash script/ops/chatwoot_upgrade.sh --tag local --skip-pull`

### 3.2 Thực hiện upgrade
Ví dụ upgrade lên một tag cụ thể (`latest` để lấy image mới nhất):
```sh
CW_IMAGE_TAG=latest docker compose -f docker-compose.production.yaml pull
CW_IMAGE_TAG=latest docker compose -f docker-compose.production.yaml up -d
```

Nếu đang chạy overlays (ví dụ Zalo adapter/Caddy), dùng cả hai file khi pull/up:
```sh
CW_IMAGE_TAG=latest docker compose -f docker-compose.production.yaml -f docker-compose.caddy.yaml pull
CW_IMAGE_TAG=latest docker compose -f docker-compose.production.yaml -f docker-compose.caddy.yaml up -d
```

PASS nếu:
- `docker compose -f docker-compose.production.yaml ps` không có container `Restarting`
- Web UI trả `200/302`

## 4) Rollback (nếu cần)

1) Set `CW_IMAGE_TAG` về version cũ.
2) `docker compose ... pull && docker compose ... up -d`
3) Nếu dữ liệu đã thay đổi theo migration, restore lại DB/storage từ backup.

## 5) Kết luận

Khi backup tạo được file hợp lệ, restore/upgrade chạy PASS theo các checkpoint ⇒ **OPS THÀNH CÔNG**.

Refs: `doc/deploy.md`, `docker-compose.production.yaml`, `docker-compose.caddy.yaml`, `docker-compose.zalo-adapter.yaml`
