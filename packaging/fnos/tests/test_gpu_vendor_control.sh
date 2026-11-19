#!/bin/bash
# 不需要 GPU：检查 patches/control/0003-gpu-vendor.patch 加进 Control（tools/strata_mcp.py）的那段过滤：
#  STRATA_FPK_GPU_VENDOR=nvidia|amd 时只留这一家的卡；机器里没有这一家的卡、或没设这个变量时，列表不变。
# 用法： packaging/fnos/tests/test_gpu_vendor_control.sh
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
P="${HERE}/../patches/control/0003-gpu-vendor.patch"
CODE="$(sed -n 's/^+        //p' "${P}" | grep -v '^#')"
[ -n "${CODE}" ] || { echo "FAIL the patch's code was not found"; exit 1; }
fails=0
check() {   # check <label> <vendor env or -> <cards json> <expected vendors, comma-separated>
    local got
    got="$(env -u STRATA_FPK_GPU_VENDOR ${2:+$([ "$2" = - ] || echo "STRATA_FPK_GPU_VENDOR=$2")} python3 -c "
import json, os, sys
hw = {'gpus': json.loads(sys.argv[1])}
exec(sys.argv[2])
print(','.join(g['vendor'] for g in hw['gpus']))" "$3" "${CODE}")"
    if [ "${got}" = "$4" ]; then echo "ok   $1"; else echo "FAIL $1 (got ${got}, want $4)"; fails=$((fails + 1)); fi
}
BOTH='[{"vendor":"nvidia","name":"RTX 3060"},{"vendor":"amd","name":"MI50"}]'
check "cuda package: only the NVIDIA card" nvidia "${BOTH}" nvidia
check "gfx906 package: only the AMD card" amd "${BOTH}" amd
check "not set: every card" - "${BOTH}" nvidia,amd
check "no card of that make: unchanged" amd '[{"vendor":"nvidia","name":"RTX 3060"}]' nvidia
check "upper case value" AMD "${BOTH}" amd
[ "${fails}" = 0 ] && echo "all passed" || { echo "${fails} failed"; exit 1; }
