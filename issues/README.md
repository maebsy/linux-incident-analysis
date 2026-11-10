# 리포트 색인

실측 수치는 각 리포트와 연결된 원본 증거를 기준으로 합니다. Sev·대응 시간·점수·운영 임계값은 권장값입니다.

리포트의 증거 발췌는 링크 옆 `Lm–n` 으로 원본 파일의 첫 줄 ~ 마지막 줄 번호를 표시합니다(중간 `…` 은 생략, `←` 는 설명).

| 파일 | 제목 | 사용한 템플릿 | Sev(권장값) | 재현율·관찰 | Issue |
| --- | --- | --- | --- | --- | --- |
| [01-oom-memory-guard.md](01-oom-memory-guard.md) | OOM — MemoryGuard 자체 SIGKILL 종료 | [bug_report.md](../.github/ISSUE_TEMPLATE/bug_report.md) | Sev2 | 최초 3/3, 후속 1/1 종료 | [#1](https://github.com/maebsy/linux-incident-analysis/issues/1) |
| [02-cpu-watchdog.md](02-cpu-watchdog.md) | CPU — Watchdog 정책에 따른 SIGTERM 종료 | [bug_report.md](../.github/ISSUE_TEMPLATE/bug_report.md) | Sev3(대체 인스턴스로 기능 유지 시), 서비스 중단이면 Sev2 이상 | 최초 3/3, 후속 51~90 설정 15/15 종료·50 설정 0/3 종료 | [#2](https://github.com/maebsy/linux-incident-analysis/issues/2) |
| [03-deadlock.md](03-deadlock.md) | Deadlock — PID 유지·락 순환 대기 | [bug_report.md](../.github/ISSUE_TEMPLATE/bug_report.md) | Sev1 | 동시성 true 30/30, false 0/20 교착 (2차 후속 포함) | [#3](https://github.com/maebsy/linux-incident-analysis/issues/3) |
| [04-scheduling-analysis.md](04-scheduling-analysis.md) | 로그 패턴으로 본 비선점 Priority (B > C > A) | [analysis.md](../.github/ISSUE_TEMPLATE/analysis.md) | — (동작 분석) | 8/8 동일 순서 관찰, 장애 재현율이 아닙니다. | [#4](https://github.com/maebsy/linux-incident-analysis/issues/4) |

## 템플릿 필드 충족 체크리스트

✅는 실제 파일에서 해당 필드·섹션을 확인했다는 뜻입니다. —는 해당 항목이 없거나 사용한 템플릿의 대상이 아니라는 뜻이며, 내용의 검증 완료를 의미하지 않습니다. 분석 리포트는 analysis.md의 별도 구조로 확인했습니다. 회고는 별도 섹션·체크리스트가 있는 경우에만 표시합니다.

| 템플릿 필드 | 01 OOM | 02 CPU | 03 Deadlock | 04 분석 |
| --- | --- | --- | --- | --- |
| 머리 표: 작성 템플릿(리포트 추가 항목) | ✅ | ✅ | ✅ | ✅ |
| 머리 표: 대상 | ✅ | ✅ | ✅ | ✅ |
| 머리 표: 환경 | ✅ | ✅ | ✅ | — |
| 머리 표: 재현 조건 | ✅ | ✅ | ✅ | — |
| 머리 표: 재현율 | ✅ | ✅ | ✅ | — |
| 머리 표: 치명도 | ✅ | ✅ | ✅ | — |
| 머리 표: 영향 | ✅ | ✅ | ✅ | — |
| 분석 머리 표: 표본 | — | — | — | ✅ |
| 분석 머리 표: 도구 | — | — | — | ✅ |
| 분석 머리 표: 원본 | — | — | — | ✅ |
| 분석 머리 표: 결론 | — | — | — | ✅ |
| Bug 1. Description | ✅ | ✅ | ✅ | — |
| Bug 2. Evidence & Logs | ✅ | ✅ | ✅ | — |
| Bug 3. Root Cause Analysis | ✅ | ✅ | ✅ | — |
| Bug 4. Workaround & Verification | ✅ | ✅ | ✅ | — |
| 재현 방법 | ✅ | ✅ | ✅ | ✅ |
| 회고 | — | — | — | — |
| Analysis 1. 관찰 개요(리포트: 로그 관찰 개요) | — | — | — | ✅ |
| Analysis 2. 증거 자료 | — | — | — | ✅ |
| Analysis 3. 패턴 분석 및 결론 | — | — | — | ✅ |
| Analysis 4. 장단점 및 적합한 아키텍처 | — | — | — | ✅ |

analysis.md 자체에는 머리 표·재현 방법·회고 필드가 없으며, 분석 리포트의 머리 표와 재현 방법은 추가 작성 항목입니다. Bug 리포트의 회고 항목은 현재 별도 작성이 필요합니다.

## 동시 장애가 겹칠 때

대응 책임자는 다음 규칙을 **번호 순서대로** 적용합니다. 점수표는 판단 근거를 기록하는 권장 보조 수단이며 규칙보다 우선하지 않습니다.

1. **시스템 가용성 우선:** 실제 메모리 고갈·OS CPU 포화·sshd 등 다른 서비스 위협을 먼저 억제합니다. 이번 OOM은 시스템 메모리 7~8%에서 자체 종료했고, CPU 사례는 다른 프로세스 지연 변화가 없었으므로 시스템 고갈·포화로 분류하지 않습니다.
2. **서비스 영향도:** 사용자 기능 중단 범위가 큰 장애부터 복구합니다. 대체 인스턴스와 우회 경로를 확인합니다.
3. **자가 복구 없음:** 영향이 같다면 멈춘 채 지속되는 장애를 우선합니다. Deadlock은 10/10 재현했고 별도 300초 관찰에서 자가 복구가 없었습니다. 세 Before 사례 모두 자동 재시작은 입증되지 않았으므로 종료된 장애도 방치하지 않습니다.
4. **증거 소멸 속도:** 종료 임박 PID의 증거만 수 초(권장값: 3~5초) 먼저 수집합니다. 복구 순서는 바꾸지 않습니다. 긴 진단은 별도 증거 담당이 병행하거나 긴급 억제 후 수행합니다.

여전히 동점이면 Sev1 → Sev2 → Sev3 순서입니다. 동일 Sev까지 같으면 병행 담당자를 배정하고, 병행 불가 시 먼저 탐지한 장애부터 처리하며 선택 이유를 기록합니다(권장값).

| 조합 | 기본 복구 결론 | 전제·예외 |
| --- | --- | --- |
| OOM + CPU | OOM → CPU | 제한된 MemoryGuard 종료 Sev2, 대체 경로가 있는 CPU Sev3 기준입니다. |
| OOM + Deadlock | Deadlock → OOM | 살아 있으나 무진행인 장애를 우선합니다. 실제 메모리 고갈이면 확산 억제가 먼저입니다. |
| CPU + Deadlock | Deadlock → CPU | 실제 사용자 영향이 CPU 쪽에서 더 크면 규칙 2로 변경합니다. |
| 세 가지 | Deadlock → OOM → CPU | 실제 메모리 고갈이면 OOM → Deadlock → CPU입니다. |

기본 결론은 시스템 자원 확산이 없고 사용자 영향이 제한된 경우의 권장 순서입니다. 사용자 영향이 같을 때 Deadlock의 지속 무진행을 먼저 해소합니다. CPU도 Sev2이면 OOM과 자동으로 순서를 고정하지 않고 동일 Sev 처리 규칙을 적용합니다. 증거만 먼저 수집하는 순서를 복구 순서와 혼동하지 않습니다.

1. **탐지:** 증거 담당은 `tools/monitor.sh --pid "$target_pid" --interval 1 --count 3 --app-log "$app_log"`로 지표를 확인하고 대응 책임자는 기능 검사를 수행합니다. 목표는 증상 발생 후 10초, 숨은 무응답은 30초 이내입니다.
2. **분류:** 증거 담당이 종료 코드·앱 로그를 비교하고 `tools/diagnose-hang.sh --pid "$target_pid" --app-log "$app_log" --window 10`으로 교착을 확인하며 대응 책임자가 확정합니다. 탐지 후 30초 이내를 목표로 하되 긴급 억제를 지연하지 않습니다.
3. **규칙 1~4 적용:** 대응 책임자가 확산·사용자 영향·자가 복구·증거 소멸을 차례로 확인하고 복구 순위를 기록합니다. 증거 담당이 관측값을 제공합니다. 탐지 후 1분 이내가 목표입니다.
4. **증거 보존:** 증거 담당이 소멸 임박 PID의 monitor·ps 스냅샷과 app.log를 3~5초 안에 보존하고, 추가 스레드 진단은 탐지 후 1분 이내 병행합니다. 대응 책임자는 복구를 진행합니다.
5. **조치:** 대응 책임자가 환경변수를 보정하고 서비스 재시작·우회를 수행합니다. 증거 담당이 변경값을 기록합니다. 탐지 후 1분 이내 착수, 유형별 복구 SLA 안에 정상화를 목표로 합니다.
6. **검증:** 대응 책임자가 기능 정상화를 확인하고 증거 담당이 격리 환경에서 `tools/run-scenario.sh scenarios/deadlock-after.env --max 120 --interval 1 --out "$validation_dir"` 등 해당 시나리오의 Before/After를 비교합니다. 조치 직후 시작하여 120~300초 관찰합니다.
7. **기록:** 대응 책임자가 순위·변경·롤백·타임라인을 남기고 증거 담당이 로그·result.txt 링크를 첨부합니다. 복구 후 30분 이내 1차 기록이 목표입니다.

위 시간은 모두 **권장값**입니다. PID·로그·출력 디렉터리 변수는 현장값을 지정하며 runner는 관찰 종료 시 앱을 정지하므로 운영 PID 대신 격리 시험 환경에서만 사용합니다. 자세한 판단 기준·점수·명령·SLA는 [runbook 2절](../docs/runbook.md#2-동시-장애-우선순위-매트릭스와-단계별-대응-절차)을 확인해 주세요.

이 파일은 front matter가 없어 `tools/publish-issues.sh`가 `title 없음`으로 건너뛰므로 Issue로 등록하지 않습니다.
