---
title: "[Bug] OOM - 실행 33초 후 MemoryGuard 가 프로세스를 SIGKILL 로 자체 종료 (메모리 누수)"
labels: bug, incident, memory
---

# [Bug] OOM - 실행 33초 후 MemoryGuard 가 프로세스를 SIGKILL 로 자체 종료 (메모리 누수)

| 항목 | 값 |
| --- | --- |
| 작성 템플릿 | [`.github/ISSUE_TEMPLATE/bug_report.md`](../.github/ISSUE_TEMPLATE/bug_report.md) — GitHub 에서 New issue 를 누르면 같은 구조로 뜸 |
| 대상 | `agent-leak-app-x86` (PyInstaller 단일 바이너리, 부모 부트로더 + 자식 앱 프로세스) |
| 환경 | Ubuntu 24.04, 2 vCPU / 8GB / swap 없음, 실행 계정 `agent-admin` |
| 재현 조건 | `MEMORY_LIMIT=256` `CPU_MAX_OCCUPY=50` `MULTI_THREAD_ENABLE=false` |
| 재현율 | 3/3 (33s · 33s · 34s) · 동료 평가 후 재현 컨테이너에서 1/1 (34s) |
| 치명도 | **Sev2 (권장)** — 프로세스가 사라져 탐지는 쉽지만 SIGKILL 이라 정리 작업이 없음. 기준: [runbook 1절](../docs/runbook.md#1-장애-유형별-치명도와-대응-sla) · 다른 장애와 겹치면: [우선순위 규칙](README.md#동시-장애가-겹칠-때) |
| 영향 | 서비스 프로세스가 예고 없이 사라짐 (SIGKILL → 정리 작업 없이 즉시 종료) |

## 1. Description (현상 설명)

- 앱을 시작하면 약 **33초 뒤** 프로세스가 사라지고 종료 코드 **137**(= 128 + SIGKILL)로 끝납니다.
- 부팅 화면에서 이미 경고가 나옵니다: `[ MEMORY ] Limit: 256MB   [ WARNING: Recommend Over 256MB ]`
- 같은 설정으로 3번 실행해 모두 33~34초에 종료됐습니다. 우연이 아니라 **설정값에 비례하는 결정적 장애**입니다.
- CPU 는 0~1.5% 로 평온했고 시스템 전체 메모리도 7~8% 만 사용 중이었습니다. 시스템 자원이 부족해서가 아니라 **이 프로세스 하나의 메모리가 계속 늘어난 것**이 문제입니다.

## 2. Evidence & Logs (증거 자료)

### 2-1. monitor.sh 관제 — RSS 가 선형으로 증가

`tools/monitor.sh --interval 2` (프로세스 단위, `/proc/<pid>/status` VmRSS) · [`evidence/oom-before/20261012-223103/monitor.log`](../evidence/oom-before/20261012-223103/monitor.log) L1–16

```text
[2026-10-12 22:31:06] PROCESS:agent-leak-app PID:3848 STATE:S CPU:0.5% MEM:0.5% RSS:42.6MB  THREADS:1 SYS_MEM:6.6%
[2026-10-12 22:31:10] PROCESS:agent-leak-app PID:3848 STATE:S CPU:0.0% MEM:0.8% RSS:67.6MB  THREADS:1
[2026-10-12 22:31:16] PROCESS:agent-leak-app PID:3848 STATE:S CPU:0.5% MEM:1.5% RSS:117.6MB THREADS:1
[2026-10-12 22:31:22] PROCESS:agent-leak-app PID:3848 STATE:S CPU:0.0% MEM:2.1% RSS:167.6MB THREADS:1
[2026-10-12 22:31:28] PROCESS:agent-leak-app PID:3848 STATE:S CPU:0.5% MEM:2.7% RSS:217.6MB THREADS:1
[2026-10-12 22:31:34] PROCESS:agent-leak-app PID:3848 STATE:S CPU:1.0% MEM:3.3% RSS:267.6MB THREADS:1
[2026-10-12 22:31:36] PROCESS:agent-leak-app PID:3848 STATE:GONE
```

| 구간 | RSS | 증가 속도 |
| --- | --- | --- |
| 22:31:06 → 22:31:34 (28초) | 42.6 → 267.6 MB | **+225 MB / 28s ≈ 8.0 MB/s**, 해제 없이 계단식 증가 |

![RSS 추이 — 한도 128/256/512MB](../docs/images/oom-rss.png)

> 그래프: `tools/plot-evidence.py` 가 위 monitor.log 3개를 그대로 그린 것. 세 실행 모두 **같은 기울기**로 오르고, 128·256 은 한도 직후 사라지며(×), 512 는 한도에서 회수 후 다시 오르는 톱니 모양입니다.

> MEM% 는 시스템 전체(8GB) 대비라 3.3% 로 작아 보입니다. 판단은 **RSS(MB)의 기울기**와 앱 한도(256MB) 기준으로 했습니다.

**샘플 주기와 원본 CSV.** 위 실행은 2초 주기(이론 측정 오차 ±0.5%p, [방법론 2-2](../docs/methodology.md#2-2-샘플-주기와-측정-오차))입니다. 33초 장애라 2초 주기로는 16샘플뿐이어서, 동료 평가 후 같은 바이너리를 **1초 주기 + CSV** 로 다시 기록했습니다([`evidence/followup/oom-before/20261110-105000/monitor.csv`](../evidence/followup/oom-before/20261110-105000/monitor.csv), 30샘플, 실제 평균 간격 1.07초 — 측정 자체에 약 0.07초가 걸림). 1초 주기에서도 기울기는 **8.05 MB/s** 로 2초 주기의 8.0 MB/s 와 같습니다.

```bash
awk -F, 'NR>1 && $7!="" {print $2, $7}' monitor.csv     # epoch, rss_mb → 그대로 그래프·회귀에 사용
```

1초 CSV 의 대표 구간 (약 5초 간격으로 뽑은 행, [원본 30행](../evidence/followup/oom-before/20261110-105000/monitor.csv)):

| 경과(초) | 시각 | RSS (MB) | 직전 행 대비 | 구간 CPU | LOG_LINES |
| ---: | --- | ---: | ---: | ---: | ---: |
| 0 | 10:50:02 | 17.5 | — | 0.0% | 19 |
| 5 | 10:50:07 | 67.5 | +50.0 (10.0 MB/s) | 0.0% | 32 |
| 11 | 10:50:13 | 117.3 | +49.8 (8.3 MB/s) | 2.0% | 34 |
| 16 | 10:50:18 | 167.2 | +49.9 (10.0 MB/s) | 3.0% | 36 |
| 21 | 10:50:23 | 192.2 | +25.0 (5.0 MB/s) | 0.0% | 37 |
| 27 | 10:50:29 | 242.2 | +50.0 (8.3 MB/s) | 0.0% | 39 |
| 31 | 10:50:33 | 267.2 | +25.0 (6.3 MB/s) | 0.0% | 40 |
| **0 → 31** | | **17.5 → 267.2** | **+249.7 (8.05 MB/s)** | 최대 3.0% | 19 → 40 |

구간마다 5~10 MB/s 로 흔들리는 것은 앱이 3.03초마다 25MB 씩 계단으로 늘리고 표본을 약 5초 간격으로 뽑았기 때문입니다(한 구간에 계단이 1~2개). 전체 기울기는 8.05 MB/s 로 일정하고, 같은 시간 CPU 는 최대 3% 로 **메모리만 늘어나는** 누수 패턴입니다.

### 2-2. top 배치 출력 — 같은 PID 의 RES 증가 (교차 확인)

`top -b -d 5 -p <PID>` · [`evidence/oom-before/20261012-225151/top.txt`](../evidence/oom-before/20261012-225151/top.txt) L8–53

```text
  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
27157 agent-a+  30  10   48344  43636   9660 S   0.0   0.5   0:00.07 agent-lea+
27157 agent-a+  30  10   99552  94844   9660 S   0.6   1.2   0:00.10 agent-lea+
27157 agent-a+  30  10  150760 146052   9660 S   0.4   1.8   0:00.12 agent-lea+
27157 agent-a+  30  10  227572 222864   9660 S   0.6   2.7   0:00.16 agent-lea+
27157 agent-a+  30  10  278780 274072   9660 S   0.6   3.3   0:00.19 agent-lea+
```

VIRT 와 RES 가 함께 늘어납니다 → 새로 할당한 메모리를 **실제로 사용(touch)** 하고 있어 물리 메모리가 계속 점유됩니다.

### 2-3. 프로그램 실행 로그 — 종료 직전·직후

[`evidence/oom-before/20261012-223103/app.log`](../evidence/oom-before/20261012-223103/app.log) L30–42

```text
2026-10-12 22:31:05,573 [INFO] [MemoryWorker] Current Heap: 25MB
2026-10-12 22:31:08,600 [INFO] [MemoryWorker] Current Heap: 50MB         ← 3.03초마다 +25MB
   …
2026-10-12 22:31:32,822 [INFO] [MemoryWorker] Current Heap: 250MB
2026-10-12 22:31:35,851 [INFO] [MemoryWorker] Current Heap: 275MB
2026-10-12 22:31:35,852 [CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB) / (Recommend Over 256MB)
2026-10-12 22:31:35,852 [CRITICAL] [MemoryGuard] Self-terminating process 3848 to prevent system instability.
```

`Self-terminating process 3848` 의 3848 은 monitor.sh 가 추적한 PID 와 같습니다 → 관제 대상과 로그의 주체가 동일 프로세스임을 확인.

### 2-4. 누가 죽였나 — strace 로 신호 출처 확인

`run-scenario.sh --trace` (앱을 `strace -f -e trace=kill,tgkill,exit_group` 의 자식으로 실행) · [`evidence/oom-before/20261012-223140/trace.txt`](../evidence/oom-before/20261012-223140/trace.txt) L1–5

```text
4676  22:32:13.099574 kill(4676, SIGKILL) = ?                        ← 앱(4676)이 자기 자신에게 SIGKILL
4676  22:32:13.119066 +++ killed by SIGKILL +++
4610  22:32:13.119249 --- SIGCHLD {si_code=CLD_KILLED, si_pid=4676, si_status=SIGKILL, …} ---
4610  22:32:13.145051 tgkill(4610, 4610, SIGKILL) = ?                ← 부트로더(4610)도 같은 신호로 스스로 종료
4610  22:32:13.145449 +++ killed by SIGKILL +++
```

| 판별 | 결과 |
| --- | --- |
| 커널 OOM Killer 인가? | **아니다.** 커널이 죽였다면 시스템 콜 없이 `+++ killed by SIGKILL +++` 만 보이고 시스템 메모리가 고갈 직전이어야 한다. 여기서는 **앱이 `kill(자기 PID, SIGKILL)` 을 직접 호출**했고 시스템 메모리 사용률은 7~8% 였다 |
| 외부에서 kill 했나? | 아니다. `kill()` 의 호출자와 대상이 같은 PID |
| 결론 | **애플리케이션 내부 정책(MemoryGuard)에 의한 자체 종료** |

### 2-5. 한도를 바꿔 본 보조 실험 — 생존 시간 ∝ MEMORY_LIMIT

| 실행 | MEMORY_LIMIT | 생존 | 종료 시 Heap | 종료 |
| --- | --- | --- | --- | --- |
| [`oom-128`](../evidence/oom-128/20261012-223217/result.txt) | 128 | **18s** | 150MB ≥ 128MB | 137 SIGKILL |
| [`oom-before` #1](../evidence/oom-before/20261012-223103/result.txt) | 256 | **33s** | 275MB ≥ 256MB | 137 SIGKILL |
| [`oom-before` #2](../evidence/oom-before/20261012-223140/result.txt) (trace) | 256 | **33s** | 275MB ≥ 256MB | 137 SIGKILL |
| [`oom-before` #3](../evidence/oom-before/20261012-225151/result.txt) (top) | 256 | **34s** | 275MB ≥ 256MB | 137 SIGKILL |

25MB × n ≥ 한도 가 되는 첫 단계에서 종료됩니다(128 → 6단계 ≈ 18s, 256 → 11단계 ≈ 33s). **누수 속도는 일정하고, 한도만이 죽는 시점을 결정**한다는 뜻입니다.

## 3. Root Cause Analysis (원인 분석)

**결함: MemoryWorker 의 메모리 누수 (할당 후 해제하지 않음)**
- Heap 이 3.03초마다 정확히 25MB 씩 늘고 줄지 않습니다(2-3). RSS·RES 도 같은 기울기로 늘어납니다(2-1, 2-2).
- 일시적 사용량 증가라면 처리 후 줄어들어야 하는데, 22:31:05~35 동안 한 번도 줄지 않았습니다 → 참조가 계속 남아 GC 가 회수하지 못하는 **누적형 누수**입니다(예: 전역 리스트·캐시에 계속 추가).

**종료 메커니즘: MemoryGuard 의 fail-fast 정책**
- Heap 이 `MEMORY_LIMIT` 이상이 되는 순간 MemoryGuard 가 `kill(getpid(), SIGKILL)` 로 자기 자신을 종료합니다(2-4).

**MemoryGuard 동작 순서 (로그·strace·경계 실험으로 확인한 것만)**

```text
 MemoryWorker: 3.03초마다 Heap += 25MB  (Current Heap: 25 → 50 → … )
        │
        ▼  매 증가 직후 검사: Heap >= MEMORY_LIMIT ?
        │── 아니오 → 계속 증가
        │
        └── 예 ──┬─ MEMORY_LIMIT ≤ 256 ─▶ [CRITICAL] Memory limit exceeded (275MB >= 256MB) / (Recommend Over 256MB)
                 │                       [CRITICAL] Self-terminating process <PID>        ← 같은 밀리초
                 │                       kill(자기 PID, SIGKILL)  → exit 137              ← SIGTERM·유예 단계 없음 (2-4)
                 │
                 └─ MEMORY_LIMIT ≥ 257 ─▶ [WARNING] Memory Usage Reached Limit (…MB). Starting cleanup...
                                         [INFO] Memory Cache Flushed. Process Stabilized.  ← 30~70ms 뒤
                                         Heap 이 25MB 부터 다시 증가 (RSS 518 → 18MB 회수, 4장)
```

| 확인한 것 | 근거 |
| --- | --- |
| 검사 시점: Heap 증가 직후, 같은 밀리초 | `Current Heap: 275MB` 22:31:35,851 → `Memory limit exceeded` 22:31:35,852 (2-3) |
| 종료는 1단계(SIGKILL) — SIGTERM → 유예 → SIGKILL 단계가 없다 | strace 에 `kill(4676, SIGKILL)` 한 번뿐, 앞선 SIGTERM 없음 (2-4) |
| 분기 경계는 256 / 257MB | 128 · 256 은 종료, 257 · 300 · 400 · 511 · 512 는 정리 후 계속 실행 ([경계 실험](../evidence/followup/sweep-oom/summary.md)) — 앱 안내 `Recommend Over 256MB` 와 일치 |
| 정리 후에도 누수 속도는 같다 | 정리 뒤 Heap 이 25MB 부터 같은 3.03초 · 25MB 간격으로 다시 증가 (4장 After 로그) |

내부 코드(임계치 상수, 정리 함수)는 디컴파일하지 않았으므로 위 표는 **관찰된 입력(MEMORY_LIMIT)과 출력(로그·신호)의 관계**입니다.

**왜 앱이 스스로 죽는가 — OS 관점**
1. 누수가 계속되면 RSS 가 물리 메모리를 잠식합니다. 커널은 먼저 페이지 캐시를 비우고, swap 이 있으면 swap 으로 밀어내며(디스크 I/O 폭증 → 시스템 전체가 느려지는 thrashing), 그래도 부족하면 **커널 OOM Killer** 가 `oom_score`(대략 메모리 점유가 큰 순)가 가장 높은 프로세스를 SIGKILL 합니다.
2. 커널 OOM Killer 는 **어떤 프로세스를 죽일지 앱이 고를 수 없습니다.** 누수 프로세스가 아닌 DB·sshd 같은 다른 중요한 프로세스가 희생될 수도 있고, 그 전에 thrashing 으로 서버 전체가 응답하지 않을 수 있습니다.
3. MemoryGuard 는 그 지점에 도달하기 **전에**, 원인 프로세스 스스로 정해진 한도에서 종료해 **피해를 자기 자신으로 한정**합니다. 시스템 메모리가 7~8% 일 때 종료된 것도 이 때문입니다.
4. SIGKILL 은 잡거나 무시할 수 없는 신호라 확실히 종료되지만, 종료 처리(버퍼 플러시, 연결 정리)가 실행되지 않습니다. 그래서 종료 로그가 마지막 2줄에서 끊깁니다.

## 4. Workaround & Verification (조치 및 검증)

### 조치

`MEMORY_LIMIT` **하나만** 256 → 512 로 올렸습니다. (다른 값은 동일: [`scenarios/oom-before.env`](../scenarios/oom-before.env) → [`scenarios/oom-after.env`](../scenarios/oom-after.env))

```bash
# 운영 환경이라면 실행 계정의 환경 파일에서 변경 (예: ~/.bash_profile 또는 /etc/agent-app/agent-app.env)
export MEMORY_LIMIT=512
```

**변경 위치와 명령** — 값이 들어 있는 곳은 세 군데이고, 어느 경우든 앱은 시작할 때만 환경변수를 읽으므로 **재시작해야** 적용됩니다.

| 어디서 | 위치 | 명령 |
| --- | --- | --- |
| 이 저장소의 실험 | [`scenarios/oom-before.env`](../scenarios/oom-before.env#L3) 3줄 `MEMORY_LIMIT=256` → [`scenarios/oom-after.env`](../scenarios/oom-after.env#L2) 2줄 `MEMORY_LIMIT=512` | `tools/run-scenario.sh scenarios/oom-after.env` |
| 같은 파일을 바꿔서 검증 (백업 · 롤백 포함) | `scenarios/oom-before.env` | `tools/apply-env.sh scenarios/oom-before.env MEMORY_LIMIT=512 --verify 60` → 나쁘면 `tools/apply-env.sh --rollback scenarios/oom-before.env` |
| 운영 서버 | 실행 계정의 환경 파일(예: `/etc/agent-app/agent-app.env`) 또는 systemd 유닛의 `Environment=MEMORY_LIMIT=512` | `tools/apply-env.sh /etc/agent-app/agent-app.env MEMORY_LIMIT=512` 후 서비스 재시작 |


### Before & After

| | Before (`MEMORY_LIMIT=256`) | After (`MEMORY_LIMIT=512`) |
| --- | --- | --- |
| 부팅 판정 | `[ WARNING: Recommend Over 256MB ]` | `[ OK ]`, 시나리오 `Healthy System Monitoring` |
| 생존 시간 | **33s / 33s / 34s** 후 종료 | **300s 관찰 내내 생존** (관찰 종료로 정지) |
| 종료 | 137 (SIGKILL, 자체 종료) | 없음 |
| 한도 도달 시 동작 | `Self-terminating process` | `Memory Usage Reached Limit (525MB). Starting cleanup...` → `Memory Cache Flushed. Process Stabilized.` |
| RSS 패턴 | 42 → 268MB 직선 상승 후 사라짐 | **톱니 모양** 517.9MB → 17.8MB(첫 회수) / 67.8MB(이후) (약 65초 주기, 5분간 4회 회수) |

**장기 시계열 (600초, 1초 주기).** 5분 관찰로는 "한도 512 에서 계속 안정적인가" 를 말하기에 짧아, 재현 컨테이너에서 10분 동안 1초 주기로 다시 기록했습니다([`evidence/followup/oom-after/20261110-105000/`](../evidence/followup/oom-after/20261110-105000/), 567샘플, CSV 포함).

| 지표 | 값 |
| --- | --- |
| 생존 | 601초 관찰 내내 생존 (관찰 종료) |
| 정리(cleanup) 횟수 · 간격 | **9회**, 10:51:04 → 10:59:51, 간격 **65~66초**로 일정 |
| 상승 기울기 | 첫 두 주기 8.34 · 7.94 MB/s (17MB → 517MB), 이후 5.5~5.7 MB/s (167MB → 517MB) |
| RSS 정점 | 매번 517.4~517.6MB (한도 512 + 마지막 25MB 단계) |
| 정리 후 RSS 바닥 | 첫 회수 17.5MB → 셋째 회수부터 **167.4MB 로 고정** (7주기 동안 그대로) |

앱의 Heap 지표는 정리 때마다 25MB 부터 다시 시작하지만, OS 가 본 RSS 바닥은 두 번째 회수 이후 한 단계 높아져 그 자리에 머뭅니다(원래 VM 실행에서도 17.8 → 67.8MB 로 같은 모양). 바닥이 주기마다 계속 올라가지는 않으므로 **추가 누수는 아니고**, 해제한 메모리 일부를 프로세스가 OS 에 돌려주지 않고 다시 쓰는 할당자 동작으로 보입니다(내부를 보지 않았으므로 추정). 운영에서는 "정리 후 RSS" 를 기준선으로 따로 추적해야 이 바닥이 늘어나는 진짜 누수와 구분됩니다.

**실험별 시작 · 종료 시각.** 아래 시각은 각 실행의 `result.txt` 기준입니다. 2026-11 후속 실험부터는 실험 ID(= 폴더 이름)와 시작 시각이 `app.log` · `monitor.log` 첫 줄 머리에도 같은 값으로 들어갑니다([방법론 2-1](../docs/methodology.md#2-1-실험-id-머리줄과-csv-추세-분석용)).

| 실험 ID (폴더) | 조건 | 시작 | 종료 | 생존 | 종료 코드 |
| --- | --- | --- | --- | --- | --- |
| `oom-before/20261012-223103` | 256 | 22:31:03 | 22:31:36 | 33s | 137 SIGKILL |
| `oom-before/20261012-223140` | 256, `--trace` | 22:31:40 | 22:32:13 | 33s | 137 SIGKILL |
| `oom-before/20261012-225151` | 256, top | 22:51:51 | 22:52:25 | 34s | 137 SIGKILL |
| `oom-128/20261012-223217` | 128 | 22:32:17 | 22:32:35 | 18s | 137 SIGKILL |
| `oom-after/20261012-223240` | 512 | 22:32:40 | 22:37:40 | 300s+ | 관찰 종료 |
| `followup/oom-before/20261110-105000` | 256, 1초 주기 | 10:50:00 | 10:50:34 | 34s | 137 SIGKILL |
| `followup/oom-after/20261110-105000` | 512, 1초 주기 | 10:50:00 | 11:00:01 | 601s+ | 관찰 종료 |

After 실행 로그 ([`evidence/oom-after/20261012-223240/app.log`](../evidence/oom-after/20261012-223240/app.log) L96–244):

```text
2026-10-12 22:33:44,571 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
2026-10-12 22:33:44,601 [INFO] [System] Memory Cache Flushed. Process Stabilized.
>>> [SYSTEM] MEMORY RECOVERED (Cache Cleared) <<<
2026-10-12 22:34:50,210 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
2026-10-12 22:35:55,847 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
2026-10-12 22:37:01,461 [WARNING] [MemoryWorker] Memory Usage Reached Limit (525MB). Starting cleanup...
```

비교표 원본: `tools/compare.sh evidence/oom-before/* evidence/oom-128/* evidence/oom-after/*`

### 해석과 한계

- 한도를 올린 것은 **임시 조치**입니다. 누수 속도(≈8MB/s)는 그대로이고, After 에서도 65초마다 512MB 까지 차오릅니다. 한도를 올린 만큼 "죽기까지의 시간"·"회수 주기" 가 늘어났을 뿐 원인은 남아 있습니다.
- 서버 메모리가 작거나 같은 서버에 다른 프로세스가 있으면, 높아진 한도까지 쓰는 동안 다른 프로세스가 압박을 받습니다. 한도는 **서버 여유 메모리 - 다른 프로세스 사용량** 안에서 정해야 합니다.

### 근본 해결 제안 (코드 레벨)

1. 누적 컨테이너(리스트·dict 캐시)에 **상한과 만료**를 둔다: `collections.deque(maxlen=N)`, `functools.lru_cache(maxsize=N)`, TTL 캐시
2. 처리 끝난 데이터의 참조를 끊는다(`del`, `pop`, 컨텍스트 매니저). 큰 버퍼는 재사용
3. `tracemalloc` 스냅샷 비교로 증가하는 할당 위치를 찾아 테스트로 고정 (메모리 회귀 테스트)
4. SIGKILL 대신 **SIGTERM → 유예 → SIGKILL** 순서로 종료해 진행 중 작업을 정리할 기회를 준다
5. 운영: 컨테이너/systemd `MemoryMax` 로 OS 수준 상한을 함께 걸고, monitor.sh 에 **RSS 기울기 경고**(예: 10분 연속 증가 + 증가율 > X MB/분)를 추가해 한도 도달 **전에** 알림 — 구체적 임계값(Warning ≥ 4MB/s, Critical ≥ 8MB/s, RSS ≥ 한도 80%/90%)과 알림 경로, **서버 메모리 크기별 권장값(2 · 8 · 32GB)** 은 [runbook 3절](../docs/runbook.md#3-알림-임계값과-알림-경로)

**적용 대상과 영향 범위** — 바이너리 소스가 없으므로 대상은 로그에 찍힌 컴포넌트 이름으로 지정하고, 같은 수정을 테스트용 가짜 앱에 적용해 효과를 테스트로 고정했습니다.

| 적용 대상 (로그 컴포넌트) | 패치 | 참고 구현 | 영향 범위 | 검증 테스트 |
| --- | --- | --- | --- | --- |
| `[MemoryWorker]` 의 누적 버퍼 | 리스트 → `deque(maxlen=N)` (오래된 항목부터 버림) | [`tests/fake-agent-leak-app.py`](../tests/fake-agent-leak-app.py) `leak-bounded` 모드 | 보관 개수를 넘는 오래된 데이터는 사라진다 → 재조회가 필요한 데이터면 캐시 미스 비용 확인 | [`tests/run-fix-tests.sh`](../tests/run-fix-tests.sh) "leak-bounded": 8초 동안 RSS 가 50~100MB 에서 멈추고 후반 변동 ≤ 15MB, 보관 5개/50MB 유지 |
| `[MemoryGuard]` 종료 단계 | `kill(SIGKILL)` → 80% 경고 · 100% SIGTERM · 정리 · 유예 후 SIGKILL (아래 "권장 종료 절차") | 같은 파일 `guard-graceful` · `guard-graceful-stuck` 모드 (대조: `guard-kill`) | 유예 동안 메모리가 더 늘 수 있음 → 유예 시간 × 누수 속도(≈8MB/s · 5초 ≈ 40MB)만큼 한도에 여유 필요 | 같은 테스트: 즉시 SIGKILL 은 exit 137 · 정리 로그 없음 / 권장 절차는 80% 경고 → SIGTERM → `cleanup done` → exit 143 / 정리가 안 끝나면 유예 1초 뒤 SIGKILL(exit 137) |

**상태 구분** — 위 표의 두 줄은 모두 **가짜 앱에 적용한 참고 구현 + 자동 테스트**입니다(실제 바이너리는 소스가 없어 고칠 수 없음). 근본 해결 제안 1~5 중 2(참조 끊기) · 3(tracemalloc) · 5(systemd `MemoryMax`, 기울기 경보)는 **제안 단계**이고 구현하지 않았습니다. 테스트 결과(`bash tests/run-fix-tests.sh`, CI 와 같은 Docker 이미지):

```text
[leak-bounded: 8초 RSS 관찰]
  PASS 마지막 RSS 50~100MB, 후반 4개 표본 변동 ≤15MB
[MemoryGuard 종료 절차: 즉시 SIGKILL vs 경고 → SIGTERM → 정리 → 유예 후 SIGKILL]
  PASS guard-kill: exit 137 (SIGKILL)
  PASS guard-kill: 정리 로그 없음
  PASS guard-graceful: exit 143 (SIGTERM)
  PASS guard-graceful: 80% 경고가 한도 도달보다 먼저
  PASS guard-graceful: 정리 완료 로그 후 종료
  PASS guard-graceful: 유예 SIGKILL 이 쓰이지 않음
  PASS guard-graceful-stuck: 정리가 안 끝나면 유예 후 SIGKILL (exit 137)
  PASS guard-graceful-stuck: grace expired 로그
```

### 권장 종료 절차 (MemoryGuard)

지금 앱은 한도에 닿는 같은 밀리초에 SIGKILL 하나로 끝냅니다(3장 동작 순서). 권장 방향과 파라미터(모두 권장값)는 다음과 같습니다.

| 단계 | 조건 | 조치 | 파라미터 근거 |
| --- | --- | --- | --- |
| 1. 경고 | Heap ≥ 한도의 80% | WARNING 로그 + 알림 (RSS 기울기 경보와 함께) | 8MB/s 누수면 80% → 100% 까지 약 6초(256MB 기준 51MB ÷ 8MB/s). 사람이 대응하기엔 짧아 **알림 + 자동 정리**가 목적 |
| 2. 정리 시도 | Heap ≥ 한도 | 캐시 비우기 (512MB 일 때 앱이 이미 하는 `Memory Cache Flushed`) | 실제 앱은 257MB 이상에서만 이 단계를 함(3장) |
| 3. 정상 종료 요청 | 정리 후에도 한도 초과 | 자기 자신에게 **SIGTERM** → 핸들러가 진행 중 작업 저장 · 연결 종료 | SIGTERM 은 잡을 수 있어 정리 기회가 있음 |
| 4. 강제 종료 | SIGTERM 후 **유예 5초** 안에 안 끝남 | SIGKILL | 유예 동안 늘 메모리(8MB/s × 5초 ≈ 40MB)를 한도에 미리 남겨 둠. 유예가 무한하면 정리 단계가 멈춘 채 메모리만 잡아먹으므로 상한 필수 |

참고 구현(`guard-graceful`)은 테스트를 빨리 돌리려고 한도 60MB · 유예 1초로 줄였고, 순서와 종료 코드(143 정상 / 137 유예 초과)가 위 표와 같음을 테스트가 확인합니다.

## 재현 방법

```bash
sudo -iu agent-admin
cd <repo>
tools/run-scenario.sh scenarios/oom-before.env            # 약 35초, exit 137
tools/run-scenario.sh scenarios/oom-before.env --trace    # + strace 신호 기록
tools/run-scenario.sh scenarios/oom-after.env --max 300   # 5분 생존 확인

# 재현 컨테이너에서 (바이너리 포함, 2 vCPU · 8GB · swap 없음)
repro/run.sh tools/run-scenario.sh scenarios/oom-after.env --interval 1 --max 600     # 10분 · 1초 주기 · CSV
repro/run.sh tools/sweep.sh scenarios/oom-before.env MEMORY_LIMIT 257 300 400 511 --repeat 1 --max 100   # 분기 경계
```
