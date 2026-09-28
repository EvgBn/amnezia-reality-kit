# zfl9/ipt2socks — pinned release v1.1.4, tagged locally as zfl9/ipt2socks:latest
ARG IPT2SOCKS_VERSION=v1.1.4

FROM alpine:3.23 AS fetch
ARG IPT2SOCKS_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl ca-certificates && \
    case "${TARGETARCH}" in \
      amd64)  ASSET="ipt2socks@x86_64-linux-musl@x86_64" ;; \
      arm64)  ASSET="ipt2socks@aarch64-linux-musl@generic+v8a" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/ipt2socks \
      "https://github.com/zfl9/ipt2socks/releases/download/${IPT2SOCKS_VERSION}/${ASSET}" && \
    chmod +x /tmp/ipt2socks

FROM alpine:3.23
COPY --from=fetch /tmp/ipt2socks /usr/local/bin/ipt2socks
RUN ipt2socks -V
ENTRYPOINT ["/usr/local/bin/ipt2socks"]
