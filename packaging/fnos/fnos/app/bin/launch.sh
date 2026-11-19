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

log() { echo "$(date '+%F %T') [launch] $*" >&2; }   # 标准错误：运行时和标准输出一起进 strata.log；exec 模式（bin/strata）不混进命令输出

# ---- 数据位置 ---------------------------------------------------------------
HOME_DIR="${PKGVAR}/home"
mkdir -p "${HOME_DIR}"

# 共享文件夹放用户在乎的东西：模型、工作区。卸载应用不会删它。
SHARE="${TRIM_DATA_SHARE_PATHS:-}"
SHARE="${SHARE%%:*}"
[ -n "${SHARE}" ] && [ -d "${SHARE}" ] || SHARE="${PKGVAR}/share"
mkdir -p "${SHARE}/models" "${SHARE}/workspace"

# ---- 模型目录：本应用的共享文件夹，或用户授权给本应用的文件夹（两个 Strata 授权同一个就共用） ----------
# 飞牛的共享文件夹由它自己的 Trim-ACL 管，应用（包括 cmd/ 脚本）以应用用户运行，改不了别的目录的权限；“授权目录”是飞牛
# 给应用开放别的文件夹的正式办法（它给这个文件夹加上应用用户的 Trim-ACL），通过 TRIM_DATA_ACCESSIBLE_PATHS 传进来。
#   - 授权的是用户自己的文件夹（如 /vol1/1000/Model）：模型放进它的 Strata 子文件夹，不和别的东西混在一起；
#   - 授权的是另一个 Strata 的共享文件夹（variant.env 的 STRATA_FPK_OTHER_SHARE）：用它的 models。
# 取第一个能写的；都不能用时退回本应用自己的，日志里说明。
MODELS_DIR="${SHARE}/models"
case "${STRATA_FPK_MODELS:-own}" in
    shared|other)
        picked=""
        IFS=':' read -r -a _authorized <<< "${TRIM_DATA_ACCESSIBLE_PATHS:-}"
        for p in "${_authorized[@]}"; do
            p="${p%/}"
            [ -n "${p}" ] || continue
            case "${p}" in
                */"${STRATA_FPK_OTHER_SHARE:-//}") cand="${p}/models" ;;
                */"${STRATA_FPK_OTHER_SHARE:-//}"/models) cand="${p}" ;;
                *) cand="${p}/Strata" ;;
            esac
            mkdir -p "${cand}" 2>/dev/null || true
            if [ -d "${cand}" ] && [ -w "${cand}" ] && [ -x "${cand}" ]; then picked="${cand}"; break; fi
        done
        if [ -n "${picked}" ]; then
            MODELS_DIR="${picked}"
            log "models: in an authorized folder (shared with the other Strata when it is authorized there too): ${MODELS_DIR}"
        else
            log "models: an authorized folder was asked for, but this app has none it can write (add one in the app's settings under authorized directories, then restart the app); using ${MODELS_DIR}"
        fi ;;
esac

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
export STRATA_MODELS_DIR="${MODELS_DIR}"
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
# Qwen3.6 的上下文（fp32 K/V）整个在显存里：小显存卡默认的 128K 起不来时自动减半重试，成功的值记进模型配置
# （packaging/fnos/patches/0003-q36-context-fallback.patch）。在模型设置里自己选过的上下文不会被改。
export STRATA_FPK_CONTEXT_FALLBACK=1
# 两个 Strata（CUDA 和 gfx906）在同一台 NAS 上：同时加载模型时两边都探到同一个空闲的引擎端口，后起的那个 EADDRINUSE 失败。
# 各用各的端口段（packaging/fnos/patches/0004-engine-port-base.patch）：CUDA 18500 起，gfx906 18600 起。
if [ "${STRATA_FPK_VARIANT}" = gfx906 ]; then export STRATA_FPK_ENGINE_PORT_BASE=18600; else export STRATA_FPK_ENGINE_PORT_BASE=18500; fi
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

# 升级 fpk 时引擎版本号可能没变、内容变了（比如 gfx906 组件加进了 strata-dsv41）：宿主看到同版本已装就保留旧的
# （apps/host/server/bundled-engine.mjs）。所以包里带的组件和已装的同名组件清单不一样时，先删掉已装的那份
# （它就是本包上次放进去的副本），宿主启动时按新包重新装。别的版本、用户自己装的引擎不动。
if [ "${1:-}" != exec ] && [ -d "${STRATA_ENGINE_BUNDLE_DIR}" ]; then   # (只在启动应用时；终端命令 bin/strata 不动)
    for b in "${STRATA_ENGINE_BUNDLE_DIR}"/*/; do
        b="${b%/}"; n="$(basename "${b}")"; inst="${STRATA_COMPONENTS_DIR}/engine/${n}"
        [ -f "${b}/engine-component.json" ] && [ -f "${inst}/engine-component.json" ] || continue
        if ! cmp -s "${b}/engine-component.json" "${inst}/engine-component.json"; then
            rm -rf "${inst}" && log "bundled engine ${n} differs from the installed copy: the installed copy was removed, the new one is installed at start"
        fi
    done
fi

# gfx906 版：DeepSeek V4.1 引擎是本包自己编的（packaging/fnos/gfx906/patches/0002-dsv41-on-gfx906.patch），和主引擎在同一个引擎组件里、
# 共用 ROCm 库；没有上游签名，所以用 Control 的 STRATA_DSV41_EXE（“自己编的引擎”）指给它。组件第一次启动时才从 engine-bundle
# 复制到 components/engine/，所以按组件目录名算出最终位置（文件还没到时 Control 当作“没有 DeepSeek 引擎”）。
if [ "${STRATA_FPK_VARIANT}" = gfx906 ] && [ -z "${STRATA_DSV41_EXE:-}" ]; then
    for d in "${STRATA_COMPONENTS_DIR}"/engine/*-hip-gfx906 "${APPDEST}"/engine-bundle/*-hip-gfx906; do
        [ -d "${d}" ] || continue
        export STRATA_DSV41_EXE="${STRATA_COMPONENTS_DIR}/engine/$(basename "${d}")/strata-dsv41"
        break
    done
fi

if [ "${1:-}" = "exec" ]; then
    shift
    exec "$@"
fi

# ---- 端口 ----------------------------------------------------------------------
# 宿主只听回环地址；对外只有反向代理（带认证）。内部端口优先用固定的端口（浏览器里的聊天记录等
# 按来源存储，宿主端口变了不影响，因为用户访问的是代理端口），被占用才退回系统给的。
# 两个变体各用一个（CUDA 18791，gfx906 18891）：飞牛开机时两个应用几乎同时启动，用同一个首选端口时
# 两边都先看到它空着，后起的宿主报 “Port 18791 is already in use” 起不来（2026-11-18 实测）。
# 局域网共享另开“宿主端口 + 1”，所以两个首选端口隔开 100。
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
if [ "${STRATA_FPK_VARIANT}" = gfx906 ]; then HOST_PORT_PREFERRED=18891; else HOST_PORT_PREFERRED=18791; fi
BACKEND_PORT="$(pick_free_port "${HOST_PORT_PREFERRED}")"

CHILD_PIDS=()
HOST_PID=""
SLEEP_PID=""
EXIT_CODE=0
cleanup() {
    log "shutting down"
    [ -z "${SLEEP_PID}" ] || kill "${SLEEP_PID}" 2>/dev/null || true
    # 宿主收到 TERM 会先停掉它启动的引擎、卸载模型，再退出。
    if [ -n "${HOST_PID}" ]; then
        kill -TERM "${HOST_PID}" 2>/dev/null
        wait "${HOST_PID}" 2>/dev/null || true   # （set -e：宿主被 TERM 后的退出码不能让这里中途退出，代理还没停）
        HOST_PID=""
    fi
    # （set -e：要停的进程已经不在时 kill 会失败，不能因此中途退出、丢掉退出码）
    [ "${#CHILD_PIDS[@]}" -eq 0 ] || kill -TERM "${CHILD_PIDS[@]}" 2>/dev/null || true
    wait 2>/dev/null || true
    exit "${EXIT_CODE}"
}
# 被飞牛要求停止是正常退出，不管宿主上一次的退出码是什么。
trap 'EXIT_CODE=0; cleanup' TERM INT
# 不管因为什么退出（包括 set -e 下某条命令失败），都不留下反向代理和宿主：留下的代理会一直占着网页端口，
# 下次启动的代理听不上，旧代理还把请求转给这个内部端口上的别的程序（曾经把 gfx906 版的网页转到了 CUDA 版）。
stop_children() {
    [ -z "${HOST_PID}" ] || kill -TERM "${HOST_PID}" 2>/dev/null || true
    [ "${#CHILD_PIDS[@]}" -eq 0 ] || kill -TERM "${CHILD_PIDS[@]}" 2>/dev/null || true
    return 0
}
trap stop_children EXIT

# 反向代理：网页端口 0.0.0.0:${PORT}，Basic Auth，转发到宿主。
# 旧版本在飞牛设置里存过一个 API Key（只有哈希）：现在 /v1 只认 Strata 自己的 Key（网页“API 服务 → API 密钥”），旧的不再用。
if [ -e "${HOME_DIR}/.api-key.json" ]; then
    rm -f "${HOME_DIR}/.api-key.json"
    log "the API key of the fnOS app settings is no longer used: programs now use Strata's own key (create it in Strata under API Serving -> API key)"
fi
if [ ! -s "${HOME_DIR}/.auth.json" ]; then
    log "ERROR: no access password set (${HOME_DIR}/.auth.json); open the app's settings and set one"
    exit 1
fi
PROXY_PORT="${PORT}" PROXY_UPSTREAM_PORT="${BACKEND_PORT}" PROXY_AUTH_FILE="${HOME_DIR}/.auth.json" \
    PROXY_TLS="${STRATA_FPK_HTTPS:-off}" PROXY_TLS_DIR="${HOME_DIR}/tls" PROXY_TLS_USER_DIR="${SHARE}/tls" \
    PROXY_HOST_STATE="${STRATA_HOME}/data/state.json" \
    "${NODE}" "${APPDEST}/bin/proxy.mjs" &
PROXY_PID=$!
CHILD_PIDS+=("${PROXY_PID}")
log "web port ${PORT} -> Strata host 127.0.0.1:${BACKEND_PORT}"
# 网页端口听不上（被占用）时代理会自己退出；这时应用开着也打不开，干脆启动失败，让飞牛显示出来。
sleep "${STRATA_PROXY_CHECK_S:-1}"
if ! kill -0 "${PROXY_PID}" 2>/dev/null; then
    log "ERROR: the web port ${PORT} could not be opened (see the [proxy] line above); is another program using it?"
    exit 1
fi

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
    # （set -e 下宿主退出码非零时，单独的 wait 会让整个脚本直接退出，下面的自动重启就不会发生）
    EXIT_CODE=0
    wait "${HOST_PID}" || EXIT_CODE=$?
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
    wait "${SLEEP_PID}" || true
    SLEEP_PID=""
done
