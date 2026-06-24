#!/usr/bin/env bash
# fnos-fan one-command installer (run on the fnOS NAS):
#   curl -fsSL https://vecr.ai/fnos-fan/install.sh | sudo bash
# Re-run to update. Uninstall:
#   curl -fsSL https://vecr.ai/fnos-fan/install.sh | sudo bash -s -- --uninstall
set -euo pipefail

# ---- config (maintainer edits before hosting, or user overrides via env) ----
BASE_URL="${FNOS_FAN_BASE_URL:-https://vecr.ai/fnos-fan}"
VERSION="${FNOS_FAN_VERSION:-latest}"
WEB_PORT="${WEB_PORT:-7831}"
BIND="${BIND:-0.0.0.0}"              # 0.0.0.0 = 局域网可访问(默认);127.0.0.1 = 仅本机
AUTH_TOKEN="${AUTH_TOKEN:-}"         # 设置后网页需输此密码(用户名随意);留空 = 无鉴权
ALLOWED_HOSTS="${ALLOWED_HOSTS:-}"   # 额外允许的 Host 名(IP 与 *.local 始终放行;反代/Tailscale 域名需在此列出,逗号分隔)
INSTALL_DIR="${FNOS_FAN_DIR:-/opt/fnos-fan}"
IMAGE="fnos-fan"
# -----------------------------------------------------------------------------

cecho() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info() { cecho "0;36" "[*] $*"; }
ok()   { cecho "0;32" "[+] $*"; }
warn() { cecho "1;33" "[!] $*"; }
die()  { cecho "1;31" "[x] $*"; exit 1; }

# 探测局域网 IPv4 地址
lan_ips() { ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }

# 若有活动防火墙则放行端口(ufw / firewalld)
open_firewall() {
  local p="$1"
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow "$p"/tcp >/dev/null 2>&1 && ok "ufw 已放行 $p/tcp"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$p"/tcp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld 已放行 $p/tcp"
  fi
}

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
  rm -f /usr/local/bin/fnos-fan
  warn "配置与编译缓存保留在 $INSTALL_DIR/data(彻底删除请手动 rm -rf $INSTALL_DIR)。"
  ok "已卸载。"
  exit 0
}
[ "${1:-}" = "--uninstall" ] && uninstall

# ---- 1. environment checks ----
command -v docker >/dev/null || die "未安装 Docker。请先安装 Docker。"
docker info >/dev/null 2>&1 || die "Docker 未运行。"

# 确保 Docker 开机自启,否则 NAS 重启后容器(及风扇控制)不会自动回来
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable docker >/dev/null 2>&1 && ok "已启用 Docker 开机自启" || warn "未能启用 Docker 开机自启(请手动:sudo systemctl enable docker)"
fi

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
      - AUTH_TOKEN=${AUTH_TOKEN}
      - ALLOWED_HOSTS=${ALLOWED_HOSTS}
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

# 局域网访问时放行防火墙端口
[ "$BIND" != "127.0.0.1" ] && open_firewall "$WEB_PORT"

# ---- 4b. install the `fnos-fan` management command ----
cat > /usr/local/bin/fnos-fan <<HELPER
#!/usr/bin/env bash
# fnos-fan management helper (installed by install.sh)
set -euo pipefail
COMPOSE=$INSTALL_DIR/docker-compose.yml
PORT=$WEB_PORT
BASE_URL=$BASE_URL
dc() { if docker compose version >/dev/null 2>&1; then docker compose "\$@"; else docker-compose "\$@"; fi; }
case "\${1:-}" in
  start)     dc -f "\$COMPOSE" up -d ;;
  stop)      docker stop fnos-fan ;;            # 触发风扇拉满 100% 的安全恢复
  restart)   docker restart fnos-fan ;;
  status)    docker ps --filter name=fnos-fan; echo; curl -fsS "http://127.0.0.1:\$PORT/api/status" 2>/dev/null | head -c 400 || echo "(API 未响应)"; echo ;;
  logs)      docker logs -f fnos-fan ;;
  update)    curl -fsSL "\$BASE_URL/install.sh" | sudo bash ;;
  uninstall) curl -fsSL "\$BASE_URL/install.sh" | sudo bash -s -- --uninstall ;;
  *) echo "用法: fnos-fan {start|stop|restart|status|logs|update|uninstall}"; exit 1 ;;
esac
HELPER
chmod +x /usr/local/bin/fnos-fan

# ---- 5. wait for first compile + sensors (with live progress) ----
WAIT_MAX=90   # 秒;首次要在容器里编译内核模块,较慢
info "等待首次编译并加载驱动(最长 ~${WAIT_MAX}s)..."
FANS_OK=0; elapsed=0; BAR_W=28

draw_progress() { # $1=百分比 $2=右侧说明;TTY 下原地重绘进度条,否则逐行打印
  local pct="$1" msg="$2" fill='' emp='' nf ne
  nf=$(( pct * BAR_W / 100 )); ne=$(( BAR_W - nf ))
  if [ "$nf" -gt 0 ]; then printf -v fill '%*s' "$nf" ''; fill=${fill// /█}; fi
  if [ "$ne" -gt 0 ]; then printf -v emp  '%*s' "$ne" ''; emp=${emp// /░}; fi
  if [ -t 1 ]; then printf '\r  [%s%s] %3d%%  %s\033[K' "$fill" "$emp" "$pct" "$msg"
  else            printf '  ...%3ds  %s\n' "$elapsed" "$msg"; fi
}
current_phase() { # 从容器日志(英文)推断阶段,转成中文提示
  case "$(docker logs --tail 6 fnos-fan 2>&1)" in
    *"starting fanctld"*) echo "启动控制服务" ;;
    *loading*|*insmod*)   echo "加载内核模块" ;;
    *building*)           echo "编译内核模块(首次较慢)" ;;
    *)                    echo "准备容器" ;;
  esac
}

while [ "$elapsed" -lt "$WAIT_MAX" ]; do
  if curl -fsS "http://127.0.0.1:${WEB_PORT}/api/status" 2>/dev/null | grep -q '"rpm"'; then FANS_OK=1; break; fi
  draw_progress "$(( elapsed * 100 / WAIT_MAX ))" "$(current_phase) · ${elapsed}s"
  sleep 2; elapsed=$(( elapsed + 2 ))
done
if [ "$FANS_OK" = 1 ]; then draw_progress 100 "完成"; else draw_progress 100 "未读到风扇"; fi
if [ -t 1 ]; then printf '\n'; fi

echo
if [ "$FANS_OK" = 1 ]; then
  ok "完成,已识别风扇。"
else
  warn "容器已启动,但暂未读到风扇。常见原因:缺内核头文件 / 机型未适配 / 内核签名强制。"
  warn "排查:docker logs fnos-fan"
fi
if [ "$BIND" = "127.0.0.1" ]; then
  echo "  网页(仅本机):http://127.0.0.1:${WEB_PORT}"
  echo "  远程访问请用 SSH 隧道: ssh -L ${WEB_PORT}:127.0.0.1:${WEB_PORT} <用户>@<NAS-IP>"
else
  echo "  网页(局域网,同网段电脑/手机浏览器打开):"
  IPS="$(lan_ips)"
  if [ -n "$IPS" ]; then for ip in $IPS; do echo "    http://${ip}:${WEB_PORT}"; done
  else echo "    http://<NAS-IP>:${WEB_PORT}"; fi
  if [ -n "$AUTH_TOKEN" ]; then
    echo "  访问需输密码(用户名随意,密码 = 你设的 AUTH_TOKEN)。"
  else
    echo "  注意:无鉴权,同网段任何设备都能改风扇;切勿在路由器把 ${WEB_PORT} 端口转发到公网。"
    echo "  想加密码:用 AUTH_TOKEN=你的密码 重新安装(详见 README)。"
  fi
fi
echo
echo "  管理命令(已安装 fnos-fan):"
echo "    fnos-fan status     查看状态"
echo "    fnos-fan logs       看日志"
echo "    fnos-fan restart    重启"
echo "    fnos-fan stop       停止(会安全把风扇拉满,勿用 docker kill)"
echo "    fnos-fan update     更新到最新版"
echo "    fnos-fan uninstall  卸载"
