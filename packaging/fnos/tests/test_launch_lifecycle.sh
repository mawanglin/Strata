#!/bin/bash
# 不需要 GPU / 飞牛 / Node：用假的 node 跑 launch.sh 从“端口”一节到结尾的部分，检查进程的生死：
#  ① 两个变体的首选宿主端口不同（CUDA 18791，gfx906 18891），开机同时启动时不再抢同一个
#  ② 宿主出错退出：自动重启（set -e 曾让脚本直接退出、不重启）；超过次数放弃时，反向代理也一起停掉
#  ③ 网页端口听不上（代理自己退出）：启动失败，宿主不启动
#  ④ 被要求停止（TERM）：正常退出，代理和宿主都不留下
# 用法： packaging/fnos/tests/test_launch_lifecycle.sh
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
L="${HERE}/../fnos/app/bin/launch.sh"
T="$(mktemp -d)"; trap 'pkill -f "${T}/" 2>/dev/null || true; rm -rf "${T}"' EXIT
fails=0
ok() { if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
TAIL="$(sed -n '/^# ---- 端口/,$p' "${L}")"
[ -n "${TAIL}" ] || { echo "FAIL the launch.sh port section was not found"; exit 1; }

# 假的 node：-e（pick_free_port）回显首选端口；proxy.mjs / index.mjs 按 FAKE_PROXY / FAKE_HOST 的要求活着或退出
mkdir -p "${T}/home"; echo '{"user":"a"}' > "${T}/home/.auth.json"
cat > "${T}/node" <<'EOF'
#!/bin/bash
case "$1" in
    -e) echo "$3" ;;
    */proxy.mjs) echo $$ >> "${FAKE_DIR}/proxy.pids"
        [ "${FAKE_PROXY}" = fail ] && exit 1
        exec sleep 300 ;;
    */index.mjs) echo $$ >> "${FAKE_DIR}/host.pids"
        n=$(wc -l < "${FAKE_DIR}/host.pids")
        [ "${FAKE_HOST}" = crash ] && exit 3
        [ "${FAKE_HOST}" = crash-once ] && [ "${n}" = 1 ] && exit 3
        exec sleep 300 ;;
esac
EOF
chmod +x "${T}/node"
cat > "${T}/run.sh" <<EOF
set -eu
log() { echo "[launch] \$*"; }
NODE="${T}/node" APPDEST="${T}/app" HOME_DIR="${T}/home" STRATA_HOME="${T}/sh" SHARE="${T}/share" PORT=47999
STRATA_FPK_HTTPS=off
${TAIL}
EOF
mkdir -p "${T}/app/host"
alive() { local p; for p in $(cat "${T}/$1.pids" 2>/dev/null); do kill -0 "${p}" 2>/dev/null && return 0; done; return 1; }
run() {   # run <variant> <proxy> <host> [extra env...]: launch.sh in the background, its pid in ${T}/launch.pid
    rm -f "${T}"/*.pids "${T}/out"
    env FAKE_DIR="${T}" FAKE_PROXY="$2" FAKE_HOST="$3" STRATA_FPK_VARIANT="$1" STRATA_PROXY_CHECK_S=0.3 STRATA_RESTART_STEP=0 "${@:4}" \
        bash "${T}/run.sh" > "${T}/out" 2>&1 &
    echo $! > "${T}/launch.pid"
}
waitfor() { local i; for i in $(seq 1 50); do eval "$1" && return 0; sleep 0.1; done; return 1; }
lpid() { cat "${T}/launch.pid"; }

# ① 首选端口
run cuda ok ok; waitfor 'grep -q "starting the Strata host" "${T}/out"'
ok "cuda: preferred host port 18791" $(grep -q "127.0.0.1:18791" "${T}/out" && echo 0 || echo 1)
kill -TERM "$(lpid)"; wait "$(lpid)" 2>/dev/null || true
run gfx906 ok ok; waitfor 'grep -q "starting the Strata host" "${T}/out"'
ok "gfx906: preferred host port 18891" $(grep -q "127.0.0.1:18891" "${T}/out" && echo 0 || echo 1)

# ④ TERM：正常退出，不留进程
kill -TERM "$(lpid)"; rc=0; wait "$(lpid)" || rc=$?
ok "stop (TERM): exit code 0 (got ${rc})" $([ "${rc}" = 0 ] && echo 0 || echo 1)
waitfor '! alive proxy && ! alive host' || true
ok "stop (TERM): no proxy or host left" $(! alive proxy && ! alive host && echo 0 || echo 1)

# ② 宿主崩溃一次：重启，第二个宿主活着
run cuda ok crash-once; waitfor '[ "$(cat "${T}/host.pids" 2>/dev/null | wc -l)" -ge 2 ]' || true
ok "host exits once: restarted" $([ "$(cat "${T}/host.pids" 2>/dev/null | wc -l)" = 2 ] && alive host && echo 0 || echo 1)
ok "host exits once: launch.sh still running" $(kill -0 "$(lpid)" 2>/dev/null && echo 0 || echo 1)
kill -TERM "$(lpid)"; wait "$(lpid)" 2>/dev/null || true

# ② 宿主一直崩：超过次数放弃，退出码非零，代理也停掉
run cuda ok crash STRATA_MAX_RESTARTS=2; rc=0; wait "$(lpid)" || rc=$?
ok "host keeps exiting: gives up with a non-zero exit" $([ "${rc}" != 0 ] && grep -q "giving up" "${T}/out" && echo 0 || echo 1)
ok "host keeps exiting: restarted before giving up" $([ "$(wc -l < "${T}/host.pids")" = 3 ] && echo 0 || echo 1)
waitfor '! alive proxy' || true
ok "host keeps exiting: no proxy left behind" $(! alive proxy && echo 0 || echo 1)

# ③ 代理听不上端口
run cuda fail ok; rc=0; wait "$(lpid)" || rc=$?
ok "web port taken: start fails" $([ "${rc}" != 0 ] && grep -q "could not be opened" "${T}/out" && echo 0 || echo 1)
ok "web port taken: the host is not started" $([ ! -s "${T}/host.pids" ] && echo 0 || echo 1)

[ "${fails}" = 0 ] && echo "all passed" || { echo "${fails} failed"; cat "${T}/out"; exit 1; }
