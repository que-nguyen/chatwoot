# Zalo Channel Adapter (zca-js)

This adapter connects Zalo Web (via `zca-js`) to a Chatwoot API inbox.

## Requirements
- Node.js >= 20
- A Chatwoot API inbox (Channel::Api) with a webhook URL pointing to this adapter
- A logged-in Zalo session (cookie + imei + user agent)

## Setup
1. Create a Chatwoot API inbox and copy its `identifier`.
2. Set the inbox `webhook_url` to this adapter (example: `http://localhost:3001/webhooks/chatwoot/secret`).
3. Install dependencies from this folder:
   - `npm install` (uses local `file:../../../zca-js`)
4. Provide environment variables (see below) and start:
   - `npm start`

## Environment variables
Required:
- `CHATWOOT_BASE_URL` (example: `http://localhost:3000`)
- `CHATWOOT_INBOX_IDENTIFIER` (the API channel identifier)
- `ZALO_IMEI`
- `ZALO_USER_AGENT`

Optional:
- `PORT` (default: `3001`)
- `CHATWOOT_WEBHOOK_PATH` (default: `/webhooks/chatwoot`)
- `CHATWOOT_HMAC_TOKEN` (if the API inbox enforces HMAC)
- `ZALO_LOGIN_MODE` (`cookie` or `qr`, default: `cookie`)
- `ZALO_COOKIE_PATH` (default: `./cookie.json`)
- `ZALO_COOKIE_JSON` (inline JSON string for cookies; overrides `ZALO_COOKIE_PATH`)
- `ZALO_SELF_LISTEN` (`true` or `false`, default: `false`)
- `ZALO_CHECK_UPDATE` (`true` or `false`, default: `true`)
- `ZALO_LOGGING` (`true` or `false`, default: `true`)

Multi-account (optional):
- `ZALO_ACCOUNTS_JSON` (JSON array of account objects)
- `ZALO_ACCOUNTS_PATH` (path to a JSON file containing the same array)

Each account object can override any single-account setting using camelCase keys, for example:
`chatwootBaseUrl`, `chatwootInboxIdentifier`, `chatwootWebhookPath`, `chatwootHmacToken`,
`zaloLoginMode`, `zaloCookiePath`, `zaloCookieJson`, `zaloImei`, `zaloUserAgent`,
`zaloSelfListen`, `zaloCheckUpdate`, `zaloLogging`, and optional `name`/`label` for logs.

When multiple accounts are configured and no per-account webhook path is provided,
paths default to `/webhooks/chatwoot/<index>` (1-based).

## Example .env
```bash
PORT=3001
CHATWOOT_BASE_URL=http://localhost:3000
CHATWOOT_INBOX_IDENTIFIER=your_api_inbox_identifier
CHATWOOT_WEBHOOK_PATH=/webhooks/chatwoot
CHATWOOT_HMAC_TOKEN=

ZALO_LOGIN_MODE=cookie
ZALO_COOKIE_PATH=./cookie.json
ZALO_COOKIE_JSON=
ZALO_IMEI=your_imei
ZALO_USER_AGENT=your_user_agent
ZALO_SELF_LISTEN=false
ZALO_CHECK_UPDATE=true
ZALO_LOGGING=true

# Multi-account (optional)
ZALO_ACCOUNTS_PATH=./accounts.json
# ZALO_ACCOUNTS_JSON=[{"label":"sales","chatwootInboxIdentifier":"..."}]
```

## Example accounts.json
```json
[
  {
    "label": "sales",
    "chatwootInboxIdentifier": "your_inbox_identifier_1",
    "chatwootWebhookPath": "/webhooks/chatwoot/sales",
    "zaloLoginMode": "cookie",
    "zaloCookiePath": "./cookie-sales.json",
    "zaloImei": "imei_sales",
    "zaloUserAgent": "user_agent_sales"
  },
  {
    "label": "support",
    "chatwootInboxIdentifier": "your_inbox_identifier_2",
    "chatwootWebhookPath": "/webhooks/chatwoot/support",
    "zaloLoginMode": "qr",
    "zaloSelfListen": false,
    "zaloCheckUpdate": true,
    "zaloLogging": true
  }
]
```

Sample file: `accounts.sample.json`.

Note: shared settings like `CHATWOOT_BASE_URL` and `CHATWOOT_HMAC_TOKEN` can stay
in `.env`, while each account overrides only what differs.


## Notes
- Messages are mapped to a Chatwoot API inbox using `source_id` values like:
  - `zalo:u:<threadId>` for user chats
  - `zalo:g:<threadId>` for group chats
- Webhooks with missing or non-Zalo `source_id` values are ignored.
- Reaction/undo events are forwarded as informational incoming messages (Chatwoot API inbox does not support editing or deleting messages).
- Zalo typing events update Chatwoot contact typing indicators (best effort).
- Zalo seen events update Chatwoot contact last-seen/read status (best effort).
- Agent typing events trigger Zalo typing indicators (best effort).
- Incoming Zalo attachment/link payloads are summarized into text and, when a URL is available, downloaded and uploaded to Chatwoot as attachments (best effort).
- Outgoing Chatwoot messages with attachments are downloaded and sent as file paths when possible.

## Design notes
- The adapter uses a Chatwoot API inbox (Channel::Api) so we can integrate Zalo without touching Chatwoot UI, auth, or core business logic.
- Zalo accounts are configured via environment variables or `accounts.json`, keeping account setup outside Chatwoot settings as required.
- Group chats map to a single Chatwoot contact (group name or fallback) because API inbox conversations are contact-based.
- If the API inbox has identity validation enabled, set `CHATWOOT_HMAC_TOKEN` to the inbox HMAC token.
