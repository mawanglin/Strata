#!/bin/bash
# 不需要 GPU、不需要飞牛：检查认证代理（Basic Auth、/v1 的 API Key——Strata 自己的那一个、转发、流式响应、WebSocket 升级、Origin 改写、HTTPS）和密码的保存。
# 用法： packaging/fnos/tests/test_proxy.sh      （需要 node 24 和 curl）
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${HERE}/../fnos/app/bin"
T="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; rm -rf "${T}"' EXIT
UP=$((20000 + RANDOM % 10000)); PX=$((UP + 1))
fails=0
ok()   { echo "ok   $*"; }
bad()  { echo "FAIL $*"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# 假的 Strata 宿主：回显收到的 Host / Origin / Authorization，带 /stream（分块）和 /redir。
cat > "${T}/up.mjs" <<JS
import http from 'node:http';
const s = http.createServer((q, r) => {
  if (q.url === '/stream') { r.writeHead(200, {'content-type': 'text/event-stream'}); let n = 0; const t = setInterval(() => { r.write('data: ' + (++n) + '\n\n'); if (n === 3) { clearInterval(t); r.end(); } }, 100); return; }
  if (q.url === '/redir') { r.writeHead(302, {location: 'http://127.0.0.1:${UP}/landed'}); return r.end(); }
  let body = ''; q.on('data', d => body += d); q.on('end', () => { r.writeHead(200, {'content-type': 'application/json'}); r.end(JSON.stringify({host: q.headers.host, origin: q.headers.origin ?? null, auth: q.headers.authorization ?? null, method: q.method, body})); });
});
s.on('upgrade', (q, sock) => { sock.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\nHELLO-WS'); sock.end(); });
s.listen(${UP}, '127.0.0.1');
JS
node "${T}/up.mjs" & 
printf 's3cret-pass\n' | node "${BIN}/set-password.mjs" admin "${T}/auth.json"
check "password file is 0600 and has no plaintext" '[ "$(stat -c %a "${T}/auth.json")" = 600 ] && ! grep -q s3cret-pass "${T}/auth.json"'
echo '{"serving":{"apiKey":null}}' > "${T}/state.json"
PROXY_PORT=${PX} PROXY_UPSTREAM_PORT=${UP} PROXY_AUTH_FILE="${T}/auth.json" PROXY_HOST_STATE="${T}/state.json" \
    node "${BIN}/proxy.mjs" > "${T}/proxy.log" 2>&1 &
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:${PX}/" && break; sleep 0.1; done

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
check "no credentials -> 401"             '[ "$(code http://127.0.0.1:${PX}/)" = 401 ]'
check "wrong password -> 401"             '[ "$(code -u admin:nope http://127.0.0.1:${PX}/)" = 401 ]'
check "wrong user -> 401"                 '[ "$(code -u root:s3cret-pass http://127.0.0.1:${PX}/)" = 401 ]'
check "right credentials -> 200"          '[ "$(code -u admin:s3cret-pass http://127.0.0.1:${PX}/)" = 200 ]'
R="$(curl -s -u admin:s3cret-pass -H "Origin: http://nas.lan:${PX}" -X POST -d 'x=1' "http://127.0.0.1:${PX}/api/x")"
check "Host is rewritten to the upstream" 'echo "${R}" | grep -q "\"host\":\"127.0.0.1:${UP}\""'
check "Origin is rewritten"               'echo "${R}" | grep -q "\"origin\":\"http://127.0.0.1:${UP}\""'
check "Authorization is not forwarded"    'echo "${R}" | grep -q "\"auth\":null"'
check "request body is forwarded"         'echo "${R}" | grep -q "\"body\":\"x=1\""'
# ---- /v1 的 API Key：只有 Strata 自己的那一个（state.json 的 serving.apiKey，网页“API 服务 → API 密钥”）---------------
K=sk-strata-host-secret-0123
check "no Strata key yet: a key on /v1 is refused (never open)" '[ "$(curl -s -o "${T}/w" -w "%{http_code}" -H "Authorization: Bearer ${K}" http://127.0.0.1:${PX}/v1/models)" = 401 ] && grep -q "No API key is set in Strata" "${T}/w"'
check "no Strata key yet: Basic Auth still reaches /v1, nothing forwarded" 'curl -s -u admin:s3cret-pass http://127.0.0.1:${PX}/v1/models | grep -q "\"auth\":null"'
sleep 0.05; echo '{"serving":{"apiKey":"'"${K}"'"}}' > "${T}/state.json"
check "Strata key set (no restart): Bearer on /v1 -> 200"       '[ "$(code -H "Authorization: Bearer ${K}" http://127.0.0.1:${PX}/v1/models)" = 200 ]'
check "Strata key: x-api-key on /v1 -> 200"                     '[ "$(code -H "x-api-key: ${K}" -X POST -d "{}" http://127.0.0.1:${PX}/v1/messages)" = 200 ]'
check "Strata key: the host gets its key as Bearer, no x-api-key" 'R="$(curl -s -H "x-api-key: ${K}" http://127.0.0.1:${PX}/v1/models)"; echo "$R" | grep -q "\"auth\":\"Bearer ${K}\""'
check "Strata key: Basic Auth on /v1 -> host gets the key"      'curl -s -u admin:s3cret-pass http://127.0.0.1:${PX}/v1/models | grep -q "\"auth\":\"Bearer ${K}\""'
check "Strata key: other paths -> no key forwarded"             'curl -s -u admin:s3cret-pass http://127.0.0.1:${PX}/api/x | grep -q "\"auth\":null"'
check "wrong key -> 401 JSON, no login prompt" '[ "$(curl -s -o "${T}/w" -w "%{http_code}" -H "Authorization: Bearer nope-nope-nope-nope" http://127.0.0.1:${PX}/v1/models)" = 401 ] && grep -q authentication_error "${T}/w" && ! curl -sI -H "Authorization: Bearer nope" http://127.0.0.1:${PX}/v1/models | grep -qi www-authenticate'
check "the key outside /v1 -> 401"             '[ "$(code -H "Authorization: Bearer ${K}" http://127.0.0.1:${PX}/api/hardware)" = 401 ]'
check "/v1x is not an API path"                '[ "$(code -H "Authorization: Bearer ${K}" http://127.0.0.1:${PX}/v1x)" = 401 ]'
check "Basic Auth still works on /v1"          '[ "$(code -u admin:s3cret-pass http://127.0.0.1:${PX}/v1/models)" = 200 ]'
sleep 0.05; echo '{"serving":{"apiKey":"sk-strata-another-key-99"}}' > "${T}/state.json"
check "key changed in Strata (no restart): the old one is refused" '[ "$(code -H "Authorization: Bearer ${K}" http://127.0.0.1:${PX}/v1/models)" = 401 ]'
sleep 0.05; echo '{"serving":{"apiKey":"'"${K}"'"}}' > "${T}/state.json"
S="$(curl -sN -u admin:s3cret-pass "http://127.0.0.1:${PX}/stream")"
check "streamed response arrives whole"   '[ "$(echo "${S}" | grep -c "^data:")" = 3 ]'
L="$(curl -s -D - -o /dev/null -u admin:s3cret-pass "http://127.0.0.1:${PX}/redir" | tr -d "\r" | sed -n "s/^[Ll]ocation: //p")"
check "redirect points at the public address" '[ "${L}" = "http://127.0.0.1:${PX}/landed" ]'
W="$(printf 'GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nAuthorization: Basic %s\r\n\r\n' "$(printf 'admin:s3cret-pass' | base64)" | timeout 3 node -e '
const s=require("net").connect(+process.argv[1],"127.0.0.1");let o="";s.on("data",d=>o+=d);s.on("close",()=>{console.log(o);process.exit()});process.stdin.pipe(s,{end:false});' "${PX}")"
check "WebSocket upgrade passes through"  'echo "${W}" | grep -q "HELLO-WS"'
W2="$(printf 'GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n' | timeout 8 node -e '
const s=require("net").connect(+process.argv[1],"127.0.0.1");let o="";s.on("data",d=>o+=d);s.on("close",()=>{console.log(o);process.exit()});process.stdin.pipe(s,{end:false});' "${PX}")"
check "WebSocket without credentials -> 401" 'echo "${W2}" | grep -q "401"'
# ---- HTTPS（PROXY_TLS=on）：同一个端口两种协议 ------------------------------------------------
PS=$((PX + 1)); TLSD="${T}/tls"; USERD="${T}/usertls"
PROXY_PORT=${PS} PROXY_UPSTREAM_PORT=${UP} PROXY_AUTH_FILE="${T}/auth.json" PROXY_HOST_STATE="${T}/state.json" \
    PROXY_TLS=on PROXY_TLS_DIR="${TLSD}" PROXY_TLS_USER_DIR="${USERD}" node "${BIN}/proxy.mjs" > "${T}/proxy-tls.log" 2>&1 &
TLSPID=$!
for _ in $(seq 1 50); do [ -s "${TLSD}/cert.pem" ] && curl -sk -o /dev/null "https://127.0.0.1:${PS}/" && break; sleep 0.1; done
check "a self-signed certificate is made (0600 key)"  '[ -s "${TLSD}/cert.pem" ] && [ "$(stat -c %a "${TLSD}/key.pem")" = 600 ]'
check "HTTPS, certificate checked as CA -> 200"       '[ "$(code --cacert "${TLSD}/cert.pem" -u admin:s3cret-pass https://127.0.0.1:${PS}/)" = 200 ]'
check "HTTPS without credentials -> 401"              '[ "$(code --cacert "${TLSD}/cert.pem" https://127.0.0.1:${PS}/)" = 401 ]'
check "HTTP page -> 308 to https on the same port"    '[ "$(curl -s -o /dev/null -w "%{http_code} %{redirect_url}" http://127.0.0.1:${PS}/x?y=1)" = "308 https://127.0.0.1:${PS}/x?y=1" ]'
check "HTTP /v1 with the API key is not redirected"   '[ "$(code -H "Authorization: Bearer ${K}" http://127.0.0.1:${PS}/v1/models)" = 200 ]'
check "HTTPS /v1 with the API key -> 200"             '[ "$(code --cacert "${TLSD}/cert.pem" -H "x-api-key: ${K}" https://127.0.0.1:${PS}/v1/models)" = 200 ]'
check "HTTPS stream arrives whole"                    '[ "$(curl -sN --cacert "${TLSD}/cert.pem" -u admin:s3cret-pass https://127.0.0.1:${PS}/stream | grep -c "^data:")" = 3 ]'
WS="$(node -e '
const tls=require("tls"),fs=require("fs");
const s=tls.connect({port:+process.argv[1],host:"127.0.0.1",ca:fs.readFileSync(process.argv[2]),servername:"localhost"},()=>{
  s.write("GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nAuthorization: Basic "+Buffer.from("admin:s3cret-pass").toString("base64")+"\r\n\r\n");});
let o="";s.on("data",d=>o+=d);s.on("close",()=>{console.log(o);process.exit()});setTimeout(()=>{console.log(o);process.exit()},3000);' "${PS}" "${TLSD}/cert.pem")"
check "WebSocket upgrade over HTTPS"                  'echo "${WS}" | grep -q HELLO-WS'
FP1="$(openssl x509 -in "${TLSD}/cert.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
kill ${TLSPID} 2>/dev/null; wait ${TLSPID} 2>/dev/null
# 用户自己的证书优先
mkdir -p "${USERD}" && node -e '
import("'"${BIN}"'/tls-cert.mjs").then(({selfSigned})=>{const {key,cert}=selfSigned({commonName:"user-cert",hosts:["localhost"],ips:["127.0.0.1"]});
require("fs").writeFileSync(process.argv[1]+"/cert.pem",cert);require("fs").writeFileSync(process.argv[1]+"/key.pem",key);});' "${USERD}"
PROXY_PORT=${PS} PROXY_UPSTREAM_PORT=${UP} PROXY_AUTH_FILE="${T}/auth.json" PROXY_TLS=on PROXY_TLS_DIR="${TLSD}" PROXY_TLS_USER_DIR="${USERD}" \
    node "${BIN}/proxy.mjs" > "${T}/proxy-tls2.log" 2>&1 &
TLSPID=$!
for _ in $(seq 1 50); do curl -sk -o /dev/null "https://127.0.0.1:${PS}/" && break; sleep 0.1; done
check "your own cert.pem / key.pem are used"          '[ "$(code --cacert "${USERD}/cert.pem" -u admin:s3cret-pass https://127.0.0.1:${PS}/)" = 200 ] && grep -q "your certificate" "${T}/proxy-tls2.log"'
kill ${TLSPID} 2>/dev/null; wait ${TLSPID} 2>/dev/null
# 证书和私钥不配对：不用它，退回只有 HTTP，日志里说明
cp "${TLSD}/key.pem" "${USERD}/key.pem"
PROXY_PORT=${PS} PROXY_UPSTREAM_PORT=${UP} PROXY_AUTH_FILE="${T}/auth.json" PROXY_TLS=on PROXY_TLS_DIR="${TLSD}" PROXY_TLS_USER_DIR="${USERD}" \
    node "${BIN}/proxy.mjs" > "${T}/proxy-tls3.log" 2>&1 &
TLSPID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:${PS}/" && break; sleep 0.1; done
check "a key that does not match -> plain HTTP, said in the log" '[ "$(code -u admin:s3cret-pass http://127.0.0.1:${PS}/)" = 200 ] && grep -q "does not belong" "${T}/proxy-tls3.log"'
kill ${TLSPID} 2>/dev/null; wait ${TLSPID} 2>/dev/null

kill %1 2>/dev/null; sleep 0.3
check "upstream down -> 502 with the starting page" '[ "$(code -u admin:s3cret-pass http://127.0.0.1:${PX}/)" = 502 ]'

echo; [ "${fails}" = 0 ] && echo "all passed" || echo "${fails} failed"
exit "${fails}"
