// 带认证的反向代理：对外听 PROXY_PORT（0.0.0.0），转发到 Strata 宿主 127.0.0.1:PROXY_UPSTREAM_PORT。
// Strata 自己没有登录功能，所以网页端口必须经过这里。转发 HTTP（含流式响应 / SSE）和 WebSocket。
// 两种认证：
//   - 网页（以及一切请求）：Basic Auth，用户名密码（set-password.mjs 写的 PROXY_AUTH_FILE）。
//   - API（/v1/...，OpenAI / Anthropic 兼容接口）：另外接受 API Key，放在 "Authorization: Bearer <key>" 或 "x-api-key: <key>"
//     里（set-api-key.mjs 写的 PROXY_API_KEY_FILE；文件不存在 = 没开 API Key 访问）。Claude Code、Codex 这类客户端只会发这种头。
// HTTPS（PROXY_TLS=on）：同一个端口同时收 HTTP 和 HTTPS（看连接的第一个字节是不是 TLS 握手）。证书优先用用户放在
// PROXY_TLS_USER_DIR 里的 cert.pem + key.pem（比如从飞牛导出的正式证书），否则用 PROXY_TLS_DIR 里自动生成的自签名证书
// （tls-cert.mjs，覆盖本机的主机名和各个 IP）。开启后网页走 HTTP 的会被 308 跳到 HTTPS；/v1 接口两种都收，已经配好的客户端不断。
// 环境：PROXY_PORT、PROXY_UPSTREAM_PORT、PROXY_AUTH_FILE、PROXY_API_KEY_FILE（可选）、PROXY_TLS、PROXY_TLS_DIR、PROXY_TLS_USER_DIR
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import os from 'node:os';
import { X509Certificate, createHash, createPrivateKey, scryptSync, timingSafeEqual } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { selfSigned } from './tls-cert.mjs';

const LISTEN = Number(process.env.PROXY_PORT);
const UP = Number(process.env.PROXY_UPSTREAM_PORT);
const AUTH_FILE = process.env.PROXY_AUTH_FILE;
const API_KEY_FILE = process.env.PROXY_API_KEY_FILE || '';
if (!LISTEN || !UP || !AUTH_FILE) { console.error('PROXY_PORT, PROXY_UPSTREAM_PORT and PROXY_AUTH_FILE are required'); process.exit(2); }

const log = (...a) => console.log(new Date().toISOString().replace('T', ' ').slice(0, 19), '[proxy]', ...a);
const TLS_ON = process.env.PROXY_TLS === 'on';
let tlsActive = false;   // HTTPS 真的在服务（有可用的证书）时才把网页从 HTTP 跳过去

// ---- 认证 -------------------------------------------------------------------
let cred = null, credMtime = 0;
function credentials() {
  const m = statSync(AUTH_FILE).mtimeMs;
  if (!cred || m !== credMtime) { cred = JSON.parse(readFileSync(AUTH_FILE, 'utf8')); credMtime = m; passed.clear(); }
  return cred;
}
const passed = new Map(); // 通过校验的 Authorization 头的 sha256 -> 过期时间（scrypt 很慢，不能每个请求都算）
const sameBytes = (a, b) => a.length === b.length && timingSafeEqual(a, b);
function authorized(req) {
  const header = req.headers.authorization;
  if (!header || !/^Basic /i.test(header)) return false;
  let c;
  try { c = credentials(); } catch { return false; }
  const key = createHash('sha256').update(header).digest('hex');
  const until = passed.get(key);
  if (until && until > Date.now()) return true;
  const text = Buffer.from(header.slice(6).trim(), 'base64').toString('utf8');
  const i = text.indexOf(':');
  if (i < 0) return false;
  const user = Buffer.from(text.slice(0, i)), password = text.slice(i + 1);
  const hash = scryptSync(password, Buffer.from(c.salt, 'hex'), c.params.keylen, { N: c.params.N, r: c.params.r, p: c.params.p });
  // 用户名和密码都要比，且两个比较都做完，不因为用户名不对就提前返回。
  const okUser = sameBytes(user, Buffer.from(c.user));
  const okPass = sameBytes(hash, Buffer.from(c.hash, 'hex'));
  if (okUser && okPass) { passed.set(key, Date.now() + 5 * 60_000); if (passed.size > 200) passed.clear(); return true; }
  return false;
}
// ---- API Key（只用于 /v1/...）--------------------------------------------------------
let apiKey = null, apiKeyMtime = -1;
function apiKeyDigest() {
  if (!API_KEY_FILE) return null;
  let m;
  try { m = statSync(API_KEY_FILE).mtimeMs; } catch { apiKey = null; apiKeyMtime = -1; return null; }   // 没有文件：没开
  if (m !== apiKeyMtime) {
    try { apiKey = Buffer.from(JSON.parse(readFileSync(API_KEY_FILE, 'utf8')).sha256, 'hex'); } catch { apiKey = null; }
    apiKeyMtime = m;
  }
  return apiKey?.length === 32 ? apiKey : null;
}
const isApiPath = url => url === '/v1' || url.startsWith('/v1/') || url.startsWith('/v1?');
/** null: the request carries no API key (Basic Auth decides); true / false: it carries one, right or wrong. */
function apiKeyVerdict(req) {
  const header = req.headers.authorization;
  const bearer = typeof header === 'string' && /^Bearer /i.test(header) ? header.slice(7).trim() : '';
  const alt = typeof req.headers['x-api-key'] === 'string' ? req.headers['x-api-key'].trim() : '';
  if (!bearer && !alt) return null;
  const want = apiKeyDigest();
  if (!want) return false;                // API Key 访问没开
  // 两个头都算一遍、都比一遍（定长摘要，恒定时间），不让时间泄露带的是哪一个。
  const a = sameBytes(createHash('sha256').update(bearer).digest(), want);
  const b = sameBytes(createHash('sha256').update(alt).digest(), want);
  return a || b;
}
/** How a request is let in: 'basic', 'apikey', or null (refused). */
function admit(req) {
  if (isApiPath(req.url ?? '')) {
    const verdict = apiKeyVerdict(req);
    if (verdict === true) return 'apikey';
    if (verdict === false) return null;
  }
  return authorized(req) ? 'basic' : null;
}

const failures = new Map(); // 客户端地址 -> 连续失败次数：失败越多，回应越慢
async function deny(remote, respond) {
  const n = (failures.get(remote) ?? 0) + 1;
  failures.set(remote, n);
  if (failures.size > 500) failures.clear();
  await new Promise(r => setTimeout(r, Math.min(250 * n, 5000)));
  respond();
}

// ---- 转发 -------------------------------------------------------------------
const upstreamOrigin = `http://127.0.0.1:${UP}`;
function upstreamHeaders(req) {
  const h = { ...req.headers };
  delete h.authorization;               // 认证到此为止，不转给宿主
  delete h['x-api-key'];
  h.host = `127.0.0.1:${UP}`;
  // 宿主会核对 Origin / Referer 与自己的地址是否一致：改成它自己的。
  if (h.origin) h.origin = upstreamOrigin;
  if (h.referer) { try { const u = new URL(h.referer); h.referer = upstreamOrigin + u.pathname + u.search; } catch { delete h.referer; } }
  return h;
}
const startingPage = 'Strata 正在启动或重启，请几秒后刷新页面。\nStrata is starting, refresh in a few seconds.\n';

const scheme = req => (req.socket.encrypted ? 'https' : 'http');

async function onRequest(req, res) {
  const remote = req.socket.remoteAddress ?? '?';
  // HTTPS 开着时，网页从 HTTP 来的跳到 HTTPS（同一个地址和端口）；/v1 接口不跳，已经配好 http:// 的客户端照常能用。
  if (tlsActive && !req.socket.encrypted && !isApiPath(req.url ?? '') && req.headers.host) {
    res.writeHead(308, { Location: `https://${req.headers.host}${req.url}`, 'Content-Length': '0' });
    return res.end();
  }
  const how = admit(req);
  if (!how) {
    return deny(remote, () => {
      if (isApiPath(req.url ?? '')) {
        // API 客户端：OpenAI / Anthropic 都能读懂的 JSON 错误；不带 WWW-Authenticate，免得浏览器弹登录框
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ type: 'error', error: { type: 'authentication_error', message: 'Invalid or missing API key (set it in the fnOS app settings of Strata)' } }) + '\n');
        return;
      }
      res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="Strata", charset="UTF-8"', 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('需要登录 / Authentication required\n');
    });
  }
  failures.delete(remote);
  const up = http.request({ host: '127.0.0.1', port: UP, method: req.method, path: req.url, headers: upstreamHeaders(req) }, ures => {
    const headers = { ...ures.headers };
    // 宿主若重定向到自己的地址，换成用户访问的地址。
    if (headers.location?.startsWith(upstreamOrigin)) headers.location = `${scheme(req)}://${req.headers.host}${headers.location.slice(upstreamOrigin.length)}`;
    res.writeHead(ures.statusCode, ures.statusMessage, headers);
    ures.pipe(res);
    ures.on('error', () => res.destroy());
  });
  up.on('error', () => {
    if (res.headersSent) return res.destroy();
    res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8', 'Retry-After': '3' });
    res.end(startingPage);
  });
  res.on('close', () => up.destroy());
  req.pipe(up);
}

async function onUpgrade(req, socket, head) {
  const remote = req.socket.remoteAddress ?? '?';
  const stop = () => socket.destroy();
  socket.on('error', stop);
  if (!admit(req)) {
    return deny(remote, () => socket.end('HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm="Strata"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'));
  }
  failures.delete(remote);
  const upstream = net.connect(UP, '127.0.0.1', () => {
    const h = upstreamHeaders(req);
    let raw = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (const [k, v] of Object.entries(h)) for (const x of [].concat(v)) raw += `${k}: ${x}\r\n`;
    upstream.write(raw + '\r\n');
    if (head?.length) upstream.write(head);
    socket.pipe(upstream); upstream.pipe(socket);
  });
  upstream.on('error', () => socket.end('HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'));
  upstream.on('close', stop);
  socket.on('close', () => upstream.destroy());
}

const tune = srv => {
  srv.requestTimeout = 0;   // 上传大文件、长时间的流式回答都不能被掐断
  srv.timeout = 0;
  srv.keepAliveTimeout = 65_000;
  srv.on('upgrade', onUpgrade);
  return srv;
};
const plain = tune(http.createServer(onRequest));

// ---- HTTPS 证书 -------------------------------------------------------------------------
/** This machine's names and addresses, for a self-signed certificate's subjectAltName. */
function myNames() {
  const ips = ['127.0.0.1', '::1'];
  for (const list of Object.values(os.networkInterfaces())) for (const a of list ?? []) if (!a.internal && !a.address.startsWith('fe80')) ips.push(a.address);
  const host = os.hostname();
  return { hosts: [...new Set([host, host.toLowerCase(), 'localhost'])], ips: [...new Set(ips)] };
}
function loadTls() {
  const userDir = process.env.PROXY_TLS_USER_DIR, dir = process.env.PROXY_TLS_DIR;
  if (userDir && existsSync(join(userDir, 'cert.pem')) && existsSync(join(userDir, 'key.pem'))) {
    const cert = readFileSync(join(userDir, 'cert.pem'), 'utf8'), key = readFileSync(join(userDir, 'key.pem'), 'utf8');
    const x = new X509Certificate(cert);
    if (!x.checkPrivateKey(createPrivateKey(key))) throw new Error(`${userDir}/key.pem does not belong to ${userDir}/cert.pem`);
    log(`HTTPS with your certificate ${userDir}/cert.pem (${x.subject.replace(/\n/g, ', ')}; valid until ${x.validTo})`);
    return { cert, key };
  }
  if (!dir) throw new Error('PROXY_TLS_DIR is not set');
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const names = myNames(), meta = join(dir, 'names.json'), certFile = join(dir, 'cert.pem'), keyFile = join(dir, 'key.pem');
  let same = false;
  try { same = readFileSync(meta, 'utf8') === JSON.stringify(names) && existsSync(certFile) && existsSync(keyFile); } catch { /* make one */ }
  if (!same) {   // 第一次，或本机的名字 / IP 变了：重新生成
    const made = selfSigned({ commonName: `Strata on ${os.hostname()}`, ...names });
    for (const [f, body] of [[keyFile, made.key], [certFile, made.cert], [meta, JSON.stringify(names)]]) {
      writeFileSync(`${f}.tmp`, body, { mode: 0o600 }); chmodSync(`${f}.tmp`, 0o600); renameSync(`${f}.tmp`, f);
    }
    log(`HTTPS: made a self-signed certificate for ${[...names.hosts, ...names.ips].join(', ')} (${certFile})`);
  }
  return { cert: readFileSync(certFile, 'utf8'), key: readFileSync(keyFile, 'utf8') };
}

let front = plain;
if (TLS_ON) {
  let tls = null;
  try { tls = loadTls(); } catch (e) { log(`HTTPS is on but no certificate could be used (${e.message}); serving plain HTTP only`); }
  if (tls) {
    const secure = tune(https.createServer(tls, onRequest));
    tlsActive = true;
    // 一个端口两种协议：TLS 握手的第一个字节是 0x16（handshake），HTTP 请求是字母。
    front = net.createServer({ pauseOnConnect: true }, socket => {
      socket.once('readable', () => {
        const first = socket.read(1);
        if (!first) return socket.destroy();
        socket.unshift(first);
        (first[0] === 0x16 ? secure : plain).emit('connection', socket);
        socket.resume();
      });
      socket.on('error', () => socket.destroy());
    });
  }
}
front.on('error', e => { log(`cannot listen on ${LISTEN}: ${e.message}`); process.exit(1); });
front.listen(LISTEN, '0.0.0.0', () => log(`listening on 0.0.0.0:${LISTEN} (${front === plain ? 'HTTP' : 'HTTP and HTTPS'}) -> ${upstreamOrigin}`));
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => { front.close(); process.exit(0); });
