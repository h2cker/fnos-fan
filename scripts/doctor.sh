#!/usr/bin/env bash
# Phase-0 feasibility check. Run on the fnOS HOST to confirm the environment
# can support the module before installing:
#   sudo bash scripts/doctor.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-detect.sh
. "$DIR/lib-detect.sh"

yn() { if "$@"; then echo yes; else echo no; fi; }

echo "== fnos-fan doctor =="
printf '%-18s %s\n' "kernel:"        "$(kver)"
printf '%-18s %s\n' "arch:"          "$(kernel_arch)"
printf '%-18s %s\n' "sys_vendor:"    "$(dmi sys_vendor)"
printf '%-18s %s\n' "product_name:"  "$(dmi product_name)"
printf '%-18s %s\n' "board_name:"    "$(dmi board_name)"
printf '%-18s %s\n' "is QNAP:"       "$(yn is_qnap)"
printf '%-18s %s\n' "x86_64:"        "$( [ "$(kernel_arch)" = x86_64 ] && echo yes || echo "no (qnap8528 needs x86)")"
printf '%-18s %s\n' "kernel headers:" "$(has_headers && echo "present -> $(headers_dir)" || echo MISSING)"
printf '%-18s %s\n' "headers valid:" "$(yn valid_headers)"
printf '%-18s %s\n' "module signing:" "$( sig_enforced && echo "ENFORCED (blocks insmod)" || echo "off" )"
printf '%-18s %s\n' "kernel lockdown:" "$( lockdown_active && echo "ACTIVE (blocks insmod)" || echo "off" )"
printf '%-18s %s\n' "fancontrol:"    "$( fancontrol_running && echo "RUNNING (will conflict!)" || echo "not running" )"
printf '%-18s %s\n' "docker:"        "$(command -v docker >/dev/null && docker --version || echo 'not found')"
printf '%-18s %s\n' "qnap8528:"      "$(yn module_loaded qnap8528)"

echo
echo "== hwmon sensors present now =="
shopt -s nullglob
found=0
for d in /sys/class/hwmon/hwmon*; do
  name="$(cat "$d/name" 2>/dev/null || echo '?')"
  fans=("$d"/fan*_input); temps=("$d"/temp*_input); pwms=("$d"/pwm[0-9])
  printf '  %-28s name=%-12s fans=%d temps=%d pwms=%d\n' "$d" "$name" "${#fans[@]}" "${#temps[@]}" "${#pwms[@]}"
  found=1
done
[ "$found" = 0 ] && echo "  (none — fan driver not loaded yet)"

echo
echo "== verdict =="
[ "$(kernel_arch)" != x86_64 ] && is_qnap && echo "  ! ARM QNAP: qnap8528 won't apply; only built-in hwmon drivers可用。"
has_headers || echo "  ! ACTION: sudo apt update && sudo apt install linux-headers-\$(uname -r)"
{ has_headers && ! valid_headers; } && echo "  ! ACTION: sudo apt install --reinstall linux-headers-\$(uname -r)"
{ sig_enforced || lockdown_active; } && echo "  ! 内核强制模块签名/lockdown:需关闭 Secure Boot 或 module.sig_enforce=0,否则无法加载。"
{ [ "$(kernel_arch)" = x86_64 ] && ! is_qnap && ! any_pwm; } && echo "  i 非 QNAP 且暂无 pwm:安装后容器会自动尝试内置 it87(覆盖 IT8613E 等较新 ITE 芯片)。"
fancontrol_running && echo "  ! ACTION: sudo systemctl disable --now fancontrol  (否则两个程序抢风扇)"
command -v docker >/dev/null || echo "  ! 未安装 Docker。"
echo "  (无 ! 行即环境就绪)"
