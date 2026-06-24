# fnos-fan

> 让飞牛 NAS(fnOS)识别并控制风扇 — 网页手动 / 按温度曲线自动调速

**简体中文** · [English](README.en.md)

fnOS 默认读不到 QNAP 主板上的风扇和温度(它们挂在 ITE8528 EC 上)。fnos-fan 用一个特权 Docker 容器,自动编译并加载 [qnap8528](https://github.com/0xGiddi/qnap8528) 内核模块把风扇暴露出来,再提供一个网页让你手动或按温度曲线自动控速。

## 一键安装

SSH 进你的 fnOS NAS,执行:

```bash
curl -fsSL https://vecr.ai/fnos-fan/install.sh | sudo bash
```

脚本会自动:检测环境 → 缺内核头文件就自动安装 → 拉取并校验镜像 → 启动 → 等待首次编译加载 → 打印结果。默认网页**局域网可访问**(`0.0.0.0:7831`,同网段设备直接打开);收紧/加密码见下方「访问与安全」。

## 前置条件

- **x86_64** 的 QNAP 机型 + fnOS,已安装 Docker。
- 若系统在跑 `fancontrol`,先停掉避免抢风扇:`sudo systemctl disable --now fancontrol`。

## 使用

装好后在**同网段**的电脑/手机浏览器打开 `http://<NAS-IP>:7831`(安装脚本结束时会打印确切地址),然后:

- **自动**:选预设(静音 / 均衡 / 性能),或直接拖动“温度→转速”曲线;
- **手动**:一个百分比滑块固定转速;
- 设置即时生效、自动保存,无需点保存。

## 管理命令

安装后附带 `fnos-fan` 命令:

```
fnos-fan status      查看状态
fnos-fan logs        看日志
fnos-fan restart     重启
fnos-fan stop        停止(会安全把风扇拉满 100%,勿用 docker kill)
fnos-fan update      更新到最新版
fnos-fan uninstall   卸载
```

## 访问与安全

- **默认局域网可直接访问** `http://NAS-IP:7831`;脚本会自动放行 ufw/firewalld 端口。
- **加访问密码**(网络不完全可信时推荐):安装时带 `AUTH_TOKEN`:
  ```bash
  curl -fsSL https://vecr.ai/fnos-fan/install.sh | sudo AUTH_TOKEN=你的密码 bash
  ```
  之后打开网页会弹登录框(用户名随意,密码即 `AUTH_TOKEN`)。
- **最严格(仅本机)**:安装时带 `BIND=127.0.0.1`,再用 SSH 隧道:`ssh -L 7831:127.0.0.1:7831 <用户>@<NAS-IP>`。
- **切勿**在路由器把 `7831` 端口转发到公网;需要外网访问请放到带 HTTPS+认证的反向代理后。
- 网页已内置防护:**只放行用 IP、`localhost`、`*.local` 访问**,可挡掉 DNS 重绑定 / 跨站(CSRF)——即你在局域网里误开的恶意网页也改不了你的风扇。若你通过**反向代理或 Tailscale 等自定义域名**访问,需用 `ALLOWED_HOSTS` 把该域名列出(逗号分隔),否则返回 403:
  ```bash
  curl -fsSL https://vecr.ai/fnos-fan/install.sh | sudo ALLOWED_HOSTS=nas.example.com bash
  ```
- 端口冲突可改 `WEB_PORT`。容器用 **host 网络**直接绑 NAS 端口;若 fnOS 跑在**非桥接(NAT)虚拟机**里,NAS 的 IP 可能不在局域网直连段,需在虚拟机平台做端口转发或改桥接网卡。
- 停止务必用 `fnos-fan stop` / `docker stop`(触发“风扇拉满”安全恢复),**不要用 `docker kill`**。

## 故障安全

退出、控制循环异常、或**所有温度传感器都读不到**时,风扇强制拉满 100%;进程崩溃后容器自动重启重新接管,绝不会把风扇卡在低速。

## 内核升级后

fnOS 升级内核后:① 重启;② `sudo apt install linux-headers-$(uname -r)`;③ `fnos-fan restart`。容器会按新内核版本自动重新编译模块。

## 已知限制

- 仅 **x86_64**;ARM 的 QNAP 用的不是 ITE8528 EC,不适用(只能走通用 hwmon)。
- 开启了 Secure Boot / 内核模块签名强制 / lockdown 时,会拒绝未签名模块,需要关闭或自行签名。
- 没有 Linux 驱动的冷门 EC 芯片不支持。

## 致谢与许可

- 内核模块 **qnap8528** 的版权与 **GPL-2.0-or-later** 许可归原作者 **[0xGiddi](https://github.com/0xGiddi/qnap8528)** 及贡献者所有;本仓库原样 vendoring 用于离线构建,详见 [NOTICE](NOTICE)。
- 仓库其余代码(Go 守护进程、脚本、Web UI)为本项目原创,采用 **GPL-3.0-or-later** 许可,详见 [LICENSE](LICENSE)。

## 二次开发 / 自建分发

想自己构建镜像、用自己的域名分发?见 [RELEASING.md](RELEASING.md)。
