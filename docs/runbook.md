# 장애 대응 Runbook

이 문서는 [OOM 리포트](../issues/01-oom-memory-guard.md), [CPU 리포트](../issues/02-cpu-watchdog.md), [Deadlock 리포트](../issues/03-deadlock.md), [실행 요약](../evidence/summary.md)을 근거로 작성했습니다. 실측값과 달리 아래 등급·SLA·알림 임계값·운영 경로는 모두 **권장값**이며, 운영 계약이나 이미 구현된 알림을 뜻하지 않습니다.

## 1. 장애 유형별 치명도와 대응 SLA

| 등급 | 의미(권장값) |
| --- | --- |
| Sev1 | 주요 기능 무응답, 광범위한 사용자 영향 또는 다른 서비스로 확산할 위험이 있어 즉시 대응합니다. |
| Sev2 | 특정 서비스가 중단되었으나 영향이 제한되어 있고 복구 경로를 확인할 수 있습니다. |
| Sev3 | 중복 인스턴스 등으로 사용자 영향이 제한되고 통제된 복구가 가능한 정책 위반입니다. |

탐지 목표는 증상 발생부터, 1차 대응·복구 목표는 탐지부터 잽니다. 1차 대응은 담당자 확인과 영향 평가, 복구는 사용자 기능 정상화를 의미합니다. 다음 시간은 모두 **권장 SLA**이며 실험 생존 시간이 아닙니다.

| 유형 | 권장 등급 | 근거(영향, 탐지 난이도, 자가 복구 여부, 정리 작업 가능 여부) | 탐지 목표 | 1차 대응 목표 | 복구 목표(권장 SLA) |
| --- | --- | --- | --- | --- | --- |
| OOM: MemoryGuard SIGKILL 자체 종료 | Sev2 | 33·33·34초 후 exit 137로 서비스가 사라집니다. 종료 감지는 쉽지만 SIGKILL 전 증거 확보는 어렵습니다. 자가 재시작은 입증되지 않았고 종료 정리는 불가능합니다. 시스템 메모리 7~8%에서 발생했으므로 커널 OOM과 구분합니다. | 10초 이내 | 5분 이내 | 15분 이내 |
| CPU: Watchdog SIGTERM | Sev3, 사용자 서비스 중단이면 Sev2 이상 | 37·25·31초 후 exit 143입니다. 앱 Current Load > 50%가 조건이며 OS CPU는 0~2.5%였습니다. 종료 감지는 쉽고 자가 재시작은 입증되지 않았습니다. SIGTERM은 정리 기회를 주지만 실제 핸들러 실행은 확인하지 못했습니다. Sev3는 대체 인스턴스로 영향이 제한될 때만 적용합니다. | 10초 이내 | 10분 이내 | 30분 이내 |
| Deadlock: PID 유지·무응답 | Sev1 | 시작 9초 후 로그가 멈추고 81초 이상 무진행했습니다(후속 실험: 재현율 10/10, 300초 관찰에도 자가 복구 없음). PID만 검사하면 헬스체크가 통과하여 탐지가 늦습니다. 관찰 중 자가 복구가 없었으며 락 대기로 정상 정리도 보장되지 않습니다. 종료 전 스레드 증거를 확보해야 합니다. | 30초 이내 | 1분 이내 | 10분 이내 |

실제 사용자 영향이 크거나 시스템 메모리 고갈이 다른 프로세스를 위협하면 유형과 관계없이 Sev1로 올립니다. 재시작 정책이 있다는 가정만으로 등급을 낮추지 않습니다.

## 2. 동시 장애 우선순위 매트릭스와 단계별 대응 절차

### 판단 기준

| 판단 기준 | 확인 내용과 우선순위 결정 |
| --- | --- |
| 사용자 영향 | 실패 요청·응답 지연·영향받은 사용자와 대체 인스턴스를 확인합니다. 핵심 기능 중단을 먼저 복구합니다. PID 존재는 정상 처리의 증거가 아닙니다. |
| 확산 위험 | 실제 시스템 메모리 고갈은 DB·다른 프로세스까지 영향을 줄 수 있어 최우선으로 억제합니다. 이번 MemoryGuard 사례는 시스템 사용률 7~8%였으므로 동일시하지 않습니다. CPU도 앱 내부 부하와 SYS_CPU를 구분합니다. |
| 증거 소멸 속도 | OOM·CPU는 종료와 함께 /proc 증거가 사라집니다. Deadlock의 스택·스레드·대기 지점도 살아 있을 때만 얻을 수 있습니다. 복구 순위와 별도로 종료 임박 PID를 먼저 짧게 수집합니다. |
| 자가 복구 여부 | 세 Before 사례 모두 자가 복구가 확인되지 않았습니다. supervisor 재시작 여부와 동일 설정 재발 여부를 확인합니다. After의 회수·쿨다운은 설정 변경 후 관찰 결과입니다. |
| 재시작 비용 | 진행 중 작업 손실, 재처리, 연결 재설정, 캐시 준비, 대체 용량을 확인합니다. 비용·시간의 실측 근거는 없으므로 현장에서 평가하며, 비싼 재시작보다 먼저 트래픽 우회 가능성을 확인합니다. |

### 조합별 매트릭스

다음은 **사용자 영향이 비슷하고 시스템 자원 확산이 없는 경우의 권장 순서**입니다. 담당자는 영향·확산·재시작 비용이 바뀔 때마다 재평가합니다. 실제 메모리 고갈이 확인되면 모든 조합에서 메모리 확산 억제가 먼저이며, 사용자 영향이 더 큰 CPU 장애는 Deadlock보다 먼저 복구할 수 있습니다.

| 조합 | 1순위 | 2순위 | 이유 | 먼저 남길 증거 |
| --- | --- | --- | --- | --- |
| OOM + CPU | OOM | CPU | SIGKILL은 정리 없이 중단됩니다. CPU의 SIGTERM은 정리 기회가 있으나 실행 여부를 확인해야 합니다. 실제 영향이 더 큰 쪽으로 순서를 바꿉니다. | 두 PID의 짧은 monitor·ps·top, 특히 RSS 상승 중인 PID를 먼저 저장하고 app.log·종료 신호 기록을 보존합니다. |
| OOM + Deadlock | Deadlock | OOM | 제한된 MemoryGuard 종료보다 탐지가 어렵고 자가 회복하지 않는 무응답을 먼저 복구합니다. 시스템 메모리 압박이면 OOM 확산 억제가 먼저입니다. | 종료 임박 OOM의 RSS·/proc 스냅샷 후 Deadlock의 스레드·futex·락 로그를 재시작 전에 확보합니다. |
| CPU + Deadlock | Deadlock | CPU | PID만으로 숨겨지는 무응답을 우선합니다. CPU는 내부 지표와 OS 지표를 구분하여 실제 영향부터 확인합니다. | 종료 임박 CPU의 Current Load·PID·짧은 스냅샷 후 Deadlock의 ps -L·top -H·진단 결과를 확보합니다. |
| OOM + CPU + Deadlock | Deadlock | OOM → CPU(3순위) | 기본은 무응답 복구, 정리 불가능 종료, 통제 가능한 정책 종료 순입니다. 실제 메모리 고갈이면 OOM → Deadlock → CPU로 바꿉니다. | OOM·CPU의 소멸 임박 증거를 짧게 저장한 뒤 Deadlock의 살아 있는 스레드 증거를 수집합니다. 가능하면 별도 담당자가 병행합니다. |

증거를 완벽히 모으느라 확산 억제를 늦추지 않습니다. 수집이 복구를 지연시키면 최소 스냅샷과 로그만 남기고 조치하며, 누락 이유를 기록합니다.

### 단계별 대응

1. **탐지·분류합니다.** 사용자 기능 검사를 PID 검사와 함께 수행합니다. exit 137만으로 커널 OOM이라고 단정하지 말고 MemoryGuard 로그와 신호 출처를 확인합니다. CPU는 app.log의 Current Load와 monitor의 구간 CPU를 함께 봅니다. PID 존재·CPU 구간 0·로그 정지는 Deadlock 의심으로 분류하고 락 대기를 확인합니다.
2. **우선순위를 결정합니다.** 영향받은 서비스·호스트·PID별로 장애를 분리하고 위 매트릭스를 적용합니다. 동일 PID가 이미 종료됐다면 살아 있는 Deadlock 증거를 기대하지 않습니다. 대응 책임자와 증거 수집 담당자를 정하고, 재시작 비용 및 확산 위험에 따라 복구 순서를 기록합니다.
3. **증거를 보존합니다.** 저장소 루트에서 실제 앱 자식 PID와 로그 경로를 입력합니다. 아래 경로는 운영값을 넣는 자리이며 새 임시 디렉터리에 저장합니다. 먼저 모니터를 백그라운드로 시작하고 짧은 스냅샷을 확보한 다음, 10초 진단과 필요한 strace를 수행합니다. PID마다 별도 디렉터리를 사용합니다.

   ```bash
   target_pid=17428 # 예시 PID: 현재 앱 자식 PID로 바꿉니다.
   app_log=/path/to/app.log
   capture_dir=$(mktemp -d /tmp/incident-capture.XXXXXX)
   tools/monitor.sh --pid "$target_pid" --interval 2 --until-exit \
     --app-log "$app_log" > "$capture_dir/monitor.log" 2>&1 &
   monitor_pid=$!
   ps -L -o pid,tid,stat,pcpu,rss,wchan:20,comm -p "$target_pid" \
     > "$capture_dir/threads.txt"
   top -H -b -n 1 -p "$target_pid" > "$capture_dir/top.txt"
   tools/diagnose-hang.sh --pid "$target_pid" --app-log "$app_log" \
     --window 10 > "$capture_dir/diagnose.txt" 2>&1
   timeout --signal=INT 5s strace -f -tt -e trace=futex \
     -p "$target_pid" -o "$capture_dir/futex.txt"
   cp -- "$app_log" "$capture_dir/app.log"
   ```

   `timeout`의 5초는 권장 수집 상한이며 시간 만료 종료는 예상 결과입니다. strace는 ptrace 권한이 필요하고 대상 타이밍에 영향을 줄 수 있습니다. 권한이 없으면 실패 사실을 기록하고 기존 로그를 사용합니다. futex 대기만으로 순환 교착을 확정하지 않고 락 보유·대기 로그를 교차 확인합니다. `diagnose-hang.sh` 8단계가 스레드별 스택(py-spy 파이썬 프레임 → gdb 네이티브 프레임 → `/proc/<tid>/stack`)을 남깁니다. ptrace 권한이 필요해 `sudo -n` 으로도 시도하며, 권한이 없으면 wchan 까지만 남으므로 그 사실을 기록합니다. 스택은 재시작하면 사라지므로 반드시 재시작 전에 수집합니다.

   종료 후에는 /proc를 복원할 수 없습니다. 기존 app.log·monitor.log·trace.txt·result.txt와 종료 시각을 우선 보존합니다. 자체 신호 출처는 아래 격리 재현의 `--trace`로 확인합니다. 임시 증거는 보존 정책에 맞는 증거 저장소로 옮기고 링크를 남깁니다. 모니터는 대상 종료 시 끝나며, 계속 살아 있다면 수집 종료 후 `monitor_pid`에 해당하는 수집기만 정리합니다.
4. **임시 조치 후 재시작합니다.** OOM은 호스트 여유 메모리와 다른 프로세스 사용량을 확인한 뒤 `MEMORY_LIMIT=512`를 검토합니다. CPU는 실험에서 `CPU_MAX_OCCUPY=50`으로 생존했지만 여유가 0이므로 운영에서는 40~45를 권장합니다. Deadlock은 `MULTI_THREAD_ENABLE=false`로 경쟁 경로를 끕니다. 환경변수 변경은 기존 PID에 적용되지 않으므로 실제 배포 설정에 반영하고 해당 서비스의 운영 절차로 재시작합니다. 재시작 전 위 증거를 남기며, 잘못된 기존 설정으로 반복 재시작하지 않습니다. 상한 증가는 누수 해결이 아니며, CPU 제한·동시성 해제의 처리량 감소도 확인합니다.
5. **Before/After를 검증합니다.** 다음은 운영 프로세스가 아닌 격리된 시험 환경에서 일반 실행 계정으로 수행합니다. runner는 관찰 종료 시 시험 앱을 종료하므로 운영에서 실행하지 않습니다. 각 명령은 별도 앱 실행이며 종료 후 다음 실행을 진행합니다. `--out`으로 새 증거를 저장소 밖에 둡니다.

   ```bash
   validation_dir=$(mktemp -d /tmp/incident-validation.XXXXXX)
   tools/run-scenario.sh scenarios/oom-before.env --trace --out "$validation_dir"
   tools/run-scenario.sh scenarios/oom-after.env --max 300 --out "$validation_dir"
   tools/run-scenario.sh scenarios/cpu-before.env --trace --out "$validation_dir"
   tools/run-scenario.sh scenarios/cpu-after.env --max 180 --out "$validation_dir"
   tools/run-scenario.sh scenarios/deadlock-before.env --max 90 --out "$validation_dir"
   tools/run-scenario.sh scenarios/deadlock-after.env --max 120 --out "$validation_dir"
   ```

   기존 관측은 OOM After 300초 생존·RSS 17.8↔517.9MB 회수, CPU After 180초 생존·50.00%에서 쿨다운, Deadlock After 120초 동안 로그 51→146줄·10초 구간 16 ticks입니다. 새 실행에서는 종료 신호·RSS·앱 부하·로그 진행·사용자 기능을 함께 비교합니다. Before의 장애 종료는 예상 결과이며 After의 관찰 종료와 구분합니다. 제한된 관찰 성공은 영구 해결의 증거가 아닙니다.
6. **회고합니다.** 타임라인, 순위 변경 이유, 확보하지 못한 증거, 조치 전후 결과를 4절 체크리스트와 PR에 기록합니다. 근본 수정 담당자와 완료 예정일을 지정합니다.

## 3. 알림 임계값과 알림 경로

아래 임계값·지속 시간은 모두 **권장값**입니다. 기존 monitor.sh는 관측 로그를 출력하며 이 알림을 자동으로 보내지는 않습니다. Warning/Critical은 지표 상태이고 Sev 등급은 실제 영향 평가 결과이므로 일대일로 고정하지 않습니다.

| 지표 | Warning(권장값) | Critical(권장값) | 해석 |
| --- | --- | --- | --- |
| RSS 증가 기울기 | 10초 창 평균 ≥ 4MB/s | 10초 창 평균 ≥ 8MB/s | 같은 PID의 시각·RSS 이력으로 계산합니다. 실측 225MB/28초 ≈ 8.0MB/s를 기준으로 삼았습니다. |
| RSS / MEMORY_LIMIT | ≥ 80% | ≥ 90% | 앱 한도 대비 비율입니다. 시스템 MEM%와 다르고 Guard의 Heap 판정과도 다릅니다. |
| 앱 Current Load | ≥ 45% | ≥ 50% | app.log에서 읽습니다. 실제 Watchdog 종료 조건은 **50% 초과**이며 50.00%에서는 쿨다운했습니다. OS CPU로 대체하지 않습니다. |
| 로그 무진행 + CPU 구간 0 + PID 존재 | LOG_LINES가 30초 이상 동일 | 같은 조건 60초 이상 지속 또는 사용자 기능 실패 확인 | Deadlock 의심입니다. RSS 고정·futex·순환 대기를 추가 확인합니다. 정상 유휴 상태와 구분합니다. |
| 시스템 메모리 사용률 SYS_MEM | ≥ 80% | ≥ 90% | 다른 프로세스로의 확산 위험을 확인합니다. 이번 OOM의 실측 7~8%와는 다른 운영 권장 기준입니다. |
| 예상치 못한 STATE:GONE | 즉시 원인 확인 | 사용자 기능 중단 또는 반복 종료 | 의도된 배포·시험 종료를 제외하고 서비스 영향으로 등급을 정합니다. |

2초 간격으로 10초 기울기를 계산하려면 6개 표본이 필요합니다. ≈8MB/s 누수는 관찰 시작 약 10초 후 약 80MB 증가로 탐지할 수 있고, 표본 정렬에 따라 약 12초까지 걸릴 수 있습니다(수집 지연 제외). RSS 42.6MB에서 256MB 한도의 80%인 204.8MB까지는 `(204.8−42.6)/8 ≈ 20.3초`, 80%에서 256MB까지는 `51.2/8 = 6.4초`입니다. 이는 선형 RSS 가정의 계산이지 종료 예측 보장이 아닙니다. 실제 Guard는 Heap을 계단식으로 검사했으므로 기울기 경보를 함께 사용합니다.

| 등급 | 권장 알림 경로 | 후속 동작 |
| --- | --- | --- |
| Sev1 | PagerDuty 및 전화 | 온콜 담당자를 호출하고 영향·확산 억제를 즉시 시작합니다. |
| Sev2 | Slack #incident | 담당자를 지정하고 증거·조치·복구 상태를 공유합니다. |
| Sev3 | Slack #ops 또는 메일 | 영향 확인 후 설정 보정 및 재발 방지 작업을 추적합니다. |

Incoming Webhook 예시는 다음과 같습니다. Webhook을 해당 채널에 연결하고 URL은 환경변수로만 주입합니다. 실제 전송을 시험 없이 수행하거나 로그에 비밀값을 출력하지 않습니다. 메시지에 개인정보·인증정보를 넣지 않습니다.

```bash
: "${SLACK_WEBHOOK_URL:?환경변수로 Webhook을 설정하세요}"
message='[Sev2] MemoryGuard 종료 의심: 영향과 증거 링크를 확인해 주세요.'
payload=$(jq -n --arg text "$message" '{text: $text}')
curl --silent --show-error --fail --max-time 10 \
  -H 'Content-Type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL"
```

다음은 monitor.log의 **마지막 한 줄**에서 RSS 비율만 판정하는 최소 예시입니다. MEMORY_LIMIT에는 해당 PID의 실제 설정값을 넣습니다. 누락 필드는 정상값 0으로 취급하지 않습니다.

```bash
MEMORY_LIMIT=256
awk -v limit="$MEMORY_LIMIT" '
  { last=$0 }
  END {
    n=split(last, fields, /[[:space:]]+/)
    for (i=1; i<=n; i++) {
      split(fields[i], pair, ":")
      if (pair[1]=="PID") pid=pair[2]
      if (pair[1]=="STATE") state=pair[2]
      if (pair[1]=="RSS") rss=pair[2]
    }
    if (state=="GONE") { print "Critical 후보: PID " pid " 종료(영향 확인)"; exit }
    sub(/MB$/, "", rss)
    if (pid !~ /^[0-9]+$/ || rss !~ /^[0-9]+([.][0-9]+)?$/ || limit<=0) {
      print "UNKNOWN: PID/RSS/한도를 확인하세요"; exit
    }
    if (rss>=limit*0.9) print "Critical: RSS >= 90%"
    else if (rss>=limit*0.8) print "Warning: RSS >= 80%"
    else print "OK: RSS 비율"
  }
' monitor.log
```

한 줄로는 RSS 기울기나 30초 정지를 판정할 수 없습니다. 실제 알림기는 PID별 타임스탬프·RSS·LOG_LINES·구간 CPU 이력을 유지하고, PID 교체·로그 회전·누락·시간 공백에서 창을 초기화해야 합니다. 로그 경로가 없으면 LOG_LINES는 `-`이므로 정지 판정을 보류합니다. 중복 알림 억제와 복구 알림도 함께 설계합니다.

## 4. 회고 체크리스트

장애 대응·PR·릴리스 후 작성하며, 해당하지 않는 항목도 이유를 기록합니다.

- [ ] 무엇이 일어났는지 발생·탐지·대응·복구 시각과 사용자 영향을 기록했습니다.
- [ ] 탐지가 늦었던 이유와 PID 검사·앱/OS 지표의 사각지대를 확인했습니다.
- [ ] 증상·종료 메커니즘·근본 원인을 구분하고 근거를 연결했습니다.
- [ ] 다음에 무엇을 다르게 할지 담당자와 완료 예정일을 정했습니다.
- [ ] 탐지 임계값·알림 경로·기능 헬스체크의 개선 및 검증 결과를 기록했습니다.
- [ ] 임시 조치의 한계·처리량 영향·재발 위험과 근본 수정 계획을 기록했습니다.
- [ ] runbook 갱신 여부와 변경 위치 또는 갱신하지 않은 이유를 기록했습니다.
- [ ] 재현 명령·Before/After 결과·증거 폴더 링크를 남겼습니다.

| 사례 | 실제 관찰에 근거한 회고 한 줄 예시 |
| --- | --- |
| [OOM](../issues/01-oom-memory-guard.md#4-workaround--verification-조치-및-검증) | 256→512MB로 변경해 33·33·34초 종료에서 300초 생존으로 바뀌었지만 ≈8MB/s 누수는 남으므로, 한도 상향과 누수 수정을 분리하고 조기 기울기 경보를 추가해야 합니다. |
| [CPU](../issues/02-cpu-watchdog.md#4-workaround--verification-조치-및-검증) | 90→50으로 낮춰 37·25·31초 종료에서 180초 생존으로 바뀌었으므로, OS CPU 0~2.5%만 보고 정상으로 판단하지 말고 앱 부하와 고정 임계치의 관계를 검증해야 합니다. |
| [Deadlock](../issues/03-deadlock.md#4-workaround--verification-조치-및-검증) | 동시성을 true→false로 바꿔 42줄 정지에서 120초간 51→146줄 진행으로 바뀌었으므로, PID 검사에 진행 검사를 추가하고 근본적으로 락 획득 순서를 통일해야 합니다. |

재현 증거는 [OOM Before](../evidence/oom-before/20261012-223103/), [OOM After](../evidence/oom-after/20261012-223240/), [CPU Before](../evidence/cpu-before/20261012-223757/), [CPU After](../evidence/cpu-after/20261012-223936/), [Deadlock Before](../evidence/deadlock-before/20261012-224253/), [Deadlock After](../evidence/deadlock-after/20261012-224440/)에서 확인할 수 있습니다.
