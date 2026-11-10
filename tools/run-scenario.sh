#!/usr/bin/env bash
# =============================================================================
#  run-scenario.sh — 시나리오 1회 실행: 앱 실행 + 관제 + (무응답 시) 진단 + 결과 요약
#
#    run-scenario.sh scenarios/oom-before.env                 # 결과: evidence/oom-before/<시각>/
#    run-scenario.sh scenarios/deadlock-before.env --max 90   # 90초 관찰 후 진단·종료
#    run-scenario.sh scenarios/oom-before.env --trace         # strace 로 종료 신호를 누가 보냈는지 기록
#
#  산출물 (evidence/<시나리오>/<실행 시각>/) — 실험 ID = <시나리오>-<실행 시각> 이 모든 파일 머리에 들어간다
#    app.log      첫 줄 '# experiment=… start=…' + 앱 표준출력/에러 전체 (Boot Sequence 포함)
#    monitor.log  첫 줄 '# monitor.sh experiment=… start=… interval=…' + tools/monitor.sh 프로세스 관제 기록
#    monitor.csv  monitor.log 와 같은 샘플을 CSV 로 (추세 분석·그래프용)
#    ps.txt       시작 직후 프로세스 트리 (ps -ef, pstree)
#    ps.csv       같은 시점의 PID 스냅샷 (epoch 포함 — monitor.csv 와 시각으로 이어 붙여 분석)
#    top.txt      top -b -d 5 -p <앱 PID> 배치 출력 (5초 간격 %CPU·RES)
#    diagnose.txt 관찰 시간 끝까지 살아 있으면 tools/diagnose-hang.sh 결과
#    trace.txt    (--trace) strace -f 로 기록한 kill/tgkill/exit_group 시스템 콜
#    result.txt   실험 ID, 환경변수, 시작/종료 시각, 생존 시간, 종료 코드·신호, 앱 PID, 종료 직전 부하·힙 N개, 최대 RSS/CPU
#
#  root 로는 실행하지 않는다 (앱 Boot [1/6] 요구사항). 예: sudo -iu agent-admin <경로>/run-scenario.sh …
# =============================================================================
set -uo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCENARIO="${1:-}"; shift || true
MAX=300            # 최대 관찰 시간(초). 이 시간 동안 살아 있으면 '생존' 으로 기록하고 종료시킨다
INTERVAL=2
TRACE=0
OUT_BASE="${EVIDENCE_DIR:-$ROOT/evidence}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --max) MAX="$2"; shift ;;
        --interval) INTERVAL="$2"; shift ;;
        --out) OUT_BASE="$2"; shift ;;
        --trace) TRACE=1 ;;
        *) echo "[ERROR] 알 수 없는 옵션: $1" >&2; exit 2 ;;
    esac
    shift
done
[[ -f "$SCENARIO" ]] || { echo "사용법: $0 scenarios/<이름>.env [--max 초] [--interval 초]" >&2; exit 2; }
[[ "$(id -u)" -ne 0 ]] || { echo "[ERROR] root 로 실행하지 마세요 (앱이 거부합니다). sudo -iu agent-admin $0 …" >&2; exit 2; }

set -a
# shellcheck disable=SC1091
source "$ROOT/tools/env/base.env"
# shellcheck disable=SC1090
source "$SCENARIO"
set +a
APP_BIN="${APP_BIN:-$AGENT_HOME/agent-leak-app-x86}"
[[ "$(uname -m)" == aarch64 || "$(uname -m)" == arm64 ]] && APP_BIN="${APP_BIN/-x86/-arm64}"
[[ -x "$APP_BIN" ]] || { echo "[ERROR] 앱 실행 파일이 없습니다: $APP_BIN" >&2; exit 2; }

mkdir -p "$OUT_BASE" && OUT_BASE="$(cd "$OUT_BASE" && pwd)"   # 아래에서 cd 하므로 절대 경로로 고정
name="$(basename "$SCENARIO" .env)"
stamp="$(date '+%Y%m%d-%H%M%S')"
EXP_ID="$name-$stamp"
LAST_N="${LAST_N:-5}"   # result.txt 에 남길 종료 직전 부하·힙 값 개수
OUT="$OUT_BASE/$name/$stamp"
mkdir -p "$OUT"
echo "[INFO] 시나리오 $name: MEMORY_LIMIT=$MEMORY_LIMIT CPU_MAX_OCCUPY=$CPU_MAX_OCCUPY MULTI_THREAD_ENABLE=$MULTI_THREAD_ENABLE (최대 ${MAX}s)"
echo "[INFO] 결과 폴더: ${OUT#"$ROOT"/}"

cd "$AGENT_HOME" || exit 1
start_epoch="$(date +%s)"; start_ts="$(date '+%Y-%m-%d %H:%M:%S')"
# 모든 산출물 머리에 같은 실험 ID·시작 시각을 남긴다 (파일만 보고도 어느 실행인지 매칭되도록)
printf '# experiment=%s start=%s scenario=%s env: MEMORY_LIMIT=%s CPU_MAX_OCCUPY=%s MULTI_THREAD_ENABLE=%s\n' \
    "$EXP_ID" "$start_ts" "$name" "$MEMORY_LIMIT" "$CPU_MAX_OCCUPY" "$MULTI_THREAD_ENABLE" > "$OUT/app.log"
if [[ $TRACE -eq 1 ]] && command -v strace >/dev/null 2>&1; then
    # 앱을 strace 의 자식으로 실행: 프로세스가 스스로 신호를 보냈는지(kill(getpid()))
    # 커널 OOM Killer 같은 외부가 죽였는지(시스템 콜 없이 +++ killed by +++) 구분할 수 있다
    strace -f -tt -e trace=kill,tgkill,tkill,exit_group -o "$OUT/trace.txt" "$APP_BIN" >> "$OUT/app.log" 2>&1 &
else
    "$APP_BIN" >> "$OUT/app.log" 2>&1 &
fi
app=$!
"$ROOT/tools/monitor.sh" --interval "$INTERVAL" --until-exit --app-log "$OUT/app.log" \
    --header "$EXP_ID" --csv "$OUT/monitor.csv" > "$OUT/monitor.log" 2>&1 &
mon=$!
sleep 3
{ echo "\$ ps -ef | grep agent-leak"; ps -ef | grep '[a]gent-leak'; echo; echo "\$ pstree -p $app"; pstree -p "$app" 2>/dev/null; } > "$OUT/ps.txt"
# 같은 순간을 CSV 로: epoch 가 있어 monitor.csv · app.log 시각과 바로 맞춰 볼 수 있다
{
    echo "epoch,ts,pid,ppid,stat,etimes,nlwp,rss_kb,comm,role"
    snap_epoch="$(date +%s)"; snap_ts="$(date '+%Y-%m-%d %H:%M:%S')"
    ps -eo pid=,ppid=,stat=,etimes=,nlwp=,rss=,comm=,args= | awk -v e="$snap_epoch" -v t="$snap_ts" -v launcher="$app" '
        /[a]gent-leak-app/ && !/strace|monitor\.sh|run-scenario|grep/ {
            role = ($1 == launcher) ? "launcher" : (($2 == launcher) ? "app" : "other")
            printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", e, t, $1, $2, $3, $4, $5, $6, $7, role }'
} > "$OUT/ps.csv"
# top 배치 모드로 5초마다 대상 프로세스의 %CPU·RES 를 함께 남긴다 (monitor.sh 값과 교차 확인용)
target="$("$ROOT/tools/monitor.sh" 2>/dev/null | grep -o 'PID:[0-9]*' | cut -d: -f2)"
topper=""
if [[ -n "$target" ]]; then
    top -b -d 5 -p "$target" > "$OUT/top.txt" 2>&1 &
    topper=$!
fi

status="exited"
while kill -0 "$app" 2>/dev/null; do
    if (( $(date +%s) - start_epoch >= MAX )); then status="alive"; break; fi
    sleep 1
done
end_epoch="$(date +%s)"; end_ts="$(date '+%Y-%m-%d %H:%M:%S')"

if [[ "$status" == alive ]]; then
    echo "[INFO] ${MAX}s 동안 살아 있음 → 무응답 여부 진단 후 종료"
    "$ROOT/tools/diagnose-hang.sh" --app-log "$OUT/app.log" --window 10 > "$OUT/diagnose.txt" 2>&1
    kill -TERM "$app" 2>/dev/null; pkill -TERM -P "$app" 2>/dev/null
    sleep 2
    kill -KILL "$app" 2>/dev/null; pkill -KILL -P "$app" 2>/dev/null
fi
wait "$app" 2>/dev/null; code=$?
# 관제는 프로세스가 사라지면 GONE 을 남기고 스스로 끝난다. 그래도 남아 있으면 정리한다.
for _ in $(seq 1 $((INTERVAL + 3))); do kill -0 "$mon" 2>/dev/null || break; sleep 1; done
kill "$mon" 2>/dev/null; wait "$mon" 2>/dev/null
[[ -n "$topper" ]] && { kill "$topper" 2>/dev/null; wait "$topper" 2>/dev/null; }

signal="-"; (( code > 128 )) && signal="$(kill -l $((code - 128)) 2>/dev/null)"
reason="$(grep -aE 'CRITICAL|WATCHDOG|SELF-TERMINATED|BLOCKED|Boot Failed|MEMORY RECOVERED|Peak reached' "$OUT/app.log" | tail -n 3)"
peak_rss="$(grep -o 'RSS:[0-9.]*' "$OUT/monitor.log" | cut -d: -f2 | sort -n | tail -1)"
peak_cpu="$(grep -o ' CPU:[0-9.]*' "$OUT/monitor.log" | cut -d: -f2 | sort -n | tail -1)"
last_log="$(grep -a '^20[0-9][0-9]-' "$OUT/app.log" | tail -n 1)"
app_pid="$(grep -m1 -o 'pid=[0-9]*' "$OUT/monitor.log" | cut -d= -f2)"
# 앱 로그는 종료 직전 부하에 PID 를 남기지 않으므로, 관제가 잡은 PID 와 직전 N개 값을 함께 요약한다
last_loads="$(grep -ao 'Current Load: [0-9.]*%' "$OUT/app.log" | tail -n "$LAST_N" | cut -d' ' -f3 | paste -sd' ')"
last_heap="$(grep -ao 'Current Heap: [0-9]*MB' "$OUT/app.log" | tail -n "$LAST_N" | cut -d' ' -f3 | paste -sd' ')"
{
    echo "experiment    : $EXP_ID"
    echo "scenario      : $name"
    echo "env           : MEMORY_LIMIT=$MEMORY_LIMIT CPU_MAX_OCCUPY=$CPU_MAX_OCCUPY MULTI_THREAD_ENABLE=$MULTI_THREAD_ENABLE"
    echo "binary        : $(basename "$APP_BIN") (launcher PID $app)"
    echo "app_pid       : ${app_pid:-?}  (관제 대상 = 실제 앱 프로세스)"
    echo "interval      : ${INTERVAL}s"
    echo "start         : $start_ts"
    echo "end           : $end_ts"
    echo "survival      : $((end_epoch - start_epoch))s$( [[ $status == alive ]] && echo " (관찰 종료 시점까지 생존 — 관찰자가 종료)")"
    echo "exit_code     : $code$( [[ $signal != - ]] && echo " (128 + SIG$signal)")"
    echo "status        : $status"
    echo "peak_rss      : ${peak_rss:-?}MB"
    echo "peak_cpu      : ${peak_cpu:-?}%  (프로세스 실측, 1코어=100%)"
    echo "samples       : $(grep -c 'STATE:[RSDTZ]' "$OUT/monitor.log")"
    echo "last_loads    : ${last_loads:--}  (앱 Current Load, 종료 직전 최대 ${LAST_N}개)"
    echo "last_heap     : ${last_heap:--}  (앱 Current Heap, 종료 직전 최대 ${LAST_N}개)"
    echo "last_app_log  : ${last_log:-(없음)}"
    echo "key_lines     :"
    printf '%s\n' "${reason:-(없음)}" | sed 's/^/  /'
} > "$OUT/result.txt"
cat "$OUT/result.txt"
