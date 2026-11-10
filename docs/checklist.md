# 체크리스트 답변

미션 체크리스트 항목별로 **어디에 근거가 있는지**와 **답변 요지**를 정리했습니다. 수치는 모두 `evidence/` 원본에서 인용했습니다.

- [항목 1 — 산출물 확인](#항목-1--산출물-확인)
- [항목 2 — 도구와 판단 흐름](#항목-2--도구와-판단-흐름)
- [항목 3 — 원리 설명](#항목-3--원리-설명)
- [항목 4 — 확장 질문](#항목-4--확장-질문)

---

## 항목 1 — 산출물 확인

| 체크 항목 | 근거 | 요지 |
| --- | --- | --- |
| [OOM] 메모리 선형 증가 → 강제 종료 패턴이 로그에 있는가 | [OOM 2-1, 2-3](../issues/01-oom-memory-guard.md#2-evidence--logs-증거-자료) | RSS 42.6 → 267.6MB (28초, ≈8MB/s 직선), Heap 3.03초마다 +25MB → `Memory limit exceeded (275MB >= 256MB)` → `Self-terminating process 3848` → exit 137 |
| [OOM] MEMORY_LIMIT 조정 Before & After | [OOM 4](../issues/01-oom-memory-guard.md#4-workaround--verification-조치-및-검증) | 256 → 33s·33s·34s 종료 / 128 → 18s / **512 → 300s 생존**(65초 주기 회수) |
| [CPU] 임계치 초과 → 종료 패턴이 로그에 있는가 | [CPU 2-1, 2-2](../issues/02-cpu-watchdog.md#2-evidence--logs-증거-자료) | Load 5% → 54.96% 계단식 → `CPU Threshold Violated!` → 0.1초 뒤 SIGTERM, exit 143 (3/3 회) |
| [CPU] CPU_MAX_OCCUPY 조정 Before & After | [CPU 4](../issues/02-cpu-watchdog.md#4-workaround--verification-조치-및-검증) | 90 → 37s·25s·31s 종료 / 60 → 24s 종료 / **50 → 180s 생존**(50.00% 에서 쿨다운) |
| [Deadlock] PID 존재 + CPU/MEM 변화 없음 + 로그 정지 식별 | [Deadlock 2-1~2-3](../issues/03-deadlock.md#2-evidence--logs-증거-자료) | PID 17428 존재, 10초간 CPU tick Δ0 · RSS 18100kB 고정 · 로그 42줄 고정, 3개 스레드 `S` + `futex_do_wait` |
| [Deadlock] MULTI_THREAD_ENABLE 조정 비교 | [Deadlock 4](../issues/03-deadlock.md#4-workaround--verification-조치-및-검증) | true → 9초 후 정지(DEADLOCK 판정) / **false → 120초간 로그 51 → 146줄 진행**("진행 중" 판정) |
| [Format] 3건 모두 현상 → 증거 → 원인 → 조치 구조 | [issues/](../issues/) · [Issue 템플릿](../.github/ISSUE_TEMPLATE/bug_report.md) | 4개 리포트 모두 `1. Description → 2. Evidence & Logs → 3. Root Cause → 4. Workaround & Verification` + 재현 방법. GitHub Issue 로도 등록 |
| [Evidence] PID · 타임스탬프 · 핵심 로그 포함 | 각 리포트 2장 | 모든 발췌에 PID(3848·12953·17428 …)와 ms 단위 타임스탬프, 원본 파일 링크 |

---

## 항목 2 — 도구와 판단 흐름

### monitor.sh 에서 메모리 증가 패턴을 추적한 명령어와 데이터 추출 방법

**수집** — [`tools/monitor.sh`](../tools/monitor.sh) 가 2초마다 한 줄을 남깁니다.

```bash
tools/monitor.sh --interval 2 --until-exit --app-log app.log > monitor.log
# [2026-10-12 22:31:16] PROCESS:agent-leak-app PID:3848 STATE:S CPU:0.5% MEM:1.5% RSS:117.6MB THREADS:1 SYS_CPU:1.2% SYS_MEM:7.0% LOG_LINES:36
```

| 값 | 읽는 곳 | 선택 이유 |
| --- | --- | --- |
| 대상 PID | `/proc/*/cmdline` 에서 패턴 일치 + **부모도 앱인 자식** | PyInstaller 바이너리는 부트로더(부모, RSS 2MB 고정) + 앱(자식) 2개. 부모를 보면 누수가 안 보인다 |
| RSS | `/proc/<pid>/status` 의 `VmRSS` | 실제 점유 물리 메모리. VSZ(가상)는 예약만 해도 늘어나 누수 판단에 부적합 |
| MEM% | VmRSS ÷ `/proc/meminfo` MemTotal | 시스템 대비 비중 (8GB 서버라 작게 보임 → 판단은 RSS MB 로) |

**추출** — 고정 포맷이라 `grep`/`awk` 로 바로 뽑힙니다.

```bash
grep -o 'RSS:[0-9.]*' monitor.log | cut -d: -f2                    # RSS 열만
awk -F'[][]' '{split($3, a, "RSS:"); split(a[2], b, "MB"); print $2, b[1]}' monitor.log   # 시각 + RSS
grep -o 'RSS:[0-9.]*' monitor.log | cut -d: -f2 | sort -n | tail -1   # 최대값 (result.txt 의 peak_rss)
```

**판단** — 값 하나가 아니라 **기울기와 회수 여부**를 봅니다. 42.6 → 67.6 → 117.6 → 167.6 → 217.6 → 267.6MB (6초마다 +50MB, 한 번도 감소 없음) → 누적형 누수. 앱 로그 `Current Heap` 이 3.03초마다 +25MB 로 같은 기울기라 교차 확인됩니다. 시각화: [`docs/images/oom-rss.png`](images/oom-rss.png)

### CPU 사용률 확인 도구와 옵션의 의미

| 도구·옵션 | 보여주는 값 | 사용 여부와 이유 |
| --- | --- | --- |
| `ps -o pcpu` | 프로세스 **시작 이후 누적 평균** (총 CPU 시간 ÷ 경과 시간) | 판단에 쓰지 않음. 오래 산 프로세스의 순간 급상승이 평균에 묻힌다 |
| `top -b -d 5 -p <PID>` | `-b` 배치 모드(파일 저장), `-d 5` 5초 간격, `-p` 대상 PID 만 → **직전 5초 구간** 사용률 | 캡처·교차 확인용 (`top.txt`). `PR`/`NI` 로 nice 10 적용도 확인 |
| `top -H -b -n 1 -p <PID>` | `-H` **스레드 단위**, `-n 1` 1회 | Deadlock 진단: 모든 스레드 `S` · 0.0% |
| `ps -L -o pid,tid,stat,pcpu,wchan` | `-L` 스레드마다 한 줄, `wchan` 커널 대기 지점 | Deadlock 진단: `futex_do_wait` |
| **`/proc/<pid>/stat` utime(14)+stime(15) 의 Δ** | Δticks ÷ (Δt × CLK_TCK) × 100 = **그 구간의 실제 사용률** (1코어 = 100%) | **monitor.sh 의 CPU 값.** 정확하고 가볍고 스크립트에서 계산 가능 |
| `strace -f -e trace=kill,tgkill` 의 `SIGCHLD si_utime/si_stime` | 종료 시점까지의 **총 CPU 시간** | 25초 생존 동안 0.28초만 사용 → 앱 지표와 OS 실측 차이 입증 |

이번 미션에서 중요했던 발견: 앱 로그의 `Current Load` 는 55% 까지 올랐지만 OS 실측은 0~2.5% 였습니다. 그래서 **앱 지표로 급상승 구간을 식별**하고, **OS 지표로 "시스템 전체 과부하가 아님"** 을 확인했습니다. [CPU 리포트 2-3](../issues/02-cpu-watchdog.md#2-3-monitorsh-관제--top--이-프로세스-이-시점)

### "살아 있지만 멈춘 상태" 진단 도구와 순서

[`tools/diagnose-hang.sh`](../tools/diagnose-hang.sh) 가 아래 순서를 그대로 실행합니다. **각 단계의 결과가 다음 단계를 볼 이유**가 됩니다.

```
① ps -ef / pstree        살아 있나?        PID 17428 존재          → OOM/CPU 같은 크래시가 아니다
② /proc/task/*/stat ×2   일을 하나?        10초간 CPU tick Δ0       → "잠깐 0%" 가 아니라 구간 전체가 0
③ VmRSS, 로그 줄 수·mtime 무언가 변하나?   18100kB 고정, 42줄 고정   → 누수(메모리만 변함)·느린 처리(로그는 진행)와 구분
④ ps -L wchan / top -H   어디서 멈췄나?    3개 스레드 S + futex     → 무한 루프(R, 100%)가 아니라 락 대기
⑤ 앱 로그 마지막 줄      무엇을 기다리나?  T1: A 보유·B 대기 / T2: B 보유·A 대기 → 순환 대기 = Deadlock
```

"CPU 0%" 만 보고 Deadlock 이라 하지 않습니다. 같은 도구로 After(정상) 실행을 진단하면 스레드는 똑같이 `S` 로 보이지만 ②③ 에서 변화가 있어 "진행 중" 으로 판정됩니다 — 순간 상태가 아니라 **구간 변화**가 판단 기준인 이유입니다.

---

## 항목 3 — 원리 설명

### 메모리 누수 시 앱의 메모리 보호 정책이 프로세스를 강제 종료하는 이유

자세히: [OOM 리포트 3장](../issues/01-oom-memory-guard.md#3-root-cause-analysis-원인-분석)

1. 누수가 계속되면 커널은 페이지 캐시 회수 → (swap 이 있으면) swap out → 그래도 부족하면 **커널 OOM Killer** 순서로 대응합니다. swap 단계에서는 디스크 I/O 폭증으로 서버 전체가 느려지고(thrashing), OOM Killer 는 `oom_score` 기준으로 희생자를 고르기 때문에 **누수와 무관한 중요한 프로세스(DB, sshd)** 가 죽을 수 있습니다.
2. MemoryGuard 는 그 전에, 원인 프로세스 자신이 **정해진 한도에서 스스로 종료**해 피해 범위를 자기 자신으로 한정합니다. 실제로 시스템 메모리 사용률 7~8% 일 때 종료됐습니다.
3. SIGKILL 은 잡거나 무시할 수 없어 확실히 종료되지만, 정리 작업 없이 끝납니다. 메모리는 "몇 초 뒤 서버 전체 장애" 로 번질 수 있어 즉시성이 우선입니다.
4. 커널이 죽인 것이 아니라 앱이 죽였다는 근거: strace 의 `kill(4676, SIGKILL)` (호출자 = 대상), 커널 OOM 이라면 시스템 콜 없이 `+++ killed by SIGKILL +++` 만 보입니다.

### CPU 과점유 시 단일 프로세스를 종료하는 것이 시스템 보호에 필요한 이유

자세히: [CPU 리포트 3장](../issues/02-cpu-watchdog.md#3-root-cause-analysis-원인-분석)

1. CPU 는 시간을 나눠 쓰는 자원입니다. CFS 스케줄러는 실행 가능한 프로세스에 가중치(nice) 비례로 시간을 나누는데, CPU-bound 프로세스가 코어를 계속 쓰면 run queue 가 길어져 **다른 모든 프로세스의 응답 지연**이 커집니다(2 vCPU 면 스레드 2개로 충분).
2. 메모리와 달리 **커널은 CPU 과점유 프로세스를 죽이지 않습니다.** 모두가 조금씩 느려질 뿐이라, 응용 계층(Watchdog)이나 cgroup(`cpu.max`) 이 상한을 지켜야 합니다.
3. 폭주한 1개를 끊으면 run queue 가 즉시 비워져 나머지 서비스가 회복되고, 재시작은 프로세스 관리자가 맡을 수 있습니다. "1개를 희생해 N개를 지킨다".
4. 이 앱은 시작 직후 nice 10 으로 자신을 낮추고(CFS 가중치 1024 → 110, 경쟁 시 약 1/9 몫), 그래도 임계치를 넘으면 SIGTERM(정상 종료 신호)으로 끝냅니다. CPU 과점유는 당장 서버를 무너뜨리진 않으므로 정리 기회를 주는 SIGTERM 이 적절합니다.

### 교착 상태의 원리 — 상호 배제와 순환 대기

자세히: [Deadlock 리포트 3-2](../issues/03-deadlock.md#3-2-왜-교착이-생기나--4가지-조건이-모두-성립)

- **상호 배제:** 락은 한 번에 한 스레드만 가질 수 있다. T1 이 `Shared_Memory_A` 를 가진 동안 T2 는 A 를 얻을 수 없다(`Strict resource locking is enabled`).
- **순환 대기:** 대기 관계가 원을 이룬다. T1 은 A 를 쥐고 B 를, T2 는 B 를 쥐고 A 를 기다린다 → T1 → T2 → T1.
- 여기에 **점유 대기**(쥔 채로 기다림)와 **비선점**(남의 락을 빼앗을 수 없음, 타임아웃 없음)까지 4조건이 모두 성립해 영원히 풀리지 않습니다. 넷 중 하나만 깨도 교착은 사라집니다 — 가장 쉬운 것은 **락 획득 순서를 통일**해 순환 대기를 없애는 것입니다.
- 락을 못 얻은 스레드는 커널 futex 큐에서 잠들기 때문에 CPU 를 쓰지 않습니다. 그래서 교착은 "CPU 0% = 한가함" 으로 오인되기 쉽습니다.

### 로그에서 순환 의존(A→B, B→A)을 파악한 추적 과정

1. **마지막 줄부터 거꾸로:** 마지막 두 줄이 모두 `WAITING … (Status: BLOCKED)` → 대기 중 멈춤.
2. **스레드별로 보유/대기 분리:** `LOCK ACQUIRED: [X]` = 보유, `WAITING for [Y]` = 대기. 해제 로그는 0줄 → 아직 쥐고 있다. `diagnose-hang.sh` 6절이 `grep -E 'LOCK ACQUIRED|WAITING for' | sed` 로 자동 추출합니다.
   ```text
   Worker-Thread-1 holds  Shared_Memory_A        Worker-Thread-2 waits  Shared_Memory_A
   Worker-Thread-2 holds  Socket_Pool_B          Worker-Thread-1 waits  Socket_Pool_B
   ```
3. **대기 그래프로 변환:** "자원 Y 를 기다림" → "Y 를 가진 스레드를 기다림". T1 →(B 소유자) T2 →(A 소유자) T1 → **사이클**.
4. **타임스탬프로 순서 확인:** 22:43:00.584 두 스레드가 각자 첫 락 획득(1ms 차) → 22:43:02.595 둘 다 상대 락 요청 → 이후 로그 없음.
5. **OS 증거로 교차 확인:** 로그만 멈추고 계산은 계속될 가능성을 배제하기 위해 전 스레드 `futex_do_wait` + CPU Δ0 확인.

---

## 항목 4 — 확장 질문

### 운영 서버라면 메모리 누수를 장애 전에 탐지하도록 monitor.sh 를 어떻게 개선하겠는가

지금 monitor.sh 는 "현재 값" 을 기록만 합니다. 누수는 **값이 아니라 추세**라서 장애 전에 잡으려면 기울기를 봐야 합니다.

| 개선 | 방법 | 이번 데이터에 적용하면 |
| --- | --- | --- |
| **RSS 기울기 경보** | 최근 N개 샘플로 선형 회귀(최소제곱) 기울기 계산, `기울기 > X MB/분` 이 M분 지속되면 WARN | +8MB/s(=480MB/분) → 첫 10초 안에 경보 |
| **한도 도달 예상 시각** | `(한도 − 현재 RSS) ÷ 기울기` 를 `ETA` 필드로 출력, ETA < 10분이면 경보 | 22:31:10 시점 (256−67.6)/8 ≈ **24초 후 종료 예측** (실제 26초 후 종료) |
| **단조 증가 감지** | "N회 연속 감소 없음" 카운터. 정상 앱은 GC 로 톱니 모양, 누수는 계단만 | Before: 샘플 15개 중 감소 0회 / After: 약 65초마다 감소 |
| **앱 한도 대비 %** | `RSS ÷ MEMORY_LIMIT` 을 함께 기록 (시스템 대비 MEM% 는 8GB 서버에서 3% 로 위험을 숨김) | 267.6/256 = 104% |
| **경보 전달** | 임계 시 `logger -p user.warning`(syslog) 또는 웹훅, 중복 억제(쿨다운) | — |
| **장기 보관·회전** | B4-1 처럼 크기 기준 로그 회전 + 일별 요약(최대·평균·기울기) | — |

```bash
# 예: 최근 30개 샘플(1분)의 RSS 기울기(MB/분)
tail -n 30 monitor.log | awk -F'RSS:' '{split($2,a,"MB"); n++; x=n*2; y=a[1]; sx+=x; sy+=y; sxy+=x*y; sxx+=x*x}
    END { if (n > 1) printf "%.1f MB/min\n", (n*sxy - sx*sy) / (n*sxx - sx*sx) * 60 }'
```

### 3가지 장애 중 실제 서비스에서 가장 치명적인 것과 근본 예방

**Deadlock 이 가장 치명적이라고 판단합니다.**

| 기준 | OOM | CPU | **Deadlock** |
| --- | --- | --- | --- |
| 감지 | 프로세스가 사라짐 → 즉시 알 수 있음 | 사라짐 → 즉시 | **PID 가 살아 있어 헬스체크 통과**, 에러 로그도 없음 |
| 자동 복구 | systemd `Restart=` 로 재시작 | 재시작 | **재시작 트리거가 없음** (죽지 않았으므로) |
| 영향 시간 | 재시작까지 수 초 | 수 초 | **사람이 알아챌 때까지 무한** |
| 데이터 | 처리 중 작업 유실 | 유실 | 락을 쥔 채 멈춰 **다른 서비스까지 연쇄 대기**(DB 락, 커넥션 풀 고갈) |
| 재현 | 결정적(한도에 비례) | 결정적 | **타이밍 의존** — 테스트에서 놓치기 쉬움 |

OOM·CPU 는 "시끄럽게 실패(fail loud)" 하지만 Deadlock 은 **"조용히 실패(fail silent)"** 합니다. 이번 실험에서도 OOM 은 33초 만에 exit 137 로 드러났지만, Deadlock 은 81초 이상 아무 신호 없이 멈춰 있었습니다(후속 실험: 10/10 재현, 300초 관찰에도 자가 복구 없음).

권장 치명도로 옮기면 **Deadlock Sev1 · OOM Sev2 · CPU Sev3**(대체 인스턴스 없이 서비스가 멈추면 Sev2)이고, 등급 정의·탐지/대응/복구 목표(SLA)는 [runbook 1절](runbook.md#1-장애-유형별-치명도와-대응-sla)에 있습니다. CPU 를 가장 낮게 둔 근거는 같은 머신의 다른 프로세스 지연이 변하지 않았다는 측정입니다([CPU 리포트 4장](../issues/02-cpu-watchdog.md#다른-프로세스에-미치는-영향-latency)).

**근본 예방**
1. **설계:** 락 획득 순서 전역 규칙(항상 A → B), 락 범위 최소화, 가능하면 공유 자원 대신 큐(메시지 전달)
2. **코드:** `acquire(timeout=…)` 필수화, 타임아웃 시 에러 로그 + 보유 락 해제 후 재시도
3. **검증:** 동시성 테스트를 반복 실행(스트레스), 정적 분석·리뷰 체크리스트에 "락 2개 이상 중첩" 항목
4. **운영:** liveness 를 "PID 존재" 가 아니라 **heartbeat/진행 지표**로 판정(일정 시간 로그·처리량 정지 시 재시작), 멈춤 감지 시 스레드 덤프(`py-spy dump`)를 먼저 남기고 재시작

### OOM 과 Deadlock 이 동시에 발생했다면 트러블슈팅 순서

**시스템 메모리가 실제로 고갈되고 있다면** OOM 대응(확산 차단) → Deadlock 증거 수집 → Deadlock 복구 → 두 원인 분석 순서로 하겠습니다. 반대로 이번 MemoryGuard 처럼 앱이 자기 한도에서 스스로 죽어 시스템 메모리가 여유로우면(7~8%) 확산 위험이 없으므로, 조용히 멈춘 Deadlock 복구를 먼저 합니다. 두 장애 이상이 겹칠 때의 판단 기준표·조합별 매트릭스·단계별 절차는 [runbook 2절](runbook.md#2-동시-장애-우선순위-매트릭스와-단계별-대응-절차)에 정리했습니다. 아래는 메모리 고갈이 진행 중인 경우입니다.

1. **OOM 쪽 확산 차단이 최우선.** 메모리 고갈은 시간이 지날수록 커널 OOM Killer 가 **무관한 프로세스까지** 죽일 수 있고 sshd 까지 잃으면 진단 자체가 불가능해집니다. 누수 프로세스의 RSS 기울기로 "남은 시간"을 먼저 계산하고(`free -m`, monitor.sh), 필요하면 해당 프로세스를 먼저 재시작하거나 한도를 조정합니다. Deadlock 은 **멈춰 있을 뿐 악화되지 않으므로**(CPU·메모리 변화 0) 몇 분 기다려도 상황이 나빠지지 않습니다.
2. **Deadlock 프로세스는 죽이기 전에 증거부터.** 재시작하면 증거가 사라집니다. `diagnose-hang.sh`(ps -L wchan, top -H, 로그 마지막 줄), 가능하면 스레드 스택 덤프를 남깁니다. 수 초면 끝나는 작업입니다.
3. **Deadlock 복구:** SIGTERM → 유예 → SIGKILL 로 재시작. 재발 방지가 확인될 때까지 `MULTI_THREAD_ENABLE=false` 로 기동.
4. **상관관계 확인:** 두 장애가 독립인지 확인합니다. 예를 들어 Deadlock 으로 처리가 멈춘 동안 요청이 쌓여 다른 프로세스 메모리가 늘었을 수 있습니다(대기 큐 누적). 이 경우 Deadlock 이 근본 원인이므로 둘을 함께 고쳐야 합니다.

판단 근거를 한 줄로: **"악화되는 장애(OOM)를 먼저 멈추고, 멈춰 있는 장애(Deadlock)는 증거를 보존한 뒤 처리한다."**

### 소스 코드를 고칠 수 있다면 장애 유형별 코드 레벨 개선

| 장애 | 임시 조치(이번) | 코드 레벨 개선 |
| --- | --- | --- |
| **OOM** | `MEMORY_LIMIT` 256 → 512 | ① 누적 컨테이너에 상한·만료 (`deque(maxlen)`, `lru_cache(maxsize)`, TTL) ② 처리 끝난 객체 참조 해제·버퍼 재사용 ③ `tracemalloc` 스냅샷 비교로 누수 위치 고정 + 메모리 회귀 테스트 ④ SIGKILL 대신 SIGTERM → 유예 → SIGKILL |
| **CPU** | `CPU_MAX_OCCUPY` 90 → 50 | ① 기동 시 `CPU_MAX_OCCUPY > 임계치` 면 기동 실패(설정 검증) ② "N초 연속 초과" 일 때만 개입, 1단계 throttle → 2단계 종료 ③ 고정 크기 워커 풀 + 작업 큐, systemd `CPUQuota` / cgroup `cpu.max` 로 OS 가 상한 강제 ④ Watchdog 판정을 OS 실측(`/proc/self/stat`) 기준으로 |
| **Deadlock** | `MULTI_THREAD_ENABLE` true → false | ① 락 획득 순서 고정(A → B) ② `acquire(timeout)` + 백오프 재시도 ③ 필요한 락을 한 번에 획득하거나 상위 락 하나로 통합 ④ 로그 쓰기용 공유 메모리 락 대신 `queue.Queue` + 전용 로그 스레드 ⑤ heartbeat 로그로 멈춤 감지 |

각 리포트의 "근본 해결 제안" 절에 근거와 함께 정리했습니다.

### 다시 처음부터 한다면 다르게 접근할 점

1. **처음부터 "실행 = 스크립트" 로.** 초반에 터미널에서 직접 실행하며 관찰하다 보니 같은 조건을 다시 만들기 어려웠습니다. `run-scenario.sh` 로 실행·관제·요약을 묶은 뒤부터 반복 실행과 비교가 쉬워졌습니다. 다음에는 첫 실행부터 이 틀로 시작하겠습니다.
2. **앱 지표와 OS 지표를 처음부터 나란히.** CPU 장애에서 "앱은 55% 라는데 OS 는 2%" 를 늦게 발견했습니다. 처음부터 두 값을 같은 타임라인에 놓았다면 Watchdog 이 무엇을 기준으로 판단하는지 더 빨리 알았을 것입니다.
3. **종료 주체를 추측하지 말고 기록.** "OOM 이니 커널이 죽였겠지" 라고 가정하기 쉬운데, strace 로 `kill(자기 PID)` 를 직접 확인한 뒤에야 확신할 수 있었습니다. 다음에는 첫 재현부터 `--trace` 를 켜겠습니다.
4. **경계값 실험을 계획에 포함.** `cpu-60` 실험 하나로 "임계치는 CPU_MAX_OCCUPY 가 아니라 고정 50%" 라는 핵심 사실이 드러났습니다. Before/After 두 점만이 아니라 **경계를 찍는 실험**을 처음부터 설계하겠습니다.
5. **멈춤 상태 진단은 증거 보존을 먼저.** Deadlock 을 처음 봤을 때 바로 종료하고 싶었지만, 종료 전에 `diagnose-hang.sh` 로 남긴 스냅샷이 리포트의 핵심 근거가 됐습니다. "죽이기 전에 찍는다" 를 습관으로 만들겠습니다.

이 회고 항목은 다음 장애·PR 때 빠지지 않도록 체크리스트로 만들었습니다: [runbook 4절](runbook.md#4-회고-체크리스트) · PR 을 열면 자동으로 뜨는 [PR 템플릿](../.github/PULL_REQUEST_TEMPLATE.md) · Issue 템플릿의 "회고" 항목.
