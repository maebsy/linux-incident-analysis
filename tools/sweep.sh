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
#  값별 실행 수 · 종료/생존 · 생존 시간(최소/중앙/최대 · 평균 ± 표준편차) · 종료 코드 · DEADLOCK 판정 수 · 종료 직전 부하를 모은다.
#  실행마다 바뀔 수 있는 조건(바이너리 sha256, 커널, CPU/메모리 제한, 이미지 ID, 커밋, 시각)은 env-<변수>=<값>-<시각>-<pid>.txt 에 남긴다.
#  ※ 관찰 종료(--max)까지 살아 있던 실행의 생존 시간은 --max 로 잘린 값이라 평균·표준편차는 "종료된 실행" 만 따로 계산한다.
# =============================================================================
set -uo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPEAT=3; MAX=120; OUT=""; PASS_ARGS=()
summarize() {   # $1 = 결과 루트 → 마크다운 표
    local base="$1" d f n died alive dl surv codes loads
    printf '| 조건 | 실행 | 종료 | 관찰 종료까지 생존 | DEADLOCK 판정 | 생존 시간 최소 / 중앙 / 최대 | 종료된 실행의 평균 ± 표준편차 | 종료 코드 | 종료 직전 Current Load (마지막 값) |\n'
    printf '| --- | ---: | ---: | ---: | ---: | --- | --- | --- | --- |\n'
    for d in "$base"/*/; do
        [[ -d "$d" ]] || continue
        n=0; died=0; alive=0; dl=0; surv=(); dsurv=(); codes=(); loads=()
        for f in "$d"*/result.txt; do
            [[ -r "$f" ]] || continue
            n=$((n + 1))
            grep -q '^status *: alive' "$f" && alive=$((alive + 1)) || died=$((died + 1))
            grep -q '결론: DEADLOCK' "$(dirname "$f")/diagnose.txt" 2>/dev/null && dl=$((dl + 1))
            surv+=("$(grep -m1 '^survival' "$f" | grep -oE '[0-9]+s' | head -1 | tr -d s)")
            grep -q '^status *: alive' "$f" || { codes+=("$(grep -m1 '^exit_code' "$f" | awk '{print $3}')"); dsurv+=("${surv[-1]}"); }
            loads+=("$(grep -m1 '^last_loads' "$f" | cut -d'(' -f1 | grep -o '[0-9.]*%' | tail -n 1)")
        done
        [[ $n -eq 0 ]] && continue
        read -r mn md mx < <(printf '%s\n' "${surv[@]}" | sort -n | awk '{a[NR]=$1} END {print a[1], a[int((NR+1)/2)], a[NR]}')
        stat="-"
        [[ ${#dsurv[@]} -gt 0 ]] && stat="$(printf '%s\n' "${dsurv[@]}" | awk '{s+=$1; q+=$1*$1; n++} END {m=s/n; v=(n>1)?(q-n*m*m)/(n-1):0; printf "%.1fs ± %.1fs (n=%d)", m, sqrt(v>0?v:0), n}')"
        printf '| `%s` | %d | %d | %d | %d | %ss / %ss / %ss | %s | %s | %s |\n' "$(basename "$d" | sed 's/^[^_]*_//')" "$n" "$died" "$alive" "$dl" \
            "$mn" "$md" "$mx" "$stat" "$(printf '%s\n' "${codes[@]}" | grep . | sort | uniq -c | awk '{printf "%s×%s ", $2, $1}')" \
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
# 재현성: 이 반복 실험을 다시 만들 때 필요한 고유값을 남긴다 (앱 자체에는 난수 seed 를 줄 방법이 없다)
{
    set -a; # shellcheck disable=SC1091
    source "$ROOT/tools/env/base.env"; set +a
    bin="${APP_BIN:-$AGENT_HOME/agent-leak-app-x86}"
    echo "date          : $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "command       : sweep.sh $(basename "$SCENARIO") $VAR ${VALUES[*]} --repeat $REPEAT --max $MAX"
    echo "binary        : $bin"
    echo "binary_sha256 : $(sha256sum "$bin" 2>/dev/null | cut -d' ' -f1)"
    echo "kernel        : $(uname -srm)"
    echo "nproc         : $(nproc)  (cgroup cpu.max: $(cat /sys/fs/cgroup/cpu.max 2>/dev/null || echo -))"
    echo "memory        : $(awk '/^MemTotal:/ {printf "%.1f GiB", $2/1048576}' /proc/meminfo) host  (cgroup memory.max: $(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo -))"
    echo "image         : ${LIA_IMAGE_ID:--}"
    echo "git_commit    : ${LIA_GIT_COMMIT:--}"
    echo "user          : $(id -un) (uid $(id -u))"
    echo "seed          : 없음 — 앱이 난수 seed 를 받지 않는다(외부 설정은 환경변수 3개뿐). 같은 조건 = 위 값 + 시나리오 파일"
} > "$OUT/env-${VAR}=$(IFS=_; echo "${VALUES[*]}")-$(date +%H%M%S)-$$.txt" 2>&1
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
