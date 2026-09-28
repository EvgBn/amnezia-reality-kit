# amneziawg/Dockerfile
# Multi-process container: AmneziaWG + ipt2socks (TCP) + udp-relay (NFQUEUE UDP)
# Supervised by supervisord

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: Build awg-tools (awg, awg-quick) from source
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:3.23 AS builder-awg-tools

ARG AWG_TOOLS_REF
RUN : "${AWG_TOOLS_REF:?AWG_TOOLS_REF build-arg is required}" && \
    apk add --no-cache git make gcc musl-dev libmnl-dev && \
    git init /src/awg-tools && \
    git -C /src/awg-tools remote add origin https://github.com/amnezia-vpn/amneziawg-tools && \
    git -C /src/awg-tools fetch --depth 1 origin "${AWG_TOOLS_REF}" && \
    git -C /src/awg-tools checkout --detach FETCH_HEAD

WORKDIR /src/awg-tools/src
RUN make -j"$(nproc)"

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1b: Minimal image for `make create-data` key generation (awg genkey / pubkey)
# ─────────────────────────────────────────────────────────────────────────────
FROM builder-awg-tools AS keygen
RUN cp /src/awg-tools/src/wg /usr/local/bin/awg && chmod +x /usr/local/bin/awg
ENTRYPOINT ["awg"]

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: Build udp-relay (NFQUEUE → SOCKS UDP exit)
# ─────────────────────────────────────────────────────────────────────────────
FROM golang:1.22-alpine AS builder-udp-relay

RUN apk add --no-cache gcc musl-dev libnetfilter_queue-dev git

WORKDIR /build
COPY go.mod go.sum ./
COPY internal/ ./internal/
COPY tests/ ./tests/
COPY cmd/udp-relay ./cmd/udp-relay
RUN go mod download
RUN CGO_ENABLED=1 GOOS=linux go build -o udp-relay ./cmd/udp-relay
RUN CGO_ENABLED=1 GOOS=linux go test ./internal/udprelay ./tests/udprelay/...

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3: ipt2socks binary (zfl9/ipt2socks:latest)
# ─────────────────────────────────────────────────────────────────────────────
FROM zfl9/ipt2socks:latest AS ipt2socks-bin

# ─────────────────────────────────────────────────────────────────────────────
# Stage 4: Runtime — AmneziaWG + ipt2socks + udp-relay + supervisord
# ─────────────────────────────────────────────────────────────────────────────
FROM alpine:3.23

RUN apk add --no-cache \
    bash \
    bind-tools \
    ca-certificates \
    curl \
    iproute2 \
    iptables \
    kmod \
    libnetfilter_queue \
    libqrencode-tools \
    supervisor \
    tzdata

COPY --from=builder-awg-tools /src/awg-tools/src/wg /usr/local/bin/awg
COPY --from=builder-awg-tools /src/awg-tools/src/wg-quick/linux.bash /usr/local/bin/awg-quick
COPY --from=ipt2socks-bin /usr/local/bin/ipt2socks /usr/local/bin/ipt2socks
COPY --from=builder-udp-relay /build/udp-relay /usr/local/bin/udp-relay

RUN ln -s awg /usr/local/bin/wg && chmod +x /usr/local/bin/udp-relay

COPY supervisord.conf /etc/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
COPY awg-init.sh /awg-init.sh
COPY awg-migrate-tproxy.sh /awg-migrate-tproxy.sh

RUN chmod +x /entrypoint.sh /healthcheck.sh /awg-init.sh /awg-migrate-tproxy.sh

ENTRYPOINT ["/entrypoint.sh"]
