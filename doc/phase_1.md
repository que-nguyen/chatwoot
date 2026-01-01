# Phase 1 — Kết nối Zalo Web ↔ Chatwoot bằng Zalo Adapter (zca-js)

Tài liệu này hướng dẫn chạy `integrations/zalo_adapter` và cấu hình Chatwoot API inbox để đồng bộ tin nhắn Zalo.

## 0) Điều kiện tiên quyết (pass/fail rõ ràng)

### Phase 0 đã chạy ổn định
- PASS nếu các service đều `Up`:
  - `docker compose -f docker-compose.production.yaml ps`
- PASS nếu Web UI trả `200/302`:
  - `curl -fsS -o /dev/null -w '%{http_code}\\n' "http://127.0.0.1:${CW_WEB_PORT:-3000}/"`
  - Ghi chú: nếu bạn override `CW_WEB_PORT` theo kiểu one-shot, hãy `export CW_WEB_PORT=...` hoặc thay port trực tiếp trong URL.

### zca-js dependency
- Mặc định adapter cài `zca-js` từ npm khi chạy `npm install`.
- Tuỳ chọn: nếu muốn dùng local checkout, dùng dependency `file:../../../zca-js` và đảm bảo tồn tại folder `../zca-js` (từ root repo Chatwoot).

### Zalo session sẵn sàng
- Cookie mode: cần cookie JSON + `ZALO_IMEI` + `ZALO_USER_AGENT`.
- QR mode: cần quét QR (adapter sẽ ghi ảnh QR ra file).

Gợi ý: nếu chỉ muốn smoke-test đường webhook Chatwoot → adapter (chưa cần đăng nhập Zalo), dùng `ZALO_DRY_RUN=true`.

## 1) Tạo Chatwoot API inbox + cấu hình webhook

Webhook URL phải truy cập được *từ container Chatwoot*.

Khuyến nghị chạy adapter như một service trong cùng Docker Compose project để dùng hostname nội bộ:
- `http://zalo_adapter:3001/webhooks/chatwoot/<secret>`

### 1.1 Tạo API inbox bằng rails runner (nhanh, tái lập được)

Ví dụ tạo inbox và set webhook URL (thay `<secret>`):
```sh
docker compose -f docker-compose.production.yaml exec -T rails \
  bundle exec rails runner \
  "account = Account.order(:id).last; \
   channel = account.api_channels.create!(webhook_url: 'http://zalo_adapter:3001/webhooks/chatwoot/<secret>', hmac_mandatory: false); \
   inbox = Inbox.create!(account: account, name: 'Zalo API Inbox', channel: channel); \
   puts \"inbox_id=#{inbox.id} identifier=#{channel.identifier} hmac_token=#{channel.hmac_token} hmac_mandatory=#{channel.hmac_mandatory}\""
```

Nếu muốn bật xác thực HMAC cho webhook (khuyến nghị production):
- set `hmac_mandatory: true`
- và set `CHATWOOT_HMAC_TOKEN=<hmac_token>` ở adapter.

## 2) Cấu hình adapter

Tạo file env (không commit):
```sh
cp integrations/zalo_adapter/.env.example integrations/zalo_adapter/.env
```

Các biến quan trọng (khi chạy adapter trong Docker cùng project Chatwoot):
- `CHATWOOT_BASE_URL=http://rails:3000`
- `CHATWOOT_INBOX_IDENTIFIER=<identifier>` (từ bước 1)
- `CHATWOOT_WEBHOOK_PATH=/webhooks/chatwoot/<secret>` (khớp webhook URL ở bước 1)
- `CHATWOOT_HMAC_TOKEN=<hmac_token>` nếu bật HMAC

Zalo login:
- Cookie mode:
  - `ZALO_LOGIN_MODE=cookie`
  - `ZALO_COOKIE_JSON=...` hoặc `ZALO_COOKIE_PATH=./cookie.json`
  - `ZALO_IMEI=...`
  - `ZALO_USER_AGENT=...`
- QR mode:
  - `ZALO_LOGIN_MODE=qr`
  - `ZALO_QR_PATH=./qr.png` (tuỳ chọn)

Smoke-test không đăng nhập Zalo:
- `ZALO_DRY_RUN=true` (adapter vẫn nhận webhook và log, không gọi Zalo)

## 3) Chạy adapter bằng Docker Compose overlay (khuyến nghị)

Start (adapter join cùng network với Chatwoot):
```sh
docker compose \
  -f docker-compose.production.yaml \
  -f docker-compose.zalo-adapter.yaml \
  up -d zalo_adapter
```

Theo dõi log:
```sh
docker compose \
  -f docker-compose.production.yaml \
  -f docker-compose.zalo-adapter.yaml \
  logs -f zalo_adapter
```

Health check (host):
- `curl -fsS "http://127.0.0.1:${ZALO_ADAPTER_HOST_PORT:-3002}/health"`
  - Ghi chú: nếu bạn override `ZALO_ADAPTER_HOST_PORT` theo kiểu one-shot, hãy `export ZALO_ADAPTER_HOST_PORT=...` hoặc thay port trực tiếp trong URL.

## 4) Checkpoint kiểm chứng chạy thành công

### 4.1 Adapter sống
- PASS nếu `/health` trả `200`:
  - `curl -fsS -o /dev/null -w '%{http_code}\\n' "http://127.0.0.1:${ZALO_ADAPTER_HOST_PORT:-3002}/health"`

### 4.2 Chatwoot → adapter (outgoing webhooks)
- PASS nếu agent gửi 1 message trong API inbox và adapter log nhận webhook (trả `200`).
- Nếu bật `ZALO_DRY_RUN=true`, adapter sẽ log và bỏ qua việc gửi sang Zalo (đúng mục đích smoke-test).

### 4.3 Zalo → Chatwoot (incoming)
- PASS nếu có message mới trên Zalo và thấy conversation/message xuất hiện trong Chatwoot API inbox.

## 5) Lỗi thường gặp & cách khắc phục

### `Chatwoot webhook error: HMAC verification failed`
- Nguyên nhân: `CHATWOOT_HMAC_TOKEN` không khớp hoặc webhook bật HMAC nhưng adapter chưa set token.
- Fix: lấy `hmac_token` từ API channel và set đúng cho adapter; đảm bảo `hmac_mandatory` đúng mong muốn.

### Adapter không nhận được webhook
- Nguyên nhân thường gặp:
  - `webhook_url` chưa set hoặc sai host/path.
  - Adapter không chạy cùng network → Chatwoot container không resolve được hostname.
- Fix:
  - xác nhận `webhook_url` của `Channel::Api` trỏ tới `http://zalo_adapter:3001/...`
  - chạy bằng overlay compose ở mục (3) để dùng hostname nội bộ.

### Cookie mode báo thiếu cookie/IMEI/User-Agent
- Nguyên nhân: thiếu `ZALO_COOKIE_JSON/ZALO_COOKIE_PATH` hoặc `ZALO_IMEI/ZALO_USER_AGENT`.
- Fix: set đủ biến hoặc chuyển `ZALO_LOGIN_MODE=qr` để login bằng QR.

## 6) Kết luận

Khi checkpoint (4.1) + (4.2) PASS, và (4.3) PASS khi có Zalo session hợp lệ ⇒ **KẾT NỐI THÀNH CÔNG**.

Refs: `doc/phase_0.md`, `docker-compose.zalo-adapter.yaml`, `integrations/zalo_adapter/README.md`
