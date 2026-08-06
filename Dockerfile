# syntax=docker/dockerfile:1
# v0.3: Warp mode × netns × N + warppool aggregate/control + single-page WebUI
ARG GO_VERSION=1.22
ARG DEBIAN_VERSION=bookworm-slim

FROM golang:${GO_VERSION}-bookworm AS warppool-build
WORKDIR /src
COPY cmd/warppool/go.mod ./
COPY cmd/warppool/*.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /warppool .

FROM debian:${DEBIAN_VERSION}

ARG TARGETARCH
ARG COMMIT_SHA=
ARG GOST_VERSION=2.11.5

LABEL org.opencontainers.image.title="warp-pool" \
      org.opencontainers.image.description="Warp mode × netns multi-instance WARP pool" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/mcheiyue/warp-pool" \
      org.opencontainers.image.revision="${COMMIT_SHA}"

RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release jq dbus iproute2 iptables procps; \
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg; \
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/cloudflare-client.list; \
  apt-get update; \
  apt-get install -y --no-install-recommends cloudflare-warp; \
  # B3: microsocks preferred (bookworm apt); else compile from rofl0r/microsocks
  if ! apt-get install -y --no-install-recommends microsocks; then \
    apt-get install -y --no-install-recommends build-essential git make; \
    git clone --depth 1 https://github.com/rofl0r/microsocks /tmp/microsocks; \
    make -C /tmp/microsocks; \
    cp /tmp/microsocks/microsocks /usr/local/bin/microsocks; \
    chmod +x /usr/local/bin/microsocks; \
    rm -rf /tmp/microsocks; \
    apt-get purge -y --auto-remove build-essential git make; \
  fi; \
  apt-get clean; \
  rm -rf /var/lib/apt/lists/*; \
  mkdir -p /opt/warp-pool/web /data/instances /run/warp-pool /root/.local/share/warp; \
  echo -n yes > /root/.local/share/warp/accepted-tos.txt; \
  # gost kept as fallback (amd64 only for now; multi-arch later)
  GOST_ARCH=amd64; \
  curl -fsSL -o /tmp/gost.gz \
    "https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-amd64-${GOST_VERSION}.gz"; \
  gunzip -c /tmp/gost.gz > /usr/local/bin/gost; \
  chmod +x /usr/local/bin/gost; \
  rm -f /tmp/gost.gz

COPY --from=warppool-build /warppool /usr/local/bin/warppool
COPY scripts/ /opt/warp-pool/scripts/
COPY web/ /opt/warp-pool/web/
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh /usr/local/bin/warppool /opt/warp-pool/scripts/*.sh; \
    if [ -f /usr/local/bin/gost ]; then chmod +x /usr/local/bin/gost; fi

USER root

ENV DATA_DIR=/data \
    WARP_INSTANCES=2 \
    INSTANCE_PORT_BASE=40000 \
    EXPOSE_PORT_BASE=11000 \
    ENABLE_EXPOSE=1 \
    AGG_SOCKS_PORT=1080 \
    CONTROL_PORT=9090 \
    CONTROL_BIND=127.0.0.1 \
    WARP_CONNECT_TIMEOUT=45 \
    BOOT_HEALTH_WAIT=120 \
    REGISTER_STAGGER=5 \
    REGISTER_JITTER_MAX=8 \
    PARTIAL_REGISTER_POLICY=degraded \
    ROTATE_MODE=restart \
    DEREGISTER_ON_SHUTDOWN=0 \
    ENABLE_AGGREGATE=1 \
    ENABLE_CONTROL=1 \
    ENABLE_HEALTH=1 \
    HEALTH_AUTO_ROTATE=0 \
    WEB_ROOT=/opt/warp-pool/web \
    SOCKS_BIN=microsocks

VOLUME ["/data"]
EXPOSE 1080 11000 11001 9090

ENTRYPOINT ["/entrypoint.sh"]
