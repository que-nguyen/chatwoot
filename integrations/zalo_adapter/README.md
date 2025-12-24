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

## Notes
- Messages are mapped to a Chatwoot API inbox using `source_id` values like:
  - `zalo:u:<threadId>` for user chats
  - `zalo:g:<threadId>` for group chats
- Webhooks with missing or non-Zalo `source_id` values are ignored.
- Incoming non-text Zalo content is skipped for now.
- Outgoing Chatwoot messages with attachments are downloaded and sent as file paths when possible.
