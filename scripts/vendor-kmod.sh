#!/usr/bin/env bash
# Vendor the qnap8528 kernel-module source into kmod/qnap8528 (one-time, needs
# GitHub access). After this, image builds are hermetic and version-pinned.
#
# Mainland-China maintainers can use a mirror, e.g.:
#   KMOD_REPO=https://gitee.com/mirrors/qnap8528.git scripts/vendor-kmod.sh
#   KMOD_REPO=https://ghproxy.com/https://github.com/0xGiddi/qnap8528.git scripts/vendor-kmod.sh
# fnOS-specific fork (may carry 6.12 fixes):
#   KMOD_REPO=https://github.com/gzxiexl/qnap8528.git scripts/vendor-kmod.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${KMOD_REPO:-https://github.com/0xGiddi/qnap8528.git}"
REF="${KMOD_REF:-master}"
DEST="kmod/qnap8528"

echo "[vendor] $REPO ($REF) -> $DEST"
rm -rf .tmp-kmod
git clone --depth 1 --branch "$REF" "$REPO" .tmp-kmod
rm -rf .tmp-kmod/.git
[ -f .tmp-kmod/src/Makefile ] || { echo "[vendor] ERROR: src/Makefile not found in repo"; rm -rf .tmp-kmod; exit 1; }
mkdir -p kmod
rm -rf "$DEST"
mv .tmp-kmod "$DEST"
echo "[vendor] done. src: $(ls "$DEST/src" | tr '\n' ' ')"
