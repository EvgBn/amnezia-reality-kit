# ipt2socks image (build artifact)

**Not a compose service.** This Dockerfile only produces `zfl9/ipt2socks:latest` for COPY into runtime containers.

```bash
make images-ipt2socks
```

Runtime: transparent TCP → SOCKS5 inside **amneziawg** and **coredns**. UDP exit uses **udp-relay** (Go), not ipt2socks `-U`.
