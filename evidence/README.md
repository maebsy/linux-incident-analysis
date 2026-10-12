# evidence — 실행 원본

리포트([`../issues/`](../issues/))가 인용한 **모든 수치와 로그의 원본**입니다. 도구가 남긴 그대로이며 사람이 편집하지 않았습니다.

- 생성: `tools/run-scenario.sh <scenario.env>` → `evidence/<시나리오>/<YYYYMMDD-HHMMSS>/`
- 환경: Ubuntu 24.04 (격리 환경, 2 vCPU / 8GB / swap 없음), 실행 계정 `agent-admin`(uid 30033), `TZ=Asia/Seoul`
- 바이너리: `agent-leak-app-x86` (sha256 `7e0a19cf…bb3e40`), 저장소에는 포함하지 않음
- 전체 요약표: [`summary.md`](summary.md) (`tools/compare.sh` 출력)

## 실행 목록 (17회)

| 폴더 | 조건 (바뀐 변수) | 옵션 | 생존 | 종료 | 인용한 리포트 |
| --- | --- | --- | --- | --- | --- |
| [`oom-before/20261012-223103`](oom-before/20261012-223103/) | `MEMORY_LIMIT=256` | | 33s | 137 SIGKILL | OOM 2-1, 2-3 |
| [`oom-before/20261012-223140`](oom-before/20261012-223140/) | `MEMORY_LIMIT=256` | `--trace` | 33s | 137 SIGKILL | OOM 2-4 |
| [`oom-before/20261012-225151`](oom-before/20261012-225151/) | `MEMORY_LIMIT=256` | top 캡처 | 34s | 137 SIGKILL | OOM 2-2 |
| [`oom-128/20261012-223217`](oom-128/20261012-223217/) | `MEMORY_LIMIT=128` (경계) | | 18s | 137 SIGKILL | OOM 2-5 |
| [`oom-after/20261012-223240`](oom-after/20261012-223240/) | `MEMORY_LIMIT=512` | `--max 300` | 300s+ | 관찰 종료 | OOM 4 |
| [`cpu-before/20261012-223757`](cpu-before/20261012-223757/) | `CPU_MAX_OCCUPY=90` | | 37s | 143 SIGTERM | CPU 2-1, 2-3 |
| [`cpu-before/20261012-223838`](cpu-before/20261012-223838/) | `CPU_MAX_OCCUPY=90` | `--trace` | 25s | 143 SIGTERM | CPU 2-5 |
| [`cpu-before/20261012-225108`](cpu-before/20261012-225108/) | `CPU_MAX_OCCUPY=90` | top 캡처 | 31s | 143 SIGTERM | CPU 2-3 |
| [`cpu-60/20261012-223907`](cpu-60/20261012-223907/) | `CPU_MAX_OCCUPY=60` (경계) | | 24s | 143 SIGTERM | CPU 2-2 |
| [`cpu-after/20261012-223936`](cpu-after/20261012-223936/) | `CPU_MAX_OCCUPY=50` | `--max 180` | 180s+ | 관찰 종료 | CPU 4 |
| [`deadlock-before/20261012-224253`](deadlock-before/20261012-224253/) | `MULTI_THREAD_ENABLE=true` | `--max 90` | 90s+ (멈춤) | 관찰 종료 | Deadlock 2 |
| [`deadlock-after/20261012-224440`](deadlock-after/20261012-224440/) | `MULTI_THREAD_ENABLE=false` | `--max 120` | 120s+ | 관찰 종료 | Deadlock 4 |
| [`schedule-runs/cpu-after/*`](schedule-runs/cpu-after/) (5회) | 정상 설정 (`cpu-after.env`) | `--max 8` | — | 관찰 종료 | 스케줄링 2 |
| [`schedule-runs/analysis.txt`](schedule-runs/analysis.txt) | 위 5회 + After 3회 분석 | | | | 스케줄링 2 |
| [`boot/missing-mission-env.txt`](boot/missing-mission-env.txt) | 미션 환경변수 미설정 | | — | 1 (Boot Failed) | 사전 확인 |

공통값: 표에 적은 변수 외에는 `MEMORY_LIMIT=512` `CPU_MAX_OCCUPY=50` `MULTI_THREAD_ENABLE=false` ([`../scenarios/`](../scenarios/)).

## 폴더 안의 파일

| 파일 | 내용 | 만드는 곳 |
| --- | --- | --- |
| `app.log` | 앱 표준출력/에러 전체 (Boot Sequence, Resource Check, 워커 로그, CRITICAL) | 앱 |
| `monitor.log` | 2초 간격 프로세스 관제. 종료되면 마지막 줄 `STATE:GONE` | `tools/monitor.sh` |
| `ps.txt` | 시작 3초 후 `ps -ef`, `pstree -p` (부모 부트로더 / 자식 앱 PID) | run-scenario.sh |
| `top.txt` | `top -b -d 5 -p <앱 PID>` (5초 간격 %CPU·RES·NI). 22:51 이후 실행에만 있음 | run-scenario.sh |
| `trace.txt` | `--trace` 실행만. `strace -f -tt -e trace=kill,tgkill,tkill,exit_group` | run-scenario.sh |
| `diagnose.txt` | `--max` 까지 살아 있던 실행만. 무응답 진단 결과 | `tools/diagnose-hang.sh` |
| `result.txt` | 조건·시작/종료·생존 시간·종료 코드(신호 이름)·최대 RSS/CPU·핵심 로그 | run-scenario.sh |

## 읽을 때 주의할 점

- **`result.txt` 의 `end`** 는 프로세스가 끝난 시각 또는 `--max` 에 도달한 시각입니다. `status: alive` 인 실행은 이어서 `diagnose-hang.sh`(10초 관찰)를 실행한 뒤 관찰자가 종료하므로, `app.log` 가 `end` 보다 약 12초 더 이어집니다. 이때의 exit 143 은 **관찰자의 SIGTERM** 이라 장애가 아닙니다(`status` 로 구분).
- **`CPU`(monitor.log) 는 OS 실측**(1코어 = 100%), 앱 로그의 **`Current Load` 는 앱 내부 지표**입니다. 둘은 다릅니다 → [CPU 리포트 2-3](../issues/02-cpu-watchdog.md#2-3-monitorsh-관제--top--이-프로세스-이-시점)
- **`MEM%`** 는 시스템 전체(8GB) 대비라 작게 보입니다. 누수 판단은 `RSS`(MB)의 기울기로 했습니다.
- PID 는 실행마다 다릅니다. 같은 실행 안에서는 `ps.txt` · `monitor.log` · `app.log`(`Self-terminating process <PID>`) · `trace.txt` 의 PID 가 일치합니다.
- `boot/missing-mission-env.txt`: 미션 변수를 설정하지 않으면 Boot [6/6] 에서 종료됩니다. 이때 안내가 `MEMORY_LIMIT … Recommend: Under 512MB` 로 나오지만, 실행 후 Resource Check 는 `Recommend Over 256MB` 로 판정합니다. 실제 동작(512 에서 생존)은 후자와 일치해 리포트는 실행 결과를 기준으로 작성했습니다.
