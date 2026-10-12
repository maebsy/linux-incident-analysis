#!/usr/bin/env bash
# =============================================================================
#  diagnose-hang.sh — "살아 있지만 멈춘" 프로세스 진단 (Deadlock 판별)
#
#    diagnose-hang.sh [--pid PID] [--app-log FILE] [--window 10]
#
#  판단 흐름 (각 단계의 결과가 다음 단계를 정당화한다)
#    1. 살아 있는가?        ps -ef            PID 존재 → 크래시가 아니다
#    2. 일을 하고 있는가?   /proc 스냅샷 2회  window 초 동안 CPU tick·RSS 변화가 0 → 멈춰 있다
#    3. 출력이 멈췄는가?    로그 줄 수·mtime  window 동안 새 줄 0 → 진행이 없다
#    4. 어디서 멈췄는가?    ps -L / top -H    모든 스레드가 S(sleep) + wchan=futex → 락 대기
#    5. 무엇을 기다리나?    앱 로그 마지막    "WAITING for X (BLOCKED)" 가 서로를 가리키면 순환 대기
#
#  CPU 가 0% 인 것만으로는 Deadlock 이라 할 수 없다(그냥 쉬는 중일 수도 있다).
#  "CPU 0 + 메모리 고정 + 로그 정지 + 모든 스레드가 락에서 sleep + 순환 대기 로그" 가 함께 성립해야 한다.
# =============================================================================
set -uo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PID=""; APP_LOG=""; WINDOW=10
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pid) PID="$2"; shift ;;
        --app-log) APP_LOG="$2"; shift ;;
        --window) WINDOW="$2"; shift ;;
        *) echo "[ERROR] 알 수 없는 옵션: $1" >&2; exit 2 ;;
    esac
    shift
done
if [[ -z "$PID" ]]; then
    PID="$("$ROOT/tools/monitor.sh" | grep -o 'PID:[0-9]*' | cut -d: -f2)"
fi
[[ -n "$PID" && -d "/proc/$PID" ]] || { echo "[ERROR] 대상 프로세스를 찾지 못했습니다"; exit 1; }

section() { printf '\n===== %s =====\n' "$*"; }
run() { echo "\$ $*"; bash -c "$*" 2>&1; }

thread_snapshot() {   # tid state utime+stime
    for t in /proc/"$PID"/task/*; do
        awk -v tid="${t##*/}" '{print tid, $3, $14 + $15}' "$t/stat" 2>/dev/null
    done
}
rss_kb() { awk '/^VmRSS:/ {print $2}' "/proc/$PID/status"; }

echo "# diagnose-hang.sh  PID=$PID  window=${WINDOW}s  $(date '+%Y-%m-%d %H:%M:%S')"

section "1. 프로세스 존재 (ps -ef)"
PATTERN="${APP_PATTERN:-agent-leak-app}"
echo "\$ ps -ef | grep '$PATTERN'"
ps -ef | grep -F -- "$PATTERN" | grep -vE 'grep|diagnose-hang|monitor\.sh|run-scenario|bash -c'
# PyInstaller 앱은 부모(부트로더)부터, 단일 프로세스 앱은 자기 자신부터 트리를 그린다
PPID_="$(awk '{print $4}' /proc/"$PID"/stat)"
TREE_ROOT="$PID"
tr '\0' ' ' < "/proc/$PPID_/cmdline" 2>/dev/null | grep -qF -- "$PATTERN" && TREE_ROOT="$PPID_"
run "pstree -p $TREE_ROOT 2>/dev/null || true"

section "2. 스레드 목록 (ps -L: 스레드별 상태·CPU·커널 대기 지점)"
run "ps -L -o pid,tid,stat,pcpu,rss,wchan:20,comm -p $PID"

section "3. top -H (스레드 단위, 1회 배치 출력)"
run "top -H -b -n 1 -p $PID | sed -n '1,4p;7,20p'"

section "4. ${WINDOW}초 간격 스냅샷 비교 (/proc/$PID/task/*/stat)"
s1="$(thread_snapshot)"; r1="$(rss_kb)"
l1="-"; m1="-"
[[ -n "$APP_LOG" && -r "$APP_LOG" ]] && { l1="$(wc -l < "$APP_LOG")"; m1="$(stat -c %y "$APP_LOG" | cut -c1-19)"; }
sleep "$WINDOW"
s2="$(thread_snapshot)"; r2="$(rss_kb)"
l2="-"; m2="-"
[[ -n "$APP_LOG" && -r "$APP_LOG" ]] && { l2="$(wc -l < "$APP_LOG")"; m2="$(stat -c %y "$APP_LOG" | cut -c1-19)"; }
printf '%-8s %-6s %-6s %12s %12s %8s\n' TID STATE1 STATE2 TICKS1 TICKS2 DELTA
total=0
while read -r tid st1 t1; do
    read -r _ st2 t2 < <(grep "^$tid " <<< "$s2")
    d=$(( ${t2:-0} - t1 )); total=$((total + d))
    printf '%-8s %-6s %-6s %12s %12s %8s\n' "$tid" "$st1" "${st2:-gone}" "$t1" "${t2:-?}" "$d"
done <<< "$s1"
echo
echo "CPU ticks 변화 합계 : $total  (CLK_TCK=$(getconf CLK_TCK) → $(awk -v d="$total" -v w="$WINDOW" -v hz="$(getconf CLK_TCK)" 'BEGIN{printf "%.2f", d*100/(w*hz)}')% CPU)"
echo "RSS                 : ${r1}kB → ${r2}kB (변화 $((r2 - r1))kB)"
echo "앱 로그 줄 수       : $l1 → $l2   마지막 수정: $m1 → $m2"
if [[ -n "$APP_LOG" && -r "$APP_LOG" ]]; then
    echo "마지막 로그 이후     : $(( $(date +%s) - $(stat -c %Y "$APP_LOG") ))초 동안 새 기록 없음"
fi

section "5. 앱 로그 마지막 기록"
if [[ -n "$APP_LOG" && -r "$APP_LOG" ]]; then
    tail -n 8 "$APP_LOG"
    section "6. 락 보유/대기 관계 (로그에서 추출)"
    grep -aE 'LOCK ACQUIRED|WAITING for' "$APP_LOG" | sed -E 's/.*\[(Worker-Thread-[0-9]+)\] LOCK ACQUIRED: \[([^]]+)\].*/\1 holds  \2/; s/.*\[(Worker-Thread-[0-9]+)\] WAITING for \[([^]]+)\].*/\1 waits  \2/'
fi

section "판정"
blocked="$(grep -c 'WAITING for' "$APP_LOG" 2>/dev/null || echo 0)"
sleeping="$(awk '$2 == "S" || $2 == "D"' <<< "$s2" | wc -l)"
threads="$(wc -l <<< "$s2")"
verdict=()
[[ $total -eq 0 ]] && verdict+=("CPU 사용 0") || verdict+=("CPU 사용 있음(${total} ticks)")
[[ $((r2 - r1)) -eq 0 ]] && verdict+=("메모리 고정") || verdict+=("메모리 변화")
[[ "$l1" == "$l2" ]] && verdict+=("로그 정지") || verdict+=("로그 진행")
verdict+=("스레드 ${sleeping}/${threads} 개 sleep")
echo "관측: ${verdict[*]}"
if [[ $total -eq 0 && "$l1" == "$l2" && $blocked -ge 2 ]]; then
    echo "결론: DEADLOCK 의심 — 프로세스는 살아 있으나 모든 스레드가 대기 상태로 진행이 없고, 로그상 서로의 자원을 기다리는 순환 대기($blocked 건)가 있다."
elif [[ $total -eq 0 && "$l1" == "$l2" ]]; then
    echo "결론: 무응답(HANG) — 진행이 없다. 원인(락/IO/외부 대기)은 스레드 wchan 과 로그로 추가 확인 필요."
else
    echo "결론: 진행 중 — 멈춘 상태가 아니다."
fi
