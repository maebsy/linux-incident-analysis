# 분석 방법론 — 어떤 도구를, 어떤 순서로, 왜

장애 3건(OOM · CPU · Deadlock)을 같은 절차로 다뤘습니다. **"현상을 숫자로 고정 → 앱 로그로 직접 원인 확인 → OS 도구로 교차 검증 → 변수 하나만 바꿔 Before/After"** 순서입니다.

- [1. 실험 설계](#1-실험-설계)
- [2. 관제 도구 monitor.sh](#2-관제-도구-monitorsh)
- [3. CPU 사용률을 무엇으로 볼 것인가](#3-cpu-사용률을-무엇으로-볼-것인가)
- [4. 종료 원인 판별: 앱이 죽였나, 커널이 죽였나](#4-종료-원인-판별-앱이-죽였나-커널이-죽였나)
- [5. "살아 있지만 멈춘" 프로세스 진단 순서](#5-살아-있지만-멈춘-프로세스-진단-순서)
- [6. 재현 환경과 한계](#6-재현-환경과-한계)

## 1. 실험 설계

| 원칙 | 적용 |
| --- | --- |
| **변수 하나만 바꾼다** | 각 Before/After 는 해당 환경변수 하나만 다르다 (`scenarios/*.env`). 예: OOM 은 `MEMORY_LIMIT` 256 → 512, 나머지는 동일 |
| **같은 조건을 2회 이상** | Before 는 2회씩 실행해 생존 시간이 우연이 아님을 확인 (OOM 33s · 33s) |
| **경계 실험 추가** | 원인을 더 정확히 찍기 위한 보조 실험: `oom-128`(한도를 더 낮추면 더 빨리 죽는가), `cpu-60`(권장값을 조금만 넘겨도 죽는가) |
| **스크립트로만 실행** | 사람이 터미널에서 친 명령은 재현이 어렵다. `tools/run-scenario.sh` 가 앱 실행·관제·진단·요약을 한 번에 하고 결과 폴더를 남긴다 |
| **원본 증거 보존** | 앱 로그·관제 로그·ps/pstree·strace 를 가공 없이 `evidence/<시나리오>/<실행 시각>/` 에 저장. 리포트의 수치는 모두 여기서 인용 |

```
run-scenario.sh scenarios/oom-before.env
 ├─ 앱 실행 (agent-admin, 일반 계정)  → app.log      앱 표준출력 전체
 ├─ monitor.sh --interval 2           → monitor.log  2초 간격 프로세스 실측
 ├─ 3초 후 ps -ef / pstree            → ps.txt       부모·자식 구조, PID
 ├─ (--trace) strace -f               → trace.txt    누가 어떤 신호를 보냈나
 ├─ (--max 초까지 살아 있으면) diagnose-hang.sh → diagnose.txt
 └─ 종료 코드·생존 시간·핵심 로그 요약 → result.txt
```

## 2. 관제 도구 monitor.sh

B4-1 의 `monitor.sh` 는 **서버 전체**를 1분마다 기록했습니다. 장애 분석에서는 **특정 프로세스**가 **몇 초 사이에** 어떻게 변하는지가 중요해서, 같은 수집 방식(`/proc` 직접 읽기, 고정 포맷)을 유지한 채 대상 PID 를 고정하고 2초 간격으로 반복하도록 확장했습니다.

```
[2026-10-12 22:31:09] PROCESS:agent-leak-app PID:3848 STATE:S CPU:0.5% MEM:0.6% RSS:50.0MB THREADS:1 SYS_CPU:1.2% SYS_MEM:7.0% LOG_LINES:31
```

| 필드(CSV 열 이름) | 의미 | 출처 | 단위 |
| --- | --- | --- | --- |
| 시각 (`ts`) | 샘플 출력 시각입니다. | `date` | `YYYY-MM-DD HH:MM:SS` |
| `epoch` (CSV 전용) | 샘플의 Unix 시각입니다. | `date +%s` | 초 |
| `PROCESS` (CSV 없음) | 관제 대상 표시 이름입니다. | monitor.sh 대상 패턴·표시 이름 | 문자열 |
| `PID` (`pid`) | 관제하는 앱 자식 프로세스입니다. | `/proc/*/cmdline`과 부모 관계, 또는 `--pid` 지정 | 프로세스 ID |
| `STATE` (`state`) | R/S/D/Z 등 상태이며 사라지면 GONE입니다. | `/proc/<pid>/stat` 3번째 필드, `/proc` 존재 확인 | 상태 코드 |
| `CPU` (`cpu_pct`) | utime+stime 구간 차이를 주기와 CLK_TCK로 나눕니다. 1코어 = 100%입니다. | `/proc/<pid>/stat` 14·15번째 필드 | % |
| `MEM` (`mem_pct`) | RSS / MemTotal × 100입니다. | `/proc/<pid>/status` VmRSS, `/proc/meminfo` MemTotal | % |
| `RSS` (`rss_mb`) | 실제 점유 물리 메모리입니다. VmRSS / 1024입니다. | `/proc/<pid>/status` VmRSS | 표시 MB (MiB 상당) |
| `THREADS` (`threads`) | 대상 프로세스의 스레드 수입니다. | `/proc/<pid>/status` Threads | 개 |
| `SYS_CPU` (`sys_cpu_pct`) | 전체 코어의 구간 busy 비율입니다. idle에는 iowait를 포함합니다. | `/proc/stat` 첫 cpu 행의 구간 차이 | % |
| `SYS_MEM` (`sys_mem_pct`) | (MemTotal − MemAvailable) / MemTotal × 100입니다. | `/proc/meminfo` | % |
| `LOG_LINES` (`log_lines`) | 앱 로그 줄 수입니다. 미지정·읽기 불가 시 `-`, CSV는 빈 값입니다. | `--app-log` 파일의 `wc -l` | 줄 |

PyInstaller 부모 부트로더는 RSS가 작고 고정되어 앱 누수를 놓칠 수 있으므로 앱 자식을 관제합니다. CPU는 구간 변화, 누수는 RSS 기울기, 무진행은 로그 줄 수·CPU·락 대기를 함께 확인합니다. RSS의 표기 MB는 KiB를 1024로 나눈 값입니다.

### 2-1. 실험 ID 머리줄과 CSV (추세 분석용)

`run-scenario.sh` 는 실행마다 실험 ID(`<시나리오>-<YYYYMMDD-HHMMSS>`, 결과 폴더 이름과 같음)를 만들어 **모든 산출물 첫 줄에 같은 ID 와 시작 시각**을 남기고, 같은 샘플을 CSV 로도 저장합니다(2026-11 후속 실험부터).

```text
app.log      # experiment=oom-before-20261110-103727 start=2026-11-10 10:37:27 scenario=oom-before env: MEMORY_LIMIT=256 …
monitor.log  # monitor.sh experiment=oom-before-20261110-103727 start=2026-11-10 10:37:27 interval=2s clk_tck=100 pid=44 pattern=agent-leak-app
monitor.csv  ts,epoch,pid,state,cpu_pct,mem_pct,rss_mb,threads,sys_cpu_pct,sys_mem_pct,log_lines
result.txt   experiment / start / end / survival / app_pid / interval / last_loads / last_heap …
```

실행 샘플 원본: [2초 간격 33초 (OOM Before)](../evidence/oom-before/20261012-223103/monitor.log) · [1초 간격 + CSV (OOM Before)](../evidence/followup/oom-before/) · [1초 간격 600초 장기 시계열 + CSV (OOM After)](../evidence/followup/oom-after/)

### 2-2. 샘플 주기와 측정 오차

CPU 는 tick(1/CLK_TCK 초, 이 환경 10ms) 단위로만 셀 수 있어서, 구간 길이가 짧을수록 tick 하나의 무게가 커집니다. 양자화 오차는 **±100 / (간격 × CLK_TCK) %p** 입니다.

| 간격 | 이론 양자화 오차 | 실측: 50% duty 제어 부하, 60초 (평균 · 표준편차 · 범위) | 판단 |
| --- | --- | --- | --- |
| 0.5초 | ±2.0%p | 51.05 · 1.48 · 48.0 ~ 54.0 (120샘플) | 짧은 스파이크는 잡지만 값이 흔들림. 비권장 |
| 1초 | ±1.0%p | 50.50 · 0.70 · 49.0 ~ 52.0 (60샘플) | 30초 안에 끝나는 장애(OOM 33s)의 기울기를 촘촘히 볼 때 |
| **2초 (기본)** | ±0.5%p | 50.10 · 0.35 · 49.5 ~ 51.0 (30샘플) | 오차와 해상도의 균형. 리포트의 모든 실행 |
| 5초 | ±0.2%p | 50.05 · 0.14 · 49.8 ~ 50.2 (12샘플) | 장시간 관찰용. 25MB/3초 계단 같은 변화가 뭉개짐 |

- 실측 원본: [`evidence/followup/sampling/`](../evidence/followup/sampling/) (20ms 계산 + 20ms 쉼을 반복하는 이론값 50% 부하를 네 간격으로 동시에 관제, 재현 컨테이너). 장애 앱이 아니라 정답을 아는 부하로 측정 도구만 검증한 것입니다.
- RSS 는 순간값이라 주기 오차가 없고, 주기는 **해상도**만 정합니다. 앱이 3.03초마다 25MB 를 잡으므로 2초 주기에서는 계단(0 또는 25MB 증가)으로, 1초 주기에서는 3샘플마다 한 번 오르는 모양으로 보입니다.
- 권장: 기본 2초, 1분 안에 끝나는 장애는 1초, 수 시간 관찰은 5초. 0.5초 미만은 측정 자체(`sleep`·`awk` 실행)가 결과에 섞이므로 쓰지 않습니다.

메모리 증가 패턴은 이렇게 뽑습니다.

```bash
grep -o 'RSS:[0-9.]*' monitor.log | cut -d: -f2           # RSS 추이
awk -F'RSS:' '{split($2,a,"MB"); print $1, a[1]}' monitor.log   # 시각 + RSS
awk -F, 'NR>1 && $7!="" {print $2, $7}' monitor.csv           # epoch + RSS (CSV, 기울기 계산용)
```

## 3. CPU 사용률을 무엇으로 볼 것인가

| 도구 | 옵션 | 보여주는 값 | 이번 분석에서의 쓰임 |
| --- | --- | --- | --- |
| `ps -o pcpu` | `%CPU` | **시작 이후 누적 평균** (총 CPU 시간 ÷ 경과 시간) | 오래 실행된 프로세스는 순간 급상승이 평균에 묻힌다 → 급상승 판별에 부적합 |
| `top -b -n 1 -p PID` | `-b` 배치(파일 저장 가능), `-n 1` 1회, `-p` 대상 지정 | 후속 표본은 갱신 구간 사용률, 첫 표본은 동일하게 해석하지 않음 | 캡처용. `-H` 를 붙이면 스레드 단위 |
| `ps -L -o pid,tid,stat,pcpu,wchan` | `-L` 스레드마다 한 줄, `wchan` 커널 대기 지점 | 스레드별 상태 | Deadlock 진단 |
| **`/proc/<pid>/stat` 차이** | utime(14)+stime(15) 를 Δt 간격으로 2회 | **그 구간의 실제 사용률** (1코어 = 100%) | monitor.sh 의 `CPU` 값. 스크립트에서 정확하고 가볍다 |

> 이번 실험에서 앱 로그의 `[CpuWorker] Current Load` 는 55% 까지 올랐지만, OS 가 측정한 프로세스 CPU 는 0~2% 에 머물렀습니다.
> 즉 이 앱의 "Current Load" 는 **앱 내부 지표**이고, Watchdog 은 OS 사용률이 아니라 이 내부 지표를 기준으로 동작합니다.
> 실제 운영에서는 앱 지표와 OS 지표가 다를 수 있으므로 **둘 다 수집**해야 한다는 근거가 됐습니다. 자세한 내용은 [CPU 리포트](../issues/02-cpu-watchdog.md).

### 선택한 방법과 대체 도구

| 방법 | 측정 방식 | 장점 | 단점 | 이번에 쓰지 않은/쓴 이유 |
| --- | --- | --- | --- | --- |
| `/proc` 구간 차이 (채택) | utime+stime을 두 번 읽어 `100 × Δticks / (CLK_TCK × Δt)`로 계산합니다. | PID·주기를 고정하고 같은 샘플을 로그·CSV에 남길 수 있습니다. | 직접 파싱과 tick 양자화 오차 관리가 필요하며 PID 교체를 구분해야 합니다. | 표준 셸·awk로 구현하며 장애 직전 구간과 RSS를 함께 기록하려고 채택했습니다. |
| `ps %cpu` | 시작 이후 누적 CPU 시간 / 경과 시간입니다. | 설치 부담이 작고 상태·PID를 함께 보기 쉽습니다. | 오래 실행하면 짧은 급상승이 누적 평균에 묻힙니다. | 프로세스·스레드 상태 확인에 사용했고 순간 CPU 판단에는 쓰지 않았습니다. |
| `top -b` | 반복 갱신 시 CPU 시간 차이를 표시합니다. 첫 표본은 후속 구간과 구분합니다. | 배치 출력 저장과 `-H` 스레드 확인이 가능합니다. | 첫 표본만으로 특정 구간 부하를 단정하기 어렵고 출력 파싱이 필요합니다. | RES·스레드 상태 교차 확인에 사용했고 주 관제는 `/proc`로 통일했습니다. |
| `pidstat` (`sysstat`) | 지정 간격의 프로세스·스레드 CPU 카운터 차이를 보고합니다. | CPU·문맥 전환 등 상세 지표를 함께 수집하기 좋습니다. | sysstat 추가 설치가 필요합니다. | 기본 환경의 표준 명령어와 `/proc`로 필요한 지표를 확보하여 채택하지 않았습니다. |
| `psutil.Process().cpu_percent(interval)` | 내부적으로 Linux의 같은 `/proc` CPU 값을 읽고 interval 구간 차이를 계산합니다. | Python에서 구조화된 값으로 다루기 쉽습니다. | Python 패키지 설치가 필요합니다. | 미션이 **리눅스 표준 명령어** 사용을 요구하므로 관제에 채택하지 않았습니다. |
| cgroup `cpu.stat` | cgroup 누적 CPU 시간(예: v2 `usage_usec`)의 구간 차이 / 경과 시간입니다. | 서비스·컨테이너 전체 CPU와 throttling을 확인하기 좋습니다. | 개별 PID와 범위가 다르고 cgroup 버전·경로·quota 해석이 필요합니다. | 이번 분석은 앱 자식 PID를 고정하므로 주 측정으로 채택하지 않았습니다. 운영 서비스 전체 검증에는 보조 지표로 쓸 수 있습니다. |

## 4. 종료 원인 판별: 앱이 죽였나, 커널이 죽였나

같은 "갑자기 사라짐" 이라도 원인에 따라 조치가 완전히 다릅니다.

| 단서 | 앱 정책(MemoryGuard/Watchdog) | 커널 OOM Killer | 외부 kill |
| --- | --- | --- | --- |
| 앱 로그 마지막 줄 | `[CRITICAL] … Self-terminating process <PID>` | 아무 예고 없음 | 아무 예고 없음 |
| 종료 코드 | 137(SIGKILL) / 143(SIGTERM) | 137 | 신호에 따라 |
| `strace -f` | **`kill(<자기 PID>, SIGKILL)` 시스템 콜이 보인다** | 시스템 콜 없이 `+++ killed by SIGKILL +++` | 시스템 콜 없음 |
| 커널 로그 | 없음 | `dmesg`: `Out of memory: Killed process …` | 없음 |
| 시스템 메모리 | 여유 있음 | 고갈 직전 | 무관 |

종료 코드 해석: `128 + 신호 번호`. 137 = 128 + 9(SIGKILL), 143 = 128 + 15(SIGTERM). `run-scenario.sh` 가 `kill -l $((code-128))` 로 신호 이름까지 기록합니다.

`--trace` 실행은 앱을 `strace -f -tt -e trace=kill,tgkill,tkill,exit_group` 의 자식으로 띄워 **신호를 보낸 주체**를 시스템 콜 수준에서 남깁니다. 앱 코드를 들여다보는 것(디컴파일)이 아니라 OS 에 요청한 동작만 관찰하는 것이라 과제 제약(리버스 엔지니어링 금지)에 해당하지 않습니다.

## 5. "살아 있지만 멈춘" 프로세스 진단 순서

`tools/diagnose-hang.sh` 가 이 순서를 그대로 자동화합니다. 각 단계가 다음 단계를 볼 이유를 만듭니다.

| 단계 | 질문 | 도구 | Deadlock 일 때 결과 | 이 단계가 필요한 이유 |
| --- | --- | --- | --- | --- |
| 1 | 살아 있나? | `ps -ef`, `pstree -p` | PID 존재 | 크래시(OOM/CPU)와 구분 |
| 2 | 일을 하나? | `/proc/<pid>/task/*/stat` 를 10초 간격 2회 | CPU tick 변화 **0** | "CPU 0%" 한 번은 쉬는 중일 수도 있다. **구간 변화 0** 이어야 멈춤 |
| 3 | 메모리·출력이 변하나? | VmRSS, 로그 줄 수·mtime | 모두 그대로 | 누수(메모리만 변함)나 느린 처리(로그는 진행)와 구분 |
| 4 | 스레드는 어디서 멈췄나? | `ps -L -o …wchan`, `top -H` | 모든 스레드 `S` + wchan `futex_do_wait` (커널 버전에 따라 `futex_wait_queue`) | 바쁜 무한 루프(R, CPU 100%)와 구분. futex = 락 대기 |
| 5 | 무엇을 기다리나? | 앱 로그 마지막 `LOCK ACQUIRED` / `WAITING for` | 1 → A 보유·B 대기, 2 → B 보유·A 대기 | **순환 대기**를 직접 증명 |

CPU 0 만 보고 Deadlock 이라 하지 않고, **"CPU 변화 0 + 메모리 고정 + 로그 정지 + 전 스레드 락 대기 + 순환 대기 로그"** 가 모두 성립할 때만 Deadlock 으로 판정합니다.

## 6. 재현 환경과 한계

| 항목 | 값 |
| --- | --- |
| OS | Ubuntu 24.04 (격리 컨테이너, 2 vCPU, 메모리 8GB, swap 없음) |
| 실행 계정 | agent-admin (일반 계정, root 아님) |
| 바이너리 | `agent-leak-app-x86` (sha256 `7e0a19cf…bb3e40`) |
| 시간대 | Asia/Seoul (로그 타임스탬프 기준) |

- 앱의 시간 경과(누수 속도, 부하 상승 속도)는 앱 내부 타이머 기준이라 환경이 달라도 비슷하게 재현됩니다. 생존 시간은 몇 초 차이가 날 수 있습니다.
- `MEM%` 는 시스템 전체 메모리 대비라 VM 메모리 크기에 따라 값이 달라집니다. 판단은 **RSS(MB)** 와 앱 한도 기준으로 했습니다.
- VM 에서 직접 재현할 때: `sudo -iu agent-admin bash -c 'cd <repo> && tools/run-all.sh'` (약 20분).
