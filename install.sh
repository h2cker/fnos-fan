#!/usr/bin/env bash
# MAINTAINER local build & run helper — NOT the hosted user installer.
#   - End users install from YOUR domain via scripts/install.sh (downloads a
#     pre-built image). See README "给用户:一条命令安装".
#   - This script builds the image from source and runs it on THIS machine
#     (useful for development / testing on the NAS itself).
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=scripts/lib-detect.sh
. scripts/lib-detect.sh

command -v docker >/dev/null || { echo "Docker 未安装。"; exit 1; }
[ -f kmod/qnap8528/src/Makefile ] || scripts/vendor-kmod.sh
has_headers || echo "WARN: 缺少 $(kver) 的内核头文件,模块将无法编译。先: sudo apt install linux-headers-\$(uname -r)"

mkdir -p data
docker compose up -d --build
echo "已启动。日志: docker logs -f fnos-fan"
