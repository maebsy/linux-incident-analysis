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

| 필드 | 출처 | 왜 이 값인가 |
| --- | --- | --- |
| `PID` | `/proc/*/cmdline` + 부모 관계 | PyInstaller 바이너리는 부트로더(부모)·앱(자식) 2개로 뜬다. 부모는 RSS 2MB 로 고정이라 부모를 보면 누수가 안 보인다 → **부모도 앱인 자식**을 고른다 |
| `STATE` | `/proc/<pid>/stat` 3번째 필드 | R/S/D/Z. Deadlock 은 S(sleep) 로 고정, 크래시는 사라짐(GONE) |
| `CPU` | `/proc/<pid>/stat` utime+stime 의 **구간 차이** | 아래 3장 |
| `RSS` / `MEM` | `/proc/<pid>/status` VmRSS / MemTotal | 가상 메모리(VSZ)가 아니라 실제 점유 물리 메모리. 누수는 RSS 의 **기울기**로 본다 |
| `THREADS` | `/proc/<pid>/status` Threads | 동시성 모드에서 1 → 3 으로 바뀌는 것이 보인다 |
| `SYS_CPU` / `SYS_MEM` | `/proc/stat`, `/proc/meminfo` | "시스템 전체" 와 "이 프로세스" 를 나란히 둬야 원인이 한 프로세스인지 구분된다 |
| `LOG_LINES` | 앱 로그 `wc -l` | 무응답 판별: 프로세스는 살아 있는데 줄 수가 멈추면 진행이 없다 |

메모리 증가 패턴은 이렇게 뽑습니다.

```bash
grep -o 'RSS:[0-9.]*' monitor.log | cut -d: -f2           # RSS 추이
awk -F'RSS:' '{split($2,a,"MB"); print $1, a[1]}' monitor.log   # 시각 + RSS
```

## 3. CPU 사용률을 무엇으로 볼 것인가

| 도구 | 옵션 | 보여주는 값 | 이번 분석에서의 쓰임 |
| --- | --- | --- | --- |
| `ps -o pcpu` | `%CPU` | **시작 이후 누적 평균** (총 CPU 시간 ÷ 경과 시간) | 오래 실행된 프로세스는 순간 급상승이 평균에 묻힌다 → 급상승 판별에 부적합 |
| `top -b -n 1 -p PID` | `-b` 배치(파일 저장 가능), `-n 1` 1회, `-p` 대상 지정 | 직전 갱신 주기(기본 3초) 사용률 | 캡처용. `-H` 를 붙이면 스레드 단위 |
| `ps -L -o pid,tid,stat,pcpu,wchan` | `-L` 스레드마다 한 줄, `wchan` 커널 대기 지점 | 스레드별 상태 | Deadlock 진단 |
| **`/proc/<pid>/stat` 차이** | utime(14)+stime(15) 를 Δt 간격으로 2회 | **그 구간의 실제 사용률** (1코어 = 100%) | monitor.sh 의 `CPU` 값. 스크립트에서 정확하고 가볍다 |

> 이번 실험에서 앱 로그의 `[CpuWorker] Current Load` 는 55% 까지 올랐지만, OS 가 측정한 프로세스 CPU 는 0~2% 에 머물렀습니다.
> 즉 이 앱의 "Current Load" 는 **앱 내부 지표**이고, Watchdog 은 OS 사용률이 아니라 이 내부 지표를 기준으로 동작합니다.
> 실제 운영에서는 앱 지표와 OS 지표가 다를 수 있으므로 **둘 다 수집**해야 한다는 근거가 됐습니다. 자세한 내용은 [CPU 리포트](../issues/02-cpu-watchdog.md).

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
