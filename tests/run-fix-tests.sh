#!/usr/bin/env bash
# 리포트의 코드 레벨 제안을 가짜 앱에 적용한 참고 구현 검증.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t lia-fix-test-XXXXXX)"
PASS=0; FAIL=0; PIDS=()
cleanup() {
    local p
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
    rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; if [[ -n "${OUT:-}" ]]; then sed -n '1,20s/^/       | /p' <<< "$OUT"; fi; }
check() { local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
section() { printf '\n[%s]\n' "$1"; }
FAKE="$TMP/fake-agent-leak-app.py"
cp "$ROOT/tests/fake-agent-leak-app.py" "$FAKE" || exit 1
export APP_PATTERN="$FAKE"
start_fake() { python3 "$FAKE" "$1" > "$TMP/$1.log" 2>&1 & FAKE_PID=$!; PIDS+=("$FAKE_PID"); sleep "${2:-1}"; }
stop_fake() { kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; PIDS=(); }

section "leak-bounded: 8초 RSS 관찰"
start_fake leak-bounded 0.2
OUT="$(timeout 20 bash "$ROOT/tools/monitor.sh" --pid "$FAKE_PID" --interval 1 --count 8 --app-log "$TMP/leak-bounded.log" 2>&1)"; code=$?
check "monitor 종료 코드 0" test "$code" -eq 0
check "대상 PID의 RSS 표본 8개" test "$(grep -c "PID:$FAKE_PID .*RSS:[0-9]" <<< "$OUT")" -eq 8
check "마지막 RSS 50~100MB, 후반 4개 표본 변동 ≤15MB" awk '
    /PROCESS:/ {
        for (i=1; i<=NF; i++) if ($i ~ /^RSS:[0-9]+([.][0-9]+)?MB$/) {
            value=$i; sub(/^RSS:/, "", value); sub(/MB$/, "", value); rss[++n]=value+0
        }
    }
    END {
        if (n != 8) exit 1
        lo=rss[5]; hi=lo
        for (i=6; i<=8; i++) { if (rss[i]<lo) lo=rss[i]; if (rss[i]>hi) hi=rss[i] }
        exit !(rss[8]>=50 && rss[8]<=100 && hi-lo<=15)
    }' <<< "$OUT"
check "보관 상한 5개/50MB 도달 및 유지" awk '
    /Retained:/ {
        n++; if ($6 !~ /^[1-5]$/ || $10 != $6*10 "MB") invalid=1
        if ($6 == 5 && $10 == "50MB") bounded++
    }
    END { exit !(n>=20 && bounded>=10 && !invalid) }' "$TMP/leak-bounded.log"
stop_fake

for mode in deadlock-ordered deadlock-timeout; do
    section "$mode: 진행 및 진단"
    start_fake "$mode" 3
    app_log="$TMP/$mode.log"
    OUT=""
    if [[ "$mode" == deadlock-timeout ]]; then
        check "TIMEOUT 후 retry 기록" grep -q 'TIMEOUT.*retry' "$app_log"
    fi
    before="$(wc -l < "$app_log")"
    p1="$(grep -c '\[Worker-Thread-1\] PROGRESS:' "$app_log")"
    p2="$(grep -c '\[Worker-Thread-2\] PROGRESS:' "$app_log")"
    OUT="$(timeout 15 bash "$ROOT/tools/diagnose-hang.sh" --pid "$FAKE_PID" --app-log "$app_log" --window 2 --no-stack 2>&1)"; code=$?
    check "diagnose 종료 코드 0" test "$code" -eq 0
    check "진단: 진행 중" grep -q '^결론: 진행 중' <<< "$OUT"
    check "진단: DEADLOCK 아님" test "$(grep -c '^결론: DEADLOCK' <<< "$OUT")" -eq 0
    check "로그 줄 수 증가" test "$(wc -l < "$app_log")" -gt "$before"
    check "Worker-Thread-1 작업 진행 증가" test "$(grep -c '\[Worker-Thread-1\] PROGRESS:' "$app_log")" -gt "$p1"
    check "Worker-Thread-2 작업 진행 증가" test "$(grep -c '\[Worker-Thread-2\] PROGRESS:' "$app_log")" -gt "$p2"
    stop_fake
done
printf '\n결과: PASS %d, FAIL %d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
