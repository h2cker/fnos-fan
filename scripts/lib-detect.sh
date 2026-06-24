#!/usr/bin/env bash
# Shared environment-detection helpers. Sourced by doctor.sh (host),
# entrypoint.sh (container) and install.sh (host). No side effects on source.

kver() { uname -r; }

# headers_dir prints the kernel build tree (where module compilation finds
# headers), or empty if none is available for the running kernel.
headers_dir() {
  local k; k="$(kver)"
  if [ -d "/lib/modules/$k/build" ]; then
    readlink -f "/lib/modules/$k/build"
  elif [ -d "/usr/src/linux-headers-$k" ]; then
    echo "/usr/src/linux-headers-$k"
  fi
}

has_headers() { [ -n "$(headers_dir)" ]; }

# valid_headers checks the headers tree is complete enough to build a module
# (a partial / interrupted install lacks Makefile or scripts/).
valid_headers() {
  local d; d="$(headers_dir)"
  [ -n "$d" ] && [ -f "$d/Makefile" ] && [ -d "$d/scripts" ]
}

dmi() { cat "/sys/class/dmi/id/$1" 2>/dev/null; }

# is_qnap returns 0 when DMI identifies the board as QNAP.
is_qnap() {
  printf '%s %s\n' "$(dmi sys_vendor)" "$(dmi board_vendor)" | grep -qi qnap
}

module_loaded() { lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

# kernel_arch is the running kernel's architecture (x86_64, aarch64, ...).
kernel_arch() { uname -m; }

# userspace_arch is the architecture of THIS image's toolchain (amd64, arm64).
userspace_arch() { dpkg --print-architecture 2>/dev/null || echo unknown; }

# sig_enforced returns 0 when the kernel rejects unsigned modules.
sig_enforced() {
  local f=/sys/module/module/parameters/sig_enforce
  [ -e "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "Y" ]
}

# lockdown_active returns 0 when kernel lockdown is in integrity/confidentiality
# mode (which blocks unsigned module loading).
lockdown_active() {
  local f=/sys/kernel/security/lockdown
  [ -e "$f" ] && grep -q '\[integrity\]\|\[confidentiality\]' "$f" 2>/dev/null
}

# fancontrol_running returns 0 when a competing fan daemon is writing PWM.
fancontrol_running() { pgrep -x fancontrol >/dev/null 2>&1 || pgrep -f 'pwmconfig' >/dev/null 2>&1; }
