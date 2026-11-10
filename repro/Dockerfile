# syntax=docker/dockerfile:1
# 실제 장애 바이너리(bin/agent-leak-app-x86)를 원래 VM 과 같은 조건으로 실행하는 재현 환경.
#   docker build -f repro/Dockerfile -t lia-repro --build-arg UID="$(id -u)" .
#   repro/run.sh tools/run-scenario.sh scenarios/deadlock-before.env --max 90
# 원래 환경: Ubuntu 24.04, 2 vCPU / 8GB / swap 없음, 실행 계정 agent-admin (repro/run.sh 가 --cpus 2 --memory 8g 로 맞춘다)
# Boot Sequence 6단계(계정 · 환경변수 · secret.key · 포트 · 로그 권한 · 미션 변수)를 이미지 안에서 모두 만족시킨다.
FROM ubuntu:24.04
ARG UID=30033
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash gawk procps psmisc strace gdb sudo curl ca-certificates \
      python3 python3-pip \
 && pip3 install --no-cache-dir --break-system-packages py-spy==0.4.1 \
 && rm -rf /var/lib/apt/lists/*
# 기본 사용자(ubuntu, uid 1000)와 UID 가 겹치면 지우고 agent-admin 을 만든다
RUN (getent passwd "$UID" | cut -d: -f1 | xargs -r userdel -r) \
 && useradd -m -u "$UID" -s /bin/bash agent-admin \
 && mkdir -p /home/agent-admin/agent-app/upload_files /home/agent-admin/agent-app/api_keys /var/log/agent-app \
 && printf 'agent_api_key_test\n' > /home/agent-admin/agent-app/api_keys/t_secret.key \
 && ln -sfn t_secret.key /home/agent-admin/agent-app/api_keys/secret.key \
 && chown -R agent-admin:agent-admin /home/agent-admin/agent-app /var/log/agent-app \
 && chmod 640 /home/agent-admin/agent-app/api_keys/t_secret.key \
 # 스택 덤프(py-spy · gdb)는 ptrace 권한이 필요하다. 운영에서처럼 이 두 명령만 sudo 로 허용한다.
 && printf 'agent-admin ALL=(root) NOPASSWD: /usr/local/bin/py-spy, /usr/bin/gdb\n' > /etc/sudoers.d/stackdump \
 && chmod 440 /etc/sudoers.d/stackdump
COPY --chown=agent-admin:agent-admin bin/agent-leak-app-x86 /home/agent-admin/agent-app/agent-leak-app-x86
ENV LANG=C.UTF-8 TZ=Asia/Seoul
USER agent-admin
WORKDIR /work
