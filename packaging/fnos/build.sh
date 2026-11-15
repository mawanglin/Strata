#!/bin/bash
# 构建 Strata 的飞牛 fnOS 原生 fpk（x86_64）。两个变体：
#
#   packaging/fnos/build.sh                                   # NVIDIA CUDA 版 -> dist/strata_<版本>_amd64.fpk
#   VARIANT=gfx906 ENGINE_COMPONENT=<引擎组件目录> packaging/fnos/build.sh
#                                                             # AMD gfx906 版 -> dist/strata-gfx906_<版本>_amd64.fpk
#
# gfx906 的引擎上游没有现成包，用 packaging/fnos/gfx906/build-engine-docker.sh 编出来，ENGINE_COMPONENT 指向它的
# out/components/engine/<版本>-linux-x86_64-hip-gfx906/。
#
# 需要：Node 24.12+（构建界面用）、python3、curl、tar、fnpack（在 PATH 或 ~/.local/bin，或用 FNPACK=… 指定）、网络。
# 运行时全部来自上游 release（逐个核对 SHA-256）：Terminal 包（自带 Python 和依赖）、CUDA13 引擎包
# （自带 cudart / cuBLAS）、Node 运行时；界面从本仓库的 release 标签源码构建。
# CUDA 版包里没有的只有 NVIDIA 驱动的用户态库 libcuda（必须和宿主机内核模块同版本，运行时从宿主机链接）；
# gfx906 版连 ROCm 运行库和 rocBLAS 内核都在引擎组件里，只需要内核的 amdgpu 驱动。
#
# 环境变量：
#   UPSTREAM_TAG   上游 release 标签（默认 v0.2.13）；界面源码取这个标签的 apps/host
#   CONTROL_ASSET / ENGINE_ASSET / NODE_VERSION  见下面的默认值，换版本时连同校验值一起改
#   BUILD_NUMBER   版本号里的本地小版本（默认 1，形如 0.2.13-cob.1）
#   VARIANT        cuda（默认）| gfx906
#   ENGINE_COMPONENT  gfx906 必填：编好的引擎组件目录
#   WORK_DIR       工作目录（默认 packaging/fnos/build/<变体>/）；下载缓存在 packaging/fnos/build/cache/（CACHE_DIR）

set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:-Niko1221/Strata}"
UPSTREAM_TAG="${UPSTREAM_TAG:-v0.2.13}"
CONTROL_ASSET="${CONTROL_ASSET:-strata-control-0.1.59.1-linux-x86_64.tar.gz}"
ENGINE_ASSET="${ENGINE_ASSET:-strata-engine-0.1.59-linux-x86_64-cuda-cuda13.tar.gz}"
# DeepSeek V4.1 的引擎是单独的组件（只有 CUDA 版；上游的 gfx906 构建明确不含它）。原样放进包里，启动时放到
# <install>/engine-dsv41/，用户选 DeepSeek 时 Strata 自己核对上游签名后安装，不用联网下载。
DSV41_ASSET="${DSV41_ASSET:-strata-dsv41-0.1.59-linux-x86_64-cuda-cuda13.tar.gz}"
NODE_VERSION="${NODE_VERSION:-24.12.0}"
# nodejs.org 的 SHASUMS256.txt 里 v24.12.0 linux-x64 的值（和 apps/desktop/scripts/fetch-node.sh 记录的一致）。
NODE_SHA256="${NODE_SHA256:-6159227e0af7d7c3c6bb2fa900452b04a6cb8841a702a79acc613209d70b04d0}"

VARIANT="${VARIANT:-cuda}"
case "${VARIANT}" in
    cuda)
        APPNAME=strata; DISPLAY_NAME="Strata"; SHARE=Strata; DEFAULT_PORT=47831
        OTHER_APP=strata-gfx906; OTHER_SHARE=Strata-gfx906; OTHER_DISPLAY="Strata (gfx906)"
        GPU_VENDOR=nvidia; ENGINE_BACKEND=cuda; ENGINE_NOTE="CUDA 13，RTX 20/30/40/50"
        DESC_BASE="原生运行的 Strata（不依赖 Docker）：本地大模型推理引擎和网页界面，使用 NVIDIA CUDA。Node、Python、引擎和 CUDA 运行库都在包里，只需要宿主机装好 NVIDIA 驱动。" ;;
    gfx906)
        APPNAME=strata-gfx906; DISPLAY_NAME="Strata (gfx906)"; SHARE=Strata-gfx906; DEFAULT_PORT=47832
        OTHER_APP=strata; OTHER_SHARE=Strata; OTHER_DISPLAY="Strata"
        GPU_VENDOR=amd; ENGINE_BACKEND=hip; ENGINE_NOTE="AMD gfx906：MI50 / MI60 / Radeon VII，ROCm 运行库在包里"
        ENGINE_COMPONENT="$(cd "${ENGINE_COMPONENT:?VARIANT=gfx906 needs ENGINE_COMPONENT=<engine component folder>}" && pwd)"
        DESC_BASE="原生运行的 Strata（不依赖 Docker）：本地大模型推理引擎和网页界面，使用 AMD gfx906 显卡（MI50 / MI60 / Radeon VII）。Node、Python、引擎、ROCm 运行库和 rocBLAS 内核都在包里，只需要内核自带的 amdgpu 驱动。" ;;
    *) echo "VARIANT must be cuda or gfx906" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
WORK_DIR="${WORK_DIR:-${HERE}/build/${VARIANT}}"
CACHE="${CACHE_DIR:-${HERE}/build/cache}"
DIST_DIR="${REPO}/dist"
PKG="${WORK_DIR}/pkg"
FNPACK="${FNPACK:-$(command -v fnpack || echo "${HOME}/.local/bin/fnpack")}"
RELEASE_URL="https://github.com/${UPSTREAM_REPO}/releases/download/${UPSTREAM_TAG}"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ -x "${FNPACK}" ] || die "fnpack not found (put it in PATH or set FNPACK=)"
command -v node >/dev/null || die "node is required"
node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>24||(a===24&&b>=12)?0:1)' || die "Node 24.12+ is required to build the UI"

mkdir -p "${CACHE}" "${DIST_DIR}"
rm -rf "${PKG}" "${WORK_DIR}/stage"
mkdir -p "${PKG}" "${WORK_DIR}/stage"

fetch() {  # fetch URL DEST SHA256
    local url="$1" dest="$2" sha="$3"
    if [ -f "${dest}" ] && echo "${sha}  ${dest}" | sha256sum -c --status; then return 0; fi
    log "downloading $(basename "${dest}")"
    curl -fL --retry 3 --connect-timeout 20 -o "${dest}.part" "${url}"
    echo "${sha}  ${dest}.part" | sha256sum -c --status || { rm -f "${dest}.part"; die "SHA-256 mismatch: $(basename "${dest}")"; }
    mv "${dest}.part" "${dest}"
}

# ---- 上游 release 的校验值 -----------------------------------------------------
log "checksums of the ${UPSTREAM_TAG} release"
curl -fsSL --retry 3 -o "${CACHE}/SHA256SUMS-${UPSTREAM_TAG}.txt" "${RELEASE_URL}/SHA256SUMS.txt"
sum_of() { awk -v f="$1" '$2==f {print $1}' "${CACHE}/SHA256SUMS-${UPSTREAM_TAG}.txt"; }
CONTROL_SHA="$(sum_of "${CONTROL_ASSET}")"
[ -n "${CONTROL_SHA}" ] || die "${CONTROL_ASSET} is not listed in SHA256SUMS.txt of ${UPSTREAM_TAG}"
fetch "${RELEASE_URL}/${CONTROL_ASSET}" "${CACHE}/${CONTROL_ASSET}" "${CONTROL_SHA}"
if [ "${VARIANT}" = cuda ]; then
    ENGINE_SHA="$(sum_of "${ENGINE_ASSET}")"
    [ -n "${ENGINE_SHA}" ] || die "${ENGINE_ASSET} is not listed in SHA256SUMS.txt of ${UPSTREAM_TAG}"
    fetch "${RELEASE_URL}/${ENGINE_ASSET}" "${CACHE}/${ENGINE_ASSET}" "${ENGINE_SHA}"
    DSV41_SHA="$(sum_of "${DSV41_ASSET}")"
    [ -n "${DSV41_SHA}" ] || die "${DSV41_ASSET} is not listed in SHA256SUMS.txt of ${UPSTREAM_TAG}"
    fetch "${RELEASE_URL}/${DSV41_ASSET}" "${CACHE}/${DSV41_ASSET}" "${DSV41_SHA}"
fi
NODE_TGZ="node-v${NODE_VERSION}-linux-x64.tar.gz"
fetch "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TGZ}" "${CACHE}/${NODE_TGZ}" "${NODE_SHA256}"

APP="${PKG}/app"
mkdir -p "${APP}"

# ---- Node ------------------------------------------------------------------------
log "Node ${NODE_VERSION}"
mkdir -p "${APP}/node"
tar -xzf "${CACHE}/${NODE_TGZ}" -C "${APP}/node" --strip-components=1 --exclude='*/include' --exclude='*/share' --exclude='*/lib/node_modules' --exclude='*/CHANGELOG.md' --exclude='*/README.md'

# npm / npx / corepack 的入口是指向 lib/node_modules 的符号链接，上面已经裁掉了，运行时也用不到。
rm -f "${APP}/node/bin/npm" "${APP}/node/bin/npx" "${APP}/node/bin/corepack"

# ---- Control（自带 Python 和依赖）-------------------------------------------------
log "Control (Python + strata_control)"
mkdir -p "${APP}/control"
tar -xzf "${CACHE}/${CONTROL_ASSET}" -C "${APP}/control"   # 这个包没有顶层目录
[ -x "${APP}/control/python/bin/python3" ] && [ -f "${APP}/control/strata.py" ] || die "unexpected layout of ${CONTROL_ASSET}"
PY="${APP}/control/python/bin/python3"

# 本包对 Control 的补丁（patches/control）：打在上游 release 的 Terminal 包上，打不上就失败。
for p in "${HERE}"/patches/control/*.patch; do
    [ -e "${p}" ] || continue
    ( cd "${APP}/control" && patch -p1 --no-backup-if-mismatch < "${p}" ) || die "control patch does not apply: $(basename "${p}")"
done

# 预先编译 .pyc（运行时设了 PYTHONDONTWRITEBYTECODE，且安装目录对应用用户只读）。
"${PY}" -I -m compileall -q "${APP}/control/strata_control" "${APP}/control/serve" "${APP}/control/strata_cli" "${APP}/control/strata.py" >/dev/null 2>&1 || true

# 固定版本的 llama.cpp（模型处理工具要用）：和 Dockerfile 一样取回并只留 gguf-py 与 ggml/CMakeLists.txt。
log "llama.cpp seed"
SEED="${APP}/seed"
( cd "${APP}/control" && STRATA_CONTROL_INSTALL=1 STRATA_INSTALL_DIR="${SEED}" PYTHONNOUSERSITE=1 "${PY}" -I -c "import sys; sys.path.insert(0, '.'); import setup; print(setup.get_llama_cpp())" )
rm -rf "${SEED}"/third_party/*.zip*
( cd "${SEED}/third_party/llama.cpp" \
    && find . -mindepth 1 -maxdepth 1 ! -name gguf-py ! -name ggml ! -name 'LICENSE*' -exec rm -rf {} + \
    && find ggml -mindepth 1 -depth ! -type d ! -name CMakeLists.txt -delete && find ggml -mindepth 1 -type d -empty -delete )
du -sh "${SEED}" | sed 's/^/    seed: /'

# ---- 引擎 ------------------------------------------------------------------------
# 宿主按 <引擎目录>/<包文件夹>/engine-component.json 找；文件夹名和 package_engine.py 的一致。
if [ "${VARIANT}" = cuda ]; then
    log "CUDA engine (upstream release)"
    ENGINE_TMP="${WORK_DIR}/stage/engine"
    mkdir -p "${ENGINE_TMP}"
    tar -xzf "${CACHE}/${ENGINE_ASSET}" -C "${ENGINE_TMP}"
    ENGINE_VERSION="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "${ENGINE_TMP}/engine-component.json" | head -1)"
    ENGINE_DIR="${APP}/engine-bundle/${ENGINE_VERSION}-linux-x86_64-cuda-cuda13"
    mkdir -p "$(dirname "${ENGINE_DIR}")"
    mv "${ENGINE_TMP}" "${ENGINE_DIR}"
else
    log "gfx906 engine (${ENGINE_COMPONENT})"
    [ -f "${ENGINE_COMPONENT}/engine-component.json" ] || die "no engine-component.json in ${ENGINE_COMPONENT}"
    grep -q '"backend": *"hip"' "${ENGINE_COMPONENT}/engine-component.json" && grep -q '"gfx906"' "${ENGINE_COMPONENT}/engine-component.json" \
        || die "${ENGINE_COMPONENT} is not a HIP gfx906 engine component"
    ENGINE_VERSION="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "${ENGINE_COMPONENT}/engine-component.json" | head -1)"
    ENGINE_DIR="${APP}/engine-bundle/$(basename "${ENGINE_COMPONENT}")"
    mkdir -p "$(dirname "${ENGINE_DIR}")"
    cp -a "${ENGINE_COMPONENT}" "${ENGINE_DIR}"
    "${PY}" -I "${REPO}/packaging/package_engine.py" --verify "${ENGINE_DIR}" >/dev/null || die "the gfx906 engine component fails its own hash check"
fi
[ -f "${ENGINE_DIR}/strata" ] || die "engine package has no strata binary"
if [ "${VARIANT}" = cuda ]; then
    log "DeepSeek engine package (as released, installed by Strata on first use)"
    mkdir -p "${APP}/dsv41"
    cp "${CACHE}/${DSV41_ASSET}" "${APP}/dsv41/"
fi

# ---- 宿主（Node）和界面 -------------------------------------------------------------
log "App Host + UI from ${UPSTREAM_TAG}"
HOSTSRC="${WORK_DIR}/stage/hostsrc"
mkdir -p "${HOSTSRC}"
( cd "${REPO}" && git archive "${UPSTREAM_TAG}" apps/host ) | tar -x -C "${HOSTSRC}"
# 本包的补丁（packaging/fnos/patches）：对上游源码打上才构建；打不上就失败，换上游版本时要重新做补丁。
for p in "${HERE}"/patches/*.patch; do
    [ -e "${p}" ] || continue
    ( cd "${HOSTSRC}/apps/host" && patch -p1 --no-backup-if-mismatch < "${p}" ) || die "patch does not apply: $(basename "${p}")"
done
( cd "${HOSTSRC}/apps/host" && npm ci --no-audit --no-fund --loglevel=error && npm run build --silent )
mkdir -p "${APP}/host"
cp -r "${HOSTSRC}/apps/host/server" "${HOSTSRC}/apps/host/dist" "${HOSTSRC}/apps/host/public" "${HOSTSRC}/apps/host/package.json" "${APP}/host/"
find "${APP}/host/dist" -name '*.map' -delete   # source map 对运行没用，体积不小

# 飞牛安装时以 root 遍历应用目录并读 ACL：悬空的、绝对路径的、指到应用目录外面的符号链接会让安装失败
# （"set app dir permissions failed … acl_get_file failed"，错误码 10234）。
bad="$(find "${APP}" -xtype l; find "${APP}" -type l -lname '/*'; \
    find "${APP}" -type l | while read -r l; do case "$(readlink -m "$l")" in "${APP}"/*) ;; *) echo "$l";; esac; done)"
[ -z "${bad}" ] || die "symlinks fnOS cannot install (dangling, absolute or pointing outside the app):
${bad}"

# ---- 骨架 --------------------------------------------------------------------------
log "assembling the fnpack project"
cp -a "${HERE}/fnos/." "${PKG}/"
# cp -a 会把 app/ 里的骨架文件合并进已有的 app/，不会覆盖上面放进去的东西
mkdir -p "${PKG}/app/ui/images"
ICON_SRC="${REPO}/apps/host/public/icon-512.png"
# 两个变体的图标不一样：中间那条横杠换成厂商的标志色，下方写厂商名（tools/make_icon.py），飞牛桌面上一眼能分清。
"${PY}" -I "${HERE}/tools/make_icon.py" "${ICON_SRC}" "${VARIANT}" "${PKG}/ICON.PNG" "${PKG}/ICON_256.PNG" \
    "64:${PKG}/app/ui/images/icon_64.png" "256:${PKG}/app/ui/images/icon_256.png"
chmod +x "${PKG}"/cmd/* "${PKG}"/app/bin/launch.sh "${PKG}"/app/bin/strata
# 这个包是哪个变体：launch.sh 读它决定显卡厂商、引擎后端，以及要不要链接宿主机的 NVIDIA 驱动库。
cat > "${PKG}/app/bin/variant.env" <<VENV
STRATA_FPK_VARIANT=${VARIANT}
STRATA_FPK_GPU_VENDOR=${GPU_VENDOR}
STRATA_FPK_ENGINE_BACKEND=${ENGINE_BACKEND}
STRATA_FPK_OTHER_APP=${OTHER_APP}
STRATA_FPK_OTHER_SHARE=${OTHER_SHARE}
STRATA_FPK_APPNAME=${APPNAME}
STRATA_FPK_SHARE=${SHARE}
VENV

NODE_FULL="$("${APP}/node/bin/node" --version)"
APP_VERSION="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "${APP}/host/package.json" | head -1)"
DESC="${DESC_BASE}Strata ${APP_VERSION}，引擎 ${ENGINE_VERSION}（${ENGINE_NOTE}），Node ${NODE_FULL}。"
sed_escape() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }
for f in manifest app/ui/config config/privilege config/resource wizard/install wizard/config wizard/uninstall; do
    sed -i \
        -e "s|@APPNAME@|$(sed_escape "${APPNAME}")|g" \
        -e "s|@DISPLAY_NAME@|$(sed_escape "${DISPLAY_NAME}")|g" \
        -e "s|@SHARE@|$(sed_escape "${SHARE}")|g" \
        -e "s|@PORT@|$(sed_escape "${DEFAULT_PORT}")|g" \
        -e "s|@DESC@|$(sed_escape "${DESC}")|g" \
        -e "s|@OTHER_SHARE@|$(sed_escape "${OTHER_SHARE}")|g" \
        -e "s|@OTHER_DISPLAY@|$(sed_escape "${OTHER_DISPLAY}")|g" \
        "${PKG}/${f}"
done
# fnos/manifest 里是上游版本；构建加上本地小版本，每次重建都是一次升级。
BASE_VERSION="$(sed -n 's/^version *= *//p' "${PKG}/manifest")"
[ "${BASE_VERSION}" = "${APP_VERSION}" ] || log "NOTE: manifest base version ${BASE_VERSION} differs from the host's ${APP_VERSION}"
VERSION="${BASE_VERSION}-cob.${BUILD_NUMBER:-1}"
sed -i "s/^version .*/version               = ${VERSION}/" "${PKG}/manifest"
if grep -rq "@[A-Z_]*@" "${PKG}/manifest" "${PKG}/app/ui" "${PKG}/config" "${PKG}/wizard"; then
    die "unreplaced placeholder left in the package"
fi

# ---- fnpack ---------------------------------------------------------------------------
log "fnpack build ($(du -sh "${PKG}" | cut -f1) staged)"
(cd "${PKG}" && "${FNPACK}" build)
FPK="$(ls "${PKG}"/*.fpk | head -n 1)"
OUT="${DIST_DIR}/${APPNAME}_${VERSION}_amd64.fpk"

# 网页端口的防火墙服务文件（config/resource 的 port-config）：fnpack 不收包根目录里多出来的文件，
# 所以加进做好的 fpk；manifest 的校验值只覆盖 app.tgz。
FPK_ROOT="${PKG}/.fpk-root"
rm -rf "${FPK_ROOT}" && mkdir -p "${FPK_ROOT}"
tar -xzf "${FPK}" -C "${FPK_ROOT}"
cat > "${FPK_ROOT}/${APPNAME}.sc" <<SC
[${APPNAME}]
title="${DISPLAY_NAME}"
desc="${DISPLAY_NAME} web port"
port_forward="no"
dst.ports="${DEFAULT_PORT}/tcp"
SC
(cd "${FPK_ROOT}" && tar -czf "${OUT}" $(ls -A))   # 成员名和 fnpack 的一致
rm -rf "${FPK_ROOT}" "${FPK}"
log "done: ${OUT} ($(stat -c %s "${OUT}" | numfmt --to=iec))"
