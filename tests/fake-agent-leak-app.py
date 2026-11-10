"""테스트용 가짜 agent-leak-app (실제 바이너리 없이 tools/*.sh 를 검증하기 위한 것).

    python3 tests/fake-agent-leak-app.py leak      # 0.3초마다 10MB 씩 메모리 증가
    python3 tests/fake-agent-leak-app.py deadlock  # 두 스레드가 락을 반대 순서로 잡아 실제 교착 상태
    python3 tests/fake-agent-leak-app.py busy      # 1코어를 계속 사용

파일 이름에 'agent-leak-app' 이 들어 있어 monitor.sh 의 기본 패턴으로 찾을 수 있다.
"""

import sys
import threading
import time

mode = sys.argv[1] if len(sys.argv) > 1 else "leak"


_out = threading.Lock()


def log(msg):
    # 여러 스레드가 동시에 print 하면 줄이 섞이므로 한 번의 write 로 쓴다
    with _out:
        sys.stdout.write(time.strftime("%Y-%m-%d %H:%M:%S") + ",000 [INFO] " + msg + "\n")
        sys.stdout.flush()


if mode == "leak":
    hoard = []
    while True:
        hoard.append(bytearray(10 * 1024 * 1024))
        log("[MemoryWorker] Current Heap: {}MB".format(len(hoard) * 10))
        time.sleep(0.3)
elif mode == "busy":
    end = time.time() + 600
    while time.time() < end:
        pass
elif mode == "deadlock":
    a, b = threading.Lock(), threading.Lock()

    def worker(name, first, second, first_name, second_name):
        with first:
            log("[AgentWorker][{}] LOCK ACQUIRED: [{}]. (Holding...)".format(name, first_name))
            time.sleep(0.5)
            log("[AgentWorker][{}] WAITING for [{}]... (Status: BLOCKED)".format(name, second_name))
            with second:
                pass

    t1 = threading.Thread(target=worker, args=("Worker-Thread-1", a, b, "Shared_Memory_A", "Socket_Pool_B"))
    t2 = threading.Thread(target=worker, args=("Worker-Thread-2", b, a, "Socket_Pool_B", "Shared_Memory_A"))
    t1.start(); t2.start(); t1.join()
elif mode == "leak-bounded":
    # 리포트 제안: 캐시/보관 컨테이너에 상한을 두어 메모리 증가를 제한한다.
    from collections import deque

    hoard = deque(maxlen=5)
    while True:
        hoard.append(bytearray(10 * 1024 * 1024))
        log("[MemoryWorker] Retained: {} blocks, Current Heap: {}MB".format(len(hoard), len(hoard) * 10))
        time.sleep(0.3)
elif mode == "deadlock-ordered":
    # 리포트 제안: 모든 워커에 Shared_Memory_A → Socket_Pool_B 전역 락 순서를 적용한다.
    a, b = threading.Lock(), threading.Lock()

    def worker(name):
        while True:
            with a:
                log("[AgentWorker][{}] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)".format(name))
                with b:
                    log("[AgentWorker][{}] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)".format(name))
                    log("[AgentWorker][{}] PROGRESS: work completed".format(name))
            time.sleep(0.2)

    t1 = threading.Thread(target=worker, args=("Worker-Thread-1",))
    t2 = threading.Thread(target=worker, args=("Worker-Thread-2",))
    t1.start(); t2.start(); t1.join()
elif mode == "deadlock-timeout":
    # 리포트 제안: 락 대기 시간 제한 후 보유 락을 해제하고 무작위 지연으로 재시도한다.
    import random

    a, b = threading.Lock(), threading.Lock()
    ready = threading.Barrier(2)

    def worker(name, first, second, first_name, second_name):
        initial = True
        while True:
            acquired = False
            with first:
                log("[AgentWorker][{}] LOCK ACQUIRED: [{}]. (Holding...)".format(name, first_name))
                if initial:
                    ready.wait()
                    initial = False
                time.sleep(0.05)
                log("[AgentWorker][{}] WAITING for [{}]... (Status: BLOCKED)".format(name, second_name))
                acquired = second.acquire(timeout=1)
                if acquired:
                    try:
                        log("[AgentWorker][{}] PROGRESS: work completed".format(name))
                    finally:
                        second.release()
                else:
                    log("[AgentWorker][{}] TIMEOUT waiting for [{}]; retry".format(name, second_name))
            time.sleep(random.uniform(0.05, 0.2) if not acquired else 0.2)

    t1 = threading.Thread(target=worker, args=("Worker-Thread-1", a, b, "Shared_Memory_A", "Socket_Pool_B"))
    t2 = threading.Thread(target=worker, args=("Worker-Thread-2", b, a, "Socket_Pool_B", "Shared_Memory_A"))
    t1.start(); t2.start(); t1.join()
elif mode in ("guard-kill", "guard-graceful", "guard-graceful-stuck"):
    # 리포트(OOM 4장) 제안: MemoryGuard 를 "즉시 SIGKILL" 대신 "경고 → SIGTERM → 정리 → 유예 후 SIGKILL" 로.
    #   guard-kill            지금 앱과 같은 방식: 한도 도달 즉시 kill(자기 PID, SIGKILL) → exit 137, 정리 로그 없음
    #   guard-graceful        80% 에서 경고, 100% 에서 SIGTERM → 핸들러가 정리(버퍼 비우기) 후 종료 → exit 143
    #   guard-graceful-stuck  정리가 끝나지 않으면 유예(GRACE) 뒤 SIGKILL 로 마무리 → exit 137 (유예가 무한하지 않음)
    import os
    import signal

    LIMIT_MB, STEP_MB, GRACE = 60, 10, 1.0
    hoard, pending = [], ["job-%d" % i for i in range(3)]

    def on_term(signum, frame):
        log("[MemoryGuard] SIGTERM received: cleanup start ({} pending jobs)".format(len(pending)))
        if mode == "guard-graceful-stuck":
            while True:          # 정리가 끝나지 않는 상황을 흉내
                time.sleep(0.1)
        pending.clear()
        log("[MemoryGuard] cleanup done: pending=0, exiting")
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        os.kill(os.getpid(), signal.SIGTERM)   # 기본 동작으로 종료 → 128 + 15

    signal.signal(signal.SIGTERM, on_term)
    warned = False
    while True:
        hoard.append(bytearray(STEP_MB * 1024 * 1024))
        heap = len(hoard) * STEP_MB
        log("[MemoryWorker] Current Heap: {}MB".format(heap))
        if heap >= LIMIT_MB * 0.8 and not warned:
            warned = True
            log("[MemoryGuard] WARNING heap {}MB >= 80% of {}MB".format(heap, LIMIT_MB))
        if heap >= LIMIT_MB:
            if mode == "guard-kill":
                log("[MemoryGuard] Self-terminating with SIGKILL (no cleanup)")
                os.kill(os.getpid(), signal.SIGKILL)
            log("[MemoryGuard] limit reached: SIGTERM, grace {}s".format(GRACE))
            # 유예 감시: 정리가 GRACE 안에 끝나지 않으면 SIGKILL
            threading.Timer(GRACE, lambda: (log("[MemoryGuard] grace expired: SIGKILL"), os.kill(os.getpid(), signal.SIGKILL))).start()
            os.kill(os.getpid(), signal.SIGTERM)
        time.sleep(0.2)
