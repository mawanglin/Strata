#!/bin/bash
# 不需要 GPU / 飞牛：launch.sh 选模型目录（本应用的 / 授权目录里另一个 Strata 的共享文件夹）。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
mkdir -p "$T/app/bin" "$T/var" "$T/vol1/@appshare/Strata-gfx906/models" "$T/vol1/@appshare/Strata/models" "$T/other"
cp "${HERE}/../fnos/app/bin/launch.sh" "$T/app/bin/"
printf 'STRATA_FPK_VARIANT=cuda\nSTRATA_FPK_GPU_VENDOR=amd\nSTRATA_FPK_ENGINE_BACKEND=cuda\nSTRATA_FPK_OTHER_APP=strata-gfx906\nSTRATA_FPK_OTHER_SHARE=Strata-gfx906\n' > "$T/app/bin/variant.env"
printf 'STRATA_FPK_PORT=47831\nSTRATA_FPK_MODELS=other\n' > "$T/var/settings.env"
run() { TRIM_APPDEST="$T/app" TRIM_PKGVAR="$T/var" TRIM_DATA_SHARE_PATHS="$T/vol1/@appshare/Strata" TRIM_DATA_ACCESSIBLE_PATHS="$1" \
        bash "$T/app/bin/launch.sh" exec sh -c 'echo "$STRATA_MODELS_DIR"' 2>/dev/null | tail -1; }
OWN="$T/vol1/@appshare/Strata/models"; OTHER="$T/vol1/@appshare/Strata-gfx906/models"; fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got $2)"; fails=$((fails+1)); fi; }
check "authorized other share -> its models"       "$(run "$T/other:$T/vol1/@appshare/Strata-gfx906")" "$OTHER"
check "nothing authorized -> own"                   "$(run "")" "$OWN"
check "unrelated authorized dir -> own"             "$(run "$T/other")" "$OWN"
check "the models dir itself (trailing /) -> it"    "$(run "$T/vol1/@appshare/Strata-gfx906/models/")" "$OTHER"
sed -i 's/STRATA_FPK_MODELS=other/STRATA_FPK_MODELS=own/' "$T/var/settings.env"
check "own selected -> own even when authorized"    "$(run "$T/vol1/@appshare/Strata-gfx906")" "$OWN"
echo; [ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"; exit "$fails"
