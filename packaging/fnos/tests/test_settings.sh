#!/bin/bash
# 不需要 GPU / 飞牛：cmd/common 的 apply_wizard_settings —— 安装向导写入设置；设置向导里“保持不变 / 留空”的项沿用当前值
# （曾经在设置里加授权目录时，把已开启的 API Key 删掉了）。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
mkdir -p "$T/app/bin" "$T/app/node/bin" "$T/var"
cp "${HERE}/../fnos/app/bin/set-password.mjs" "$T/app/bin/"
ln -s "$(command -v node)" "$T/app/node/bin/node"
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }
run() {   # run apply_wizard_settings with the wizard_* variables given as arguments; prints nothing, returns its status
    ( export TRIM_APPDEST="$T/app" TRIM_PKGVAR="$T/var"; for kv in "$@"; do export "$kv"; done
      . "${HERE}/../fnos/cmd/common"; apply_wizard_settings ) >/dev/null 2>&1
}
S="$T/var/settings.env"; K="$T/var/home/.api-key.json"
get() { sed -n "s/^$1=//p" "$S" | tr -d "'"; }

run wizard_port=47831 wizard_username=admin wizard_password=secret-123 wizard_source=custom wizard_endpoint=https://mirror.example/hf \
    wizard_models=shared wizard_https=on
check "install: settings written"                 '[ "$(get STRATA_FPK_PORT)" = 47831 ] && [ "$(get STRATA_FPK_MODELS)" = shared ] && [ "$(get STRATA_FPK_HTTPS)" = on ] && [ "$(get STRATA_FPK_HF_ENDPOINT)" = https://mirror.example/hf ]'
before="$(cat "$S")"
run wizard_port= wizard_username= wizard_source=keep wizard_models=keep wizard_https=keep
check "settings, everything kept: nothing changes" '[ "$(cat "$S")" = "${before}" ]'
run wizard_port=48000 wizard_source=keep wizard_models=keep wizard_https=keep
check "only the port changed"                     '[ "$(get STRATA_FPK_PORT)" = 48000 ] && [ "$(get STRATA_FPK_MODELS)" = shared ] && [ "$(get STRATA_FPK_HF_ENDPOINT)" = https://mirror.example/hf ]'
run wizard_source=modelscope
check "source changed, the rest kept"             '[ "$(get STRATA_FPK_SOURCE)" = modelscope ] && [ -z "$(get STRATA_FPK_HF_ENDPOINT)" ] && [ "$(get STRATA_FPK_PORT)" = 48000 ]'
before="$(cat "$S")"
check "old wizard API fields are ignored (no error, nothing changes)" 'run wizard_api=true wizard_api_key=sk-other_0123456789abcdef && [ "$(cat "$S")" = "${before}" ] && [ ! -e "$K" ]'
check "username change without a password: refused" '! run wizard_username=root'
run wizard_username=root wizard_password=another-123
check "username change with a password: ok"       '[ "$(get STRATA_FPK_USER)" = root ] && grep -q "\"user\": \"root\"" "$T/var/home/.auth.json"'
check "a bad port is refused"                     '! run wizard_port=80'

echo; [ "$fails" = 0 ] && echo "all passed" || echo "$fails failed"; exit "$fails"
