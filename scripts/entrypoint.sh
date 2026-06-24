#!/usr/bin/env bash
# Container entrypoint — the runtime "brain". On every start it:
#   1. validates architecture (image userspace vs host kernel)
#   2. detects board + checks module-signing / lockdown that would block loading
#   3. compiles qnap8528.ko against the host's kernel headers
#      (cached per kernel version AND header fingerprint)
#   4. loads it into the HOST kernel (retrying with skip_hw_check)
#   5. optionally loads generic Super-IO drivers for non-QNAP boards
#   6. execs the fan-control daemon
#
# On a QNAP board, a failure to provide working fan control is FATAL (exit 1):
# the restart policy will retry and the logs make the problem visible, rather
# than silently running with no thermal control.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-detect.sh
. "$DIR/lib-detect.sh"

SRC="/opt/qnap8528/src"
KVER="$(kver)"
CACHE="/data/modules/$KVER"
KO="$CACHE/qnap8528.ko"
BUILD_ID_FILE="$CACHE/.build-id"
IT87_SRC="/opt/it87"                        # vendored frankcrawford/it87 fork
IT87_KO="$CACHE/it87.ko"
IT87_BUILD_ID_FILE="$CACHE/.it87-build-id"

log() { echo "[entrypoint] $*"; }
fatal_if_qnap() { if is_qnap; then log "FATAL: $*"; sleep 10; exit 1; else log "WARN: $*"; fi; }

# Fingerprint of the current kernel build environment. If the kernel is rebuilt
# with the same version string but a different config/ABI, this changes and we
# force a recompile instead of loading a stale, incompatible .ko.
build_id() {
  local d; d="$(headers_dir)"
  if [ -f "$d/.config" ]; then
    cat "$d/.config" "$d/include/generated/utsrelease.h" 2>/dev/null | sha256sum | cut -d' ' -f1
  else
    # Some kernels (e.g. fnOS) ship headers without .config — hashing only
    # utsrelease.h would miss an ABI change on a same-version rebuild. Fold in
    # the headers-tree mtime so a re-installed/changed header set forces a rebuild.
    { cat "$d/include/generated/utsrelease.h" 2>/dev/null; stat -c '%Y' "$d" 2>/dev/null; } | sha256sum | cut -d' ' -f1
  fi
}

arch_check() {
  local k u; k="$(kernel_arch)"; u="$(userspace_arch)"
  # qnap8528 targets the x86 ITE8528 EC.
  if is_qnap && [ "$k" != "x86_64" ]; then
    log "host kernel arch is $k (not x86_64) — qnap8528 does not apply to ARM QNAP; using built-in hwmon only"
    return 1
  fi
  # Image userspace must match the host kernel arch or the module won't link.
  if { [ "$k" = "x86_64" ] && [ "$u" != "amd64" ]; } || { [ "$k" = "aarch64" ] && [ "$u" != "arm64" ]; }; then
    fatal_if_qnap "image arch ($u) does not match host kernel ($k). Pull/build the linux/$( [ "$k" = x86_64 ] && echo amd64 || echo arm64 ) image."
    return 1
  fi
  return 0
}

build_module() {
  if ! valid_headers; then
    if has_headers; then
      fatal_if_qnap "kernel headers for $KVER are incomplete (missing Makefile/scripts). Try: apt install --reinstall linux-headers-$KVER"
    else
      fatal_if_qnap "no kernel headers for $KVER. On the HOST: apt install linux-headers-$KVER (and 'docker restart fnos-fan')"
    fi
    return 1
  fi
  log "building qnap8528.ko for $KVER (headers: $(headers_dir)) ..."
  mkdir -p "$CACHE"
  if make -C "$(headers_dir)" M="$SRC" modules >/tmp/build.log 2>&1; then
    cp "$SRC/qnap8528.ko" "$KO"
    build_id > "$BUILD_ID_FILE"
    make -C "$(headers_dir)" M="$SRC" clean >/dev/null 2>&1 || true
    log "build OK -> $KO"
    return 0
  fi
  log "build FAILED:"; sed 's/^/    /' /tmp/build.log
  fatal_if_qnap "module compilation failed (see log above)"
  return 1
}

load_qnap_module() {
  if module_loaded qnap8528; then log "qnap8528 already loaded"; return 0; fi
  arch_check || return 0
  if ! is_qnap; then
    log "host is not QNAP — skipping qnap8528 (using built-in hwmon drivers)"
    return 0
  fi
  if sig_enforced || lockdown_active; then
    log "FATAL: kernel enforces module signing / lockdown — an unsigned out-of-tree module cannot be loaded."
    log "       Options: (1) boot with module.sig_enforce=0, (2) disable Secure Boot, (3) sign the module with your MOK."
    sleep 10; exit 1
  fi

  # (Re)build if no cached .ko or the kernel build fingerprint changed.
  if [ ! -f "$KO" ] || [ "$(cat "$BUILD_ID_FILE" 2>/dev/null)" != "$(build_id)" ]; then
    rm -f "$KO"
    build_module || return 1
  fi

  log "loading $KO"
  if insmod "$KO" 2>/tmp/insmod.log; then return 0; fi
  log "plain insmod failed, retrying with skip_hw_check=1"
  if insmod "$KO" skip_hw_check=1 2>>/tmp/insmod.log; then return 0; fi
  log "load FAILED:"; sed 's/^/    /' /tmp/insmod.log
  return 1
}

# Opt-in generic Super-IO/EC drivers for non-QNAP boards.
# Set EXTRA_MODULES="it87 nct6775" in the environment to try them.
load_generic_modules() {
  for m in ${EXTRA_MODULES:-}; do
    log "modprobe $m"; modprobe "$m" 2>/dev/null || log "  (modprobe $m unavailable)"
  done
}

# Fallback for non-QNAP x86 boards: if nothing exposes a pwm yet, build+load the
# vendored frankcrawford/it87 fork. It supports many ITE Super-I/O chips the
# in-tree it87 lacks (e.g. IT8613E on the Beelink ME mini), letting generic
# mini-NAS boxes expose pwm/fan via hwmon. Best-effort: never fatal — if it does
# not bind, the web UI still runs for temperature monitoring.
maybe_load_it87() {
  is_qnap && return 0                          # QNAP boards use qnap8528
  [ -f "$IT87_SRC/Makefile" ] || return 0      # it87 not vendored into this image
  if any_pwm; then log "pwm control already present — skipping it87"; return 0; fi
  if module_loaded it87; then log "it87 already loaded"; return 0; fi
  [ "$(kernel_arch)" = x86_64 ] || { log "it87 needs x86_64 — skipping (host is $(kernel_arch))"; return 0; }
  arch_check || return 0                        # image userspace vs kernel match
  if sig_enforced || lockdown_active; then
    log "WARN: kernel enforces module signing / lockdown — cannot load out-of-tree it87"
    return 0
  fi
  if ! valid_headers; then
    log "WARN: no valid kernel headers for $KVER — cannot build it87 (on the HOST: apt install linux-headers-$KVER)"
    return 0
  fi

  # (Re)build if no cached .ko or the kernel build fingerprint changed.
  if [ ! -f "$IT87_KO" ] || [ "$(cat "$IT87_BUILD_ID_FILE" 2>/dev/null)" != "$(build_id)" ]; then
    log "building it87 (frankcrawford fork) for $KVER ..."
    mkdir -p "$CACHE"
    if make -C "$IT87_SRC" TARGET="$KVER" >/tmp/it87-build.log 2>&1; then
      cp "$IT87_SRC/it87.ko" "$IT87_KO"
      build_id > "$IT87_BUILD_ID_FILE"
      make -C "$IT87_SRC" TARGET="$KVER" clean >/dev/null 2>&1 || true
      log "it87 build OK -> $IT87_KO"
    else
      log "it87 build FAILED:"; sed 's/^/    /' /tmp/it87-build.log
      return 0
    fi
  fi

  modprobe hwmon_vid wmi 2>/dev/null || true   # it87 deps; insmod won't auto-resolve them
  log "loading $IT87_KO"
  if insmod "$IT87_KO" 2>/tmp/it87-insmod.log; then
    if any_pwm; then log "it87 loaded — pwm fan control now available"
    else log "it87 loaded but found no supported chip on this board (no pwm appeared)"; fi
  else
    log "it87 load FAILED:"; sed 's/^/    /' /tmp/it87-insmod.log
  fi
  return 0
}

if fancontrol_running; then
  log "WARN: a 'fancontrol' process is running on the host and will fight us over PWM. Stop it: systemctl disable --now fancontrol"
fi

if ! load_qnap_module; then
  fatal_if_qnap "qnap8528 not loaded — refusing to run with no fan control on a QNAP board"
fi
load_generic_modules
maybe_load_it87

log "starting fanctld"
exec /usr/local/bin/fanctld
