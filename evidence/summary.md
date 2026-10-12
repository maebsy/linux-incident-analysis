| 실행 | MEMORY_LIMIT | CPU_MAX_OCCUPY | MULTI_THREAD | 생존 시간 | 종료 | 최대 RSS | 마지막 핵심 로그 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `oom-before/20261012-223103` | 256 | 50 | false | 33s | exit 137 (128 + SIGKILL) | 267.6MB | [CRITICAL] [MemoryGuard] Self-terminating process 3848 to prevent syst |
| `oom-before/20261012-223140` | 256 | 50 | false | 33s | exit 137 (128 + SIGKILL) | 267.6MB | [CRITICAL] [MemoryGuard] Self-terminating process 4676 to prevent syst |
| `oom-before/20261012-225151` | 256 | 50 | false | 34s | exit 137 (128 + SIGKILL) | 267.6MB | [CRITICAL] [MemoryGuard] Self-terminating process 27157 to prevent sys |
| `oom-128/20261012-223217` | 128 | 50 | false | 18s | exit 137 (128 + SIGKILL) | 142.6MB | [CRITICAL] [MemoryGuard] Self-terminating process 5398 to prevent syst |
| `oom-after/20261012-223240` | 512 | 50 | false | 300s | 생존 (관찰 종료) | 517.9MB | [INFO] [CpuWorker] Peak reached (50.00%). Starting cooldown... |
| `cpu-before/20261012-223757` | 512 | 90 | false | 37s | exit 143 (128 + SIGTERM) | 17.6MB | [CRITICAL] [CpuWorker] CPU Threshold Violated! (54.959999999999994%). |
| `cpu-before/20261012-223838` | 512 | 90 | false | 25s | exit 143 (128 + SIGTERM) | 17.6MB | [CRITICAL] [CpuWorker] CPU Threshold Violated! (50.959999999999994%). |
| `cpu-before/20261012-225108` | 512 | 90 | false | 31s | exit 143 (128 + SIGTERM) | 17.7MB | [CRITICAL] [CpuWorker] CPU Threshold Violated! (52.22%). |
| `cpu-60/20261012-223907` | 512 | 60 | false | 24s | exit 143 (128 + SIGTERM) | 17.7MB | [CRITICAL] [CpuWorker] CPU Threshold Violated! (51.06999999999999%). |
| `cpu-after/20261012-223936` | 512 | 50 | false | 180s | 생존 (관찰 종료) | 518.0MB | [INFO] [CpuWorker] Peak reached (50.00%). Starting cooldown... |
| `deadlock-before/20261012-224253` | 512 | 50 | true | 90s | 생존 (관찰 종료) | 17.7MB | [INFO] [AgentWorker][Worker-Thread-1] WAITING for [Socket_Pool_B]... ( |
| `deadlock-after/20261012-224440` | 512 | 50 | false | 120s | 생존 (관찰 종료) | 518.0MB | >>> [SYSTEM] MEMORY RECOVERED (Cache Cleared) <<< |
