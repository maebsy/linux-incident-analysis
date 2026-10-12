#!/usr/bin/env python3
"""evidence/ 의 원본 로그로 리포트용 그래프를 만든다 (분석에는 쓰지 않는 보조 도구).

    python3 tools/plot-evidence.py            # → docs/images/*.png

분석·판정은 bash 도구(monitor.sh, diagnose-hang.sh, analyze-schedule.sh)가 하고,
이 스크립트는 그 결과 로그를 사람이 한눈에 보도록 시각화만 한다. 값은 가공하지 않는다.
"""
from __future__ import annotations

import re
import sys
from datetime import datetime
from pathlib import Path

try:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import font_manager
except ImportError:  # pragma: no cover
    sys.exit("matplotlib 이 필요합니다: pip install matplotlib")

ROOT = Path(__file__).resolve().parent.parent
EV = ROOT / "evidence"
OUT = ROOT / "docs" / "images"

MON = re.compile(r"^\[(?P<ts>[\d-]+ [\d:]+)\] .*?\bCPU:(?P<cpu>[\d.]+)% .*?RSS:(?P<rss>[\d.]+)MB .*?LOG_LINES:(?P<lines>\d+)")
APP = re.compile(r"^(?P<ts>[\d-]+ [\d:]+),(?P<ms>\d{3}) \[\w+\] (?P<msg>.*)$")


def font() -> None:
    for name in ("Noto Sans CJK KR", "Noto Sans CJK JP", "NanumGothic", "Malgun Gothic"):
        if any(f.name == name for f in font_manager.fontManager.ttflist):
            plt.rcParams["font.family"] = name
            break
    plt.rcParams["axes.unicode_minus"] = False
    plt.rcParams["figure.dpi"] = 110


def ts(s: str, ms: str = "0") -> float:
    return datetime.strptime(s, "%Y-%m-%d %H:%M:%S").timestamp() + int(ms) / 1000


def start_of(run: Path) -> float:
    for line in (run / "result.txt").read_text(encoding="utf-8").splitlines():
        if line.startswith("start"):
            return ts(line.split(":", 1)[1].strip())
    raise ValueError(run)


def monitor(run: Path):
    t0, rows = start_of(run), []
    for line in (run / "monitor.log").read_text(encoding="utf-8", errors="replace").splitlines():
        m = MON.match(line)
        if m:
            rows.append((ts(m["ts"]) - t0, float(m["cpu"]), float(m["rss"]), int(m["lines"])))
    return rows


def app_events(run: Path, pattern: str):
    t0, rows, rx = start_of(run), [], re.compile(pattern)
    for line in (run / "app.log").read_text(encoding="utf-8", errors="replace").splitlines():
        m = APP.match(line)
        if m and (k := rx.search(m["msg"])):
            rows.append((ts(m["ts"], m["ms"]) - t0, k))
    return rows


def run_dir(*parts: str) -> Path:
    """리포트가 인용한 실행 폴더. 직접 재실행해 그 폴더가 없으면 같은 시나리오의 가장 최근 실행을 쓴다."""
    path = EV.joinpath(*parts)
    if path.is_dir():
        return path
    runs = sorted(d for d in path.parent.glob("2*") if (d / "result.txt").is_file())
    if not runs:
        sys.exit(f"증거 폴더 없음: {path.parent}")
    return runs[-1]


def plot_oom() -> Path:
    fig, ax = plt.subplots(figsize=(9, 4.2))
    for label, run, style, lw in (
        ("MEMORY_LIMIT=512 (After) → 생존, 한도 도달 시 회수", run_dir("oom-after", "20261012-223240"), "C2-", 1.6),
        ("MEMORY_LIMIT=256 (Before) → 33s 종료", run_dir("oom-before", "20261012-223103"), "C3-", 2.6),
        ("MEMORY_LIMIT=128 → 18s 종료", run_dir("oom-128", "20261012-223217"), "C1-", 2.6),
    ):
        rows = [r for r in monitor(run) if r[0] <= 200]
        ax.plot([r[0] for r in rows], [r[2] for r in rows], style, lw=lw, label=label)
        if "종료" in label:
            ax.plot(rows[-1][0], rows[-1][2], "x", color=style[:2], ms=9, mew=2.5)
    for y, c in ((128, "C1"), (256, "C3"), (512, "C2")):
        ax.axhline(y, color=c, lw=0.8, ls=":", alpha=0.7)
        ax.text(201, y, f"{y}MB", va="center", fontsize=8, color=c)
    ax.set(title="OOM — 프로세스 RSS 추이 (monitor.sh, 2초 간격)", xlabel="실행 후 경과 (초)", ylabel="RSS (MB)", xlim=(0, 200))
    ax.grid(alpha=0.3)
    ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.16), ncol=3, fontsize=8, frameon=False)
    return save(fig, "oom-rss.png")


def plot_cpu() -> Path:
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.2), sharey=True)
    for ax, (title, run, xmax) in zip(axes, (
        ("Before: CPU_MAX_OCCUPY=90 → 37s 에 SIGTERM", run_dir("cpu-before", "20261012-223757"), 40),
        ("After: CPU_MAX_OCCUPY=50 → 180s 생존", run_dir("cpu-after", "20261012-223936"), 180),
    )):
        load = [(t, float(m[1])) for t, m in app_events(run, r"\[CpuWorker\] Current Load: ([\d.]+)%") if t <= xmax]
        os_cpu = [(r[0], r[1]) for r in monitor(run) if r[0] <= xmax]
        ax.plot([x for x, _ in load], [y for _, y in load], "C1-o", ms=3, lw=1.6, label="앱 로그 Current Load (앱 내부 지표)")
        ax.plot([x for x, _ in os_cpu], [y for _, y in os_cpu], "C0-", lw=1.2, label="OS 실측 프로세스 CPU (/proc stat Δ)")
        ax.axhline(50, color="C3", ls="--", lw=1)
        ax.text(1, 51.5, "Watchdog 임계치 50%", color="C3", fontsize=8)
        for t, _ in app_events(run, r"CPU Threshold Violated"):
            ax.axvline(t, color="C3", lw=1.2)
            ax.text(t - 0.5, 60, "SIGTERM", color="C3", fontsize=8, ha="right")
        ax.set(title=title, xlabel="실행 후 경과 (초)", xlim=(0, xmax), ylim=(0, 65))
        ax.grid(alpha=0.3)
    axes[0].set_ylabel("CPU (%)")
    axes[1].legend(loc="upper right", fontsize=8)
    fig.suptitle("CPU — 앱 부하 지표 vs OS 실측", fontsize=11)
    return save(fig, "cpu-load.png")


def plot_deadlock() -> Path:
    fig, ax = plt.subplots(figsize=(9, 4.2))
    for label, run, c in (
        ("MULTI_THREAD_ENABLE=true (Before)", run_dir("deadlock-before", "20261012-224253"), "C3"),
        ("MULTI_THREAD_ENABLE=false (After)", run_dir("deadlock-after", "20261012-224440"), "C2"),
    ):
        rows = monitor(run)
        ax.plot([r[0] for r in rows], [r[3] for r in rows], color=c, lw=1.8, label=label + " — 로그 줄 수")
    ax.annotate("22:43:02 WAITING… (BLOCKED) 이후\n로그 42줄에서 정지", xy=(12, 42), xytext=(30, 47),
                arrowprops={"arrowstyle": "->", "color": "C3"}, color="C3", fontsize=8)
    ax.set(title="Deadlock — 앱 로그 진행 (monitor.sh LOG_LINES)", xlabel="실행 후 경과 (초)", ylabel="로그 줄 수")
    ax.grid(alpha=0.3)
    ax.legend(loc="upper left", fontsize=8)
    return save(fig, "deadlock-progress.png")


def plot_schedule() -> Path:
    run = run_dir("schedule-runs", "cpu-after", "20261012-224828")
    events = app_events(run, r"\[(Thread-[ABC])\] (Task Started|Calculating|Task Completed)")
    spans: dict[str, list[float]] = {}
    for t, m in events:
        spans.setdefault(m[1], []).append(t)
    t0 = min(v[0] for v in spans.values())
    fig, ax = plt.subplots(figsize=(9, 2.6))
    order = ["Thread-A", "Thread-B", "Thread-C"]
    for i, name in enumerate(order):
        ts_ = [t - t0 for t in spans.get(name, [])]
        if not ts_:
            continue
        ax.broken_barh([(ts_[0] * 1000, (ts_[-1] - ts_[0]) * 1000 + 50)], (i - 0.35, 0.7), color=f"C{i}")
        ax.plot([t * 1000 for t in ts_], [i] * len(ts_), "k|", ms=12)
        ax.text(ts_[0] * 1000 + 5, i, f"{name} 5단계 연속", va="center", fontsize=8, color="white")
    ax.set_yticks(range(3), order)
    ax.invert_yaxis()
    ax.set(title="스케줄링 — 등록 순서 A,B,C / 실행 순서 B → C → A (끼어들기 없음)", xlabel="첫 작업 시작 후 경과 (ms)")
    ax.grid(axis="x", alpha=0.3)
    return save(fig, "schedule-gantt.png")


def save(fig, name: str) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    path = OUT / name
    fig.savefig(path)
    plt.close(fig)
    return path


def main() -> None:
    font()
    for fn in (plot_oom, plot_cpu, plot_deadlock, plot_schedule):
        print(fn().relative_to(ROOT))


if __name__ == "__main__":
    main()
