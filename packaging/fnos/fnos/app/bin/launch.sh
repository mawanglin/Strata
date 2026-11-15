#!/bin/bash
# 以应用用户运行（没有沙箱，也不用 Docker）：Strata 宿主（Node）+ 带认证的反向代理。
# 运行时（Node、Python、引擎、GPU 运行库）全部在 fpk 里。
#   CUDA 版：只有 NVIDIA 驱动的用户态库 libcuda.so.1 / libnvidia-ml.so.1 来自宿主机（要和内核模块同一个版本，没法打进包里）。
#   gfx906 版：ROCm 运行库和 rocBLAS 内核都在引擎组件里，只用内核的 amdgpu 驱动（/dev/kfd、/dev/dri）。
#
# 用法： launch.sh                  前台运行
#        launch.sh exec CMD [ARG..] 用和运行时相同的环境跑一条命令（测试和排错用）
# 环境： TRIM_APPDEST、TRIM_PKGVAR（飞牛设置）、TRIM_DATA_SHARE_PATHS（可选）

set -eu

APPDEST="${TRIM_APPDEST:?}"
PKGVAR="${TRIM_PKGVAR:?}"
NODE="${APPDEST}/node/bin/node"

# 变体（build.sh 写的）：STRATA_FPK_VARIANT、STRATA_FPK_GPU_VENDOR、STRATA_FPK_ENGINE_BACKEND
# shellcheck source=/dev/null
. "${APPDEST}/bin/variant.env"

# shellcheck source=/dev/null
[ -f "${PKGVAR}/settings.env" ] && . "${PKGVAR}/settings.env"
PORT="${STRATA_FPK_PORT:-47831}"

log() { echo "$(date '+%F %T') [launch] $*"; }

# ---- 数据位置 ---------------------------------------------------------------
HOME_DIR="${PKGVAR}/home"
mkdir -p "${HOME_DIR}"

# 共享文件夹放用户在乎的东西：模型、工作区。卸载应用不会删它。
SHARE="${TRIM_DATA_SHARE_PATHS:-}"
SHARE="${SHARE%%:*}"
[ -n "${SHARE}" ] && [ -d "${SHARE}" ] || SHARE="${PKGVAR}/share"
mkdir -p "${SHARE}/models" "${SHARE}/workspace"

# ---- 宿主机的 NVIDIA 驱动库 --------------------------------------------------
# 只把驱动自带的几个库做成符号链接放进一个单独目录，再把这个目录加进 LD_LIBRARY_PATH：
# 不会把宿主机别的库带进来，内置的 CUDA 运行库（cudart / cuBLAS）仍然优先用包里的。
link_host_driver_libs() {
    local dest="${PKGVAR}/hostlibs" dir pat f n=0
    rm -rf "${dest}"; mkdir -p "${dest}"
    for dir in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib /lib/x86_64-linux-gnu /usr/local/nvidia/lib64 /usr/local/nvidia/lib; do
        [ -d "${dir}" ] || continue
        for pat in libcuda.so.1 libnvidia-ml.so.1 libnvidia-ptxjitcompiler.so.1 'libnvidia-nvvm.so*' libnvidia-gpucomp.so.* libnvidia-cfg.so.1; do
            for f in "${dir}"/${pat}; do
                [ -e "${f}" ] || continue
                [ -e "${dest}/$(basename "${f}")" ] && continue
                ln -s "${f}" "${dest}/$(basename "${f}")" && n=$((n + 1))
            done
        done
    done
    if [ ! -e "${dest}/libcuda.so.1" ]; then
        log "WARNING: libcuda.so.1 was not found on this system: install the NVIDIA driver app first (the engine cannot see the GPU without it)"
    else
        log "NVIDIA driver libraries from the host: $(readlink -f "${dest}/libcuda.so.1") (${n} files linked)"
    fi
    echo "${dest}"
}
HOSTLIBS=""
[ "${STRATA_FPK_GPU_VENDOR}" = nvidia ] && HOSTLIBS="$(link_host_driver_libs)"

# ---- 环境 ---------------------------------------------------------------------
export HOME="${HOME_DIR}"
export XDG_DATA_HOME="${HOME_DIR}/.local/share" XDG_CONFIG_HOME="${HOME_DIR}/.config" XDG_STATE_HOME="${HOME_DIR}/.local/state" XDG_CACHE_HOME="${HOME_DIR}/.cache"
export TMPDIR="${HOME_DIR}/tmp"
mkdir -p "${TMPDIR}" "${XDG_DATA_HOME}" "${XDG_CONFIG_HOME}" "${XDG_STATE_HOME}" "${XDG_CACHE_HOME}"

export LANG=C.UTF-8 PYTHONUNBUFFERED=1 PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1
export PATH="${APPDEST}/node/bin:${APPDEST}/control/python/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
if [ -n "${HOSTLIBS}" ]; then
    export LD_LIBRARY_PATH="${HOSTLIBS}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
else
    unset LD_LIBRARY_PATH
fi

# 模型下载源（向导里选的）：HF 镜像站 / 官方 / ModelScope / 自定义。
unset HF_ENDPOINT STRATA_SOURCE
[ -n "${STRATA_FPK_HF_ENDPOINT:-}" ] && export HF_ENDPOINT="${STRATA_FPK_HF_ENDPOINT}"
[ -n "${STRATA_FPK_SOURCE:-}" ] && export STRATA_SOURCE="${STRATA_FPK_SOURCE}"

# Strata 自己的东西
export STRATA_HOME="${HOME_DIR}/strata"
export STRATA_MODELS_DIR="${SHARE}/models"
export STRATA_WORKSPACE="${SHARE}/workspace"
export STRATA_COMPONENTS_DIR="${PKGVAR}/components"
export STRATA_INSTALL_DIR="${PKGVAR}/install"
export STRATA_CONTROL_DIR="${APPDEST}/control"
export STRATA_ENGINE_BUNDLE_DIR="${APPDEST}/engine-bundle"
export STRATA_PACKAGED=1 STRATA_REAL_ENGINE=1 STRATA_NO_ACQUIRE=1 STRATA_NO_REPAIR_ACCESS=1
# 这个包只带一种引擎：别的厂商的卡（同一台机器上的另一块显卡）不参与硬件识别和模型规划
# （packaging/fnos/patches/0001-gpu-vendor.patch），Control 也只选这一种后端。
export STRATA_FPK_GPU_VENDOR STRATA_ENGINE_BACKEND="${STRATA_FPK_ENGINE_BACKEND}"
# 引擎、Control、DeepSeek 引擎都随 fpk 走，不在线更新（packaging/fnos/patches/0002-no-online-updates.patch）。
# 模型、读图文件、DFlash2 草稿模型照常下载（它们不是程序）。
export STRATA_FPK_NO_UPDATES=1
# gfx906（MI50 / MI60 / Radeon VII）不在上游 Control 的 AMD 支持名单里：本包的 Control 补丁加了这个开关
# （packaging/fnos/patches/control/0001-gfx906-opt-in-and-backend.patch）。
[ "${STRATA_FPK_VARIANT}" = gfx906 ] && export STRATA_EXPERIMENTAL_GFX906=1
export NODE_ENV=production
mkdir -p "${STRATA_HOME}" "${STRATA_COMPONENTS_DIR}" "${STRATA_INSTALL_DIR}/third_party"

# 固定版本的 llama.cpp（模型处理工具要用）随包带着，第一次启动不用访问 GitHub。
if [ -d "${APPDEST}/seed/third_party/llama.cpp" ] && [ ! -e "${STRATA_INSTALL_DIR}/third_party/llama.cpp" ]; then
    ln -s "${APPDEST}/seed/third_party/llama.cpp" "${STRATA_INSTALL_DIR}/third_party/llama.cpp"
fi

# DeepSeek V4.1 的引擎包（只有 CUDA 版带）：放进 <install>/engine-dsv41/，用户选 DeepSeek 时 Strata 核对签名后自己安装。
# 已经装好（有 strata-dsv41 的版本目录）或包已经在那里，就什么也不做。
if [ -d "${APPDEST}/dsv41" ]; then
    DSV41_DIR="${STRATA_INSTALL_DIR}/engine-dsv41"
    mkdir -p "${DSV41_DIR}"
    for pkg in "${APPDEST}"/dsv41/strata-dsv41-*.tar.gz; do
        [ -f "${pkg}" ] || continue
        ver="$(basename "${pkg}" .tar.gz)"; ver="${ver#strata-dsv41-}"
        if [ ! -x "${DSV41_DIR}/${ver}/strata-dsv41" ] && [ ! -f "${DSV41_DIR}/$(basename "${pkg}")" ]; then
            cp "${pkg}" "${DSV41_DIR}/" && log "DeepSeek engine package placed in ${DSV41_DIR} (installed when a DeepSeek model is chosen)"
        fi
    done
fi

if [ "${1:-}" = "exec" ]; then
    shift
    exec "$@"
fi

# ---- 端口 ----------------------------------------------------------------------
# 宿主只听回环地址；对外只有反向代理（带认证）。内部端口优先用固定的 18791（浏览器里的聊天记录等
# 按来源存储，宿主端口变了不影响，因为用户访问的是代理端口），被占用才退回系统给的。
pick_free_port() {
    "${NODE}" -e '
const net = require("node:net");
const try_ = (ports) => {
  const p = ports.shift();
  const s = net.createServer();
  s.once("error", () => (ports.length ? try_(ports) : process.exit(1)));
  s.listen({ port: p, host: "127.0.0.1", exclusive: true }, () => { console.log(s.address().port); s.close(); });
};
try_([Number(process.argv[1]) || 0, 0]);' "$1"
}
BACKEND_PORT="$(pick_free_port 18791)"

CHILD_PIDS=()
HOST_PID=""
SLEEP_PID=""
EXIT_CODE=0
cleanup() {
    log "shutting down"
    [ -n "${SLEEP_PID}" ] && kill "${SLEEP_PID}" 2>/dev/null
    # 宿主收到 TERM 会先停掉它启动的引擎、卸载模型，再退出。
    if [ -n "${HOST_PID}" ]; then
        kill -TERM "${HOST_PID}" 2>/dev/null
        wait "${HOST_PID}" 2>/dev/null
    fi
    [ "${#CHILD_PIDS[@]}" -gt 0 ] && kill -TERM "${CHILD_PIDS[@]}" 2>/dev/null
    wait 2>/dev/null
    exit "${EXIT_CODE}"
}
# 被飞牛要求停止是正常退出，不管宿主上一次的退出码是什么。
trap 'EXIT_CODE=0; cleanup' TERM INT

# 反向代理：网页端口 0.0.0.0:${PORT}，Basic Auth，转发到宿主。
if [ ! -s "${HOME_DIR}/.auth.json" ]; then
    log "ERROR: no access password set (${HOME_DIR}/.auth.json); open the app's settings and set one"
    exit 1
fi
PROXY_PORT="${PORT}" PROXY_UPSTREAM_PORT="${BACKEND_PORT}" PROXY_AUTH_FILE="${HOME_DIR}/.auth.json" \
    PROXY_API_KEY_FILE="${HOME_DIR}/.api-key.json" \
    "${NODE}" "${APPDEST}/bin/proxy.mjs" &
CHILD_PIDS+=($!)
log "web port ${PORT} -> Strata host 127.0.0.1:${BACKEND_PORT} (API key access: $([ -s "${HOME_DIR}/.api-key.json" ] && echo on || echo off))"

# 宿主意外退出（内存不足被杀、崩溃……）时重启：${MAX_RESTARTS} 次 / ${RESTART_WINDOW} 秒，间隔递增；
# 超过就放弃并停止应用，避免起不来的东西无限循环。被要求停止（TERM）不会重启。
MAX_RESTARTS="${STRATA_MAX_RESTARTS:-5}"
RESTART_WINDOW="${STRATA_RESTART_WINDOW:-600}"
RESTART_STEP="${STRATA_RESTART_STEP:-3}"

describe_exit() {
    local code="$1"
    if [ "${code}" -gt 128 ]; then
        echo "${code}, killed by signal $((code - 128)) ($(kill -l $((code - 128)) 2>/dev/null))$([ "${code}" = 137 ] && echo ', often out of memory')"
    else
        echo "${code}"
    fi
}

exit_times=()
while :; do
    log "starting the Strata host on 127.0.0.1:${BACKEND_PORT}"
    (
        cd "${APPDEST}/host"
        STRATA_PORT="${BACKEND_PORT}" STRATA_BIND=127.0.0.1 STRATA_DIST="${APPDEST}/host/dist" \
            exec "${NODE}" "${APPDEST}/host/server/index.mjs"
    ) &
    HOST_PID=$!
    wait "${HOST_PID}"
    EXIT_CODE=$?
    HOST_PID=""

    now="$(date +%s)"
    recent=()
    for t in "${exit_times[@]}"; do
        [ $((now - t)) -lt "${RESTART_WINDOW}" ] && recent+=("${t}")
    done
    exit_times=("${recent[@]}" "${now}")
    if [ "${#exit_times[@]}" -gt "${MAX_RESTARTS}" ]; then
        log "the host exited (last: $(describe_exit "${EXIT_CODE}")) ${#exit_times[@]} times within ${RESTART_WINDOW} s: giving up, stopping the app"
        [ "${EXIT_CODE}" = 0 ] && EXIT_CODE=1
        cleanup
    fi
    delay=$((RESTART_STEP * ${#exit_times[@]}))
    log "the host exited ($(describe_exit "${EXIT_CODE}")); restarting in ${delay} s (${#exit_times[@]} of ${MAX_RESTARTS} allowed within ${RESTART_WINDOW} s)"
    sleep "${delay}" &
    SLEEP_PID=$!
    wait "${SLEEP_PID}"
    SLEEP_PID=""
done
