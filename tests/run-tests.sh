#!/usr/bin/env bash
# tools/*.sh 자동 테스트 (실제 바이너리·root 불필요). 가짜 앱(tests/fake-agent-leak-app.py)으로
# 메모리 증가·실제 교착 상태·CPU 사용을 만들고, 스케줄링 로그는 fixtures 로 검증한다.
#   bash tests/run-tests.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t lia-test-XXXXXX)"
PASS=0; FAIL=0; PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${OUT:-}" ]] && printf '%s\n' "$OUT" | head -20 | sed 's/^/       | /'; }
check() { local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
section() { printf '\n[%s]\n' "$1"; }
FAKE="$TMP/fake-agent-leak-app.py"
cp "$ROOT/tests/fake-agent-leak-app.py" "$FAKE"
# 실제 agent-leak-app 이 떠 있어도 섞이지 않도록 임시 경로를 관제 패턴으로 쓴다
export APP_PATTERN="$FAKE"
start_fake() { python3 "$FAKE" "$1" > "$TMP/$1.log" 2>&1 & PIDS+=($!); FAKE_PID=$!; sleep "${2:-1}"; }
stop_fake() { kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; }

section "문법 / ShellCheck"
for f in "$ROOT"/tools/*.sh "$ROOT"/tests/*.sh; do check "bash -n $(basename "$f")" bash -n "$f"; done
if command -v shellcheck >/dev/null 2>&1; then
    OUT="$(shellcheck -S warning "$ROOT"/tools/*.sh "$ROOT"/tests/*.sh 2>&1)"; check "shellcheck warning 0" test -z "$OUT"
fi

section "monitor.sh: 메모리 증가 추적"
start_fake leak 0.5
OUT="$("$ROOT/tools/monitor.sh" --interval 1 --count 3 --app-log "$TMP/leak.log" 2>&1)"
check "3줄 기록" test "$(grep -c 'PROCESS:agent-leak-app' <<< "$OUT")" -eq 3
check "형식 [ts] PROCESS PID STATE CPU MEM RSS THREADS SYS_CPU SYS_MEM LOG_LINES" \
    grep -Eq '^\[[0-9-]+ [0-9:]+\] PROCESS:agent-leak-app PID:[0-9]+ STATE:[RSD] CPU:[0-9.]+% MEM:[0-9.]+% RSS:[0-9.]+MB THREADS:[0-9]+ SYS_CPU:[0-9.]+% SYS_MEM:[0-9.]+% LOG_LINES:[0-9]+$' <<< "$OUT"
r1="$(grep -o 'RSS:[0-9.]*' <<< "$OUT" | head -1 | cut -d: -f2)"; r3="$(grep -o 'RSS:[0-9.]*' <<< "$OUT" | tail -1 | cut -d: -f2)"
check "RSS 증가 감지 ($r1 → $r3 MB)" awk -v a="$r1" -v b="$r3" 'BEGIN { exit !(b > a + 15) }'
check "대상 PID 가 가짜 앱" grep -q "PID:$FAKE_PID " <<< "$OUT"
stop_fake
OUT="$("$ROOT/tools/monitor.sh" 2>&1)"; code=$?
check "프로세스 없음 → NOT_RUNNING, 종료 코드 1" bash -c '[[ $1 -eq 1 ]] && grep -q NOT_RUNNING <<< "$2"' _ "$code" "$OUT"

section "monitor.sh: 구간 CPU 실측 (ps %cpu 누적 평균과 다름)"
start_fake busy 2
OUT="$("$ROOT/tools/monitor.sh" --interval 1 2>&1)"
cpu="$(grep -o ' CPU:[0-9.]*' <<< "$OUT" | cut -d: -f2)"
check "바쁜 프로세스 CPU ≥ 70% (측정 $cpu%)" awk -v c="$cpu" 'BEGIN { exit !(c >= 70) }'
stop_fake

section "monitor.sh: --until-exit (프로세스 종료 시 GONE 후 종료)"
start_fake leak 0.5
( sleep 8; kill "$FAKE_PID" ) &
OUT="$(timeout 20 "$ROOT/tools/monitor.sh" --interval 1 --until-exit 2>&1)"; code=$?
check "종료 코드 0 (timeout 아님)" test "$code" -eq 0
check "마지막 줄 STATE:GONE" bash -c 'tail -n 1 <<< "$1" | grep -q STATE:GONE' _ "$OUT"

section "diagnose-hang.sh: 실제 교착 상태 판정"
start_fake deadlock 1.5
OUT="$("$ROOT/tools/diagnose-hang.sh" --pid "$FAKE_PID" --app-log "$TMP/deadlock.log" --window 2 2>&1)"
check "ps -ef 출력" grep -q 'ps -ef' <<< "$OUT"
check "ps -L 스레드 목록" grep -q 'ps -L' <<< "$OUT"
check "스레드 3개 (main + worker 2)" grep -q '스레드 3/3 개 sleep' <<< "$OUT"
check "CPU 0 · 로그 정지" grep -q '관측: CPU 사용 0 메모리 고정 로그 정지' <<< "$OUT"
check "보유/대기 관계 추출" bash -c 'grep -q "Worker-Thread-1 holds  Shared_Memory_A" <<< "$1" && grep -q "Worker-Thread-1 waits  Socket_Pool_B" <<< "$1"' _ "$OUT"
check "결론 DEADLOCK" grep -q '결론: DEADLOCK' <<< "$OUT"
stop_fake
start_fake busy 1.5
OUT="$("$ROOT/tools/diagnose-hang.sh" --pid "$FAKE_PID" --window 1 2>&1)"
check "바쁜 프로세스는 '진행 중'" grep -q '결론: 진행 중' <<< "$OUT"
stop_fake

section "analyze-schedule.sh: 알고리즘 판정 (보너스)"
OUT="$("$ROOT/tools/analyze-schedule.sh" "$ROOT/tests/fixtures/schedule-priority.log" "$ROOT/tests/fixtures/schedule-priority.log" 2>&1)"
check "B→C→A 고정 + 비선점 → Priority" grep -q 'VERDICT: 비선점 + 등록 순서와 다른 고정 순서' <<< "$OUT"
check "문맥 교환 2회" grep -q 'context switches : 2' <<< "$OUT"
OUT="$("$ROOT/tools/analyze-schedule.sh" "$ROOT/tests/fixtures/schedule-fcfs.log" 2>&1)"
check "등록 순서대로 연속 실행 → FCFS" grep -q 'VERDICT: 비선점 + 등록 순서대로 → FCFS' <<< "$OUT"
OUT="$("$ROOT/tools/analyze-schedule.sh" "$ROOT/tests/fixtures/schedule-rr.log" 2>&1)"
check "중간 교대 → Round-Robin" grep -q 'VERDICT: 선점이 관찰됨' <<< "$OUT"
check "선점 표시" grep -q 'no (선점' <<< "$OUT"

section "compare.sh"
mkdir -p "$TMP/ev/oom-before/r1" "$TMP/ev/oom-after/r1"
printf 'env           : MEMORY_LIMIT=256 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false\nsurvival      : 33s\nexit_code     : 137 (128 + SIGKILL)\nstatus        : exited\npeak_rss      : 267.6MB\nkey_lines     :\n  2026-10-12 22:31:35,852 [CRITICAL] [MemoryGuard] Self-terminating process 1\n' > "$TMP/ev/oom-before/r1/result.txt"
printf 'env           : MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false\nsurvival      : 300s (관찰 종료)\nexit_code     : 143\nstatus        : alive\npeak_rss      : 530MB\nkey_lines     :\n  x [INFO] [System] Memory Cache Flushed.\n' > "$TMP/ev/oom-after/r1/result.txt"
OUT="$("$ROOT/tools/compare.sh" "$TMP/ev/oom-before/r1" "$TMP/ev/oom-after/r1")"
check "Before 행 (33s, SIGKILL)" grep -q '| 256 | 50 | false | 33s | exit 137 (128 + SIGKILL) |' <<< "$OUT"
check "After 행 (생존)" grep -q '| 512 | 50 | false | 300s | 생존 (관찰 종료) |' <<< "$OUT"

printf '\n결과: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
