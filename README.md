# fnos-fan

> 让飞牛 NAS(fnOS)识别并控制风扇 — 网页手动 / 按温度曲线自动调速

**简体中文** · [English](README.en.md)

fnOS 默认读不到 QNAP 主板上的风扇和温度(它们挂在 ITE8528 EC 上)。fnos-fan 用一个特权 Docker 容器,自动编译并加载 [qnap8528](https://github.com/0xGiddi/qnap8528) 内核模块把风扇暴露出来,再提供一个网页让你手动或按温度曲线自动控速。

## 一键安装

SSH 进你的 fnOS NAS,执行:

```bash
curl -fsSL https://vecr.ai/fnos-fan/install.sh | sudo bash
```

脚本会自动:检测环境 → 缺内核头文件就自动安装 → 拉取并校验镜像 → 启动 → 等待首次编译加载 → 打印结果。默认网页只监听本机(`127.0.0.1:7831`)。

## 前置条件

- **x86_64** 的 QNAP 机型 + fnOS,已安装 Docker。
- 若系统在跑 `fancontrol`,先停掉避免抢风扇:`sudo systemctl disable --now fancontrol`。

## 使用

浏览器打开网页后:

- **自动**:选预设(静音 / 均衡 / 性能),或直接拖动“温度→转速”曲线;
- **手动**:一个百分比滑块固定转速;
- 设置即时生效、自动保存,无需点保存。

远程访问(默认仅本机监听,最安全):

```bash
ssh -L 7831:127.0.0.1:7831 <用户>@<NAS-IP>
# 然后本机浏览器打开 http://127.0.0.1:7831
```

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

## 安全

默认只绑 `127.0.0.1`,通过上面的 SSH 隧道访问。若设 `BIND=0.0.0.0` 暴露到局域网,则**接口无鉴权**(任何设备都能改你的风扇),请放到带认证的反向代理后面。停止务必用 `fnos-fan stop` / `docker stop`(会触发“风扇拉满”的安全恢复),**不要用 `docker kill`**。

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
- 仓库其余代码(Go 守护进程、脚本、Web UI)为本项目原创。

## 二次开发 / 自建分发

想自己构建镜像、用自己的域名分发?见 [RELEASING.md](RELEASING.md)。
