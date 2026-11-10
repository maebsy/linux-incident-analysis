#!/usr/bin/env bash
# =============================================================================
#  sweep.sh — 환경변수 하나를 여러 값으로 바꿔 시나리오를 반복 실행하고 요약표를 만든다
#
#    sweep.sh scenarios/cpu-before.env CPU_MAX_OCCUPY 50 51 60 90 --repeat 3 --max 120
#    sweep.sh scenarios/deadlock-before.env MULTI_THREAD_ENABLE true false --repeat 10 --max 40
#    sweep.sh --summary evidence/followup/sweep-cpu      # 이미 끝난 실행들만 다시 요약
#
#  값마다 시나리오 파일을 복사해 그 변수만 바꾼 env 를 만들고(<시나리오>_<변수>=<값>.env),
#  tools/run-scenario.sh 를 --repeat 번 실행한다. 결과 폴더 아래 summary.md 에
#  값별 실행 수 · 종료/생존 · 생존 시간(최소/중앙/최대) · 종료 코드 · DEADLOCK 판정 수 · 종료 직전 부하를 모은다.
# =============================================================================
set -uo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPEAT=3; MAX=120; OUT=""; PASS_ARGS=()
summarize() {   # $1 = 결과 루트 → 마크다운 표
    local base="$1" d f n died alive dl surv codes loads
    printf '| 조건 | 실행 | 종료 | 관찰 종료까지 생존 | DEADLOCK 판정 | 생존 시간 최소 / 중앙 / 최대 | 종료 코드 | 종료 직전 Current Load (마지막 값) |\n'
    printf '| --- | ---: | ---: | ---: | ---: | --- | --- | --- |\n'
    for d in "$base"/*/; do
        [[ -d "$d" ]] || continue
        n=0; died=0; alive=0; dl=0; surv=(); codes=(); loads=()
        for f in "$d"*/result.txt; do
            [[ -r "$f" ]] || continue
            n=$((n + 1))
            grep -q '^status *: alive' "$f" && alive=$((alive + 1)) || died=$((died + 1))
            grep -q '결론: DEADLOCK' "$(dirname "$f")/diagnose.txt" 2>/dev/null && dl=$((dl + 1))
            surv+=("$(grep -m1 '^survival' "$f" | grep -oE '[0-9]+s' | head -1 | tr -d s)")
            grep -q '^status *: alive' "$f" || codes+=("$(grep -m1 '^exit_code' "$f" | awk '{print $3}')")
            loads+=("$(grep -m1 '^last_loads' "$f" | cut -d'(' -f1 | grep -o '[0-9.]*%' | tail -n 1)")
        done
        [[ $n -eq 0 ]] && continue
        read -r mn md mx < <(printf '%s\n' "${surv[@]}" | sort -n | awk '{a[NR]=$1} END {print a[1], a[int((NR+1)/2)], a[NR]}')
        printf '| `%s` | %d | %d | %d | %d | %ss / %ss / %ss | %s | %s |\n' "$(basename "$d" | sed 's/^[^_]*_//')" "$n" "$died" "$alive" "$dl" \
            "$mn" "$md" "$mx" "$(printf '%s\n' "${codes[@]}" | grep . | sort | uniq -c | awk '{printf "%s×%s ", $2, $1}')" \
            "$(printf '%s ' "${loads[@]}" | tr -s ' ')"
    done
}
if [[ "${1:-}" == --summary ]]; then summarize "$2"; exit 0; fi
SCENARIO="${1:-}"; VAR="${2:-}"; shift 2 || true
VALUES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repeat) REPEAT="$2"; shift ;;
        --max) MAX="$2"; shift ;;
        --out) OUT="$2"; shift ;;
        --interval|--trace) PASS_ARGS+=("$1"); [[ "$1" == --interval ]] && { PASS_ARGS+=("$2"); shift; } ;;
        --*) echo "[ERROR] 알 수 없는 옵션: $1" >&2; exit 2 ;;
        *) VALUES+=("$1") ;;
    esac
    shift
done
[[ -f "$SCENARIO" && -n "$VAR" && ${#VALUES[@]} -gt 0 ]] || { sed -n '3,6p' "$0" | sed 's/^# *//'; exit 2; }
grep -q "^$VAR=" "$SCENARIO" "$ROOT/tools/env/base.env" 2>/dev/null || echo "[WARN] $VAR 가 시나리오에 없어 새로 추가합니다" >&2
name="$(basename "$SCENARIO" .env)"
OUT="${OUT:-$ROOT/evidence/sweep-$name-$(date '+%Y%m%d-%H%M%S')}"
mkdir -p "$OUT/env"
for v in "${VALUES[@]}"; do
    env_file="$OUT/env/${name}_${VAR}=${v}.env"
    { grep -v "^$VAR=" "$SCENARIO"; echo "$VAR=$v"; } > "$env_file"
    for i in $(seq 1 "$REPEAT"); do
        echo "[INFO] $VAR=$v  실행 $i/$REPEAT"
        "$ROOT/tools/run-scenario.sh" "$env_file" --max "$MAX" --out "$OUT" "${PASS_ARGS[@]}" > /dev/null
        sleep 1   # 실행 폴더 이름(초 단위 시각)이 겹치지 않도록
    done
done
summarize "$OUT" | tee "$OUT/summary.md"
