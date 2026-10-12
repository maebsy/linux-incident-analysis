#!/usr/bin/env bash
# =============================================================================
#  monitor.sh — 프로세스 단위 장애 관제 (B4-1 monitor.sh 의 수집 방식을 프로세스 중심으로 확장)
#
#  B4-1 은 "서버 전체" 상태를 1분마다 기록했다. 장애 분석에는 "특정 프로세스" 의 변화를
#  몇 초 단위로 봐야 하므로 대상 PID 를 고정하고 짧은 간격으로 반복 샘플링한다.
#
#    monitor.sh                                   # 1회 측정 (B4-1 과 같은 사용법)
#    monitor.sh --interval 2 --until-exit         # 2초마다, 프로세스가 사라질 때까지
#    monitor.sh --interval 2 --app-log app.log    # 앱 로그 줄 수도 함께 기록 (로그 멈춤 탐지)
#
#  기록 형식 (key:value, 공백 구분 — grep/awk 로 바로 추출 가능)
#  [2026-10-12 22:16:45] PROCESS:agent-leak-app PID:512 STATE:S CPU:0.5% MEM:3.1% RSS:250.4MB
#                        THREADS:1 SYS_CPU:2.0% SYS_MEM:9.0% LOG_LINES:42
#
#  측정 방법
#    CPU  : /proc/<pid>/stat 의 utime+stime 을 간격 전후로 읽어 차이 / (간격 × CLK_TCK) × 100
#           → "그 구간" 의 사용률 (1코어 = 100%). ps %cpu 는 실행 이후 평균이라 급상승이 묻힌다.
#    RSS  : /proc/<pid>/status 의 VmRSS (실제 물리 메모리) / MEM% = RSS ÷ MemTotal
#    STATE: /proc/<pid>/stat 3번째 필드 (R 실행, S 대기, D 디스크 대기, Z 좀비, T 정지)
#
#  대상 프로세스 선택: PyInstaller 바이너리는 부트로더(부모)와 실제 앱(자식) 2개로 뜬다.
#  패턴에 맞는 프로세스 중 "부모도 패턴에 맞는 자식" 을 실제 앱으로 고른다.
# =============================================================================
set -uo pipefail
export LC_ALL=C

PATTERN="${APP_PATTERN:-agent-leak-app}"
LABEL="${APP_LABEL:-agent-leak-app}"
INTERVAL=0
UNTIL_EXIT=0
APP_LOG=""
COUNT=0
TARGET_PID=""

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) INTERVAL="${2:-}"; shift ;;
        --until-exit) UNTIL_EXIT=1 ;;
        --app-log) APP_LOG="${2:-}"; shift ;;
        --count) COUNT="${2:-}"; shift ;;
        --pid) TARGET_PID="${2:-}"; shift ;;
        --pattern) PATTERN="${2:-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[ERROR] 알 수 없는 옵션: $1" >&2; exit 2 ;;
    esac
    shift
done
[[ "$INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "[ERROR] --interval 은 숫자여야 합니다" >&2; exit 2; }

HZ="$(getconf CLK_TCK)"
MEM_TOTAL_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"

# 패턴에 맞는 프로세스 중 실제 앱(자식)을 찾는다. 자식이 아직 없으면 부모를 돌려주고 종료 코드 3.
find_target() {
    local pids=() pid ppid
    for dir in /proc/[0-9]*; do
        pid="${dir#/proc/}"
        [[ "$pid" == "$$" ]] && continue
        tr '\0' ' ' < "$dir/cmdline" 2>/dev/null | grep -q -- "$PATTERN" || continue
        tr '\0' ' ' < "$dir/cmdline" 2>/dev/null | grep -qE '(monitor|diagnose|run-scenario)\.sh|grep|strace|timeout' && continue
        pids+=("$pid")
    done
    [[ ${#pids[@]} -eq 0 ]] && return 1
    for pid in "${pids[@]}"; do
        ppid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)"
        if printf '%s\n' "${pids[@]}" | grep -qx "$ppid"; then echo "$pid"; return 0; fi
    done
    echo "${pids[0]}"
    return 3
}

proc_ticks() { awk '{print $14 + $15}' "/proc/$1/stat" 2>/dev/null; }
proc_state() { awk '{print $3}' "/proc/$1/stat" 2>/dev/null; }
sys_ticks()  { awk '/^cpu / { idle = $5 + $6; t = 0; for (i = 2; i <= NF; i++) t += $i; print idle, t }' /proc/stat; }

sample() {   # $1=pid → 한 줄 출력 (간격 동안 CPU 를 측정하므로 최소 1초 소요)
    local pid="$1" window t1 t2 s1i s1t s2i s2t rss thr state cpu syscpu sysmem mem lines
    window="$INTERVAL"; [[ "$window" == 0 ]] && window=1
    t1="$(proc_ticks "$pid")"; read -r s1i s1t < <(sys_ticks)
    sleep "$window"
    t2="$(proc_ticks "$pid")"; read -r s2i s2t < <(sys_ticks)
    if [[ -z "$t1" || -z "$t2" ]]; then
        printf '[%s] PROCESS:%s PID:%s STATE:GONE\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LABEL" "$pid"
        return 1
    fi
    state="$(proc_state "$pid")"
    rss="$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status" 2>/dev/null)"; rss="${rss:-0}"
    thr="$(awk '/^Threads:/ {print $2}' "/proc/$pid/status" 2>/dev/null)"
    cpu="$(awk -v d=$((t2 - t1)) -v w="$window" -v hz="$HZ" 'BEGIN { printf "%.1f", d * 100 / (w * hz) }')"
    syscpu="$(awk -v di=$((s2i - s1i)) -v dt=$((s2t - s1t)) 'BEGIN { printf "%.1f", (dt > 0 ? 100 * (1 - di / dt) : 0) }')"
    sysmem="$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "%.1f", 100 * (t - a) / t}' /proc/meminfo)"
    mem="$(awk -v r="$rss" -v t="$MEM_TOTAL_KB" 'BEGIN { printf "%.1f", 100 * r / t }')"
    lines="-"; [[ -n "$APP_LOG" && -r "$APP_LOG" ]] && lines="$(wc -l < "$APP_LOG")"
    printf '[%s] PROCESS:%s PID:%s STATE:%s CPU:%s%% MEM:%s%% RSS:%.1fMB THREADS:%s SYS_CPU:%s%% SYS_MEM:%s%% LOG_LINES:%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$LABEL" "$pid" "$state" "$cpu" "$mem" "$(awk -v r="$rss" 'BEGIN{print r/1024}')" \
        "$thr" "$syscpu" "$sysmem" "$lines"
}

pid="$TARGET_PID"
if [[ -z "$pid" ]]; then
    # --until-exit 이면 앱이 뜰 때까지 최대 30초 기다린다 (run-scenario.sh 가 동시에 시작하므로).
    # 프로세스가 하나만 보이면(rc 3) PyInstaller 부트로더일 수 있어 자식이 뜨기를 5초 더 기다리고,
    # 그래도 하나뿐이면 단일 프로세스 앱으로 보고 그대로 관제한다.
    single=0
    for _ in $(seq 1 60); do
        pid="$(find_target)"; rc=$?
        [[ $rc -eq 0 ]] && break
        [[ $UNTIL_EXIT -eq 1 ]] || break
        if [[ $rc -eq 3 ]]; then single=$((single + 1)); [[ $single -ge 10 ]] && break; fi
        sleep 0.5
    done
fi
if [[ -z "$pid" || ! -d "/proc/$pid" ]]; then
    printf '[%s] PROCESS:%s PID:- STATE:NOT_RUNNING\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LABEL"
    exit 1
fi

if [[ "$INTERVAL" == 0 ]]; then sample "$pid"; exit $?; fi
n=0
while :; do
    sample "$pid" || exit 0       # 프로세스가 사라지면 GONE 을 남기고 종료
    n=$((n + 1))
    [[ $COUNT -gt 0 && $n -ge $COUNT ]] && exit 0
    [[ $UNTIL_EXIT -eq 0 && $COUNT -eq 0 ]] && exit 0
done
