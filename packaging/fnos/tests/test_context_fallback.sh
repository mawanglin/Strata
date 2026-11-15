#!/bin/bash
# 不需要 GPU / 飞牛：检查 patches/0003-q36-context-fallback.patch 的判断（只看最后一次启动的日志、128K -> 64K、16K 下限、开关关闭时不变）。
# 用法： packaging/fnos/tests/test_context_fallback.sh   （需要 git、patch、node 24；在本仓库里运行）
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
TAG="${UPSTREAM_TAG:-v0.2.13}"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
git -C "${REPO}" archive "${TAG}" apps/host/server | tar -x -C "${T}"
for p in "${HERE}"/../patches/*.patch; do (cd "${T}/apps/host" && patch -p1 -s < "${p}"); done
cat > "${T}/t.mjs" <<JS
import {q36VramStop, saferStart} from '${T}/apps/host/server/native-resources.mjs';
import {writeFileSync} from 'node:fs';
const L='${T}/q36.log';
let fails=0; const ok=(n,c)=>{console.log((c?'ok   ':'FAIL ')+n); if(!c)fails++;};
writeFileSync(L,'[strata] engine started: a\nstrata-q36: cudaMalloc(&p, n * 4) failed: out of memory (x.cu:1128)\n[strata] engine started: b\nstrata-q36: ready\n');
ok("an older start's OOM does not count", q36VramStop(L)===false);
writeFileSync(L,'[strata] engine started: a\nstrata-q36: ready\n[strata] engine started: b\nstrata-q36: cudaMalloc(&p, n * 4) failed: out of memory (x.cu:1128)\n');
ok("the last start's cudaMalloc OOM counts", !!q36VramStop(L));
writeFileSync(L,"[strata] engine started: b\nstrata-q36: not enough VRAM left for the hybrid experts' buffers and slots (1256 MiB needed, 216 MiB free)\n");
ok('"not enough VRAM" counts', !!q36VramStop(L));
writeFileSync(L,'[strata] engine started: b\nstrata-q36: not enough VRAM for 2 slots at a context of 65536 (1.47 GiB each, 3.10 GiB free): use fewer slots\n');
const two=q36VramStop(L);
ok('a 2-slot stop names count and sizes', two.slots===2&&two.eachGib===1.47&&two.freeGib===3.1);
ok('no log file -> false', q36VramStop('/nonexistent/x.log')===false);
const cfg={log:L,args:['--native','m.gguf','--max-context','131072','--mtp','2']};
const fail='server_exited (exit code 1): EngineDied: the engine exited before it was ready';
process.env.STRATA_FPK_CONTEXT_FALLBACK='1';
ok('2 slots that fail while one fits: no context change (one request at a time is the fix)', saferStart(cfg,{ram_gb:125},{},fail)===null);
writeFileSync(L,'[strata] engine started: b\nstrata-q36: not enough VRAM for 2 slots at a context of 131072 (2.95 GiB each, 1.20 GiB free): use fewer slots\n');
let r0=saferStart(cfg,{ram_gb:125},{},fail);
ok('2 slots where even one does not fit: halve', !!r0&&r0.keepContext===65536);
writeFileSync(L,'[strata] engine started: b\nstrata-q36: cudaMalloc(&p, n * 4) failed: out of memory (x.cu:1128)\n');
let r=saferStart(cfg,{ram_gb:125},{},fail);
ok('128K -> 64K with keepContext, the given config untouched', !!r&&r.keepContext===65536&&r.config.args[3]==='65536'&&cfg.args[3]==='131072');
r=saferStart({...cfg,args:['--max-context','16384']},{ram_gb:125},{},fail);
ok('16K is the floor: no context retry', !r||r.keepContext===undefined);
delete process.env.STRATA_FPK_CONTEXT_FALLBACK;
r=saferStart(cfg,{ram_gb:125},{},fail);
ok('switch off -> upstream behaviour (no keepContext)', !r||r.keepContext===undefined);
const nc=await import('${T}/apps/host/server/native-control.mjs');
ok('patched native-control.mjs loads', typeof nc.createNativeControl==='function');
console.log(fails?fails+' failed':'\nall passed'); process.exit(fails?1:0);
JS
node "${T}/t.mjs"
