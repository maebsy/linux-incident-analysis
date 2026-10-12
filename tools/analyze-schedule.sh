#!/usr/bin/env bash
# =============================================================================
#  analyze-schedule.sh — [보너스] 로그 타임스탬프로 스케줄링 알고리즘 역추론
#
#    analyze-schedule.sh evidence/schedule-runs/*/app.log
#
#  각 실행 로그에서 [Scheduler] Registered Tasks 와 [Thread-X] … (NN%) 줄을 뽑아
#    1) 타임라인: 시각(ms) · 스레드 · 진행률 · 이전 줄과의 간격
#    2) 실행 순서 / 문맥 교환(스레드가 바뀐 횟수) / 스레드별 연속 실행 여부
#    3) 판정 근거: 선점(중간에 끼어들기) 여부, 등록 순서와 실행 순서의 일치 여부, 실행 간 순서 고정 여부
#  를 출력한다. 판정 규칙
#    - 한 스레드가 100% 전에 다른 스레드가 실행됨(교환 > 스레드 수-1)  → 선점형 → Round-Robin 후보
#    - 모두 끝까지 연속 실행 + 실행 순서 = 등록 순서                    → FCFS
#    - 모두 끝까지 연속 실행 + 실행 순서 ≠ 등록 순서 + 여러 번 실행해도 같음 → (비선점) Priority
# =============================================================================
set -uo pipefail
export LC_ALL=C
[[ $# -gt 0 ]] || { echo "사용법: $0 <app.log> [app.log ...]" >&2; exit 2; }

orders=()
for log in "$@"; do
    [[ -r "$log" ]] || { echo "[WARN] 읽을 수 없음: $log" >&2; continue; }
    echo "=================================================================="
    echo "log: $log"
    registered="$(grep -a "Registered Tasks" "$log" | sed -E "s/.*\[(.*)\].*/\1/; s/'//g; s/, /,/g")"
    echo "registered order : ${registered:-(없음)}"
    result="$(grep -aE '\[Thread-[A-Z]\] .*\([0-9]+%\)' "$log" | awk -v reg="$registered" '
        function ms(ts,   a, b) { split(ts, a, ":"); split(a[3], b, ","); return ((a[1] * 60 + a[2]) * 60 + b[1]) * 1000 + b[2] }
        {
            t = ms($2)
            th = $0; sub(/^.*\[Thread-/, "", th); th = "Thread-" substr(th, 1, 1)
            pct = $0; sub(/^.*\(/, "", pct); sub(/%\).*$/, "", pct)
            n++; T[n] = t; TH[n] = th; P[n] = pct; RAW[n] = $2
            if (!(th in first)) { first[th] = n; order = order (order == "" ? "" : ",") th; k++ }
            last[th] = n
            if (n > 1 && TH[n - 1] != th) switches++
        }
        END {
            if (n == 0) { print "NO_DATA"; exit }
            printf "%-14s %-9s %5s %8s\n", "time", "thread", "pct", "gap(ms)"
            for (i = 1; i <= n; i++) printf "%-14s %-9s %4s%% %8s%s\n", RAW[i], TH[i], P[i], (i > 1 ? T[i] - T[i - 1] : "-"), (i > 1 && TH[i] != TH[i - 1] ? "   <- switch" : "")
            contiguous = 1
            for (th in first) for (i = first[th]; i <= last[th]; i++) if (TH[i] != th) contiguous = 0
            printf "\nexecution order  : %s\n", order
            printf "context switches : %d (threads %d → 연속 실행이면 %d)\n", switches, k, k - 1
            printf "each runs to 100%% before next : %s\n", contiguous ? "yes (비선점)" : "no (선점: 다른 스레드가 끼어듦)"
            for (th in first) printf "  %s: %s ~ %s (%d ms, %d steps)\n", th, RAW[first[th]], RAW[last[th]], T[last[th]] - T[first[th]], last[th] - first[th] + 1
            printf "ORDER=%s\nPREEMPTIVE=%d\nMATCH_REGISTERED=%d\n", order, !contiguous, (order == reg)
        }')"
    if [[ "$result" == NO_DATA ]]; then echo "(Thread-X 실행 로그 없음)"; continue; fi
    grep -v -E '^(ORDER|PREEMPTIVE|MATCH_REGISTERED)=' <<< "$result"
    orders+=("$(grep '^ORDER=' <<< "$result" | cut -d= -f2)|$(grep '^PREEMPTIVE=' <<< "$result" | cut -d= -f2)|$(grep '^MATCH_REGISTERED=' <<< "$result" | cut -d= -f2)")
done

[[ ${#orders[@]} -gt 0 ]] || exit 1
echo "=================================================================="
echo "SUMMARY (${#orders[@]} runs)"
printf '%s\n' "${orders[@]}" | awk -F'|' '{ printf "  run %d: order=%s preemptive=%s same_as_registered=%s\n", NR, $1, ($2 ? "yes" : "no"), ($3 ? "yes" : "no") }'
distinct="$(printf '%s\n' "${orders[@]}" | cut -d'|' -f1 | sort -u | wc -l)"
preempt="$(printf '%s\n' "${orders[@]}" | cut -d'|' -f2 | grep -c 1)"
match="$(printf '%s\n' "${orders[@]}" | cut -d'|' -f3 | grep -c 1)"
echo "  distinct orders: $distinct / preemptive runs: $preempt / runs matching registration: $match"
if [[ $preempt -gt 0 ]]; then
    echo "VERDICT: 선점이 관찰됨 → Round-Robin(시간 할당 후 교대) 계열"
elif [[ $match -eq ${#orders[@]} ]]; then
    echo "VERDICT: 비선점 + 등록 순서대로 → FCFS"
elif [[ $distinct -eq 1 ]]; then
    echo "VERDICT: 비선점 + 등록 순서와 다른 고정 순서가 매번 반복 → Priority(비선점, 우선순위 순)"
else
    echo "VERDICT: 비선점이지만 순서가 실행마다 달라짐 → 고정 우선순위가 아님 (도착 순서/무작위 등 추가 분석 필요)"
fi
