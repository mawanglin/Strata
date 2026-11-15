#!/bin/bash
# 不需要 GPU / 飞牛：检查 launch.sh 里和引擎组件有关的两段：
#  ① 升级 fpk 时包里的引擎组件和已装的同名组件清单不同：删掉已装的那份（宿主再按新包装）；相同、别的版本、终端命令（exec）都不动
#  ② gfx906 版的 STRATA_DSV41_EXE 指向 components/engine/<组件>/strata-dsv41（组件还在 engine-bundle 里时也按最终位置算）
# 用法： packaging/fnos/tests/test_launch_engine.sh
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
L="${HERE}/../fnos/app/bin/launch.sh"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
fails=0
ok() { if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
UPG="$(sed -n '/^if \[ "\${1:-}" != exec \] && \[ -d "\${STRATA_ENGINE_BUNDLE_DIR}" \]/,/^fi$/p' "${L}")"
DSV="$(sed -n '/^if \[ "\${STRATA_FPK_VARIANT}" = gfx906 \] && \[ -z "\${STRATA_DSV41_EXE:-}" \]/,/^fi$/p' "${L}")"
[ -n "${UPG}" ] && [ -n "${DSV}" ] || { echo "FAIL the launch.sh blocks were not found"; exit 1; }

setup() {
    rm -rf "${T}/b" "${T}/c"; mkdir -p "${T}/b/0.1.59-x-hip-gfx906" "${T}/c/engine/0.1.59-x-hip-gfx906" "${T}/c/engine/0.1.58-x-hip-gfx906"
    echo new > "${T}/b/0.1.59-x-hip-gfx906/engine-component.json"
    echo "$1" > "${T}/c/engine/0.1.59-x-hip-gfx906/engine-component.json"
    echo old > "${T}/c/engine/0.1.58-x-hip-gfx906/engine-component.json"
}
run_upg() { STRATA_ENGINE_BUNDLE_DIR="${T}/b" STRATA_COMPONENTS_DIR="${T}/c" bash -c "log(){ :; }; set -- $1; ${UPG}"; }

setup old-build; run_upg ""
ok "different manifest: the installed copy is removed" $([ ! -e "${T}/c/engine/0.1.59-x-hip-gfx906" ] && echo 0 || echo 1)
ok "another version is kept" $([ -e "${T}/c/engine/0.1.58-x-hip-gfx906" ] && echo 0 || echo 1)
setup new; run_upg ""
ok "same manifest: kept" $([ -e "${T}/c/engine/0.1.59-x-hip-gfx906" ] && echo 0 || echo 1)
setup old-build; run_upg "exec"
ok "terminal command (exec): nothing removed" $([ -e "${T}/c/engine/0.1.59-x-hip-gfx906" ] && echo 0 || echo 1)

dsv() { env -u STRATA_DSV41_EXE STRATA_FPK_VARIANT="$1" STRATA_COMPONENTS_DIR="${T}/c" APPDEST="${T}/app" bash -c "${DSV}; echo \${STRATA_DSV41_EXE:-none}"; }
rm -rf "${T}/c" "${T}/app"; mkdir -p "${T}/app/engine-bundle/0.1.59-x-hip-gfx906"
ok "gfx906, component still in engine-bundle: its final place" $([ "$(dsv gfx906)" = "${T}/c/engine/0.1.59-x-hip-gfx906/strata-dsv41" ] && echo 0 || echo 1)
rm -rf "${T}/app"; mkdir -p "${T}/c/engine/0.1.59-x-hip-gfx906"
ok "gfx906, installed component" $([ "$(dsv gfx906)" = "${T}/c/engine/0.1.59-x-hip-gfx906/strata-dsv41" ] && echo 0 || echo 1)
ok "cuda: not set" $([ "$(dsv cuda)" = none ] && echo 0 || echo 1)

[ "${fails}" = 0 ] && echo "all passed" || { echo "${fails} failed"; exit 1; }
