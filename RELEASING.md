# 构建与发布(维护者)

终端用户只需 `curl ... | sudo bash`(见 [README](README.md))。本文档面向**维护者**:如何构建镜像并从自己的域名分发。

> 为什么这样设计:GitHub、Docker Hub 在国内常被墙。所以**维护者预构建好整个镜像**,把镜像与安装脚本放到**自己可达的域名**;终端用户只从该域名下载,全程不碰 GitHub/Docker Hub,也不需要装 Go/gcc(编译工具链都在镜像里)。

## 一次性:vendoring 内核模块源码

```bash
scripts/vendor-kmod.sh
# 国内镜像可用环境变量,如:
#   KMOD_REPO=https://ghproxy.com/https://github.com/0xGiddi/qnap8528.git scripts/vendor-kmod.sh
# fnOS 适配 fork:
#   KMOD_REPO=https://github.com/gzxiexl/qnap8528.git scripts/vendor-kmod.sh
```

之后 `kmod/qnap8528/` 进仓库,构建不再依赖 GitHub。

## 构建 + 打包

```bash
PUBLISH_BASE_URL=https://你的域名/fnos-fan bash scripts/release.sh
```

产出 `dist/`:`fnos-fan-<版本>.tar.gz`、`.sha256`、`latest.txt`、`install.sh`(已把域名写进去)。

**在哪构建**(镜像是 `linux/amd64`):

- **原生 x86_64 机器最快**(无模拟)。若该机能正常 `docker pull`(海外/云主机/配了加速),首选在那构建。
- ARM Mac 也能构建(QEMU 模拟 amd64),但较慢;且国内直连 Docker Hub 可能极慢,建议给 Docker 配国内加速源。

## 分发(任意静态 HTTPS 服务器)

把 `dist/` 里这 4 个文件放到你网站的 `/fnos-fan/` 路径下,通过 HTTPS 提供即可(Nginx / Caddy / 对象存储 / CDN 均可):

```
fnos-fan-<版本>.tar.gz
fnos-fan-<版本>.tar.gz.sha256
latest.txt
install.sh
```

验证:

```bash
curl -fsSL https://你的域名/fnos-fan/latest.txt        # 应输出版本号
curl -fsSL https://你的域名/fnos-fan/install.sh | head
```

## 更新发布

1. 改根目录 `VERSION`;
2. 重新 `scripts/release.sh`;
3. 重新上传 `dist/` 4 个文件(覆盖)。
   - 用户侧 `fnos-fan update` 即可升级。
   - 若域名走 CDN/Cloudflare,记得清一下 `install.sh` 和 `latest.txt` 的缓存。

## Fork / 换域名

- 终端用户侧:`FNOS_FAN_BASE_URL=https://你的域名/fnos-fan`(install.sh 也支持该环境变量)。
- 维护者侧:`PUBLISH_BASE_URL=...`(release.sh 会把它写进 `dist/install.sh`)。

## 本地开发(直接构建运行)

在能访问 Docker Hub 的开发机上:

```bash
scripts/vendor-kmod.sh        # 若未 vendoring
bash install.sh               # = docker compose up -d --build,本机构建并运行
```
