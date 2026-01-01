# Phase 2 — Public access + TLS cho Chatwoot bằng Caddy (Docker Compose overlay)

Phase này giúp đưa Chatwoot (đang chạy theo Phase 0) ra internet qua domain + HTTPS, không cần cài Nginx/Caddy trên host.

## 0) Điều kiện tiên quyết (pass/fail rõ ràng)

### Phase 0 đã chạy ổn định
- PASS nếu `rails/postgres/redis/sidekiq` đều `Up` và `(healthy)`:
  - `docker compose -f docker-compose.production.yaml ps`

### Domain + firewall
- PASS nếu:
  - DNS A/AAAA record của domain trỏ về IP VPS
  - Firewall/VPC mở inbound `80/tcp` và `443/tcp`

Ghi chú:
- Nếu máy đã có service chiếm port `80/443`, bạn phải dừng service đó hoặc đổi port mapping bằng `CW_CADDY_HTTP_PORT/CW_CADDY_HTTPS_PORT`.
- Let's Encrypt HTTP-01/TLS-ALPN challenges thường yêu cầu port `80/443` đúng chuẩn.

### Lưu ý về port override / overlay (tránh downtime ngoài ý muốn)
- Nếu Phase 0 đang chạy với `CW_WEB_PORT/CW_POSTGRES_PORT/CW_REDIS_PORT` khác mặc định, hãy đảm bảo các biến này **vẫn được set** (export hoặc để trong `.env`) khi chạy lệnh ở Phase 2. Nếu thiếu, `docker compose up` có thể recreate container với port mặc định và fail do port conflict.
- Nếu bạn đang chạy overlay Phase 1 (Zalo adapter), hãy include cả file đó khi `up/pull/logs` để tránh orphan containers.

## 1) Chuẩn bị `.env` (không commit)

Trong `.env` (hoặc export khi chạy compose), set tối thiểu:
- `FRONTEND_URL=https://chatwoot.example.com`
- `FORCE_SSL=true`
- `CADDY_DOMAIN=chatwoot.example.com`

Tuỳ chọn (đổi port nếu xung đột):
- `CW_CADDY_HTTP_PORT=8080`
- `CW_CADDY_HTTPS_PORT=8443`

## 2) Start stack với Caddy overlay

Nếu đang chạy kèm Zalo adapter (Phase 1), dùng cả 3 file:
```sh
docker compose \
  -f docker-compose.production.yaml \
  -f docker-compose.zalo-adapter.yaml \
  -f docker-compose.caddy.yaml \
  up -d
```

Nếu không dùng adapter, chỉ cần production + caddy:
```sh
docker compose \
  -f docker-compose.production.yaml \
  -f docker-compose.caddy.yaml \
  up -d
```

Theo dõi log:
```sh
docker compose \
  -f docker-compose.production.yaml \
  -f docker-compose.caddy.yaml \
  logs -f caddy rails
```

## 3) Checkpoint kiểm chứng chạy thành công

### 3.1 HTTP/HTTPS trả về từ reverse proxy
- PASS nếu HTTP trả `200/302` (tuỳ cấu hình redirect):
  - `curl -fsS -o /dev/null -w '%{http_code}\\n' "http://chatwoot.example.com/"`
- PASS nếu HTTPS trả `200/302`:
  - `curl -fsS -o /dev/null -w '%{http_code}\\n' "https://chatwoot.example.com/"`

### 3.2 Web UI hoạt động
- PASS nếu truy cập được UI và login được:
  - `https://chatwoot.example.com/`

## 4) Lỗi thường gặp & cách khắc phục

### Caddy không lấy được certificate (ACME errors)
- Nguyên nhân thường gặp:
  - DNS chưa trỏ đúng IP
  - Firewall chặn `80/443`
  - Domain đã được dùng ở nơi khác / proxy upstream đang chiếm challenge
- Fix:
  - kiểm tra lại DNS (`dig A/AAAA`) và inbound rules
  - xem log Caddy: `docker compose ... logs --tail=200 caddy`

### Port `80/443` đang bị chiếm
- Dấu hiệu: compose báo `bind: address already in use`.
- Fix:
  - dừng service đang chiếm port, hoặc set:
    - `CW_CADDY_HTTP_PORT=8080 CW_CADDY_HTTPS_PORT=8443 ... up -d`

## 5) Kết luận

Khi checkpoint (3) PASS ⇒ **PUBLIC + TLS THÀNH CÔNG**.

Refs: `doc/phase_0.md`, `docker-compose.caddy.yaml`, `Caddyfile`
