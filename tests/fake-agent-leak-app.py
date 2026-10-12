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
