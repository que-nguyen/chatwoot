import { Zalo, ThreadType } from "zca-js";
import crypto from "crypto";
import fs from "fs";
import http from "http";
import imageSizeModule from "image-size";
import os from "os";
import path from "path";

const config = loadConfig();
const chatwoot = new ChatwootClient(config);
const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "chatwoot-zalo-"));
const imageSize = typeof imageSizeModule === "function" ? imageSizeModule : imageSizeModule.imageSize;
let api;
const groupNameCache = new Map();
const groupNamePending = new Map();

await start();

async function start() {
  validateConfig();

  const zalo = new Zalo({
    selfListen: config.zaloSelfListen,
    checkUpdate: config.zaloCheckUpdate,
    logging: config.zaloLogging,
    imageMetadataGetter
  });

  api = await loginZalo(zalo);
  api.listener.on("message", (message) => handleIncomingZaloMessage(message));
  api.listener.on("reaction", (reaction) => handleIncomingZaloReaction(reaction));
  api.listener.on("undo", (undo) => handleIncomingZaloUndo(undo));
  api.listener.on("group_event", (event) => handleIncomingZaloGroupEvent(event));
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

async function imageMetadataGetter(filePath) {
  try {
    const buffer = await fs.promises.readFile(filePath);
    const metadata = imageSize(buffer);
    if (!metadata || !metadata.width || !metadata.height) {
      return null;
    }

    return {
      width: metadata.width,
      height: metadata.height,
      size: buffer.length
    };
  } catch (error) {
    console.warn("Failed to read image metadata", filePath, error?.message || error);
    return null;
  }
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
  const { content, attachments } = await normalizeIncomingPayload(message, thread);
  const echoId = message?.data?.msgId || message?.data?.cliMsgId;
  const contactName = await resolveContactName({
    thread,
    senderName: message?.data?.dName
  });

  await syncIncomingToChatwoot({
    sourceId,
    thread,
    content: content || "",
    echoId,
    attachments,
    contactName
  });
}

async function handleIncomingZaloReaction(reaction) {
  if (!reaction || reaction.isSelf) return;

  const thread = buildThreadRefFromEvent(reaction);
  if (!thread) return;

  const sourceId = buildSourceId(thread);
  const content = formatReactionContent(reaction, thread);
  const echoId = buildEventEchoId("reaction", reaction?.data);
  const contactName = await resolveContactName({
    thread,
    senderName: reaction?.data?.dName
  });

  await syncIncomingToChatwoot({
    sourceId,
    thread,
    content,
    echoId,
    contactName
  });
}

async function handleIncomingZaloUndo(undo) {
  if (!undo || undo.isSelf) return;

  const thread = buildThreadRefFromEvent(undo);
  if (!thread) return;

  const sourceId = buildSourceId(thread);
  const content = formatUndoContent(undo, thread);
  const echoId = buildEventEchoId("undo", undo?.data);
  const contactName = await resolveContactName({
    thread,
    senderName: undo?.data?.dName
  });

  await syncIncomingToChatwoot({
    sourceId,
    thread,
    content,
    echoId,
    contactName
  });
}

async function handleIncomingZaloGroupEvent(event) {
  if (!event || event.isSelf) return;
  if (!event.threadId) return;

  const thread = { id: event.threadId, type: ThreadType.Group };
  const sourceId = buildSourceId(thread);
  const content = formatGroupEventContent(event, thread);
  const echoId = buildGroupEventEchoId(event);
  const contactName = await resolveContactName({
    thread,
    groupName: event?.data?.groupName
  });

  if (!content) return;

  await syncIncomingToChatwoot({
    sourceId,
    thread,
    content,
    echoId,
    contactName
  });
}

async function handleChatwootWebhook(payload) {
  if (!payload || payload.event !== "message_created") return;
  if (payload.private) return;
  if (payload.message_type !== "outgoing") return;

  const sourceId = payload?.conversation?.contact_inbox?.source_id;
  if (!sourceId) {
    console.warn("Skipping webhook without source_id");
    return;
  }
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

function buildThreadRefFromEvent(event) {
  if (!event || !event.threadId) return null;
  return {
    id: event.threadId,
    type: event.isGroup ? ThreadType.Group : ThreadType.User
  };
}

function buildSourceId(thread) {
  const prefix = thread.type === ThreadType.Group ? "g" : "u";
  return `zalo:${prefix}:${thread.id}`;
}

function parseSourceId(sourceId) {
  if (!sourceId) return null;
  const match = sourceId.match(/^zalo:(u|g):(.+)$/);
  if (!match) return null;
  return {
    type: match[1] === "g" ? ThreadType.Group : ThreadType.User,
    id: match[2]
  };
}

async function normalizeIncomingPayload(message, thread) {
  const content = normalizeIncomingContent(message, thread);
  const attachmentTargets = extractIncomingAttachmentTargets(message);
  if (attachmentTargets.length === 0) {
    return { content, attachments: [] };
  }

  const attachments = await downloadIncomingAttachments(attachmentTargets);
  const fallback = content || buildAttachmentFallback(message, thread, attachmentTargets);
  return { content: fallback, attachments };
}

function normalizeIncomingContent(message, thread) {
  const content = message?.data?.content;
  if (typeof content === "string") {
    return prefixGroupSender(thread, message, content);
  }

  if (content && typeof content === "object") {
    const summary = buildAttachmentSummary(content);
    return summary ? prefixGroupSender(thread, message, summary) : "";
  }

  return "";
}

function formatReactionContent(reaction, thread) {
  const icon = reaction?.data?.content?.rIcon || "";
  const targets = reaction?.data?.content?.rMsg || [];
  const targetIds = targets
    .map((target) => target?.gMsgID || target?.cMsgID)
    .filter(Boolean);
  const targetLabel = targetIds.length > 0 ? ` on message ${targetIds.join(", ")}` : "";
  const baseText = `Reaction ${icon}`.trim() + targetLabel;
  const sender = reaction?.data?.dName || reaction?.data?.uidFrom;
  return prefixGroupSenderId(thread, sender, baseText);
}

function formatUndoContent(undo, thread) {
  const target =
    undo?.data?.content?.globalMsgId ||
    undo?.data?.realMsgId ||
    undo?.data?.msgId ||
    undo?.data?.cliMsgId;
  const baseText = target ? `Message removed (${target})` : "Message removed";
  const sender = undo?.data?.dName || undo?.data?.uidFrom;
  return prefixGroupSenderId(thread, sender, baseText);
}

function formatGroupEventContent(event, thread) {
  const type = event?.type || "unknown";
  const label = groupEventLabel(type);
  const members = extractGroupEventMembers(event);
  const memberText = members.length > 0 ? ` - ${members.join(", ")}` : "";
  const baseText = `${label}${memberText}`.trim();
  if (!baseText) return "";
  return prefixGroupSenderId(thread, event?.act, baseText);
}

function extractGroupEventMembers(event) {
  const data = event?.data;
  if (Array.isArray(data?.updateMembers)) {
    return data.updateMembers
      .map((member) => {
        if (typeof member === "string") return member;
        return member?.dName || member?.id;
      })
      .filter(Boolean);
  }
  if (Array.isArray(data?.uids)) {
    return data.uids.filter(Boolean);
  }
  return [];
}

function groupEventLabel(type) {
  const labels = {
    join_request: "Join request",
    join: "Member joined",
    leave: "Member left",
    remove_member: "Member removed",
    block_member: "Member blocked",
    update_setting: "Group settings updated",
    update: "Group updated",
    new_link: "New group link created",
    add_admin: "Member promoted to admin",
    remove_admin: "Admin removed",
    new_pin_topic: "Pinned topic added",
    update_pin_topic: "Pinned topic updated",
    reorder_pin_topic: "Pinned topics reordered",
    update_board: "Board updated",
    remove_board: "Board removed",
    update_topic: "Topic updated",
    unpin_topic: "Topic unpinned",
    remove_topic: "Topic removed",
    accept_remind: "Reminder accepted",
    reject_remind: "Reminder rejected",
    remind_topic: "Reminder created",
    update_avatar: "Group avatar updated",
    unknown: "Group event"
  };

  if (!type) return "Group event";
  return labels[type] || `Group event (${type})`;
}

function buildEventEchoId(prefix, data) {
  const id = data?.actionId || data?.msgId || data?.cliMsgId || data?.realMsgId;
  return id ? `${prefix}:${id}` : undefined;
}

function buildGroupEventEchoId(event) {
  const time = event?.data?.time || event?.data?.createTime || event?.data?.editTime;
  const parts = ["group_event", event?.type, event?.threadId, time].filter(Boolean);
  if (parts.length <= 2) return undefined;
  return parts.map((part) => String(part).replace(/\s+/g, "_")).join(":");
}

async function resolveContactName({ thread, senderName, groupName }) {
  if (!thread) return senderName || "Zalo User";
  if (thread.type !== ThreadType.Group) return senderName || "Zalo User";

  if (groupName) {
    groupNameCache.set(thread.id, groupName);
    return groupName;
  }

  const cached = groupNameCache.get(thread.id);
  if (cached) return cached;

  const fetched = await resolveGroupName(thread.id);
  if (fetched) return fetched;

  return `Zalo Group ${thread.id}`;
}

async function resolveGroupName(threadId) {
  if (!threadId) return null;

  const cached = groupNameCache.get(threadId);
  if (cached) return cached;

  const pending = groupNamePending.get(threadId);
  if (pending) return pending;

  const task = (async () => {
    if (!api || typeof api.getGroupInfo !== "function") return null;
    try {
      const response = await api.getGroupInfo(threadId);
      const info = response?.gridInfoMap?.[threadId];
      const name = info?.name || info?.groupName;
      if (name) groupNameCache.set(threadId, name);
      return name || null;
    } catch (error) {
      console.warn("Failed to fetch Zalo group info", threadId, error?.message || error);
      return null;
    } finally {
      groupNamePending.delete(threadId);
    }
  })();

  groupNamePending.set(threadId, task);
  return task;
}

function prefixGroupSenderId(thread, senderId, text) {
  if (thread?.type === ThreadType.Group && senderId && text) {
    return `[${senderId}] ${text}`;
  }
  return text;
}

async function syncIncomingToChatwoot({
  sourceId,
  thread,
  content,
  echoId,
  attachments = [],
  contactName
}) {
  try {
    await chatwoot.ensureContact({
      sourceId,
      name: contactName || "Zalo User",
      identifier: sourceId
    });

    const conversationId = await chatwoot.getOrCreateConversation(sourceId, {
      zalo_thread_id: thread.id,
      zalo_thread_type: thread.type === ThreadType.Group ? "group" : "user"
    });

    if (!content && attachments.length === 0) {
      console.log("Skipping empty Zalo event", { sourceId, echoId });
      return;
    }

    await chatwoot.createIncomingMessage({
      sourceId,
      conversationId,
      content: content || "",
      echoId,
      attachments
    });
  } catch (error) {
    console.error("Failed to sync Zalo event:", error);
  }
}

function prefixGroupSender(thread, message, text) {
  if (thread.type === ThreadType.Group && message?.data?.uidFrom && text) {
    return `[${message.data.uidFrom}] ${text}`;
  }
  return text;
}

function extractIncomingAttachmentTargets(message) {
  const content = message?.data?.content;
  if (!content || typeof content !== "object") return [];

  const href = typeof content.href === "string" ? content.href : "";
  const thumb = typeof content.thumb === "string" ? content.thumb : "";
  if (href) return [{ url: href }];
  if (thumb) return [{ url: thumb }];
  return [];
}

function buildAttachmentSummary(content) {
  if (!content || typeof content !== "object") return "";
  const title = typeof content.title === "string" ? content.title.trim() : "";
  const description = typeof content.description === "string" ? content.description.trim() : "";
  const href = typeof content.href === "string" ? content.href.trim() : "";
  const parts = [title, description, href].filter(Boolean);
  return parts.join(" - ");
}

function buildAttachmentFallback(message, thread, attachmentTargets) {
  const urls = attachmentTargets.map((target) => target.url).filter(Boolean);
  if (urls.length === 0) return "";
  const text = `Attachment: ${urls.join(" ")}`;
  return prefixGroupSender(thread, message, text);
}

async function downloadIncomingAttachments(targets) {
  const unique = Array.from(new Set(targets.map((target) => target.url).filter(Boolean)));
  if (unique.length === 0) return [];

  const batchId = Date.now();
  const results = await Promise.allSettled(
    unique.map(async (url, index) => {
      const response = await fetch(url, { redirect: "follow" });
      if (!response.ok) {
        throw new Error(`Incoming attachment download failed (${response.status})`);
      }

      const buffer = Buffer.from(await response.arrayBuffer());
      const contentType = response.headers.get("content-type") || "application/octet-stream";
      const ext = extensionFromUrl(url) || extensionFromContentType(contentType) || "bin";
      const filename = `zalo-attachment-${batchId}-${index}.${ext}`;
      return { buffer, contentType, filename };
    })
  );

  const attachments = [];
  results.forEach((result, index) => {
    if (result.status === "fulfilled") {
      attachments.push(result.value);
      return;
    }
    console.warn("Failed to download Zalo attachment", {
      url: unique[index],
      error: result.reason?.message || result.reason
    });
  });

  return attachments;
}

async function downloadAttachments(attachments) {
  const supported = attachments.filter((attachment) => {
    if (!attachment || !attachment.data_url) return false;
    return ["image", "audio", "video", "file"].includes(attachment.file_type);
  });
  if (supported.length === 0) return [];

  const batchId = Date.now();
  const downloads = supported.map(async (attachment, index) => {
    const url = attachment.data_url;
    const ext = attachment.extension || extensionFromUrl(url) || "bin";
    const idPart = attachment.id || `${batchId}-${index}`;
    const filename = `attachment-${idPart}.${ext}`;
    const filePath = path.join(tempRoot, filename);

    const response = await fetch(url, { redirect: "follow" });
    if (!response.ok) {
      throw new Error(`Attachment download failed (${response.status})`);
    }

    const buffer = Buffer.from(await response.arrayBuffer());
    fs.writeFileSync(filePath, buffer);
    return filePath;
  });

  const results = await Promise.allSettled(downloads);
  const files = [];
  results.forEach((result, index) => {
    if (result.status === "fulfilled") {
      files.push(result.value);
      return;
    }
    console.warn("Failed to download Chatwoot attachment", {
      id: supported[index]?.id,
      url: supported[index]?.data_url,
      error: result.reason?.message || result.reason
    });
  });

  return files;
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

function extensionFromContentType(contentType) {
  const type = (contentType || "").split(";")[0].trim().toLowerCase();
  const map = {
    "image/jpeg": "jpg",
    "image/jpg": "jpg",
    "image/png": "png",
    "image/gif": "gif",
    "image/webp": "webp",
    "video/mp4": "mp4",
    "audio/mpeg": "mp3",
    "audio/ogg": "ogg",
    "audio/wav": "wav",
    "application/pdf": "pdf"
  };
  return map[type] || null;
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

  async createIncomingMessage({ sourceId, conversationId, content, echoId, attachments = [] }) {
    if (attachments.length > 0) {
      return this.requestMultipart(this.messagesUrl(sourceId, conversationId), {
        content,
        echoId,
        attachments
      });
    }

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

  async requestMultipart(url, { content, echoId, attachments }) {
    const form = new FormData();
    if (content !== undefined) {
      form.append("content", content);
    }
    if (echoId) {
      form.append("echo_id", echoId);
    }
    attachments.forEach((attachment) => {
      const file = new Blob([attachment.buffer], {
        type: attachment.contentType || "application/octet-stream"
      });
      form.append("attachments[]", file, attachment.filename || "attachment.bin");
    });

    const response = await fetch(url, {
      method: "POST",
      headers: {
        Accept: "application/json"
      },
      body: form
    });

    const text = await response.text();
    const data = text ? JSON.parse(text) : null;
    if (!response.ok) {
      throw new Error(`Chatwoot request failed (${response.status}): ${text}`);
    }

    return data;
  }
}
