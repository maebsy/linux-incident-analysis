#!/usr/bin/env bash
# =============================================================================
#  latency-probe.sh — 같은 시스템의 "다른 프로세스" 가 느려지는지 재는 탐침
#
#    latency-probe.sh --duration 40 --out probe.csv [--label baseline]
#
#  0.5초마다 두 가지를 잰다 (장애 프로세스가 CPU 를 실제로 점유하면 둘 다 늘어난다)
#    http_ms  : 같은 머신의 작은 웹 서버(python3 -m http.server)에 curl 요청 1회 왕복 시간
#    sched_ms : sleep 0.1 이 실제로 걸린 시간 - 100ms (깨어나 CPU 를 다시 받기까지의 지연)
#  끝나면 p50 / p95 / max 를 출력한다.
# =============================================================================
set -uo pipefail
export LC_ALL=C
DUR=30; OUT=/dev/stdout; LABEL=probe; PORT="${PROBE_PORT:-18080}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration) DUR="$2"; shift ;;
        --out) OUT="$2"; shift ;;
        --label) LABEL="$2"; shift ;;
        *) echo "[ERROR] 알 수 없는 옵션: $1" >&2; exit 2 ;;
    esac
    shift
done
srv_dir="$(mktemp -d)"; echo ok > "$srv_dir/index.html"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$srv_dir" >/dev/null 2>&1 & srv=$!
trap 'kill "$srv" 2>/dev/null; rm -rf "$srv_dir"' EXIT
for _ in $(seq 1 20); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.2; done
echo "ts,label,http_ms,sched_ms" > "$OUT"
end=$(( $(date +%s) + DUR ))
while (( $(date +%s) < end )); do
    http="$(curl -s -o /dev/null -w '%{time_total}' "http://127.0.0.1:$PORT/" | awk '{printf "%.2f", $1 * 1000}')"
    t0="$(date +%s%N)"; sleep 0.1; t1="$(date +%s%N)"
    printf '%s,%s,%s,%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LABEL" "$http" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", (b-a)/1e6 - 100}')" >> "$OUT"
    sleep 0.4
done
[[ "$OUT" == /dev/stdout ]] && exit 0
awk -F, 'NR > 1 { h[++n] = $3; s[n] = $4 }
  function pct(a, n, p,   i, j, t, b) { for (i = 1; i <= n; i++) b[i] = a[i]
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (b[j] < b[i]) { t = b[i]; b[i] = b[j]; b[j] = t }
      return b[int((n - 1) * p) + 1] }
  END { printf "%s  samples=%d  http_ms p50=%.2f p95=%.2f max=%.2f  sched_ms p50=%.2f p95=%.2f max=%.2f\n",
        FILENAME, n, pct(h, n, .5), pct(h, n, .95), pct(h, n, 1), pct(s, n, .5), pct(s, n, .95), pct(s, n, 1) }' "$OUT"
