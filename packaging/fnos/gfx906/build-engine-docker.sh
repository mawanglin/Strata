#!/bin/bash
# 在任意有 docker 的 x86_64 Linux（比如飞牛本机）上编译 gfx906 引擎组件。
#
#   packaging/fnos/gfx906/build-engine-docker.sh <工作目录>
#
# 工作目录约需 30 GB（ROCm wheel 解开后很大）；venv 和下载会留在里面，第二次构建快很多。
# 产物：<工作目录>/out/components/engine/<版本>-linux-x86_64-hip-gfx906/
#
# 源码：默认用本仓库里上游 release 引擎的那个提交（ENGINE_COMMIT），git archive 到 <工作目录>/src；
# 在没有本仓库的机器上运行时，先把 src.tar 放进工作目录（SRC_TAR=<工作目录>/src.tar）。
# 环境：ENGINE_COMMIT、PKGVER、ROCM_VERSION、IMAGE（默认 ubuntu:22.04）、JOBS、APT_MIRROR、PIP_MIRROR

set -euo pipefail
WORK="$(mkdir -p "${1:?usage: build-engine-docker.sh <work dir>}" && cd "$1" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
# 上游 v0.2.13 release 里 0.1.59 引擎的源码提交（engine BUILD.json 的 "source": "f-0213-rc 712fec6b4297"）
ENGINE_COMMIT="${ENGINE_COMMIT:-712fec6b4297}"
PKGVER="${PKGVER:-0.1.59}"
IMAGE="${IMAGE:-ubuntu:22.04}"
SUDO=""; [ "$(id -u)" = 0 ] || docker info >/dev/null 2>&1 || SUDO="sudo"

rm -rf "${WORK}/src" && mkdir -p "${WORK}/src"
if [ -n "${SRC_TAR:-}" ]; then
    tar -xf "${SRC_TAR}" -C "${WORK}/src"
else
    git -C "${HERE}" archive "${ENGINE_COMMIT}" | tar -x -C "${WORK}/src"
    ENGINE_COMMIT="$(git -C "${HERE}" rev-parse "${ENGINE_COMMIT}")"
fi
# 没有 .git 的源码树：build id 写进 BUILD_ID（CMakeLists.txt 读它）
printf '%s\n' "${ENGINE_COMMIT:0:9}" > "${WORK}/src/BUILD_ID"
[ "${HERE}/build-engine.sh" -ef "${WORK}/build-engine.sh" ] || cp "${HERE}/build-engine.sh" "${WORK}/build-engine.sh"
# 对引擎源码的补丁
if ! [ "${HERE}/patches" -ef "${WORK}/patches" ]; then rm -rf "${WORK}/patches"; cp -r "${HERE}/patches" "${WORK}/patches"; fi

${SUDO} docker run --rm -v "${WORK}:/work" -e PKGVER="${PKGVER}" -e COMMIT="${ENGINE_COMMIT}" \
    ${ROCM_VERSION:+-e ROCM_VERSION="${ROCM_VERSION}"} ${JOBS:+-e JOBS="${JOBS}"} ${APT_MIRROR:+-e APT_MIRROR="${APT_MIRROR}"} ${PIP_MIRROR:+-e PIP_MIRROR="${PIP_MIRROR}"} \
    "${IMAGE}" bash /work/build-engine.sh
# 容器里是 root：把产物交还给调用者
[ -n "${SUDO}" ] && ${SUDO} chown -R "$(id -u):$(id -g)" "${WORK}/out" || true
ls -d "${WORK}"/out/components/engine/*/
