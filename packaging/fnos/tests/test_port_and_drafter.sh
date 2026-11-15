#!/bin/bash
# 不需要 GPU / 飞牛：检查 patches/0004-engine-port-base.patch（两个 Strata 的引擎端口各用一段）和
# patches/control/0002-dflash2-hf-endpoint.patch（DFlash2 drafter 按 HF_ENDPOINT 换下载源）。
# 用法： packaging/fnos/tests/test_port_and_drafter.sh   （需要 git、patch、node 24、python3；在本仓库里运行）
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
TAG="${UPSTREAM_TAG:-v0.2.13}"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
git -C "${REPO}" archive "${TAG}" apps/host/server strata_control | tar -x -C "${T}"
for p in "${HERE}"/../patches/*.patch; do (cd "${T}/apps/host" && patch -p1 -s < "${p}"); done
(cd "${T}" && patch -p1 -s < "${HERE}/../patches/control/0002-dflash2-hf-endpoint.patch")
fails=0
ok() { if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

# freePort 从 native-control.mjs 里原样取出来跑（它在 createNativeControl 的闭包里）。
cat > "${T}/port.mjs" <<JS
import {readFileSync} from 'node:fs';
import {createServer} from 'node:net';
const src=readFileSync('${T}/apps/host/server/native-control.mjs','utf8');
const m=src.match(/ const ENGINE_PORT_BASE=[^\n]*\n async function freePort\(requested\)\{[^\n]*\n/);
if(!m){console.log('no freePort');process.exit(2);}
const instances=new Map();
const freePort=new Function('createServer','instances','return (async()=>{'+m[0]+' return freePort;})()');
console.log(await (await freePort(createServer,instances))(undefined));
JS
p=$(node "${T}/port.mjs"); ok "unset: the first engine port is 18500 (upstream) [${p}]" $([ "${p}" = 18500 ] && echo 0 || echo 1)
p=$(STRATA_FPK_ENGINE_PORT_BASE=18600 node "${T}/port.mjs"); ok "STRATA_FPK_ENGINE_PORT_BASE=18600: 18600 [${p}]" $([ "${p}" = 18600 ] && echo 0 || echo 1)
for v in cuda gfx906; do
    want=18500; [ "${v}" = gfx906 ] && want=18600
    got=$(STRATA_FPK_VARIANT=${v} bash -c "$(grep -m1 'STRATA_FPK_ENGINE_PORT_BASE=18600' "${HERE}/../fnos/app/bin/launch.sh"); echo \${STRATA_FPK_ENGINE_PORT_BASE}")
    ok "launch.sh, ${v}: ${want} [${got}]" $([ "${got}" = "${want}" ] && echo 0 || echo 1)
done

url() { (cd "${T}" && env -u HF_ENDPOINT ${1:+HF_ENDPOINT="$1"} python3 -I -c 'import sys; sys.path.insert(0, "."); from strata_control import drafting; print(drafting.BASE_URL)' 2>/dev/null); }
u=$(url ""); ok "no HF_ENDPOINT: huggingface.co (upstream)" $([[ "${u}" == https://huggingface.co/incoai/Qwen3.8-Flash-Next-DFlash2/resolve/* ]] && echo 0 || echo 1)
u=$(url "https://hf-mirror.com/"); ok "HF_ENDPOINT=https://hf-mirror.com/: the mirror, no double slash" $([[ "${u}" == https://hf-mirror.com/incoai/Qwen3.8-Flash-Next-DFlash2/resolve/* ]] && echo 0 || echo 1)
u=$(url "  "); ok "blank HF_ENDPOINT: huggingface.co" $([[ "${u}" == https://huggingface.co/* ]] && echo 0 || echo 1)

[ "${fails}" = 0 ] && echo "all passed" || { echo "${fails} failed"; exit 1; }
