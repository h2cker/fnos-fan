# kmod/

第三方内核模块源码的 vendoring 目录。

`kmod/qnap8528/` 由 `scripts/vendor-kmod.sh` 拉取(需要一次 GitHub 访问,国内可用镜像)。
**构建镜像前必须先 vendoring** —— `scripts/release.sh` 在缺失时会自动执行。

- 上游:https://github.com/0xGiddi/qnap8528
- fnOS 适配 fork(可能含 6.12 内核修复):https://github.com/gzxiexl/qnap8528

切换来源/版本:
```bash
KMOD_REPO=https://github.com/gzxiexl/qnap8528.git KMOD_REF=master scripts/vendor-kmod.sh
```
