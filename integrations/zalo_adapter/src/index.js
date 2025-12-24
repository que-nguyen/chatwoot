import { Zalo, ThreadType } from "zca-js";
import crypto from "crypto";
import fs from "fs";
import http from "http";
import os from "os";
import path from "path";

const config = loadConfig();
const chatwoot = new ChatwootClient(config);
const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "chatwoot-zalo-"));
let api;

await start();

async function start() {
  validateConfig();

  const zalo = new Zalo({
    selfListen: config.zaloSelfListen,
    checkUpdate: config.zaloCheckUpdate,
    logging: config.zaloLogging
  });

  api = await loginZalo(zalo);
  api.listener.on("message", (message) => handleIncomingZaloMessage(message));
  api.listener.start();

  const server = http.createServer(async (req, res) => {
    const { pathname } = new URL(req.url, `http://${req.headers.host}`);
    if (req.method === "POST" && pathname === config.chatwootWebhookPath) {
      try {
        const payload = await readJson(req);
        await handleChatwootWebhook(payload);
        res.writeHead(200, { "Content-Type": "text/plain" });
        res.end("ok");
      } catch (error) {
        console.error("Chatwoot webhook error:", error);
        res.writeHead(500, { "Content-Type": "text/plain" });
        res.end("error");
      }
      return;
    }

    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("not found");
  });

  server.listen(config.port, () => {
    console.log(`Zalo adapter listening on :${config.port}${config.chatwootWebhookPath}`);
  });
}

async function loginZalo(zalo) {
  if (config.zaloLoginMode === "qr") {
    console.log("Logging in with QR...");
    return zalo.loginQR();
  }

  const cookieJson = config.zaloCookieJson || fs.readFileSync(config.zaloCookiePath, "utf-8");
  const cookie = JSON.parse(cookieJson);

  console.log("Logging in with cookie...");
  return zalo.login({
    cookie,
    imei: config.zaloImei,
    userAgent: config.zaloUserAgent
  });
}

async function handleIncomingZaloMessage(message) {
  if (!message || message.isSelf) return;

  const thread = buildThreadRef(message);
  const sourceId = buildSourceId(thread);
  const content = normalizeIncomingContent(message, thread);
  const echoId = message?.data?.msgId || message?.data?.cliMsgId;

  try {
    await chatwoot.ensureContact({
      sourceId,
      name: message?.data?.dName || "Zalo User",
      identifier: sourceId
    });

    const conversationId = await chatwoot.getOrCreateConversation(sourceId, {
      zalo_thread_id: thread.id,
      zalo_thread_type: thread.type === ThreadType.Group ? "group" : "user"
    });

    if (!content) {
      console.log("Skipping empty Zalo message", { sourceId, echoId });
      return;
    }

    await chatwoot.createIncomingMessage({
      sourceId,
      conversationId,
      content,
      echoId
    });
  } catch (error) {
    console.error("Failed to sync Zalo message:", error);
  }
}

async function handleChatwootWebhook(payload) {
  if (!payload || payload.event !== "message_created") return;
  if (payload.private) return;
  if (payload.message_type !== "outgoing") return;

  const sourceId = payload?.conversation?.contact_inbox?.source_id;
  const thread = parseSourceId(sourceId);
  if (!thread) {
    console.warn("Skipping webhook with unsupported source_id", { sourceId });
    return;
  }

  const content = typeof payload.content === "string" ? payload.content : "";
  const attachments = Array.isArray(payload.attachments) ? payload.attachments : [];

  await sendZaloMessage({ thread, content, attachments });
}

async function sendZaloMessage({ thread, content, attachments }) {
  if (!api) throw new Error("Zalo API not initialized");

  const files = await downloadAttachments(attachments);
  try {
    if (files.length > 0) {
      await api.sendMessage(
        {
          msg: content || "",
          attachments: files
        },
        thread.id,
        thread.type
      );
      return;
    }

    if (!content) return;

    await api.sendMessage(content, thread.id, thread.type);
  } finally {
    cleanupFiles(files);
  }
}

function buildThreadRef(message) {
  const threadType = message.type === ThreadType.Group ? ThreadType.Group : ThreadType.User;
  return { id: message.threadId, type: threadType };
}

function buildSourceId(thread) {
  const prefix = thread.type === ThreadType.Group ? "g" : "u";
  return `zalo:${prefix}:${thread.id}`;
}

function parseSourceId(sourceId) {
  if (!sourceId) return null;
  const match = sourceId.match(/^zalo:(u|g):(.+)$/);
  if (match) {
    return {
      type: match[1] === "g" ? ThreadType.Group : ThreadType.User,
      id: match[2]
    };
  }
  return { type: ThreadType.User, id: sourceId };
}

function normalizeIncomingContent(message, thread) {
  const content = message?.data?.content;
  if (typeof content === "string") {
    if (thread.type === ThreadType.Group && message?.data?.uidFrom) {
      return `[${message.data.uidFrom}] ${content}`;
    }
    return content;
  }
  return "";
}

async function downloadAttachments(attachments) {
  const supported = attachments.filter((attachment) => {
    if (!attachment || !attachment.data_url) return false;
    return ["image", "audio", "video", "file"].includes(attachment.file_type);
  });

  const downloads = supported.map(async (attachment) => {
    const url = attachment.data_url;
    const ext = attachment.extension || extensionFromUrl(url) || "bin";
    const filename = `attachment-${attachment.id || Date.now()}.${ext}`;
    const filePath = path.join(tempRoot, filename);

    const response = await fetch(url, { redirect: "follow" });
    if (!response.ok) {
      throw new Error(`Attachment download failed (${response.status})`);
    }

    const buffer = Buffer.from(await response.arrayBuffer());
    fs.writeFileSync(filePath, buffer);
    return filePath;
  });

  return Promise.all(downloads);
}

function cleanupFiles(files) {
  files.forEach((filePath) => {
    try {
      fs.unlinkSync(filePath);
    } catch (error) {
      console.warn("Failed to cleanup temp file", filePath, error?.message);
    }
  });
}

function extensionFromUrl(url) {
  try {
    const pathname = new URL(url).pathname;
    const ext = path.extname(pathname).replace(".", "");
    return ext || null;
  } catch {
    return null;
  }
}

async function readJson(req) {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(chunk);
  }
  const body = Buffer.concat(chunks).toString("utf-8").trim();
  return body ? JSON.parse(body) : {};
}

function loadConfig() {
  return {
    port: parseInt(process.env.PORT || "3001", 10),
    chatwootBaseUrl: (process.env.CHATWOOT_BASE_URL || "").replace(/\/+$/, ""),
    chatwootInboxIdentifier: process.env.CHATWOOT_INBOX_IDENTIFIER || "",
    chatwootWebhookPath: process.env.CHATWOOT_WEBHOOK_PATH || "/webhooks/chatwoot",
    chatwootHmacToken: process.env.CHATWOOT_HMAC_TOKEN || "",
    zaloLoginMode: process.env.ZALO_LOGIN_MODE || "cookie",
    zaloCookiePath: process.env.ZALO_COOKIE_PATH || "./cookie.json",
    zaloCookieJson: process.env.ZALO_COOKIE_JSON || "",
    zaloImei: process.env.ZALO_IMEI || "",
    zaloUserAgent: process.env.ZALO_USER_AGENT || "",
    zaloSelfListen: parseBool(process.env.ZALO_SELF_LISTEN, false),
    zaloCheckUpdate: parseBool(process.env.ZALO_CHECK_UPDATE, true),
    zaloLogging: parseBool(process.env.ZALO_LOGGING, true)
  };
}

function validateConfig() {
  const missing = [];
  if (!config.chatwootBaseUrl) missing.push("CHATWOOT_BASE_URL");
  if (!config.chatwootInboxIdentifier) missing.push("CHATWOOT_INBOX_IDENTIFIER");
  if (config.zaloLoginMode === "cookie") {
    if (!config.zaloImei) missing.push("ZALO_IMEI");
    if (!config.zaloUserAgent) missing.push("ZALO_USER_AGENT");
  }
  if (missing.length > 0) {
    throw new Error(`Missing required env vars: ${missing.join(", ")}`);
  }
}

function parseBool(value, defaultValue) {
  if (value === undefined || value === "") return defaultValue;
  return ["1", "true", "yes", "y"].includes(String(value).toLowerCase());
}

class ChatwootClient {
  constructor(options) {
    this.baseUrl = options.chatwootBaseUrl;
    this.inboxId = options.chatwootInboxIdentifier;
    this.hmacToken = options.chatwootHmacToken;
  }

  async ensureContact({ sourceId, name, identifier }) {
    const payload = {
      source_id: sourceId,
      name,
      identifier
    };

    if (this.hmacToken) {
      payload.identifier_hash = this.hmacIdentifier(identifier || sourceId);
    }

    return this.requestJson(this.contactUrl(), {
      method: "POST",
      body: payload
    });
  }

  async getOrCreateConversation(sourceId, customAttributes) {
    const list = await this.requestJson(this.conversationsUrl(sourceId));
    const open = Array.isArray(list) ? list.find((conv) => conv.status !== "resolved") : null;
    if (open) return open.id;

    const payload = { custom_attributes: customAttributes || {} };
    const created = await this.requestJson(this.conversationsUrl(sourceId), {
      method: "POST",
      body: payload
    });
    return created.id;
  }

  async createIncomingMessage({ sourceId, conversationId, content, echoId }) {
    const payload = {
      content,
      echo_id: echoId
    };
    return this.requestJson(this.messagesUrl(sourceId, conversationId), {
      method: "POST",
      body: payload
    });
  }

  contactUrl() {
    return `${this.baseUrl}/public/api/v1/inboxes/${this.inboxId}/contacts`;
  }

  conversationsUrl(sourceId) {
    return `${this.baseUrl}/public/api/v1/inboxes/${this.inboxId}/contacts/${encodeURIComponent(sourceId)}/conversations`;
  }

  messagesUrl(sourceId, conversationId) {
    return `${this.baseUrl}/public/api/v1/inboxes/${this.inboxId}/contacts/${encodeURIComponent(sourceId)}/conversations/${conversationId}/messages`;
  }

  hmacIdentifier(identifier) {
    return crypto.createHmac("sha256", this.hmacToken).update(String(identifier)).digest("hex");
  }

  async requestJson(url, options = {}) {
    const response = await fetch(url, {
      method: options.method || "GET",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json"
      },
      body: options.body ? JSON.stringify(options.body) : undefined
    });

    const text = await response.text();
    const data = text ? JSON.parse(text) : null;
    if (!response.ok) {
      throw new Error(`Chatwoot request failed (${response.status}): ${text}`);
    }

    return data;
  }
}
