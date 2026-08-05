# syntax=docker/dockerfile:1
# v0.2: official cloudflare-warp (proxy mode) × N + warppool aggregate/control

ARG GO_VERSION=1.22
ARG DEBIAN_VERSION=bookworm-slim

FROM golang:${GO_VERSION}-bookworm AS warppool-build
WORKDIR /src
COPY cmd/warppool/go.mod ./
COPY cmd/warppool/*.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /warppool .

FROM debian:${DEBIAN_VERSION}

ARG TARGETPLATFORM
ARG TARGETARCH
ARG COMMIT_SHA=

LABEL org.opencontainers.image.title="warp-pool" \
      org.opencontainers.image.description="Multi official WARP proxy pool (warp-svc × N + warppool)" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/mcheiyue/warp-pool" \
      org.opencontainers.image.revision="${COMMIT_SHA}"

COPY --from=warppool-build /warppool /usr/local/bin/warppool
COPY scripts/ /opt/warp-pool/scripts/
COPY entrypoint.sh /entrypoint.sh

RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release sudo jq dbus; \
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg; \
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/cloudflare-client.list; \
  apt-get update; \
  apt-get install -y --no-install-recommends cloudflare-warp; \
  apt-get clean; \
  rm -rf /var/lib/apt/lists/*; \
  chmod +x /entrypoint.sh /usr/local/bin/warppool /opt/warp-pool/scripts/*.sh; \
  useradd -m -s /bin/bash warp; \
  echo "warp ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/warp; \
  mkdir -p /home/warp/.local/share/warp; \
  echo -n yes > /home/warp/.local/share/warp/accepted-tos.txt; \
  chown -R warp:warp /home/warp

USER warp

ENV DATA_DIR=/data \
    WARP_INSTANCES=2 \
    INSTANCE_PORT_BASE=40000 \
    AGG_SOCKS_PORT=1080 \
    CONTROL_PORT=9090 \
    CONTROL_BIND=127.0.0.1 \
    WARP_CONNECT_TIMEOUT=45 \
    BOOT_HEALTH_WAIT=90 \
    REGISTER_STAGGER=5 \
    REGISTER_JITTER_MAX=8 \
    PARTIAL_REGISTER_POLICY=degraded \
    ROTATE_MODE=reconnect \
    DEREGISTER_ON_SHUTDOWN=1 \
    ENABLE_AGGREGATE=1 \
    ENABLE_CONTROL=1 \
    ENABLE_HEALTH=1 \
    HEALTH_AUTO_ROTATE=0

VOLUME ["/data"]
EXPOSE 1080 40000 9090

# Default: no NET_ADMIN / no tun (WARP proxy mode)
ENTRYPOINT ["/entrypoint.sh"]
