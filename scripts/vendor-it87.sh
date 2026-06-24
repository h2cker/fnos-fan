#!/usr/bin/env bash
# Vendor the frankcrawford/it87 kernel-module source into kmod/it87 (one-time,
# needs GitHub access). This out-of-tree fork supports many ITE Super-I/O chips
# the in-tree it87 driver does not (e.g. IT8613E on the Beelink ME mini), so it
# lets non-QNAP x86 boxes expose pwm/fan via hwmon. After vendoring, image
# builds are hermetic and version-pinned.
#
# Mainland-China maintainers can use a mirror, e.g.:
#   IT87_REPO=https://ghproxy.com/https://github.com/frankcrawford/it87.git scripts/vendor-it87.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${IT87_REPO:-https://github.com/frankcrawford/it87.git}"
REF="${IT87_REF:-20f2f2f}"   # pinned: v1.0-232-g20f2f2f (validated on IT8613E / fnOS 6.18)
DEST="kmod/it87"

echo "[vendor-it87] $REPO ($REF) -> $DEST"
rm -rf .tmp-it87
git clone "$REPO" .tmp-it87
git -C .tmp-it87 checkout --quiet "$REF"
rm -rf .tmp-it87/.git
rm -rf .tmp-it87/Research   # ~32MB upstream datasheet archive — not needed to build the module
rm -f .tmp-it87/*.patch     # ~410K upstream reference patches against mainline — not used by our build
[ -f .tmp-it87/it87.c ] && [ -f .tmp-it87/Makefile ] || { echo "[vendor-it87] ERROR: it87.c / Makefile not found in repo"; rm -rf .tmp-it87; exit 1; }
mkdir -p kmod
rm -rf "$DEST"
mv .tmp-it87 "$DEST"
echo "[vendor-it87] done. files: $(ls "$DEST" | tr '\n' ' ')"
