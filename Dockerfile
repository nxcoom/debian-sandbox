# syntax=docker/dockerfile:1
# ============================================================
# debian-sandbox — 面板沙箱容器的自定义 Debian 底座镜像
# 目标平台: Pterodactyl / Pelican (Wings) 类面板
#   * ENTRYPOINT 走 tini -g -- sandbox-init（与平台现有行为一致）
#   * 兼容 wings 注入的 STARTUP / SERVER_PORT / HOME=/home/container
#   * init 管理: supervisord + 内置真实 root sshd
#   * 常用网络工具全家桶直接烧进镜像（容器重启不丢）
# ============================================================
ARG BASE_IMAGE=debian:bookworm-slim
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="debian-sandbox" \
      org.opencontainers.image.description="Debian sandbox base for Pelican/Pterodactyl(Wings) panels: tini+supervisord init, network toolkit, STARTUP-compatible entrypoint, built-in root sshd" \
      org.opencontainers.image.source="https://github.com/nxcoom/debian-sandbox" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8

# ---------- 常用工具 ----------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates openssl gnupg \
      curl wget aria2 \
      iproute2 net-tools iputils-ping traceroute mtr-tiny bind9-dnsutils \
      netcat-openbsd socat tcpdump nmap iperf3 lsof ethtool whois iftop \
      openssh-client openssh-server rsync dropbear-bin \
      proxychains4 iptables wireguard-tools \
      tini supervisor cron sudo strace procps htop \
      git python3 python3-pip jq \
      unzip zip xz-utils file less vim nano tree pv speedtest-cli \
    ; apt-get clean; rm -rf /var/lib/apt/lists/*

# ---------- cloudflared（隧道常用） ----------
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) cf="cloudflared-linux-amd64" ;; \
      arm64) cf="cloudflared-linux-arm64" ;; \
      *) echo "unsupported arch: $arch"; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/${cf}"; \
    chmod 0755 /usr/local/bin/cloudflared; \
    /usr/local/bin/cloudflared --version

# ---------- init 脚本与配置 ----------
COPY rootfs/ /
# 编译 fakepw.so：让非 root dropbear 用任意用户名/uid 都能通过公钥登录
# （平台容器 uid 随节点变化 988/999/...，只读根无法运行时改 /etc/passwd）
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends gcc libc6-dev; \
    gcc -shared -fPIC -O2 -o /etc/sandbox/fakepw.so /etc/sandbox/fakepw.c; \
    rm -f /etc/sandbox/fakepw.c; \
    apt-get purge -y gcc libc6-dev >/dev/null 2>&1 || true; \
    apt-get autoremove -y >/dev/null 2>&1 || true; \
    rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    echo 'container:x:988:' >> /etc/group; \
    echo 'container:x:988:988::/home/container:/bin/bash' >> /etc/passwd; \
    chmod 0755 /usr/local/bin/sandbox-init /usr/local/bin/sandbox-proot /usr/local/bin/sandbox-keepalive; \
    mkdir -p /home/container /run/sshd /var/log/supervisor /etc/supervisor/conf.d; \
    chown 988:988 /home/container

WORKDIR /home/container

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/sandbox-init"]
