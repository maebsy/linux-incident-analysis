#!/usr/bin/env bash
# Before/After 비교표: 여러 실행의 result.txt 를 한 표로 모은다.
#   tools/compare.sh evidence/oom-before/* evidence/oom-after/*
set -uo pipefail
printf '| 실행 | MEMORY_LIMIT | CPU_MAX_OCCUPY | MULTI_THREAD | 생존 시간 | 종료 | 최대 RSS | 마지막 핵심 로그 |\n'
printf '| --- | --- | --- | --- | --- | --- | --- | --- |\n'
for dir in "$@"; do
    f="$dir/result.txt"; [[ -r "$f" ]] || continue
    get() { grep -m1 "^$1" "$f" | cut -d: -f2- | sed 's/^ *//'; }
    env="$(get env)"
    m="$(grep -o 'MEMORY_LIMIT=[^ ]*' <<< "$env" | cut -d= -f2)"
    c="$(grep -o 'CPU_MAX_OCCUPY=[^ ]*' <<< "$env" | cut -d= -f2)"
    t="$(grep -o 'MULTI_THREAD_ENABLE=[^ ]*' <<< "$env" | cut -d= -f2)"
    status="$(get status)"; code="$(get exit_code)"
    [[ "$status" == alive ]] && end="생존 (관찰 종료)" || end="exit $code"
    key="$(sed -n '/^key_lines/,$p' "$f" | tail -n 1 | sed 's/^ *//; s/^[0-9-]* [0-9:,]* //; s/|/\\|/g' | cut -c1-70)"
    printf '| `%s` | %s | %s | %s | %s | %s | %s | %s |\n' "$(basename "$(dirname "$dir")")/$(basename "$dir")" "$m" "$c" "$t" \
        "$(get survival | cut -d' ' -f1)" "$end" "$(get peak_rss)" "$key"
done
