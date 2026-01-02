# Chatwoot (Docker Compose) – Runbook triển khai

Tài liệu này hướng dẫn triển khai Chatwoot bằng Docker Compose theo hướng “chạy được trước, tối ưu sau”, kèm checkpoint pass/fail và các lỗi thường gặp.

> Phạm vi: Ubuntu 20.04+ (hoặc tương đương), Docker Compose (không Kubernetes).

## 0) Mục tiêu & tiêu chí đạt

**PASS khi:**
- `bash script/ops/chatwoot_preflight.sh --env-file <env>` trả về `Preflight OK`
- `script/ops/chatwoot_compose.sh --env-file <env> ps` không có container crash-loop
- `bash script/ops/chatwoot_smoketest.sh --env-file <env>` trả về `Smoketest OK`
- Truy cập Web UI được, tạo admin thành công, tạo inbox, gửi/nhận thử message
- Restart stack không mất dữ liệu (Postgres/Redis/Storage persist qua volumes)

**FAIL khi:** bất kỳ bước nào ở trên fail, hoặc `migrate` không exit code 0.

## 1) Điều kiện tiên quyết (Preflight checklist)

### 1.1 Docker & Docker Compose

Chạy (tại repo root):

```bash
docker --version
docker compose version
docker ps
```

**Pass:** thấy version, `docker ps` chạy được (không permission error).

### 1.2 Tài nguyên máy

Khuyến nghị tối thiểu để chạy thử:
- Disk trống: >= 10GiB (tùy số lượng attachments)
- RAM: >= 2GiB (nên 4GiB+ cho production)

Script `chatwoot_preflight.sh` sẽ cảnh báo nếu thấp.

### 1.3 Port & firewall

Mặc định (không reverse proxy), stack bind vào localhost:
- Web: `127.0.0.1:${CW_WEB_PORT:-6000}`
- Postgres: `127.0.0.1:${CW_POSTGRES_PORT:-2716}`
- Redis: `127.0.0.1:${CW_REDIS_PORT:-6379}`

**Production có domain/public access:** dùng Caddy overlay (`docker-compose.caddy.yaml`) để mở `80/443`.

Nếu bật firewall (ufw/firewalld/security group), cần allow các port tương ứng (đặc biệt 80/443 khi dùng Caddy).

## 2) Chuẩn bị cấu hình (.env)

### 2.1 Tạo env file

Khuyến nghị không dùng `.env` chung cho mọi môi trường. Tạo file riêng:

```bash
cp .env.example .env.production
```

### 2.2 Các biến bắt buộc

Mở `.env.production` và set tối thiểu:

- `SECRET_KEY_BASE`: secret cho cookie/signing (bắt buộc, không dùng placeholder)
- `POSTGRES_PASSWORD`: password DB (bắt buộc)
- `REDIS_PASSWORD`: password Redis (bắt buộc)
- `FRONTEND_URL`: URL public dùng trong link/email (local: `http://127.0.0.1:<port>`, production: `https://<domain>`)

Gợi ý generate nhanh:

```bash
openssl rand -hex 64  # SECRET_KEY_BASE
openssl rand -hex 24  # POSTGRES_PASSWORD
openssl rand -hex 24  # REDIS_PASSWORD
```

### 2.3 Biến quan trọng nên set cho production

- `CW_IMAGE_TAG`: tuỳ chọn; mặc định `latest`. Nếu pin version mà gặp lỗi `manifest unknown`, đổi về `latest` hoặc bỏ biến này.
- `ENABLE_ACCOUNT_SIGNUP=false`: chặn self-signup (tùy chính sách)
- `FORCE_SSL=true`: khi chạy sau reverse proxy TLS (HTTPS / Caddy)

### 2.4 Chọn compose files (CW_COMPOSE_FILES)

Mặc định scripts dùng `docker-compose.production.yaml`.

- Chỉ production compose:
  ```bash
  CW_COMPOSE_FILES="docker-compose.production.yaml"
  ```
- Bật Caddy (public HTTPS):
  ```bash
  CW_COMPOSE_FILES="docker-compose.production.yaml docker-compose.caddy.yaml"
  CADDY_DOMAIN=chatwoot.example.com
  ```

## 3) Chạy preflight (bắt buộc)

```bash
bash script/ops/chatwoot_preflight.sh --env-file .env.production
```

**Pass:** `Preflight OK`  
**Fail:** sửa theo message (thiếu secret, port conflict, docker daemon, …) rồi chạy lại.

Tip (VPS/prod): dùng strict mode để preflight fail sớm nếu config “không an toàn cho production”:
```bash
bash script/ops/chatwoot_preflight.sh --env-file .env.production --strict-production
```

## 4) Triển khai stack

### 4.1 Cách khuyến nghị (1 lệnh)

```bash
bash DEPLOY.sh
```

Script này sẽ tự tạo `.env.production` từ `.env.example` (nếu chưa có) và generate các secret bắt buộc trước khi deploy.

### 4.2 Cách thủ công

Khởi động:

```bash
script/ops/chatwoot_compose.sh --env-file .env.production up -d
```

Theo dõi log (đặc biệt `migrate` phải thành công):

```bash
script/ops/chatwoot_compose.sh --env-file .env.production logs -f --tail=200 migrate rails sidekiq postgres redis
```

## 5) Kiểm chứng chạy thành công

### 5.1 Smoke test tự động

```bash
bash script/ops/chatwoot_smoketest.sh --env-file .env.production
```

### 5.2 Kiểm chứng thủ công (UI)

1) Mở Web UI:
- Nếu không dùng Caddy: `http://127.0.0.1:${CW_WEB_PORT:-6000}`
- Nếu dùng Caddy: `https://$CADDY_DOMAIN`

2) Tạo admin, tạo inbox, gửi thử tin nhắn.

3) Worker/Sidekiq, Redis, Postgres hoạt động:

```bash
script/ops/chatwoot_compose.sh --env-file .env.production ps
script/ops/chatwoot_compose.sh --env-file .env.production logs --tail=200 rails sidekiq
```

## 6) Kiểm tra sau triển khai (persist & restart)

Healthcheck tổng:

```bash
bash script/ops/chatwoot_healthcheck.sh --env-file .env.production
```

Restart stack và xác nhận dữ liệu không mất:

```bash
script/ops/chatwoot_compose.sh --env-file .env.production down
script/ops/chatwoot_compose.sh --env-file .env.production up -d
bash script/ops/chatwoot_smoketest.sh --env-file .env.production
```

> Lưu ý: dữ liệu persist qua volumes `postgres_data`, `redis_data`, `storage_data` (xem `docker-compose.production.yaml`).

## 7) Lỗi thường gặp & cách xử lý

### 7.1 Thiếu secret / password

**Triệu chứng:** preflight fail hoặc `redis` báo `REDIS_PASSWORD is required`.  
**Fix:** set `SECRET_KEY_BASE`, `POSTGRES_PASSWORD`, `REDIS_PASSWORD` trong env file rồi deploy lại.

### 7.2 Port conflict

**Triệu chứng:** preflight fail `port is already in use`.  
**Fix:** đổi `CW_WEB_PORT/CW_POSTGRES_PORT/CW_REDIS_PORT` sang port rảnh, rồi `up -d` lại.

### 7.3 `migrate` fail, rails/sidekiq không lên

**Check:**
```bash
script/ops/chatwoot_compose.sh --env-file .env.production logs --tail=300 migrate
```

**Fix thường gặp:** sai `POSTGRES_PASSWORD`, volume DB lỗi, disk full → sửa root-cause rồi chạy lại `up -d`.

### 7.4 Không truy cập được từ bên ngoài VPS

- Nếu stack bind vào `127.0.0.1`, bạn chỉ truy cập được trên VPS.
- Cách an toàn: bật Caddy overlay (80/443) hoặc dùng SSH tunnel:
  ```bash
  ssh -L 6000:127.0.0.1:6000 user@your-vps
  ```
- Nếu dùng firewall/security group: allow port 80/443 (Caddy) hoặc port bạn expose.

## 8) Kết luận (ghi nhận trạng thái)

Kết luận theo checklist ở mục **0)**:
- **CÀI ĐẶT THÀNH CÔNG** khi tất cả tiêu chí PASS đạt.
- **CHƯA ĐẠT** nếu còn fail, kèm log và nguyên nhân gốc (root cause) + hướng sửa.
