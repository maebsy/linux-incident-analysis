#!/usr/bin/env bash
# =============================================================================
#  apply-env.sh — 환경 파일의 변수를 바꾸고(백업 포함), 검증 실행 후 필요하면 되돌린다
#
#    apply-env.sh scenarios/cpu-before.env CPU_MAX_OCCUPY=50            # 백업 후 변경, 바뀐 줄 diff 출력
#    apply-env.sh scenarios/cpu-before.env CPU_MAX_OCCUPY=50 --dry-run  # 바꿀 내용만 출력 (파일은 그대로)
#    apply-env.sh scenarios/cpu-before.env CPU_MAX_OCCUPY=50 --verify 60
#                                                    # 변경 후 tools/run-scenario.sh 로 60초 검증 실행
#    apply-env.sh --rollback scenarios/cpu-before.env  # 가장 최근 백업(<파일>.bak-<시각>)으로 복원
#
#  절차: 적용(백업) → 검증(--verify) → 결과가 나쁘면 --rollback → 기록. 자세한 기준은 docs/runbook.md
#  운영 환경 파일(예: /etc/agent-app/agent-app.env)에도 같은 방식으로 쓸 수 있다. 앱은 재시작해야 새 값을 읽는다.
# =============================================================================
set -uo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
usage() { sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; }

if [[ "${1:-}" == --rollback ]]; then
    file="${2:-}"; [[ -f "$file" ]] || { echo "[ERROR] 파일이 없습니다: $file" >&2; exit 2; }
    backup="$(find "$(dirname "$file")" -maxdepth 1 -name "$(basename "$file").bak-*" | sort | tail -n 1)"
    [[ -n "$backup" ]] || { echo "[ERROR] 되돌릴 백업이 없습니다: $file.bak-*" >&2; exit 1; }
    diff -u --label "현재 $file" --label "복원 $backup" "$file" "$backup"
    cp -p "$backup" "$file" && rm -f "$backup"
    echo "[INFO] 복원 완료: $file ← $(basename "$backup") (사용한 백업은 삭제)"
    exit 0
fi

file="${1:-}"; shift || true
[[ -f "$file" ]] || { usage >&2; exit 2; }
assigns=(); DRY=0; VERIFY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        --verify) VERIFY="${2:-}"; shift ;;
        *=*) [[ "${1%%=*}" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "[ERROR] 변수 이름이 올바르지 않습니다: $1" >&2; exit 2; }
             assigns+=("$1") ;;
        *) echo "[ERROR] 알 수 없는 인자: $1" >&2; exit 2 ;;
    esac
    shift
done
[[ ${#assigns[@]} -gt 0 ]] || { usage >&2; exit 2; }

new="$(mktemp)"; trap 'rm -f "$new"' EXIT
cp "$file" "$new"
for kv in "${assigns[@]}"; do
    var="${kv%%=*}"; val="${kv#*=}"
    if grep -q "^$var=" "$new"; then
        awk -v k="$var" -v v="$val" 'index($0, k "=") == 1 { print k "=" v; next } { print }' "$new" > "$new.tmp" && mv "$new.tmp" "$new"
    else
        printf '%s=%s\n' "$var" "$val" >> "$new"
    fi
done
if cmp -s "$file" "$new"; then echo "[INFO] 바뀌는 내용이 없습니다: $file"; exit 0; fi
diff -u --label "변경 전 $file" --label "변경 후 $file" "$file" "$new"
if [[ $DRY -eq 1 ]]; then echo "[DRY] 파일은 바꾸지 않았습니다"; exit 0; fi

backup="$file.bak-$(date '+%Y%m%d-%H%M%S')"
cp -p "$file" "$backup" && cp "$new" "$file"
echo "[INFO] 적용 완료: $file (백업: $backup — 되돌리기: $0 --rollback $file)"

if [[ "$VERIFY" != 0 ]]; then
    [[ "$VERIFY" =~ ^[0-9]+$ ]] || { echo "[ERROR] --verify 는 초 단위 숫자" >&2; exit 2; }
    echo "[INFO] 검증 실행: tools/run-scenario.sh $file --max $VERIFY"
    "$ROOT/tools/run-scenario.sh" "$file" --max "$VERIFY"
    rc=$?
    echo "[INFO] 검증 결과 확인: status 가 alive(관찰 종료까지 생존)가 아니거나 Before 와 같은 종료 코드면 --rollback 하세요 (run-scenario 종료 코드 $rc)"
fi
