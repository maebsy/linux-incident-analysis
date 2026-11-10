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
