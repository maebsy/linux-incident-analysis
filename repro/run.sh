#!/usr/bin/env bash
# repro/run.sh <명령…> : 재현 컨테이너(lia-repro)에서 명령을 실행한다. 저장소를 /work 로 마운트해 evidence 가 그대로 남는다.
#   repro/run.sh tools/run-scenario.sh scenarios/oom-before.env
# 원래 VM 과 같게 2 vCPU · 8GB · swap 없음. 스택 덤프(ptrace)를 위해 SYS_PTRACE 를 준다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${LIA_IMAGE:-lia-repro}"
docker image inspect "$IMAGE" >/dev/null 2>&1 \
    || docker build -q -f "$ROOT/repro/Dockerfile" -t "$IMAGE" --build-arg UID="$(id -u)" "$ROOT" >/dev/null
# 재현성 기록용: 어떤 이미지 · 어떤 커밋으로 돌렸는지 컨테이너 안 도구(sweep.sh env.txt)에 넘긴다
image_id="$(docker image inspect -f '{{.Id}}' "$IMAGE")"
commit="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo -)$(git -C "$ROOT" diff --quiet 2>/dev/null || echo '+dirty')"
exec docker run --rm --init --cpus 2 --memory 8g --memory-swap 8g --cap-add SYS_PTRACE \
    -e TZ=Asia/Seoul -e LIA_IMAGE_ID="$image_id" -e LIA_GIT_COMMIT="$commit" -v "$ROOT:/work" -w /work "$IMAGE" "$@"
