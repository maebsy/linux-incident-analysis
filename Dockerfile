# syntax=docker/dockerfile:1
# 분석 도구를 CI 와 같은 OS(Ubuntu 24.04)에서 실행한다.
# 컨테이너는 자기 PID 네임스페이스를 가지므로, 다른 프로세스가 많은 데스크톱에서도 /proc 관측이 같은 조건이 된다.
#   docker build -t linux-incident-analysis .
#   docker run --rm --cap-add SYS_PTRACE linux-incident-analysis   # ShellCheck + 도구 테스트 (strace 에 ptrace 권한 필요)
# 실제 장애 재현(agent-leak-app 실행, 계정·권한 설정)은 README 의 VM 절차를 따른다.
FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends bash gawk procps psmisc strace shellcheck python3 \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8
WORKDIR /app
COPY . .
CMD ["bash", "-c", "shellcheck -S warning tools/*.sh tests/*.sh && bash tests/run-tests.sh"]
