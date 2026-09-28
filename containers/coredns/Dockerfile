# coredns/Dockerfile
# Multi-process container: CoreDNS + ipt2socks (DoT upstream)
# Supervised by supervisord

FROM coredns/coredns:1.11.1 AS coredns-binary

FROM zfl9/ipt2socks:latest AS ipt2socks-bin

FROM alpine:3.23

RUN apk add --no-cache \
    bash \
    bind-tools \
    iptables \
    supervisor

COPY --from=coredns-binary /coredns /usr/local/bin/coredns
COPY --from=ipt2socks-bin /usr/local/bin/ipt2socks /usr/local/bin/ipt2socks

COPY supervisord.conf /etc/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
COPY coredns-init.sh /coredns-init.sh

RUN chmod +x /entrypoint.sh /healthcheck.sh /coredns-init.sh

EXPOSE 53/udp 53/tcp

ENTRYPOINT ["/entrypoint.sh"]
