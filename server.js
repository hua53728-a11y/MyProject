const fs = require("fs");
const path = require("path");
const http = require("http");
const crypto = require("crypto");
const QRCode = require("qrcode");

const env = process.env;
const cfg = {
  ServerIP: env.SERVER_IP || "1.2.3.4",
  Port: env.NODE_PORT || "443",
  UUID: env.UUID || "00000000-0000-0000-0000-000000000000",
  Flow: env.FLOW || "xtls-rprx-vision",
  Security: "reality",
  SNI: env.SNI || "www.apple.com",
  PublicKey: env.PUBLIC_KEY || "YOUR_PUBLIC_KEY",
  ShortID: env.SHORT_ID === undefined ? "abcd1234" : env.SHORT_ID,
  NodeName: env.NODE_NAME || "VLESS-Reality",
};

const boolEnv = (name, fallback) => {
  const raw = String(env[name] || "").trim().toLowerCase();
  if (raw === "") return fallback;
  return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
};

const host = env.HOST || "127.0.0.1";
const port = Number(env.PORT || 8080);
const keepAliveTimeoutMs = Number(env.KEEP_ALIVE_TIMEOUT_MS || 65000);
const headersTimeoutMs = Number(env.HEADERS_TIMEOUT_MS || 66000);
const requestTimeoutMs = Number(env.REQUEST_TIMEOUT_MS || 15000);
const maxConnections = Number(env.MAX_CONNECTIONS || 1024);
const logDir = env.LOG_DIR ? path.resolve(env.LOG_DIR) : path.join(__dirname, "logs");
const trustProxy = boolEnv("TRUST_PROXY", false);

const qrPath = env.QR_PATH || "/";
const subPath = env.SUB_PATH || "/sub";
const clashPath = env.CLASH_PATH || "/clash";
// 设为 1 时彻底关闭访问令牌校验(即使 ACCESS_TOKEN 有值也忽略)
const authDisabled = boolEnv("AUTH_DISABLED", false);
const accessToken = authDisabled ? "" : (env.ACCESS_TOKEN || "");
const scanWindowMs = Number(env.SCAN_WINDOW_MS || 60000);
const scanLimit = Number(env.SCAN_LIMIT || 20);
const blockDurationMs = Number(env.BLOCK_DURATION_MS || 15 * 60 * 1000);
const ipStateMax = Number(env.IP_STATE_MAX || 10000);
const logFlushMs = Number(env.LOG_FLUSH_MS || 2000);
const logMaxLines = Number(env.LOG_MAX_LINES || 8000);
const logRetentionDays = Math.max(1, Number(env.LOG_RETENTION_DAYS || 1));

const suspiciousPathRegex = /(\.env|\.git|wp-admin|phpmyadmin|v2ray|xray|trojan|config\.ya?ml|actuator|swagger|jenkins|login)/i;
const suspiciousUaRegex = /(zgrab|masscan|nmap|sqlmap|nikto|curl\/(7|8)|python-requests|go-http-client|apachebench|httpclient)/i;
const ipState = new Map();

const stats = {
  total: 0,
  served: 0,
  blockedHit: 0,
  blockedNew: 0,
  notFound: 0,
  forbidden: 0,
  droppedLogs: 0,
};

const enc = encodeURIComponent;
const link =
  `vless://${cfg.UUID}@${cfg.ServerIP}:${cfg.Port}` +
  `?encryption=none&flow=${enc(cfg.Flow)}&security=${cfg.Security}` +
  `&sni=${enc(cfg.SNI)}&fp=chrome&pbk=${enc(cfg.PublicKey)}&sid=${enc(cfg.ShortID)}` +
  `#${enc(cfg.NodeName)}`;

// Clash 系客户端(mihomo/Clash Verge/FlClash/Stash 等)订阅用的 YAML 配置
const clashConfig = () => {
  const realityOpts = [`      public-key: "${cfg.PublicKey}"`];
  if (cfg.ShortID) realityOpts.push(`      short-id: "${cfg.ShortID}"`);
  return [
    "proxies:",
    `  - name: "${cfg.NodeName}"`,
    "    type: vless",
    `    server: ${cfg.ServerIP}`,
    `    port: ${Number(cfg.Port) || 443}`,
    `    uuid: ${cfg.UUID}`,
    "    network: tcp",
    "    udp: true",
    "    tls: true",
    `    flow: ${cfg.Flow}`,
    `    servername: ${cfg.SNI}`,
    "    reality-opts:",
    ...realityOpts,
    "    client-fingerprint: chrome",
    "proxy-groups:",
    '  - name: "节点选择"',
    "    type: select",
    "    proxies:",
    `      - "${cfg.NodeName}"`,
    "",
  ].join("\n");
};

const esc = (s) =>
  s.replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));

const now = () => Date.now();

const clientIp = (req) => {
  // 仅在确认位于可信反向代理之后时才信任 X-Forwarded-For,
  // 否则攻击者可伪造 XFF 绕过限流并无限膨胀 ipState
  if (trustProxy) {
    const forwarded = req.headers["x-forwarded-for"];
    if (typeof forwarded === "string" && forwarded.length > 0) {
      return forwarded.split(",")[0].trim();
    }
  }
  const raw = req.socket.remoteAddress || "-";
  return raw.startsWith("::ffff:") ? raw.slice(7) : raw;
};

const dateKey = (date = new Date()) => {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
};

const trafficLogFile = (date = new Date()) => path.join(logDir, `traffic-${dateKey(date)}.log`);
const securityLogFile = (date = new Date()) => path.join(logDir, `security-${dateKey(date)}.log`);

// 缓冲日志:按固定间隔批量追加写盘,避免扫描风暴时每个请求都触发一次
// 打开-写-关闭文件,导致磁盘 I/O 队列无限增长、拖慢整机甚至假死/OOM
const logBuffers = new Map();

class BufferedLog {
  constructor(filePath) {
    this.filePath = filePath;
    this.lines = [];
    this.writing = false;
  }
  write(record) {
    if (this.lines.length >= logMaxLines) {
      stats.droppedLogs++;
      return;
    }
    this.lines.push(`${JSON.stringify(record)}\n`);
  }
  flush() {
    if (this.writing || this.lines.length === 0) return;
    const payload = this.lines.join("");
    this.lines = [];
    this.writing = true;
    fs.promises.appendFile(this.filePath, payload)
      .catch((err) => console.error("[log-write-error]", err.message))
      .finally(() => {
        this.writing = false;
      });
  }
}

const writeLog = (filePath, record) => {
  let buffer = logBuffers.get(filePath);
  if (!buffer) {
    buffer = new BufferedLog(filePath);
    logBuffers.set(filePath, buffer);
  }
  buffer.write(record);
};

const flushLogs = () => {
  for (const [filePath, buffer] of logBuffers.entries()) {
    buffer.flush();
    const current = filePath === trafficLogFile() || filePath === securityLogFile();
    if (!current && !buffer.writing && buffer.lines.length === 0) {
      logBuffers.delete(filePath);
    }
  }
};

const appendTrafficLog = (record) => writeLog(trafficLogFile(), record);
const appendSecurityLog = (record) => writeLog(securityLogFile(), record);

// 定时清理过期日志:默认仅保留当天日志(即删除前一天的),可通过 LOG_RETENTION_DAYS 调整保留天数。
// 先冲刷缓冲再删除,并跳过仍有写入在途的文件,避免“删除后被缓冲补写复活”的竞态。
const cleanOldLogs = async () => {
  flushLogs();
  const cutoffDate = new Date(now() - (logRetentionDays - 1) * 24 * 60 * 60 * 1000);
  const cutoff = dateKey(cutoffDate);
  try {
    const entries = await fs.promises.readdir(logDir, { withFileTypes: true });
    const tasks = entries
      .filter((entry) => entry.isFile() && /^(traffic|security)-\d{4}-\d{2}-\d{2}\.log$/.test(entry.name))
      .filter((entry) => entry.name.slice(-14, -4) < cutoff)
      .filter((entry) => {
        const buffer = logBuffers.get(path.join(logDir, entry.name));
        return !buffer || (!buffer.writing && buffer.lines.length === 0);
      })
      .map((entry) => path.join(logDir, entry.name));

    for (const filePath of tasks) logBuffers.delete(filePath);

    if (tasks.length > 0) {
      await Promise.all(tasks.map((filePath) => fs.promises.unlink(filePath)));
      console.log(`[log-cleanup] deleted ${tasks.length} log file(s) older than ${cutoff}`);
    }
  } catch (err) {
    console.error("[log-cleanup-error]", err.message);
  }
};

// 内存保护:ipState 超过上限时驱逐未封禁条目,防止海量伪造 IP 撑爆内存
const evictIpStates = (ts) => {
  for (const [ip, state] of ipState.entries()) {
    if (ipState.size < ipStateMax) break;
    if (state.blockedUntil <= ts) ipState.delete(ip);
  }
  if (ipState.size >= ipStateMax) {
    const first = ipState.keys().next();
    if (!first.done) ipState.delete(first.value);
  }
};

const touchState = (ip) => {
  const ts = now();
  let state = ipState.get(ip);
  if (!state) {
    if (ipState.size >= ipStateMax) evictIpStates(ts);
    state = {
      hits: [],
      blockedUntil: 0,
    };
    ipState.set(ip, state);
  }

  state.hits.push(ts);
  const minTs = ts - scanWindowMs;
  state.hits = state.hits.filter((n) => n >= minTs);
  return state;
};

const isBlocked = (ip) => {
  const state = ipState.get(ip);
  if (!state) {
    return false;
  }
  return state.blockedUntil > now();
};

const blockIp = (ip, reason) => {
  const state = touchState(ip);
  state.blockedUntil = now() + blockDurationMs;
  appendSecurityLog({
    ts: new Date().toISOString(),
    event: "ip_blocked",
    ip,
    reason,
    blockedUntil: new Date(state.blockedUntil).toISOString(),
  });
};

const looksLikeScanner = (req) => {
  const requestPath = req.url || "";
  const ua = req.headers["user-agent"] || "";

  if (req.method !== "GET" && req.method !== "HEAD") {
    return { flagged: true, reason: "invalid_method" };
  }
  if (suspiciousPathRegex.test(requestPath)) {
    return { flagged: true, reason: "suspicious_path" };
  }
  if (suspiciousUaRegex.test(ua)) {
    return { flagged: true, reason: "suspicious_ua" };
  }

  return { flagged: false, reason: "" };
};

// 安全解析 URL,畸形输入返回 null(不再让 new URL 抛异常击穿进程)
const parseUrl = (raw) => {
  try {
    return new URL(raw || "/", "http://localhost");
  } catch {
    return null;
  }
};

const hasAccessToken = (req, fullUrl) => {
  if (!accessToken) {
    return true;
  }

  const tokenFromQuery = fullUrl ? fullUrl.searchParams.get("k") || "" : "";
  const tokenFromHeader = String(req.headers["x-access-token"] || "");
  const candidate = tokenFromHeader || tokenFromQuery;

  if (!candidate) {
    return false;
  }

  const left = Buffer.from(candidate);
  const right = Buffer.from(accessToken);
  if (left.length !== right.length) {
    return false;
  }
  return crypto.timingSafeEqual(left, right);
};

const securityHeaders = {
  "X-Content-Type-Options": "nosniff",
  "X-Frame-Options": "DENY",
  "Referrer-Policy": "no-referrer",
  "Content-Security-Policy": "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
};

const decoyPage = Buffer.from(
  "<!doctype html><html><head><meta charset=\"utf-8\"><title>Welcome</title></head><body><h1>Welcome</h1></body></html>",
  "utf8"
);

const htmlTemplate = (svg, subUrl, clashUrl) => `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Client Config</title>
<style>
body{font-family:system-ui,sans-serif;max-width:560px;margin:40px auto;padding:0 16px;text-align:center}
h3{margin-top:28px;border-bottom:1px solid #eee;padding-bottom:8px;text-align:left}
.qr{background:#fff;display:inline-block;padding:8px;border:1px solid #ddd;border-radius:8px}
textarea{width:100%;height:120px;margin-top:16px;font-family:monospace;box-sizing:border-box}
textarea.sub{height:48px}
button{margin-top:8px;padding:8px 16px}
p.hint{color:#666;font-size:13px;margin:16px 0 4px;text-align:left}
</style></head><body>
<h2>${esc(cfg.NodeName)}</h2>

<h3>方式一：扫码订阅</h3>
<p class="hint">用 Shadowrocket / v2rayNG / v2rayN 的「扫一扫」直接添加节点。</p>
<div class="qr">${svg}</div>

<h3>方式二：URL 订阅</h3>
<p class="hint">通用客户端（Shadowrocket / v2rayN / v2rayNG 等），粘贴到「订阅 / Subscribe URL」：</p>
<textarea id="sub" class="sub" readonly>${esc(subUrl)}</textarea><br>
<button onclick="copyText('sub')">复制通用订阅地址</button>
<p class="hint">Clash 客户端（Clash Verge / FlClash / mihomo / Stash 等），粘贴到「订阅 / Subscribe URL」：</p>
<textarea id="clash" class="sub" readonly>${esc(clashUrl)}</textarea><br>
<button onclick="copyText('clash')">复制 Clash 订阅地址</button>

<h3>节点链接（手动导入）</h3>
<textarea id="link" readonly>${esc(link)}</textarea><br>
<button onclick="copyText('link')">复制节点链接</button>
<script>
function copyText(id){const t=document.getElementById(id);t.select();navigator.clipboard?navigator.clipboard.writeText(t.value):document.execCommand('copy')}
</script>
</body></html>`;

const bootstrap = async () => {
  await fs.promises.mkdir(logDir, { recursive: true });
  await cleanOldLogs();
  setInterval(cleanOldLogs, 60 * 60 * 1000).unref();
  setInterval(flushLogs, logFlushMs).unref();

  const svg = await QRCode.toString(link, {
    type: "svg",
    errorCorrectionLevel: "M",
    margin: 2,
    width: 300,
  });

  const server = http.createServer((req, res) => {
    const started = process.hrtime.bigint();
    const reqBytes = Number(req.headers["content-length"] || 0);
    const ip = clientIp(req);
    stats.total++;

    const reply = (statusCode, body, contentType = "text/plain; charset=utf-8", opts = {}) => {
      const headers = {
        ...securityHeaders,
        "Content-Type": contentType,
        "Content-Length": body.length,
      };
      if (opts.noStore) headers["Cache-Control"] = "no-store";
      if (opts.close) {
        // 扫描/被拒请求立即关闭连接,释放 socket,不再为其保留 keep-alive
        headers.Connection = "close";
        res.shouldKeepAlive = false;
        if (req.method !== "GET" && req.method !== "HEAD") req.resume();
      } else {
        headers.Connection = "keep-alive";
      }
      res.writeHead(statusCode, headers);
      if (req.method === "HEAD") {
        res.end();
      } else {
        res.end(body);
      }
      if (opts.traffic !== false) {
        const durationMs = Number(process.hrtime.bigint() - started) / 1e6;
        appendTrafficLog({
          ts: new Date().toISOString(),
          method: req.method,
          path: req.url,
          status: statusCode,
          ip,
          ua: req.headers["user-agent"] || "",
          reqBytes,
          resBytes: body.length,
          durationMs: Number(durationMs.toFixed(3)),
        });
      }
    };

    // 1) 已封禁 IP:最廉价响应,不解析 URL;重复噪声不写入 traffic 日志
    //    (首次触发的封禁事件已记录在 security 日志中)
    if (isBlocked(ip)) {
      stats.blockedHit++;
      reply(404, decoyPage, "text/html; charset=utf-8", { close: true, traffic: false });
      return;
    }

    // 2) 特征匹配:纯内存正则,零磁盘 I/O
    const scanner = looksLikeScanner(req);
    if (scanner.flagged) {
      stats.blockedNew++;
      blockIp(ip, scanner.reason);
      reply(404, decoyPage, "text/html; charset=utf-8", { close: true });
      return;
    }

    // 3) 频率限制
    const state = touchState(ip);
    if (state.hits.length > scanLimit) {
      stats.blockedNew++;
      blockIp(ip, "rate_limit");
      reply(404, decoyPage, "text/html; charset=utf-8", { close: true });
      return;
    }

    // 4) 路径校验(解析失败同样视为扫描)
    const fullUrl = parseUrl(req.url);
    const isMainPage = fullUrl && fullUrl.pathname === qrPath;
    const isSubPage = fullUrl && fullUrl.pathname === subPath;
    const isClashPage = fullUrl && fullUrl.pathname === clashPath;
    if (!fullUrl || (!isMainPage && !isSubPage && !isClashPage)) {
      stats.notFound++;
      reply(404, decoyPage, "text/html; charset=utf-8", { close: true });
      return;
    }

    // 5) 访问令牌
    if (!hasAccessToken(req, fullUrl)) {
      stats.forbidden++;
      appendSecurityLog({
        ts: new Date().toISOString(),
        event: "auth_failed",
        ip,
        path: req.url,
        ua: req.headers["user-agent"] || "",
      });
      reply(403, Buffer.from("Forbidden", "utf8"));
      return;
    }

    // 6) 订阅地址:返回纯文本 vless 链接,供 Shadowrocket/v2rayN 等客户端"订阅"导入
    if (isSubPage) {
      reply(200, Buffer.from(link + "\n", "utf8"), "text/plain; charset=utf-8", { noStore: true });
      return;
    }

    // 6b) Clash 订阅地址:返回 YAML 配置,供 Clash 系客户端导入
    if (isClashPage) {
      reply(200, Buffer.from(clashConfig(), "utf8"), "text/yaml; charset=utf-8", { noStore: true });
      return;
    }

    // 7) 主页面:按当前请求注入订阅地址(含 host 与令牌)
    const forwardedProto = trustProxy
      ? String(req.headers["x-forwarded-proto"] || "").split(",")[0].trim()
      : "";
    const proto = forwardedProto === "https" ? "https" : "http";
    const hostHeader = req.headers["host"] || `${host}:${port}`;
    const authParam = accessToken ? `?k=${encodeURIComponent(accessToken)}` : "";
    const subUrl = `${proto}://${hostHeader}${subPath}${authParam}`;
    const clashUrl = `${proto}://${hostHeader}${clashPath}${authParam}`;
    const html = htmlTemplate(svg, subUrl, clashUrl);

    stats.served++;
    reply(200, Buffer.from(html, "utf8"), "text/html; charset=utf-8", { noStore: true });
  });

  server.keepAliveTimeout = keepAliveTimeoutMs;
  server.headersTimeout = headersTimeoutMs;
  server.requestTimeout = requestTimeoutMs;
  server.maxConnections = maxConnections;
  server.on("connection", (socket) => socket.setNoDelay(true));
  server.on("clientError", (err, socket) => {
    if (socket.writable) socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
    else socket.destroy();
  });
  server.on("drop", () => console.warn("[connection-drop] maxConnections reached"));
  server.on("error", (err) => console.error("[server-error]", err.message));

  // 定期清理过期 IP 状态并输出运行统计,控制内存占用
  setInterval(() => {
    const ts = now();
    const threshold = ts - Math.max(blockDurationMs, scanWindowMs) * 2;
    for (const [ip, state] of ipState.entries()) {
      const lastHit = state.hits[state.hits.length - 1] || 0;
      if (state.blockedUntil < ts && lastHit < threshold) {
        ipState.delete(ip);
      }
    }
    console.log("[stats]", JSON.stringify(stats));
  }, 5 * 60 * 1000).unref();

  let shuttingDown = false;
  const shutdown = (signal) => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(`[shutdown] ${signal} received, closing server and flushing logs`);
    if (typeof server.closeIdleConnections === "function") server.closeIdleConnections();
    server.close(() => {
      flushLogs();
      setTimeout(() => process.exit(0), 300).unref();
    });
    setTimeout(() => process.exit(0), 5000).unref();
  };
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));

  server.listen(port, host, () => {
    console.log(`http://${host}:${port}`);
    console.log(`[traffic-log] ${logDir}`);
    console.log(`[security] qrPath=${qrPath} tokenEnabled=${Boolean(accessToken)} trustProxy=${trustProxy} maxConnections=${maxConnections}`);
    console.log(`[log-retention] keep ${logRetentionDays} day(s) of logs, cleanup every hour`);
  });
};

// 进程级兜底:任何未捕获异常/拒绝只记录不退出,避免单次异常导致进程死亡(假死)
process.on("uncaughtException", (err) => {
  console.error("[uncaught-exception]", err && err.stack ? err.stack : err);
});
process.on("unhandledRejection", (reason) => {
  console.error("[unhandled-rejection]", reason && reason.stack ? reason.stack : reason);
});

bootstrap().catch((err) => {
  console.error("[startup-error]", err);
  process.exit(1);
});
