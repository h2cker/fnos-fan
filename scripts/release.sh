#!/usr/bin/env bash
# Maintainer release: build the image and produce a distributable tarball.
#   scripts/release.sh
# Run on a machine that can reach GitHub (for vendoring) and Docker base images
# (use a proxy if in mainland China). END USERS never need either — they only
# download the resulting tarball + install.sh from YOUR domain.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null || echo dev)"
IMAGE="fnos-fan"
PLATFORM="${PLATFORM:-linux/amd64}"   # qnap8528 EC is x86-only
DIST="dist"

sha_emit() {
  local f="$1" d b; d="$(dirname "$f")"; b="$(basename "$f")"
  if command -v sha256sum >/dev/null; then ( cd "$d" && sha256sum "$b" > "$b.sha256" )
  else ( cd "$d" && shasum -a 256 "$b" > "$b.sha256" ); fi
}

# 1. vendor the kernel-module source if missing
[ -f kmod/qnap8528/src/Makefile ] || { echo "[release] vendoring qnap8528 ..."; scripts/vendor-kmod.sh; }

# 2. build (amd64 image even on an ARM build host)
echo "[release] building $IMAGE:$VERSION ($PLATFORM) ..."
docker build --platform "$PLATFORM" --build-arg "VERSION=$VERSION" \
  -t "$IMAGE:$VERSION" -t "$IMAGE:latest" .

# 3. save image + checksum + latest marker + installer
mkdir -p "$DIST"
TAR="$DIST/fnos-fan-$VERSION.tar.gz"
echo "[release] saving $TAR ..."
docker save "$IMAGE:$VERSION" "$IMAGE:latest" | gzip > "$TAR"
sha_emit "$TAR"
echo "$VERSION" > "$DIST/latest.txt"
cp scripts/install.sh "$DIST/install.sh"
if [ -n "${PUBLISH_BASE_URL:-}" ]; then
  sed -i.bak "s#https://vecr.ai/fnos-fan#${PUBLISH_BASE_URL}#g" "$DIST/install.sh"
  rm -f "$DIST/install.sh.bak"
fi

cat <<EOF

[release] done. Upload the contents of $DIST/ to your web root, e.g.:
  https://vecr.ai/fnos-fan/
    fnos-fan-$VERSION.tar.gz
    fnos-fan-$VERSION.tar.gz.sha256
    latest.txt
    install.sh        (set PUBLISH_BASE_URL before running to bake your domain in)

End users then install with one command:
  curl -fsSL https://vecr.ai/fnos-fan/install.sh | sudo bash
EOF
