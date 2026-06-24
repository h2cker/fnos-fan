# fnos-fan

让 **fnOS(飞牛)** 能识别并控制风扇的一体化方案:一个**特权 Docker 容器**,启动时自动检测环境、编译并加载 [qnap8528](https://github.com/0xGiddi/qnap8528) 内核模块(QNAP 的 ITE8528 EC),再通过网页手动 / 自动控制转速。

> ⚠️ 内核模块运行在**宿主机内核**里,不在容器内。容器负责:编译 `.ko`、把它 `insmod` 进宿主内核、再读写宿主 `/sys/class/hwmon` 来控风扇。因此容器**必须 `privileged`**,且仅支持 **x86_64**(qnap8528 是 x86 的 EC)。

---

## 给用户:一条命令安装

在 **fnOS NAS** 上执行(脚本与镜像都从维护者的域名下载,**不经过 GitHub**):

```bash
curl -fsSL https://YOUR_DOMAIN/fnos-fan/install.sh | sudo bash
```

脚本会自动:检测架构 / Docker / fancontrol 冲突 → **缺内核头文件自动 `apt install`** → 下载并校验镜像 → `docker load` → 写 compose → 启动 → 等首次编译(~30-60s)→ 验证风扇 → 打印网址。

- 默认网页**只绑 `127.0.0.1`**(安全)。远程访问用 SSH 隧道:
  `ssh -L 7831:127.0.0.1:7831 <user>@<nas-ip>`,再开 `http://127.0.0.1:7831`。
- 想直接在局域网访问:`BIND=0.0.0.0 curl ... | sudo bash`(**无鉴权,自担风险**,建议套带认证的反向代理)。
- 更新:重新跑安装命令。卸载:`curl -fsSL https://YOUR_DOMAIN/fnos-fan/install.sh | sudo bash -s -- --uninstall`。

### 前置条件
- x86_64 的 QNAP + fnOS,已装 Docker。
- 若宿主在跑 `fancontrol`:`sudo systemctl disable --now fancontrol`(否则两边抢风扇)。

---

## 给维护者:构建与发布

为什么这样设计(中国网络现实):GitHub、Docker Hub、ghcr.io 在国内都不稳/被墙。所以**你(维护者)预构建好整个镜像**,把镜像与安装脚本放到**你自己的域名**,终端用户全程不碰 GitHub / Docker Hub。

```bash
# 1) 一次性把内核模块源码 vendoring 进仓库(需 GitHub,可用镜像)
scripts/vendor-kmod.sh
#   国内镜像: KMOD_REPO=https://ghproxy.com/https://github.com/0xGiddi/qnap8528.git scripts/vendor-kmod.sh

# 2) 构建镜像 + 打包 tarball + 校验 + install.sh(把域名写进去)
PUBLISH_BASE_URL=https://YOUR_DOMAIN/fnos-fan scripts/release.sh

# 3) 把 dist/ 里的文件上传到你的网站根:
#    fnos-fan-<ver>.tar.gz, .sha256, latest.txt, install.sh
```

渠道默认走 **镜像 tarball + `docker load`**(零 registry 运维,国内你的服务器直连最稳)。`install.sh` 顶部 `BASE_URL` 一个变量即可改成自建 registry。

---

## 架构

```
通用镜像(build 一次,linux/amd64) + 运行时检测大脑(每次启动)
  entrypoint.sh: 架构校验 → 签名/lockdown 检查 → 编译/取缓存 .ko(按内核版本+头文件指纹)
                 → insmod 进宿主内核 → 扫描 hwmon → 启动 fanctld
  fanctld (Go) : 手动/自动控制循环 + 失效保护 + Web UI + JSON API
```

控制守护是**驱动无关**的:只消费 `/sys/class/hwmon` 通用接口,所以 QNAP(qnap8528)和主线内核已支持的通用 EC(it87 / nct6775,设 `EXTRA_MODULES`)都能用。

## 配置与界面

网页:模式(自动曲线 / 手动固定)、预设(静音/均衡/性能)、可拖拽温控曲线、传感器下拉选择、最低转速、采样间隔。**即改即存**,配置持久化在 `data/config.json`。

- 自动:按曲线对决策温度线性插值;不低于 `min_pwm` 地板。
- 手动:固定转速。
- 服务端对所有写入做范围/单调/去重校验(防 curl/脚本写入畸形曲线烧硬件)。

## 安全模型(务必了解)

- 这是一个能停风扇的**特权**服务。默认**只绑 localhost**,通过 SSH 隧道访问。
- `BIND=0.0.0.0` 会暴露到局域网且**无鉴权**——任何设备都能改你的风扇。要暴露请放到带认证的反向代理(Caddy 自动 HTTPS / nginx + Basic Auth)后面。
- 停止请用 **`docker stop fnos-fan`**(触发"风扇拉满 100%"的安全恢复);**不要 `docker kill`**(SIGKILL 无法在用户态恢复,风扇会停在最后转速)。

## 故障安全

- 退出(SIGTERM)、控制循环 panic、或**全部温度传感器读不到**时:风扇强制拉满 100%。
- panic 后进程崩溃,容器 `restart: unless-stopped` 自动重启重新接管。

## 内核升级后

fnOS 升级内核后:① 重启;② `sudo apt install linux-headers-$(uname -r)`;③ `docker restart fnos-fan`。容器会按新内核版本+头文件指纹**自动重新编译** `.ko`(旧缓存自动失效)。

## 排障

```bash
sudo bash scripts/doctor.sh     # 体检:架构/头文件/签名/lockdown/fancontrol/传感器
docker logs -f fnos-fan         # 运行日志
```

## 已知限制

- **架构**:仅 x86_64;ARM QNAP 的 EC 不是 ITE8528,qnap8528 不适用(仅通用 hwmon 可用)。
- **Secure Boot / 模块签名 / 内核 lockdown**:会拒绝未签名模块。需关闭 Secure Boot 或 `module.sig_enforce=0`,或用你的 MOK 给模块签名。entrypoint 会检测并给出明确报错。
- **冷门 EC**:没有 Linux 驱动的芯片不支持(需单独写驱动)。
- `kmod/qnap8528` 默认取上游 `master`,建议 `KMOD_REF` 钉到具体 tag/commit。

## 目录结构

```
cmd/fanctld/        守护进程入口(扫描→控制→Web,失效保护)
internal/hwmon/     驱动无关的 hwmon sysfs 扫描/读写
internal/control/   控制循环(手动/自动 + 滞回 + 失效保护 + 传感器失效保护)
internal/config/    配置加载/持久化
internal/api/       JSON API(含服务端校验) + 内嵌 Web UI
scripts/lib-detect.sh  共享检测(内核/头文件/架构/签名/lockdown/fancontrol)
scripts/doctor.sh      宿主体检
scripts/entrypoint.sh  容器运行时大脑
scripts/install.sh     终端用户一键安装(从你的域名)
scripts/vendor-kmod.sh 维护者:vendoring 内核模块源码
scripts/release.sh     维护者:构建镜像 + 打包 tarball
kmod/qnap8528/         vendored 内核模块源码(由 vendor-kmod.sh 生成)
Dockerfile             多阶段:Go 交叉编译 amd64 + 运行时(工具链 + 源码)
docker-compose.yml     开发/构建用(build);终端用户用 install.sh 生成的 image 版
```

## 致谢与第三方许可

- 内核模块 **qnap8528**(`kmod/qnap8528/`)版权归原作者 **[0xGiddi](https://github.com/0xGiddi/qnap8528)** 及贡献者所有,许可证 **GPL-2.0-or-later**,本仓库原样 vendoring 用于离线构建,未作修改;fnOS 适配 fork:[gzxiexl/qnap8528](https://github.com/gzxiexl/qnap8528)。详见 [NOTICE](NOTICE)。
- 本仓库其余代码(`fanctld` Go 守护、脚本、Web UI)为本项目原创。

## 后续可选增强(尚未实现)

可观测性(Prometheus `/metrics`、结构化日志)、API 鉴权(Bearer Token)、CSRF 防护、HTTPS/TLS、配置变更审计日志、UI 按 PWM 分组展示。这些不影响核心功能,按需再加。
