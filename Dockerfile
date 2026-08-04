# syntax=docker/dockerfile:1

ARG GO_VERSION=1.22
ARG ALPINE_VERSION=3.20
ARG WGCF_VERSION=2.2.32
ARG WIREPROXY_VERSION=1.1.3

FROM golang:${GO_VERSION}-alpine AS warppool-build
WORKDIR /src
COPY cmd/warppool/go.mod ./
COPY cmd/warppool/*.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /warppool .

FROM alpine:${ALPINE_VERSION}

ARG WGCF_VERSION
ARG WIREPROXY_VERSION
ARG TARGETARCH

RUN apk add --no-cache bash curl ca-certificates jq coreutils \
  && update-ca-certificates

# arch map: docker TARGETARCH is amd64/arm64
RUN set -eux; \
  case "${TARGETARCH}" in \
    amd64) WP_ARCH=amd64; WG_ARCH=amd64 ;; \
    arm64) WP_ARCH=arm64; WG_ARCH=arm64 ;; \
    arm)   WP_ARCH=arm;   WG_ARCH=armv7 ;; \
    *) echo "unsupported arch: ${TARGETARCH}"; exit 1 ;; \
  esac; \
  WGCF_URL="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VERSION}/wgcf_${WGCF_VERSION}_linux_${WG_ARCH}"; \
  if [ -n "${GH_PROXY:-}" ]; then WGCF_URL="${GH_PROXY%/}/${WGCF_URL}"; fi; \
  curl -fsSL -o /usr/local/bin/wgcf "${WGCF_URL}"; \
  chmod +x /usr/local/bin/wgcf; \
  WP_URL="https://github.com/pufferffish/wireproxy/releases/download/v${WIREPROXY_VERSION}/wireproxy_linux_${WP_ARCH}.tar.gz"; \
  if [ -n "${GH_PROXY:-}" ]; then WP_URL="${GH_PROXY%/}/${WP_URL}"; fi; \
  curl -fsSL -o /tmp/wireproxy.tar.gz "${WP_URL}"; \
  tar -xzf /tmp/wireproxy.tar.gz -C /usr/local/bin; \
  chmod +x /usr/local/bin/wireproxy; \
  rm -f /tmp/wireproxy.tar.gz; \
  wgcf --version || true; \
  wireproxy --version || true

COPY --from=warppool-build /warppool /usr/local/bin/warppool
COPY scripts/ /opt/warp-pool/scripts/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /opt/warp-pool/scripts/*.sh /usr/local/bin/warppool

ENV DATA_DIR=/data \
    WARP_INSTANCES=1 \
    INSTANCE_PORT_BASE=11000 \
    AGG_SOCKS_PORT=1080 \
    CONTROL_PORT=9090 \
    CONTROL_BIND=127.0.0.1 \
    WGCF_VERSION=${WGCF_VERSION} \
    WIREPROXY_VERSION=${WIREPROXY_VERSION}

VOLUME ["/data"]
EXPOSE 1080 11000 9090

# Default: no NET_ADMIN, no /dev/net/tun (wireproxy userspace)
ENTRYPOINT ["/entrypoint.sh"]
