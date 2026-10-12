#!/usr/bin/env bash
# =============================================================================
#  publish-issues.sh — issues/*.md 를 GitHub Issue 로 등록 (같은 제목이 있으면 건너뜀)
#
#    tools/publish-issues.sh                 # 등록
#    DRY_RUN=1 tools/publish-issues.sh       # 등록할 제목·라벨·본문 첫 줄만 출력
#
#  - front matter 의 title / labels 를 그대로 쓰고, 없는 라벨은 만든다
#  - 저장소 안 상대 링크(../evidence/…)는 Issue 화면에서 열리도록 blob URL 로 바꾼다
#  - gh CLI 인증 필요 (gh auth login). REST API 만 사용
# =============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${REPO:-$(cd "$ROOT" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo maebsy/linux-incident-analysis)}"
BRANCH="${BRANCH:-main}"
BLOB="https://github.com/$REPO/blob/$BRANCH"

declare -A COLOR=([bug]=d73a4a [incident]=b60205 [memory]=5319e7 [cpu]=fbca04 [deadlock]=0e8a16 [analysis]=1d76db)
declare -A DESC=([incident]="장애 리포트" [memory]="메모리 / OOM" [cpu]="CPU 과점유" [deadlock]="교착 상태" [analysis]="동작 분석 리포트")

front() { awk -v k="$2" 'NR == 1 && $0 == "---" { f = 1; next } f && $0 == "---" { exit } f && index($0, k ": ") == 1 { sub(k ": ", ""); gsub(/^"|"$/, ""); print }' "$1"; }
body() {
    awk 'n >= 2; $0 == "---" { n++ }' "$1" |
        sed -E "s#\]\(\.\./docs/images/([^)]+)\)#](${BLOB}/docs/images/\1?raw=true)#g; s#\]\(\.\./#](${BLOB}/#g"
}

existing="$(gh api "repos/$REPO/issues?state=all&per_page=100" --jq '.[].title' 2>/dev/null || true)"
existing_labels="$(gh api "repos/$REPO/labels?per_page=100" --jq '.[].name' 2>/dev/null || true)"

for f in "$ROOT"/issues/*.md; do
    title="$(front "$f" title)"; labels="$(front "$f" labels)"
    [[ -n "$title" ]] || { echo "[SKIP] title 없음: $f"; continue; }
    if grep -qxF -- "$title" <<< "$existing"; then echo "[SKIP] 이미 있음: $title"; continue; fi
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
        echo "[DRY] $title  labels=[$labels]"; body "$f" | sed -n '1,3p'; continue
    fi
    args=()
    IFS=',' read -ra arr <<< "$labels"
    for l in "${arr[@]}"; do
        l="${l// /}"; [[ -n "$l" ]] || continue
        if ! grep -qxF -- "$l" <<< "$existing_labels"; then
            gh api "repos/$REPO/labels" -f name="$l" -f color="${COLOR[$l]:-ededed}" -f description="${DESC[$l]:-}" > /dev/null
            existing_labels+=$'\n'"$l"
        fi
        args+=(-f "labels[]=$l")
    done
    url="$(gh api "repos/$REPO/issues" -f title="$title" -f body="$(body "$f")" "${args[@]}" --jq .html_url)"
    echo "[OK] $url  ← $(basename "$f")"
done
