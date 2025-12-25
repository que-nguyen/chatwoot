import { Zalo, ThreadType, LoginQRCallbackEventType } from "zca-js";
import crypto from "crypto";
import fs from "fs";
import http from "http";
import imageSizeModule from "image-size";
import os from "os";
import path from "path";
import { ProxyAgent } from "undici";

const DEFAULT_WEBHOOK_PATH = "/webhooks/chatwoot";
const DEFAULT_QR_PATH = "./qr.png";
const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "chatwoot-zalo-"));
const imageSize = typeof imageSizeModule === "function" ? imageSizeModule : imageSizeModule.imageSize;

async function start() {
  const baseConfig = loadConfig();
  const accounts = buildAccounts(baseConfig);
  validateConfig(baseConfig, accounts);

  for (const account of accounts) {
    await startAccount(account);
  }

  const server = createServer(accounts);
  server.listen(baseConfig.port, () => {
    const bindings = accounts
      .map((account) => `${account.config.chatwootWebhookPath} => ${account.label}`)
      .join(", ");
    const suffix = accounts.length > 1 ? ` (${bindings})` : ` ${bindings}`;
    console.log(`Zalo adapter listening on :${baseConfig.port}${suffix}`);
  });
}

async function startAccount(account) {
  const zalo = new Zalo(buildZaloOptions(account));

  account.api = await loginZalo(zalo, account);
  account.api.listener.on("message", (message) => handleIncomingZaloMessage(account, message));
  account.api.listener.on("reaction", (reaction) => handleIncomingZaloReaction(account, reaction));
  account.api.listener.on("undo", (undo) => handleIncomingZaloUndo(account, undo));
  account.api.listener.on("group_event", (event) => handleIncomingZaloGroupEvent(account, event));
  account.api.listener.on("typing", (typing) => handleIncomingZaloTyping(account, typing));
  account.api.listener.on("seen_messages", (messages) => handleIncomingZaloSeen(account, messages));
  account.api.listener.start();
}

function buildZaloOptions(account) {
  const options = {
    selfListen: account.config.zaloSelfListen,
    checkUpdate: account.config.zaloCheckUpdate,
    logging: account.config.zaloLogging,
    imageMetadataGetter
  };

  const proxyUrl = (account.config.zaloProxyUrl || "").trim();
  if (!proxyUrl) return options;

  const agent = createProxyAgent(proxyUrl, account.label);
  if (!agent) return options;

  options.agent = agent;
  options.polyfill = createProxyAwareFetch();
  return options;
}

function createProxyAgent(proxyUrl, label) {
  try {
    return new ProxyAgent(proxyUrl);
  } catch (error) {
    const prefix = label ? `[${label}] ` : "";
    console.warn(`${prefix}Failed to create proxy agent`, error?.message || error);
    return null;
  }
}

function createProxyAwareFetch() {
  return (url, options = {}) => {
    if (!options || !options.agent) return fetch(url, options);

    const { agent, ...rest } = options;
    if (rest.dispatcher) return fetch(url, rest);
    return fetch(url, { ...rest, dispatcher: agent });
  };
}

function createServer(accounts) {
  const accountByPath = new Map();
  accounts.forEach((account) => {
    accountByPath.set(normalizePath(account.config.chatwootWebhookPath), account);
  });

  return http.createServer(async (req, res) => {
    const { pathname } = new URL(req.url, `http://${req.headers.host}`);
    const account = accountByPath.get(normalizePath(pathname));

    if (req.method === "POST" && account) {
      try {
        const payload = await readJson(req);
        await handleChatwootWebhook(account, payload);
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
}

function buildAccounts(baseConfig) {
  const { accounts: rawAccounts, baseDir } = loadAccountsFromEnv(baseConfig);
  const items = rawAccounts.length > 0 ? rawAccounts : [{}];
  const total = items.length;

  return items.map((raw, index) => {
    const resolvedRaw = resolveAccountPaths(raw, baseDir);
    const config = mergeAccountConfig(baseConfig, resolvedRaw, index, total);
    const label = resolveAccountLabel(raw, index, config);
    return {
      id: raw?.id || raw?.name || `account-${index + 1}`,
      label,
      config,
      chatwoot: new ChatwootClient(config),
      api: null,
      groupNameCache: new Map(),
      groupNamePending: new Map()
    };
  });
}

function resolveAccountLabel(raw, index, config) {
  return (
    raw?.label ||
    raw?.name ||
    raw?.id ||
    config.chatwootInboxIdentifier ||
    `account-${index + 1}`
  );
}

function mergeAccountConfig(baseConfig, raw, index, total) {
  const { zaloAccountsJson, zaloAccountsPath, ...base } = baseConfig;
  const merged = { ...base, ...raw };
  merged.chatwootBaseUrl = normalizeBaseUrl(merged.chatwootBaseUrl);
  merged.chatwootWebhookPath = resolveWebhookPath(
    base.chatwootWebhookPath,
    raw?.chatwootWebhookPath,
    index,
    total
  );
  merged.zaloLoginMode = normalizeLoginMode(merged.zaloLoginMode);
  merged.zaloCookiePath = resolveCookiePath(
    base.zaloCookiePath,
    raw?.zaloCookiePath,
    index,
    total
  );
  merged.zaloQrPath = resolveQrPath(base.zaloQrPath, raw?.zaloQrPath, merged, index, total);
  return merged;
}

function normalizeLoginMode(value) {
  if (!value) return "cookie";
  const normalized = String(value).toLowerCase();
  return normalized === "qr" ? "qr" : "cookie";
}

function resolveWebhookPath(basePath, rawPath, index, total) {
  if (rawPath) return normalizePath(rawPath);
  const normalizedBase = normalizePath(basePath || DEFAULT_WEBHOOK_PATH) || DEFAULT_WEBHOOK_PATH;
  if (total > 1) {
    return normalizePath(`${normalizedBase}/${index + 1}`);
  }
  return normalizedBase;
}

function resolveCookiePath(basePath, rawPath, index, total) {
  const resolved = rawPath || basePath || "./cookie.json";
  if (total <= 1 || rawPath) return resolved;
  return appendSuffixToPath(resolved, index + 1);
}

function resolveQrPath(basePath, rawPath, merged, index, total) {
  if (rawPath) return rawPath;
  if (merged.zaloLoginMode !== "qr") return basePath || "";
  const resolved = basePath || DEFAULT_QR_PATH;
  if (total > 1) return appendSuffixToPath(resolved, index + 1);
  return resolved;
}

function appendSuffixToPath(filePath, suffix) {
  if (!filePath) return filePath;
  const parsed = path.parse(filePath);
  const name = parsed.name || "file";
  const ext = parsed.ext || "";
  const dir = parsed.dir || ".";
  return path.join(dir, `${name}-${suffix}${ext}`);
}

function normalizePath(value) {
  if (!value) return "";
  let normalized = value.trim();
  if (!normalized.startsWith("/")) {
    normalized = `/${normalized}`;
  }
  if (normalized.length > 1 && normalized.endsWith("/")) {
    normalized = normalized.slice(0, -1);
  }
  return normalized;
}

function normalizeBaseUrl(value) {
  return (value || "").replace(/\/+$/, "");
}

function loadAccountsFromEnv(baseConfig) {
  const jsonValue = baseConfig.zaloAccountsJson || "";
  const pathValue = baseConfig.zaloAccountsPath || "";
  if (!jsonValue && !pathValue) return { accounts: [], baseDir: "" };

  let raw = jsonValue;
  let baseDir = "";
  if (!raw) {
    const resolvedPath = path.resolve(pathValue);
    raw = fs.readFileSync(resolvedPath, "utf-8");
    baseDir = path.dirname(resolvedPath);
  }

  const parsed = JSON.parse(raw);
  if (!Array.isArray(parsed)) {
    throw new Error("ZALO_ACCOUNTS_JSON/PATH must be a JSON array");
  }

  return { accounts: parsed, baseDir };
}

function resolveAccountPaths(raw, baseDir) {
  if (!raw || !baseDir) return raw || {};

  return {
    ...raw,
    zaloCookiePath: resolvePathFromBase(baseDir, raw?.zaloCookiePath),
    zaloQrPath: resolvePathFromBase(baseDir, raw?.zaloQrPath)
  };
}

function resolvePathFromBase(baseDir, value) {
  if (!baseDir || !value || typeof value !== "string") return value;
  if (path.isAbsolute(value)) return value;
  return path.join(baseDir, value);
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

async function loginZalo(zalo, account) {
  const config = account.config;
  const prefix = account?.label ? `[${account.label}] ` : "";

  if (config.zaloLoginMode === "qr") {
    console.log(`${prefix}Logging in with QR...`);
    const options = {};
    if (config.zaloUserAgent) options.userAgent = config.zaloUserAgent;
    if (config.zaloQrPath) {
      ensureDirectoryForFile(config.zaloQrPath, `${prefix}QR path`);
      options.qrPath = config.zaloQrPath;
    }
    if (config.zaloCookiePath) {
      ensureDirectoryForFile(config.zaloCookiePath, `${prefix}Cookie path`);
    }

    const api = await zalo.loginQR(options, (event) => {
      if (event.type === LoginQRCallbackEventType.GotLoginInfo) {
        persistQrLoginInfo(account, event.data, prefix);
      }
    });

    return api;
  }

  const cookie = readCookiePayload(account);

  console.log(`${prefix}Logging in with cookie...`);
  return zalo.login({
    cookie,
    imei: config.zaloImei,
    userAgent: config.zaloUserAgent
  });
}

function persistQrLoginInfo(account, loginInfo, prefix) {
  const cookiePath = account?.config?.zaloCookiePath;
  if (!cookiePath) return;

  try {
    ensureDirectoryForFile(cookiePath, `${prefix}Cookie path`);
    fs.writeFileSync(cookiePath, JSON.stringify(loginInfo.cookie, null, 2));
    console.log(`${prefix}Saved QR session cookies to ${cookiePath}`);
  } catch (error) {
    console.warn(`${prefix}Failed to save QR cookies`, error?.message || error);
  }
}

function readCookiePayload(account) {
  const config = account?.config || {};
  const prefix = account?.label ? `[${account.label}] ` : "";
  const inline = typeof config.zaloCookieJson === "string" ? config.zaloCookieJson.trim() : "";

  let raw = inline;
  let sourceLabel = "ZALO_COOKIE_JSON";
  if (!raw) {
    if (!config.zaloCookiePath) {
      throw new Error(`${prefix}Missing cookie JSON (set ZALO_COOKIE_JSON or ZALO_COOKIE_PATH)`);
    }
    sourceLabel = config.zaloCookiePath;
    raw = fs.readFileSync(config.zaloCookiePath, "utf-8");
  }

  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(
      `${prefix}Invalid cookie JSON from ${sourceLabel}: ${error?.message || error}`
    );
  }
}

async function handleIncomingZaloMessage(account, message) {
  if (!message || message.isSelf) return;

  const thread = buildThreadRef(message);
  const sourceId = buildSourceId(thread);
  const { content, attachments } = await normalizeIncomingPayload(message, thread);
  const echoId = message?.data?.msgId || message?.data?.cliMsgId;
  const contactName = await resolveContactName(account, {
    thread,
    senderName: message?.data?.dName
  });

  await syncIncomingToChatwoot(account, {
    sourceId,
    thread,
    content: content || "",
    echoId,
    attachments,
    contactName
  });
}

async function handleIncomingZaloReaction(account, reaction) {
  if (!reaction || reaction.isSelf) return;

  const thread = buildThreadRefFromEvent(reaction);
  if (!thread) return;

  const sourceId = buildSourceId(thread);
  const content = formatReactionContent(reaction, thread);
  const echoId = buildEventEchoId("reaction", reaction?.data);
  const contactName = await resolveContactName(account, {
    thread,
    senderName: reaction?.data?.dName
  });

  await syncIncomingToChatwoot(account, {
    sourceId,
    thread,
    content,
    echoId,
    contactName
  });
}

async function handleIncomingZaloUndo(account, undo) {
  if (!undo || undo.isSelf) return;

  const thread = buildThreadRefFromEvent(undo);
  if (!thread) return;

  const sourceId = buildSourceId(thread);
  const content = formatUndoContent(undo, thread);
  const echoId = buildEventEchoId("undo", undo?.data);
  const contactName = await resolveContactName(account, {
    thread,
    senderName: undo?.data?.dName
  });

  await syncIncomingToChatwoot(account, {
    sourceId,
    thread,
    content,
    echoId,
    contactName
  });
}

async function handleIncomingZaloGroupEvent(account, event) {
  if (!event || event.isSelf) return;
  if (!event.threadId) return;

  const thread = { id: event.threadId, type: ThreadType.Group };
  const sourceId = buildSourceId(thread);
  const content = formatGroupEventContent(event, thread);
  const echoId = buildGroupEventEchoId(event);
  const contactName = await resolveContactName(account, {
    thread,
    groupName: event?.data?.groupName
  });

  if (!content) return;

  await syncIncomingToChatwoot(account, {
    sourceId,
    thread,
    content,
    echoId,
    contactName
  });
}

async function handleIncomingZaloTyping(account, typing) {
  if (!typing || typing.isSelf) return;

  const thread = buildThreadRefFromTyping(typing);
  if (!thread) return;

  const sourceId = buildSourceId(thread);
  try {
    const contactName = await resolveContactName(account, { thread });
    await account.chatwoot.ensureContact({
      sourceId,
      name: contactName || "Zalo User",
      identifier: sourceId
    });

    const conversationId = await account.chatwoot.findOpenConversation(sourceId);
    if (!conversationId) return;

    await account.chatwoot.toggleTyping({
      sourceId,
      conversationId,
      status: "on"
    });
  } catch (error) {
    console.warn("Failed to sync typing event", error?.message || error);
  }
}

async function handleIncomingZaloSeen(account, messages) {
  if (!Array.isArray(messages) || messages.length === 0) return;

  const threads = new Map();
  messages.forEach((message) => {
    if (!message || message.isSelf) return;
    if (!message.threadId) return;
    const type = message.type === ThreadType.Group ? ThreadType.Group : ThreadType.User;
    const key = `${type}:${message.threadId}`;
    if (!threads.has(key)) {
      threads.set(key, { id: message.threadId, type });
    }
  });

  for (const thread of threads.values()) {
    const sourceId = buildSourceId(thread);
    try {
      const contactName = await resolveContactName(account, { thread });
      await account.chatwoot.ensureContact({
        sourceId,
        name: contactName || "Zalo User",
        identifier: sourceId
      });

      const conversationId = await account.chatwoot.findOpenConversation(sourceId);
      if (!conversationId) continue;

      await account.chatwoot.updateLastSeen({ sourceId, conversationId });
    } catch (error) {
      console.warn("Failed to sync seen event", error?.message || error);
    }
  }
}

async function handleChatwootWebhook(account, payload) {
  if (!payload || !payload.event) return;

  if (payload.event === "message_created") {
    if (isChatwootPrivate(payload)) return;
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

    await sendZaloMessage(account, { thread, content, attachments });
    return;
  }

  if (payload.event === "conversation_typing_on") {
    await handleChatwootTyping(account, payload);
  }
}


function isChatwootPrivate(payload) {
  return payload?.private === true || payload?.is_private === true;
}

async function handleChatwootTyping(account, payload) {
  if (isChatwootPrivate(payload)) return;

  const sourceId = payload?.conversation?.contact_inbox?.source_id;
  if (!sourceId) {
    console.warn("Skipping typing webhook without source_id");
    return;
  }
  const thread = parseSourceId(sourceId);
  if (!thread) {
    console.warn("Skipping typing webhook with unsupported source_id", { sourceId });
    return;
  }

  if (!account.api || typeof account.api.sendTypingEvent !== "function") return;

  try {
    await account.api.sendTypingEvent(thread.id, thread.type);
  } catch (error) {
    console.warn("Failed to send typing event", error?.message || error);
  }
}

async function sendZaloMessage(account, { thread, content, attachments }) {
  if (!account.api) throw new Error("Zalo API not initialized");

  const files = await downloadAttachments(attachments);
  try {
    if (files.length > 0) {
      await account.api.sendMessage(
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

    await account.api.sendMessage(content, thread.id, thread.type);
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

function buildThreadRefFromTyping(typing) {
  if (!typing || !typing.threadId) return null;
  const type = typing.type === ThreadType.Group ? ThreadType.Group : ThreadType.User;
  return { id: typing.threadId, type };
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
  const content = normalizeIncomingContent(message);
  if (!shouldDownloadIncomingAttachments(message)) {
    return { content: prefixGroupSender(thread, message, content), attachments: [] };
  }
  const attachmentTargets = extractIncomingAttachmentTargets(message);
  if (attachmentTargets.length === 0) {
    return { content: prefixGroupSender(thread, message, content), attachments: [] };
  }

  const attachments = await downloadIncomingAttachments(attachmentTargets);
  const fallback = content || buildAttachmentFallback(message, attachmentTargets);
  return { content: prefixGroupSender(thread, message, fallback), attachments };
}

function normalizeIncomingContent(message) {
  const content = message?.data?.content;
  const quote = buildQuoteSummary(message);
  let base = "";
  if (typeof content === "string") {
    base = content;
  } else if (content && typeof content === "object") {
    base = buildAttachmentSummary(content);
  }

  if (!quote) return base;
  if (!base) return quote;
  return `${quote}
${base}`;
}

function shouldDownloadIncomingAttachments(message) {
  const msgType = typeof message?.data?.msgType === "string" ? message.data.msgType.toLowerCase() : "";
  if (!msgType) return true;
  const nonAttachmentTypes = new Set([
    "webchat",
    "chat.link",
    "chat.location.new",
    "chat.todo",
    "chat.recommended"
  ]);
  return !nonAttachmentTypes.has(msgType);
}

function buildQuoteSummary(message) {
  const quote = message?.data?.quote;
  if (!quote) return "";
  const quoted = typeof quote.msg === "string" ? quote.msg.trim() : "";
  if (!quoted) return "";
  const from = typeof quote.fromD === "string" && quote.fromD.trim() ? quote.fromD.trim() : quote.ownerId;
  const prefix = from ? `Replying to ${from}: ` : "Replying to: ";
  return `${prefix}${quoted}`.trim();
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

async function resolveContactName(account, { thread, senderName, groupName }) {
  if (!thread) return senderName || "Zalo User";
  if (thread.type !== ThreadType.Group) return senderName || "Zalo User";

  if (groupName) {
    account.groupNameCache.set(thread.id, groupName);
    return groupName;
  }

  const cached = account.groupNameCache.get(thread.id);
  if (cached) return cached;

  const fetched = await resolveGroupName(account, thread.id);
  if (fetched) return fetched;

  return `Zalo Group ${thread.id}`;
}

async function resolveGroupName(account, threadId) {
  if (!threadId) return null;

  const cached = account.groupNameCache.get(threadId);
  if (cached) return cached;

  const pending = account.groupNamePending.get(threadId);
  if (pending) return pending;

  const task = (async () => {
    if (!account.api || typeof account.api.getGroupInfo !== "function") return null;
    try {
      const response = await account.api.getGroupInfo(threadId);
      const info = response?.gridInfoMap?.[threadId];
      const name = info?.name || info?.groupName;
      if (name) account.groupNameCache.set(threadId, name);
      return name || null;
    } catch (error) {
      console.warn("Failed to fetch Zalo group info", threadId, error?.message || error);
      return null;
    } finally {
      account.groupNamePending.delete(threadId);
    }
  })();

  account.groupNamePending.set(threadId, task);
  return task;
}

function prefixGroupSenderId(thread, senderId, text) {
  if (thread?.type === ThreadType.Group && senderId && text) {
    return `[${senderId}] ${text}`;
  }
  return text;
}

async function syncIncomingToChatwoot(
  account,
  { sourceId, thread, content, echoId, attachments = [], contactName }
) {
  try {
    await account.chatwoot.ensureContact({
      sourceId,
      name: contactName || "Zalo User",
      identifier: sourceId
    });

    const conversationId = await account.chatwoot.getOrCreateConversation(sourceId, {
      zalo_thread_id: thread.id,
      zalo_thread_type: thread.type === ThreadType.Group ? "group" : "user"
    });

    if (!content && attachments.length === 0) {
      console.log("Skipping empty Zalo event", { sourceId, echoId });
      return;
    }

    await account.chatwoot.createIncomingMessage({
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
  if (thread?.type !== ThreadType.Group || !text) return text;
  const sender = getSenderLabel(message);
  return sender ? `[${sender}] ${text}` : text;
}

function getSenderLabel(message) {
  const name = typeof message?.data?.dName === "string" ? message.data.dName.trim() : "";
  if (name) return name;
  return message?.data?.uidFrom || "";
}

function extractIncomingAttachmentTargets(message) {
  const content = message?.data?.content;
  if (!content || typeof content !== "object") return [];

  const targets = [];
  const href = typeof content.href === "string" ? content.href.trim() : "";
  const thumb = typeof content.thumb === "string" ? content.thumb.trim() : "";
  if (href) targets.push({ url: href });
  if (thumb) targets.push({ url: thumb });

  const paramUrl = extractUrlFromParams(content.params);
  if (paramUrl) targets.push({ url: paramUrl });

  const seen = new Set();
  return targets.filter((target) => {
    if (!target.url) return false;
    if (seen.has(target.url)) return false;
    seen.add(target.url);
    return true;
  });
}

function extractUrlFromParams(params) {
  if (typeof params !== "string") return "";
  try {
    const parsed = JSON.parse(params);
    const candidates = [
      parsed?.href,
      parsed?.thumb,
      parsed?.normalUrl,
      parsed?.oriUrl,
      parsed?.hdUrl,
      parsed?.fileUrl,
      parsed?.url
    ];
    const url = candidates.find((value) => typeof value === "string" && value.trim());
    return url ? url.trim() : "";
  } catch {
    return "";
  }
}

function buildAttachmentSummary(content) {
  if (!content || typeof content !== "object") return "";
  const title = typeof content.title === "string" ? content.title.trim() : "";
  const description = typeof content.description === "string" ? content.description.trim() : "";
  const href = typeof content.href === "string" ? content.href.trim() : "";
  const parts = [title, description, href].filter(Boolean);
  return parts.join(" - ");
}

function buildAttachmentFallback(message, attachmentTargets) {
  const urls = attachmentTargets.map((target) => target.url).filter(Boolean);
  if (urls.length === 0) return "";
  return `Attachment: ${urls.join(" ")}`;
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
    chatwootWebhookPath: process.env.CHATWOOT_WEBHOOK_PATH || DEFAULT_WEBHOOK_PATH,
    chatwootHmacToken: process.env.CHATWOOT_HMAC_TOKEN || "",
    zaloLoginMode: process.env.ZALO_LOGIN_MODE || "cookie",
    zaloCookiePath: process.env.ZALO_COOKIE_PATH || "./cookie.json",
    zaloCookieJson: process.env.ZALO_COOKIE_JSON || "",
    zaloQrPath: process.env.ZALO_QR_PATH || "",
    zaloImei: process.env.ZALO_IMEI || "",
    zaloUserAgent: process.env.ZALO_USER_AGENT || "",
    zaloSelfListen: parseBool(process.env.ZALO_SELF_LISTEN, false),
    zaloCheckUpdate: parseBool(process.env.ZALO_CHECK_UPDATE, true),
    zaloLogging: parseBool(process.env.ZALO_LOGGING, true),
    zaloProxyUrl: process.env.ZALO_PROXY_URL || "",
    zaloAccountsJson: process.env.ZALO_ACCOUNTS_JSON || "",
    zaloAccountsPath: process.env.ZALO_ACCOUNTS_PATH || ""
  };
}

function validateConfig(baseConfig, accounts) {
  if (!accounts.length) {
    throw new Error("No Zalo accounts configured");
  }

  const pathMap = new Map();

  accounts.forEach((account) => {
    const missing = [];
    const config = account.config;

    if (!config.chatwootBaseUrl) missing.push("CHATWOOT_BASE_URL");
    if (!config.chatwootInboxIdentifier) missing.push("CHATWOOT_INBOX_IDENTIFIER");
    if (config.zaloLoginMode === "cookie") {
      if (!config.zaloImei) missing.push("ZALO_IMEI");
      if (!config.zaloUserAgent) missing.push("ZALO_USER_AGENT");

      const inlineCookie = typeof config.zaloCookieJson === "string" ? config.zaloCookieJson.trim() : "";
      if (!inlineCookie) {
        if (!config.zaloCookiePath) {
          missing.push("ZALO_COOKIE_PATH");
        } else if (!fs.existsSync(config.zaloCookiePath)) {
          throw new Error(
            "[" + account.label + "] Cookie file not found at " + config.zaloCookiePath +
              ". Provide ZALO_COOKIE_JSON or ensure the file exists."
          );
        }
      }
    }
    if (!config.chatwootWebhookPath) missing.push("CHATWOOT_WEBHOOK_PATH");

    if (missing.length > 0) {
      throw new Error(`[${account.label}] Missing required env vars: ${missing.join(", ")}`);
    }

    if (accounts.length > 1) {
      const normalizedPath = normalizePath(config.chatwootWebhookPath);
      const existing = pathMap.get(normalizedPath);
      if (existing) {
        throw new Error(
          `Duplicate webhook path ${normalizedPath} for accounts ${existing} and ${account.label}`
        );
      }
      pathMap.set(normalizedPath, account.label);
    }
  });
}

function parseBool(value, defaultValue) {
  if (value === undefined || value === "") return defaultValue;
  return ["1", "true", "yes", "y"].includes(String(value).toLowerCase());
}

function ensureDirectoryForFile(filePath, label) {
  if (!filePath) return;
  const dir = path.dirname(filePath);
  if (!dir || dir === ".") return;
  try {
    fs.mkdirSync(dir, { recursive: true });
  } catch (error) {
    console.warn(`Failed to create directory for ${label}: ${dir}`, error?.message || error);
  }
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
    const openId = await this.findOpenConversation(sourceId);
    if (openId) return openId;

    const payload = { custom_attributes: customAttributes || {} };
    const created = await this.requestJson(this.conversationsUrl(sourceId), {
      method: "POST",
      body: payload
    });
    return created.id;
  }

  async findOpenConversation(sourceId) {
    const list = await this.requestJson(this.conversationsUrl(sourceId));
    const open = Array.isArray(list) ? list.find((conv) => conv.status !== "resolved") : null;
    return open ? open.id : null;
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

  async toggleTyping({ sourceId, conversationId, status }) {
    return this.requestJson(this.typingUrl(sourceId, conversationId), {
      method: "POST",
      body: { typing_status: status }
    });
  }

  async updateLastSeen({ sourceId, conversationId }) {
    return this.requestJson(this.lastSeenUrl(sourceId, conversationId), {
      method: "POST"
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

  typingUrl(sourceId, conversationId) {
    return `${this.baseUrl}/public/api/v1/inboxes/${this.inboxId}/contacts/${encodeURIComponent(sourceId)}/conversations/${conversationId}/toggle_typing`;
  }

  lastSeenUrl(sourceId, conversationId) {
    return `${this.baseUrl}/public/api/v1/inboxes/${this.inboxId}/contacts/${encodeURIComponent(sourceId)}/conversations/${conversationId}/update_last_seen`;
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

await start();
