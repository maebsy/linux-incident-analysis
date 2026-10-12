---
name: 장애 리포트 (Bug)
about: 운영 중 관측된 장애를 현상 → 증거 → 원인 → 조치 순서로 보고합니다
title: "[Bug] {장애 유형} - {한 줄 요약}"
labels: bug, incident
---

## 1. Description (현상 설명)
- 어떤 현상이 발생했는가?
- 언제, 어떤 조건(환경변수·실행 계정·버전)에서 발생했는가?
- 영향 범위 (서비스 중단 / 지연 / 무응답)

## 2. Evidence & Logs (증거 자료)
- monitor.sh 관제 로그 (수치·추이)
- 프로그램 실행 로그 핵심 구간 (타임스탬프·PID 포함)
- 시스템 도구 출력 (ps, top, pstree, /proc …)

## 3. Root Cause Analysis (원인 분석)
- 증거를 근거로 한 기술적 원인
- 관련 OS 동작 원리

## 4. Workaround & Verification (조치 및 검증)
- 조정한 환경변수와 값 (Before → After)
- Before & After 비교 (수치·로그)
- 근본 해결을 위한 코드 레벨 제안

## 재현 방법
```bash
tools/run-scenario.sh scenarios/<before>.env
tools/run-scenario.sh scenarios/<after>.env
```
