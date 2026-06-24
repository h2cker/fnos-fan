#!/usr/bin/env bash
# fnos-fan one-command installer (run on the fnOS NAS):
#   curl -fsSL https://YOUR_DOMAIN/fnos-fan/install.sh | sudo bash
# Re-run to update. Uninstall:
#   curl -fsSL https://YOUR_DOMAIN/fnos-fan/install.sh | sudo bash -s -- --uninstall
set -euo pipefail

# ---- config (maintainer edits before hosting, or user overrides via env) ----
BASE_URL="${FNOS_FAN_BASE_URL:-https://YOUR_DOMAIN/fnos-fan}"
VERSION="${FNOS_FAN_VERSION:-latest}"
WEB_PORT="${WEB_PORT:-7831}"
BIND="${BIND:-127.0.0.1}"            # localhost by default (safe). 0.0.0.0 = LAN-exposed.
INSTALL_DIR="${FNOS_FAN_DIR:-/opt/fnos-fan}"
IMAGE="fnos-fan"
# -----------------------------------------------------------------------------

cecho() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info() { cecho "0;36" "[*] $*"; }
ok()   { cecho "0;32" "[+] $*"; }
warn() { cecho "1;33" "[!] $*"; }
die()  { cecho "1;31" "[x] $*"; exit 1; }

[ "$(id -u)" = 0 ] || die "请用 root 运行(sudo)。"

compose() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then docker-compose "$@"
  else die "未找到 docker compose,请安装 Docker Compose。"; fi
}

uninstall() {
  info "卸载 fnos-fan ..."
  [ -f "$INSTALL_DIR/docker-compose.yml" ] && compose -f "$INSTALL_DIR/docker-compose.yml" down 2>/dev/null || true
  docker rmi "$IMAGE:latest" 2>/dev/null || true
  warn "配置与编译缓存保留在 $INSTALL_DIR/data(彻底删除请手动 rm -rf $INSTALL_DIR)。"
  ok "已卸载。"
  exit 0
}
[ "${1:-}" = "--uninstall" ] && uninstall

# ---- 1. environment checks ----
command -v docker >/dev/null || die "未安装 Docker。请先安装 Docker。"
docker info >/dev/null 2>&1 || die "Docker 未运行。"

ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] || warn "当前架构 $ARCH 非 x86_64;qnap8528 仅支持 x86,只会启用通用 hwmon 路径。"

if pgrep -x fancontrol >/dev/null 2>&1; then
  warn "检测到 fancontrol 正在运行,会和本程序抢风扇。建议先执行:systemctl disable --now fancontrol"
fi

# ---- 2. kernel headers (fnOS apt repo is reachable in China) ----
KVER="$(uname -r)"
if [ ! -d "/lib/modules/$KVER/build" ] && [ ! -d "/usr/src/linux-headers-$KVER" ]; then
  info "未发现内核头文件,尝试安装 linux-headers-$KVER ..."
  if command -v apt-get >/dev/null; then
    apt-get update -y && apt-get install -y "linux-headers-$KVER" \
      || warn "头文件自动安装失败;模块将无法编译(网页仍可启动)。"
  else
    warn "非 apt 系统,请手动安装与 $KVER 匹配的内核头文件。"
  fi
else
  ok "内核头文件已就绪。"
fi

# ---- 3. resolve version + download image ----
if [ "$VERSION" = "latest" ]; then
  RV="$(curl -fsSL "$BASE_URL/latest.txt" 2>/dev/null | tr -d '[:space:]' || true)"
  [ -n "$RV" ] && VERSION="$RV" || die "无法解析最新版本($BASE_URL/latest.txt)。"
fi
TAR="fnos-fan-$VERSION.tar.gz"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

info "下载镜像 $TAR ..."
curl -fSL --progress-bar "$BASE_URL/$TAR" -o "$TMP/$TAR" || die "镜像下载失败:$BASE_URL/$TAR"
if curl -fsSL "$BASE_URL/$TAR.sha256" -o "$TMP/$TAR.sha256" 2>/dev/null; then
  info "校验 SHA256 ..."
  ( cd "$TMP" && { sha256sum -c "$TAR.sha256" >/dev/null 2>&1 || shasum -a 256 -c "$TAR.sha256" >/dev/null 2>&1; } ) \
    || die "校验失败,文件可能损坏或被篡改。"
  ok "校验通过。"
else
  warn "未找到校验文件,跳过校验。"
fi
info "加载镜像到 Docker ..."
gunzip -c "$TMP/$TAR" | docker load

# ---- 4. write compose + start ----
mkdir -p "$INSTALL_DIR/data"
cat > "$INSTALL_DIR/docker-compose.yml" <<YAML
services:
  fnos-fan:
    image: ${IMAGE}:latest
    container_name: fnos-fan
    platform: linux/amd64
    privileged: true
    restart: unless-stopped
    stop_grace_period: 30s
    network_mode: host
    environment:
      - WEB_PORT=${WEB_PORT}
      - BIND=${BIND}
      # - EXTRA_MODULES=it87 nct6775   # 非 QNAP 主板可尝试通用驱动
    volumes:
      - /lib/modules:/lib/modules:ro
      - /usr/src:/usr/src:ro
      - /sys:/sys
      - ${INSTALL_DIR}/data:/data
    healthcheck:
      test: ["CMD", "curl", "-fsS", "-m", "3", "http://127.0.0.1:${WEB_PORT}/api/status"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 90s
YAML

info "启动容器 ..."
compose -f "$INSTALL_DIR/docker-compose.yml" up -d

# ---- 5. wait for first compile + sensors ----
info "等待首次编译并加载驱动(最长 ~90s) ..."
FANS_OK=0
for _ in $(seq 1 45); do
  if curl -fsS "http://127.0.0.1:${WEB_PORT}/api/status" 2>/dev/null | grep -q '"rpm"'; then FANS_OK=1; break; fi
  sleep 2
done

echo
if [ "$FANS_OK" = 1 ]; then
  ok "完成,已识别风扇。"
else
  warn "容器已启动,但暂未读到风扇。常见原因:缺内核头文件 / 机型未适配 / 内核签名强制。"
  warn "排查:docker logs fnos-fan"
fi
if [ "$BIND" = "127.0.0.1" ]; then
  echo "  网页(仅本机):http://127.0.0.1:${WEB_PORT}"
  echo "  远程访问请用 SSH 隧道: ssh -L ${WEB_PORT}:127.0.0.1:${WEB_PORT} <user>@<nas-ip>"
else
  echo "  网页:http://<nas-ip>:${WEB_PORT}  (注意:已暴露到局域网且无鉴权)"
fi
echo "  日志:docker logs -f fnos-fan"
echo "  停止(会安全恢复风扇):docker stop fnos-fan   ← 不要用 docker kill"
echo "  卸载:curl -fsSL $BASE_URL/install.sh | sudo bash -s -- --uninstall"
