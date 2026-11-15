#!/bin/bash
# 不需要 GPU、不需要飞牛：检查认证代理（Basic Auth、/v1 的 API Key、转发、流式响应、WebSocket 升级、Origin 改写）和密码 / Key 的保存。
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
check "API key shorter than 16 is refused" '! printf "short\n" | node "${BIN}/set-api-key.mjs" "${T}/key.json" 2>/dev/null && [ ! -e "${T}/key.json" ]'
printf 'sk-test_0123456789abcdef\n' | node "${BIN}/set-api-key.mjs" "${T}/key.json"
check "API key file is 0600 and has no plaintext" '[ "$(stat -c %a "${T}/key.json")" = 600 ] && ! grep -q sk-test_0123456789abcdef "${T}/key.json"'
PROXY_PORT=${PX} PROXY_UPSTREAM_PORT=${UP} PROXY_AUTH_FILE="${T}/auth.json" PROXY_API_KEY_FILE="${T}/key.json" node "${BIN}/proxy.mjs" > "${T}/proxy.log" 2>&1 &
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
K=sk-test_0123456789abcdef
check "API: Bearer key on /v1 -> 200"         '[ "$(code -H "Authorization: Bearer ${K}" http://127.0.0.1:${PX}/v1/models)" = 200 ]'
check "API: x-api-key on /v1 -> 200"          '[ "$(code -H "x-api-key: ${K}" -X POST -d "{}" http://127.0.0.1:${PX}/v1/messages)" = 200 ]'
RK="$(curl -s -H "Authorization: Bearer ${K}" -H "x-api-key: ${K}" http://127.0.0.1:${PX}/v1/models)"
check "API: key headers are not forwarded"    'echo "${RK}" | grep -q "\"auth\":null"'
check "API: wrong key -> 401 JSON, no login prompt" '[ "$(curl -s -o "${T}/w" -w "%{http_code}" -H "Authorization: Bearer nope-nope-nope-nope" http://127.0.0.1:${PX}/v1/models)" = 401 ] && grep -q authentication_error "${T}/w" && ! curl -sI -H "Authorization: Bearer nope" http://127.0.0.1:${PX}/v1/models | grep -qi www-authenticate'
check "API: key outside /v1 -> 401"           '[ "$(code -H "Authorization: Bearer ${K}" http://127.0.0.1:${PX}/api/hardware)" = 401 ]'
check "API: /v1x is not an API path"          '[ "$(code -H "Authorization: Bearer ${K}" http://127.0.0.1:${PX}/v1x)" = 401 ]'
check "API: Basic Auth still works on /v1"    '[ "$(code -u admin:s3cret-pass http://127.0.0.1:${PX}/v1/models)" = 200 ]'
node "${BIN}/set-api-key.mjs" "${T}/key.json" --clear
check "API: key access off -> key refused"    '[ "$(code -H "Authorization: Bearer ${K}" http://127.0.0.1:${PX}/v1/models)" = 401 ]'
printf '%s\n' "${K}" | node "${BIN}/set-api-key.mjs" "${T}/key.json"
check "API: key turned on again without restart" '[ "$(code -H "Authorization: Bearer ${K}" http://127.0.0.1:${PX}/v1/models)" = 200 ]'
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
kill %1 2>/dev/null; sleep 0.3
check "upstream down -> 502 with the starting page" '[ "$(code -u admin:s3cret-pass http://127.0.0.1:${PX}/)" = 502 ]'

echo; [ "${fails}" = 0 ] && echo "all passed" || echo "${fails} failed"
exit "${fails}"
