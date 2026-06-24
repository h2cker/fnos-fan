# syntax=docker/dockerfile:1

# ---- stage 1: build the Go daemon (static, cross-compiled to amd64) ----
# Runs natively on the build host's arch, emits a linux/amd64 binary.
FROM --platform=$BUILDPLATFORM golang:1.24-bookworm AS gobuild
WORKDIR /src
COPY go.mod ./
# No external module deps yet; add `COPY go.sum ./` + `go mod download` when added.
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/fanctld ./cmd/fanctld

# ---- stage 2: runtime (amd64; compiles the .ko at startup -> needs a toolchain) ----
# qnap8528 targets the x86 ITE8528 EC, so the image is pinned to linux/amd64.
FROM --platform=linux/amd64 debian:bookworm-slim AS runtime
ARG VERSION=dev
LABEL org.opencontainers.image.title="fnos-fan" \
      org.opencontainers.image.description="fnOS fan control via qnap8528 (ITE8528 EC) + web UI" \
      org.opencontainers.image.version="${VERSION}"
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential kmod libelf-dev bc curl \
    && rm -rf /var/lib/apt/lists/*

# Vendored kernel-module source (run scripts/vendor-kmod.sh before building).
# Compiled at runtime against the host's kernel headers (mounted read-only).
COPY kmod/qnap8528 /opt/qnap8528
COPY scripts/ /opt/fnos-fan/scripts/
COPY --from=gobuild /out/fanctld /usr/local/bin/fanctld
RUN chmod +x /opt/fnos-fan/scripts/*.sh

ENV WEB_PORT=7831
ENTRYPOINT ["/opt/fnos-fan/scripts/entrypoint.sh"]
