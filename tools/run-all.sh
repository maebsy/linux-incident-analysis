#!/usr/bin/env bash
# 리포트에 쓰인 모든 실행을 순서대로 재현한다 (약 20분). 포트 15034 를 쓰므로 한 번에 하나씩 실행한다.
#   sudo -iu agent-admin bash -c 'cd <repo> && tools/run-all.sh'
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
R=tools/run-scenario.sh
run() { echo; echo "################ $* ################"; "$R" "$@"; sleep 3; }

run scenarios/oom-before.env --max 120
run scenarios/oom-before.env --max 120 --trace
run scenarios/oom-128.env --max 120
run scenarios/oom-after.env --max 300

run scenarios/cpu-before.env --max 120
run scenarios/cpu-before.env --max 120 --trace
run scenarios/cpu-60.env --max 120
run scenarios/cpu-after.env --max 180

run scenarios/deadlock-before.env --max 90
run scenarios/deadlock-after.env --max 120

# [보너스] 스케줄링 추론용: 정상 모드 시작 직후 Scheduler 로그를 5회 수집
for _ in 1 2 3 4 5; do run scenarios/cpu-after.env --max 8 --out evidence/schedule-runs; done

# 분석 결과 정리
tools/analyze-schedule.sh evidence/schedule-runs/cpu-after/*/app.log \
    evidence/oom-after/*/app.log evidence/cpu-after/*/app.log evidence/deadlock-after/*/app.log \
    > evidence/schedule-runs/analysis.txt
tools/compare.sh evidence/oom-before/* evidence/oom-128/* evidence/oom-after/* \
    evidence/cpu-before/* evidence/cpu-60/* evidence/cpu-after/* \
    evidence/deadlock-before/* evidence/deadlock-after/* > evidence/summary.md
# 그래프 (선택, matplotlib 필요) — 리포트의 docs/images/*.png
command -v python3 >/dev/null && python3 tools/plot-evidence.py || true
