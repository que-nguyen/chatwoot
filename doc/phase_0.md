# Phase 0 — Triển khai Chatwoot bằng Docker Compose (prod/staging)

Tài liệu này là runbook triển khai Chatwoot bằng `docker-compose.production.yaml` trong repo này.

## 0) Điều kiện tiên quyết (pass/fail rõ ràng)

### Docker + Compose
- PASS nếu chạy được:
  - `docker --version`
  - `docker compose version`
- FAIL nếu thiếu Docker/Compose → cài đặt lại theo hướng dẫn chính thức của Docker.

### Port không xung đột
Mặc định stack sẽ dùng các host port (bind vào `127.0.0.1`):
- Web: `3000`
- Postgres: `5432`
- Redis: `6379`

PASS nếu không có service khác đang chiếm các port này.

Lệnh kiểm tra:
- `ss -ltn | rg -n ":(3000|5432|6379)\\b" || true`

Nếu xung đột port, dùng các biến override sau (không cần sửa file YAML):
- `CW_WEB_PORT` (mặc định `3000`)
- `CW_POSTGRES_PORT` (mặc định `5432`)
- `CW_REDIS_PORT` (mặc định `6379`)

Ví dụ:
- `CW_WEB_PORT=3001 CW_POSTGRES_PORT=5434 CW_REDIS_PORT=6380 docker compose -f docker-compose.production.yaml up -d`

Ghi chú: nếu bạn set các biến này theo kiểu “one-shot” (đặt trước lệnh `docker compose`), chúng **không tự áp dụng** cho các lệnh checkpoint chạy sau đó. Để các lệnh `curl` dùng đúng port, hãy:
- export biến vào shell (ví dụ `export CW_WEB_PORT=3001`), hoặc
- thay trực tiếp port trong URL (ví dụ `http://127.0.0.1:3001/`).

Khuyến nghị (để tái lập được và tránh quên biến khi chạy overlay Phase 1/2/3/4):
- đặt `CW_WEB_PORT/CW_POSTGRES_PORT/CW_REDIS_PORT` trực tiếp trong `.env` (file này không commit) để mọi lệnh `docker compose` đều dùng cùng giá trị.

### Disk/RAM
- PASS nếu còn đủ dung lượng và RAM để chạy Postgres + Redis + Rails.
- Lệnh kiểm tra nhanh:
  - `df -h`
  - `free -h`

### Quyền user + firewall
- PASS nếu user chạy được Docker mà không bị permission error:
  - `docker ps`
- Nếu triển khai trên VPS và muốn truy cập từ bên ngoài:
  - Mở port ở firewall/reverse proxy tương ứng với `CW_WEB_PORT` (hoặc cấu hình Nginx/Caddy làm reverse proxy).

## 1) Chuẩn bị cấu hình `.env` (không commit)

File env (mặc định `.env`) đang được `.gitignore` ignore. Tạo từ mẫu:
- `cp .env.example .env`

Tuỳ chọn (tách file staging/prod): dùng file khác và set `CW_ENV_FILE` khi chạy compose:
- `cp .env.example .env.production`
- `CW_ENV_FILE=.env.production docker compose -f docker-compose.production.yaml up -d`

### Biến quan trọng (bắt buộc)
- `SECRET_KEY_BASE`
  - BẮT BUỘC thay bằng secret dài, không dùng placeholder.
  - Gợi ý:
    - `openssl rand -hex 64`
- `FRONTEND_URL`
  - Local: `http://127.0.0.1:${CW_WEB_PORT:-3000}`
  - Production: URL public (thường là `https://chatwoot.your-domain.tld`)
- `POSTGRES_HOST=postgres`
- `POSTGRES_USERNAME` (phải khớp với user tạo trong container Postgres; mặc định `postgres`)
- `POSTGRES_PASSWORD` (BẮT BUỘC, Compose sẽ fail nếu thiếu)
- `POSTGRES_DATABASE` (tuỳ chọn)
  - Nếu không set, mặc định `chatwoot_production`.
  - `docker-compose.production.yaml` sẽ tạo DB theo giá trị này.
- `REDIS_URL=redis://redis:6379`
- `REDIS_PASSWORD` (BẮT BUỘC; Redis container sẽ exit nếu rỗng)

### Biến phục vụ setup admin
- `ENABLE_ACCOUNT_SIGNUP=true` để vào onboarding tạo admin lần đầu.
- Sau khi tạo xong admin, nên set lại `ENABLE_ACCOUNT_SIGNUP=false` để hạn chế public signup.

## 2) Triển khai stack

### Start
Chạy (thêm override port nếu cần):
- `CW_WEB_PORT=3000 docker compose -f docker-compose.production.yaml up -d`

Tuỳ chọn (khuyến nghị production): **pin version Chatwoot image** để tránh upgrade ngoài ý muốn:
- `CW_IMAGE_TAG=4.9.1 docker compose -f docker-compose.production.yaml up -d`

Ghi chú:
- Compose có service `migrate` chạy `rails db:chatwoot_prepare` rồi mới start `rails` + `sidekiq` để tránh crash loop do thiếu migrations.

### Theo dõi trạng thái & log
- PASS nếu tất cả service `Up` và (sau khi boot) hiển thị `(healthy)`:
  - `docker compose -f docker-compose.production.yaml ps`
- Xem log:
  - `docker compose -f docker-compose.production.yaml logs -f postgres redis migrate rails sidekiq`

## 3) Checkpoint kiểm chứng chạy thành công

### 3.1 Web UI truy cập được
- PASS nếu HTTP trả về `200` hoặc `302`:
  - `curl -fsS -o /dev/null -w '%{http_code}\\n' "http://127.0.0.1:${CW_WEB_PORT:-3000}/"`

### 3.2 Tạo admin (qua UI)
- PASS nếu truy cập được:
  - `http://127.0.0.1:${CW_WEB_PORT:-3000}/installation/onboarding`
- Tạo admin theo form onboarding.

Tuỳ chọn (headless, để smoke-test DB): tạo SuperAdmin bằng rails runner (không in password ra log):
```sh
docker compose -f docker-compose.production.yaml exec -T rails \
  bundle exec rails runner \
  "pw = SecureRandom.hex(16) + 'A!'; AccountBuilder.new(account_name: 'Demo', user_full_name: 'Admin', email: 'admin@example.com', user_password: pw, super_admin: true, confirmed: true).perform; puts 'created admin@example.com'"
```

### 3.3 Tạo inbox + gửi thử tin nhắn (API inbox)
PASS nếu tạo được inbox, conversation và message:
```sh
docker compose -f docker-compose.production.yaml exec -T rails \
  bundle exec rails runner \
  "account = Account.order(:id).last; channel = Channel::Api.create!(account: account); inbox = Inbox.create!(account: account, name: 'API Inbox', channel: channel); ci = ContactInboxWithContactBuilder.new(inbox: inbox, contact_attributes: { name: 'Customer', email: 'customer@example.com' }).perform; convo = Conversation.create!(account: account, inbox: inbox, contact: ci.contact, contact_inbox: ci); msg = Messages::MessageBuilder.new(nil, convo, { content: 'Hello from API inbox', message_type: 'incoming' }).perform; puts \"ok inbox_id=#{inbox.id} conversation_id=#{convo.id} message_id=#{msg.id}\""
```

### 3.4 Postgres/Redis/Sidekiq chạy ổn định
- PASS nếu:
  - `docker compose -f docker-compose.production.yaml ps` không có container `Restarting`
  - `docker compose -f docker-compose.production.yaml logs --tail=200 sidekiq` có dòng `connecting to Redis ... password: "REDACTED"`

## 4) Kiểm tra sau triển khai (persistence + restart)

### Volume persist
- PASS nếu thấy volumes:
  - `docker volume ls | rg -n "chatwoot_(postgres_data|redis_data|storage_data)" || true`

### Restart stack không mất dữ liệu
1) Stop:
   - `docker compose -f docker-compose.production.yaml down`
2) Start lại:
   - `docker compose -f docker-compose.production.yaml up -d`
3) PASS nếu dữ liệu còn:
   - `docker compose -f docker-compose.production.yaml exec -T rails bundle exec rails runner "puts \"users=#{User.count} accounts=#{Account.count} inboxes=#{Inbox.count} conversations=#{Conversation.count} messages=#{Message.count}\""`

## 5) Lỗi thường gặp & cách khắc phục

### `address already in use` (port conflict)
- Nguyên nhân: host port đang bị process/container khác chiếm.
- Fix: đổi port bằng `CW_WEB_PORT`, `CW_POSTGRES_PORT`, `CW_REDIS_PORT` khi chạy `docker compose`.

### `POSTGRES_PASSWORD is required`
- Nguyên nhân: thiếu `POSTGRES_PASSWORD` trong `.env`.
- Fix: set `POSTGRES_PASSWORD` rồi chạy lại `docker compose up -d`.

### `REDIS_PASSWORD is required`
- Nguyên nhân: thiếu `REDIS_PASSWORD` trong `.env`.
- Fix: set `REDIS_PASSWORD` rồi restart service:
  - `docker compose -f docker-compose.production.yaml up -d --force-recreate redis`

### Sidekiq/Rails crash do thiếu tables (`installation_configs`…)
- Nguyên nhân: DB chưa được migrate/seed.
- Fix:
  - xem log `migrate`: `docker compose -f docker-compose.production.yaml logs --tail=200 migrate`
  - chạy lại migrate: `docker compose -f docker-compose.production.yaml up -d --force-recreate migrate`

### Redis cảnh báo `Memory overcommit must be enabled`
- Khuyến nghị trên Linux host:
  - `sudo sysctl vm.overcommit_memory=1`
  - và cấu hình persist trong `/etc/sysctl.conf`.

## 6) Kết luận

Khi thỏa các checkpoint ở mục (3) và kiểm tra persistence ở mục (4) đều PASS ⇒ **CÀI ĐẶT THÀNH CÔNG**.

Nếu cần public access + TLS qua domain, xem thêm `doc/phase_2.md`.

Refs: `docker-compose.production.yaml`, `.env.example`, `doc/phase_2.md`
