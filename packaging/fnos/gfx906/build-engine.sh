#!/bin/bash
# 在 Ubuntu 22.04 容器里编译 gfx906（MI50 / MI60 / Radeon VII）的 Strata 引擎并打成引擎组件。由 build-engine-docker.sh 调用。
#
# glibc 2.35 的环境编出来的程序能跑在之后所有发行版上（飞牛是 Debian 12，glibc 2.36），和上游官方 HIP 包的做法一样。
# ROCm 来自 AMD TheRock 的 gfx906 wheel（带 gfx906 的 rocBLAS 内核；AMD 正式版 ROCm 已经不带 gfx906 了）。
# 引擎和 ROCm 运行库、rocBLAS 内核数据一起打包，RUNPATH 都是 $ORIGIN，运行时不需要宿主机装 ROCm，只要内核的 amdgpu 驱动。
#
# 目录（容器里）：/work/src 引擎源码（上游 release 引擎的提交），/work/out 输出，/work/pip-cache 下载缓存（复用）。
# Python 环境放在容器自己的文件系统（/opt/venv）：rocm-sdk 展开 devel 内容时要建硬链接，链接目标跨出 /work 这个
# 绑定挂载时会报 "Invalid cross-device link"（在飞牛的 ZFS 卷上实际遇到过）。
# 环境：ROCM_VERSION、ROCM_INDEX、PKGVER（引擎版本）、COMMIT（源码提交，写进 build id）、JOBS、
#       PIP_MIRROR（可选，如 https://mirrors.cloud.tencent.com/pypi/simple：PyPI 在国内常超时；只用于构建工具，ROCm 仍从 AMD 的索引装）
#       APT_MIRROR（可选，如 http://mirrors.ustc.edu.cn：Ubuntu 官方源在国内很慢；基础镜像没有 CA 证书，要用 http）

set -euo pipefail
ROCM_VERSION="${ROCM_VERSION:-7.14.0a20260612}"
ROCM_INDEX="${ROCM_INDEX:-https://rocm.nightlies.amd.com/v2/gfx906/}"
PKGVER="${PKGVER:?PKGVER=<engine version, e.g. 0.1.59>}"
COMMIT="${COMMIT:?COMMIT=<source commit>}"
JOBS="${JOBS:-$(nproc)}"
SRC=/work/src
OUT=/work/out
VENV=/opt/venv
export PIP_CACHE_DIR=/work/pip-cache
ARCH=gfx906
log() { echo "==> $(date +%T) $*"; }

log "system packages"
export DEBIAN_FRONTEND=noninteractive
if [ -n "${APT_MIRROR:-}" ]; then
    sed -i -e "s|http://archive.ubuntu.com|${APT_MIRROR%/}|g" -e "s|http://security.ubuntu.com|${APT_MIRROR%/}|g" /etc/apt/sources.list
fi
apt-get update -qq
apt-get install -y -qq --no-install-recommends python3 build-essential git patchelf unzip ca-certificates curl file binutils >/dev/null

# Python 3.12：TheRock 的 rocm-sdk 工具在 22.04 的 Python 3.10 和早期 3.11 上都会报
# "MetadataPathFinder.invalidate_caches() missing 1 required positional argument"。用 Strata 自己固定的独立版 CPython
# （python-build-standalone，和 packaging/package_terminal.py 的版本、校验值一致），放在 /work 里复用。
PBS_FILE="cpython-3.12.15+20261009-x86_64-unknown-linux-gnu-install_only.tar.gz"
PBS_SHA256="5864001bf969db329fadc2b654c4878c6027d170c6bd77e28f88666260bcaf63"
log "Python 3.12 (standalone)"
if [ ! -x /work/python312/bin/python3 ]; then
    if ! echo "${PBS_SHA256}  /work/${PBS_FILE}" | sha256sum -c --status 2>/dev/null; then
        curl -fL --retry 5 --connect-timeout 30 -o "/work/${PBS_FILE}" \
            "https://github.com/astral-sh/python-build-standalone/releases/download/20261009/${PBS_FILE/+/%2B}"
        echo "${PBS_SHA256}  /work/${PBS_FILE}" | sha256sum -c --status || { echo "CPython download does not match its pin" >&2; exit 1; }
    fi
    rm -rf /work/python312.partial && mkdir -p /work/python312.partial
    tar -xzf "/work/${PBS_FILE}" -C /work/python312.partial --strip-components=1
    mv /work/python312.partial /work/python312
fi

log "Python venv + build tools"
[ -x "${VENV}/bin/python" ] || /work/python312/bin/python3 -m venv "${VENV}"
mkdir -p "${PIP_CACHE_DIR}" && chown "$(id -u):$(id -g)" "${PIP_CACHE_DIR}"   # pip 不用不属于自己的缓存目录
PY="${VENV}/bin/python"
PIPOPTS=(-q --disable-pip-version-check --timeout 120 --retries 10)
"${PY}" -m pip install "${PIPOPTS[@]}" ${PIP_MIRROR:+--index-url "${PIP_MIRROR}"} -r "${SRC}/requirements.txt" -r "${SRC}/requirements-build.txt"
export PATH="${VENV}/bin:${PATH}"

log "ROCm ${ROCM_VERSION} (TheRock, gfx906)"
STAMP="${VENV}/.rocm-${ROCM_VERSION}"
if [ ! -f "${STAMP}" ]; then
    "${PY}" -m pip install "${PIPOPTS[@]}" --index-url "${ROCM_INDEX}" "rocm[libraries,devel]==${ROCM_VERSION}"
    touch "${STAMP}"
fi
HP="$("${VENV}/bin/rocm-sdk" path --root)"
SP="$("${PY}" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
LIBW="${SP}/_rocm_sdk_libraries_gfx906"
CORE="${SP}/_rocm_sdk_core"
[ -x "${HP}/llvm/bin/clang++" ] || { echo "no clang++ in ${HP}" >&2; exit 1; }
[ -d "${LIBW}/lib/rocblas/library" ] || { echo "no rocBLAS kernel data in ${LIBW}" >&2; exit 1; }
ls "${LIBW}/lib/rocblas/library/" | grep -q "${ARCH}" || ls "${LIBW}/lib/rocblas/library/${ARCH}" >/dev/null || { echo "rocBLAS has no ${ARCH} kernels" >&2; exit 1; }
echo "    HP=${HP}"; echo "    LIBW=${LIBW}"; echo "    CORE=${CORE}"

# 本包对引擎源码的补丁（packaging/fnos/gfx906/patches，由 build-engine-docker.sh 放到 /work/patches）
for p in /work/patches/*.patch; do
    [ -e "$p" ] || continue
    log "patch $(basename "$p")"
    ( cd "${SRC}" && patch -p1 --forward --no-backup-if-mismatch < "$p" ) || { echo "patch does not apply: $p" >&2; exit 1; }
done

log "llama.cpp at the pinned commit"
( cd "${SRC}" && "${PY}" -c "import setup; print(setup.get_llama_cpp())" )
LLAMA="${SRC}/third_party/llama.cpp"

export HIP_PLATFORM=amd HIP_COMPILER=clang HIP_RUNTIME=rocclr ROCM_PATH="${HP}" HIP_PATH="${HP}"
SYSDEPS=""; [ -d "${HP}/lib/rocm_sysdeps" ] && SYSDEPS=";${HP}/lib/rocm_sysdeps"
HIPDEFS=(-DCMAKE_HIP_COMPILER="${HP}/llvm/bin/clang++" -DCMAKE_HIP_COMPILER_ROCM_ROOT="${HP}" "-DCMAKE_PREFIX_PATH=${HP};${LIBW}${SYSDEPS}"
         "-DCMAKE_HIP_FLAGS=--rocm-path=${HP} --rocm-device-lib-path=${HP}/lib/llvm/amdgcn/bitcode")
mkdir -p "${OUT}"
cd "${SRC}"

log "engine (STRATA_HIP_GFX906, ${ARCH})"
cmake -G Ninja -S . -B "${OUT}/b" -DCMAKE_BUILD_TYPE=Release -DSTRATA_HIP_GFX906=ON -DCMAKE_HIP_ARCHITECTURES="${ARCH}" \
    -DSTRATA_BUILD_TESTS=OFF -DSTRATA_GGML_DIR="${LLAMA}" -DSTRATA_PORTABLE=ON \
    -DCMAKE_C_COMPILER="${HP}/llvm/bin/clang" -DCMAKE_CXX_COMPILER="${HP}/llvm/bin/clang++" "${HIPDEFS[@]}" \
    "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-rpath,'\$ORIGIN' -Wl,--enable-new-dtags" > "${OUT}/cfg.log" 2>&1 \
    || { tail -40 "${OUT}/cfg.log"; exit 1; }
# -k 0：一个文件出错也继续编其余的，一次就能看到所有出错的地方
nice -n 10 cmake --build "${OUT}/b" --target strata -j "${JOBS}" -- -k 0 > "${OUT}/build.log" 2>&1 \
    || { grep -a "^FAILED" "${OUT}/build.log"; grep -a " error: " "${OUT}/build.log" | sort | uniq | head -40; exit 1; }
[ -x "${OUT}/b/strata" ] || { echo "no strata binary" >&2; exit 1; }

# DeepSeek V4.1 引擎（strata-dsv41）：上游不给 gfx906 编（CMake 里排除了），本包的 patches/0002-dsv41-on-gfx906.patch 让它走上游 AMD
# 版的代码分支 + gfx906 的 wave64 兼容层。单独一个构建目录，主引擎的配置一点不变。DSV41=0 跳过。
if [ "${DSV41:-1}" = 1 ]; then
    log "DeepSeek engine strata-dsv41 (STRATA_HIP_GFX906, ${ARCH})"
    cmake -G Ninja -S . -B "${OUT}/bd" -DCMAKE_BUILD_TYPE=Release -DSTRATA_HIP_GFX906=ON -DCMAKE_HIP_ARCHITECTURES="${ARCH}" \
        -DSTRATA_BUILD_TESTS=OFF -DSTRATA_GGML_DIR="${LLAMA}" -DSTRATA_PORTABLE=ON -DSTRATA_BUILD_DSV41=ON -DSTRATA_NATIVE_EXPERTS=ON \
        -DCMAKE_C_COMPILER="${HP}/llvm/bin/clang" -DCMAKE_CXX_COMPILER="${HP}/llvm/bin/clang++" "${HIPDEFS[@]}" \
        "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-rpath,'\$ORIGIN' -Wl,--enable-new-dtags" > "${OUT}/cfg-dsv41.log" 2>&1 \
        || { tail -40 "${OUT}/cfg-dsv41.log"; exit 1; }
    nice -n 10 cmake --build "${OUT}/bd" --target strata-dsv41 -j "${JOBS}" -- -k 0 > "${OUT}/build-dsv41.log" 2>&1 \
        || { grep -a "^FAILED" "${OUT}/build-dsv41.log"; grep -a " error: " "${OUT}/build-dsv41.log" | sort | uniq | head -40; exit 1; }
    [ -x "${OUT}/bd/strata-dsv41" ] || { echo "no strata-dsv41 binary" >&2; exit 1; }
    grep -aq "amdgcn-amd-amdhsa--${ARCH}" "${OUT}/bd/strata-dsv41" || { echo "strata-dsv41 has no ${ARCH} code object" >&2; exit 1; }
fi

log "CPU picture reader (portable)"
cmake -G Ninja -S tools/vision -B "${OUT}/bv" -DCMAKE_BUILD_TYPE=Release -DLLAMA_DIR="${LLAMA}" -DSTRATA_VISION_CUDA=OFF -DSTRATA_PORTABLE=ON \
    > "${OUT}/cfg-vision.log" 2>&1 || { tail -40 "${OUT}/cfg-vision.log"; exit 1; }
nice -n 10 cmake --build "${OUT}/bv" --target strata-vision -j "${JOBS}" > "${OUT}/build-vision.log" 2>&1 || { tail -40 "${OUT}/build-vision.log"; exit 1; }

# GPU 读图器：llama.cpp 的 ggml-hip，编给 gfx906（上游 build_hip_linux.sh 的做法）。显存 24 GB 起 Strata 默认用 GPU 读图，
# MI50 / MI60 都在这个范围；读图器起不来时 Strata 自己退回 CPU 读图器。
log "GPU picture reader (ggml-hip, ${ARCH})"
cmake -G Ninja -S tools/vision -B "${OUT}/bh" -DCMAKE_BUILD_TYPE=Release -DLLAMA_DIR="${LLAMA}" -DSTRATA_VISION_HIP=ON \
    "-DSTRATA_VISION_HIP_ARCHS=${ARCH}" -DSTRATA_PORTABLE=ON "${HIPDEFS[@]}" > "${OUT}/cfg-vision-hip.log" 2>&1 \
    || { tail -40 "${OUT}/cfg-vision-hip.log"; exit 1; }
nice -n 10 cmake --build "${OUT}/bh" --target strata-vision -j "${JOBS}" > "${OUT}/build-vision-hip.log" 2>&1 \
    || { grep -a " error: " "${OUT}/build-vision-hip.log" | head -20; tail -20 "${OUT}/build-vision-hip.log"; exit 1; }
[ -x "${OUT}/bh/bin/strata-vision-hip" ] || { echo "no strata-vision-hip" >&2; exit 1; }

log "stage: binaries, ROCm libraries, rocBLAS ${ARCH} kernel data"
STAGE="${OUT}/stage"; rm -rf "${STAGE}"; mkdir -p "${STAGE}"
cat > "${STAGE}/BUILD.json" <<EOJ
{"version": "${PKGVER}", "source": "fnos-gfx906 ${COMMIT}", "variant": "gfx906", "archs": ["${ARCH}"], "portable": true, "vision": "gpu", "vision_cpu": "strata-vision", "vision_gpu": "strata-vision-hip", "vision_archs": ["${ARCH}"], "rocm": "${ROCM_VERSION} (TheRock gfx906)", "dsv41": $([ "${DSV41:-1}" = 1 ] && echo true || echo false)}
EOJ
DATA=(--data "${LIBW}/lib/rocblas/library=rocblas/library" --data-arch "${ARCH}")
: > "${OUT}/collect.log"
DSV41_BIN=(); [ "${DSV41:-1}" = 1 ] && DSV41_BIN=("${OUT}/bd/strata-dsv41")
for bin in "${OUT}/b/strata" "${OUT}/bh/bin/strata-vision-hip" "${DSV41_BIN[@]}"; do     # 引擎和 GPU 读图器各自要的库（CPU 读图器只用系统库）
    "${PY}" packaging/collect_libs.py --binary "${bin}" --search "${LIBW}/lib" --search "${HP}/lib" --search "${CORE}/lib" --search "${HP}/lib/llvm/lib" \
        ${SYSDEPS:+--search "${HP}/lib/rocm_sysdeps/lib"} --also 'libamd_comgr.so*' --also 'libhiprtc*.so*' --out "${STAGE}" \
        "${DATA[@]}" >> "${OUT}/collect.log" 2>&1 || { tail -40 "${OUT}/collect.log"; exit 1; }
    DATA=()                                                              # 内核数据只收一次
done
cp "${OUT}/b/strata" "${OUT}/bv/bin/strata-vision" "${OUT}/bh/bin/strata-vision-hip" "${STAGE}/"
[ "${DSV41:-1}" = 1 ] && cp "${OUT}/bd/strata-dsv41" "${STAGE}/"
for f in "${STAGE}"/*.so "${STAGE}"/*.so.*; do [ -f "$f" ] && [ ! -L "$f" ] && patchelf --set-rpath '$ORIGIN' "$f"; done
echo "    glibc needed (max): $(for f in "${STAGE}"/strata "${STAGE}"/*.so*; do objdump -T "$f" 2>/dev/null; done | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
echo "    GLIBCXX needed (max): $(for f in "${STAGE}"/strata "${STAGE}"/*.so*; do objdump -T "$f" 2>/dev/null; done | grep -o 'GLIBCXX_[0-9.]*' | sort -uV | tail -1)"
du -sh "${STAGE}" | sed 's/^/    stage: /'
# BUILD.json 的 hipblaslt_version（package_engine.py 要求 AMD 包都有）；gfx906 没有调优表，引擎走普通 hipBLAS
"${PY}" packaging/stage_tuning.py --stage "${STAGE}" --archs "${ARCH}" --rocm "${HP}" > "${OUT}/stage_tuning.log" 2>&1 \
    || { tail -20 "${OUT}/stage_tuning.log"; exit 1; }
tail -n 1 "${OUT}/stage_tuning.log" | sed 's/^/    tuning: /'

log "package"
rm -rf "${OUT}/components"; mkdir -p "${OUT}/components/engine"
"${PY}" packaging/package_engine.py --src "${STAGE}" --backend hip --version "${PKGVER}" --out "${OUT}/components/engine" --arch "${ARCH}" \
    --variant gfx906 --platform linux-x86_64 --build-id "${COMMIT:0:12}+rocm${ROCM_VERSION}" --tree \
    --notes "AMD gfx906 (MI50 / MI60 / Radeon VII) build for the fnOS package: engine, DeepSeek engine (strata-dsv41), CPU and GPU picture readers, ROCm ${ROCM_VERSION} from TheRock" \
    > "${OUT}/package.log" 2>&1 || { tail -40 "${OUT}/package.log"; exit 1; }
for d in "${OUT}"/components/engine/*/; do
    "${PY}" packaging/package_engine.py --verify "$d"
    "${PY}" packaging/binary_deps.py "$d" | tail -5
done
log "done: $(ls -d "${OUT}"/components/engine/*/)"
