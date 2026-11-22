# debian-sandbox

面向 **Pterodactyl / Pelican (Wings) 类游戏面板沙箱容器**的自定义 Debian 底座镜像。

**适配平台实测约束**（tryaltare 验证）：

- 容器根文件系统**只读**，唯一可写卷 = `/home/container`
- 容器强制以 **uid 988（container 用户）**运行，无 root
- 所以：supervisor / 保活 / 用户服务的全部状态都放在 `/home/container/sandbox/` 下（可写、持久）
- SSH 保留平台自带的 `.sandbox/altare-sshd`（凭据由面板管理），守护模式会自动拉起它

## 特性

- **init 管理**：`tini -g` 作 PID1 + `supervisord`（以 988 运行，状态在可写卷）管理常驻服务
- **低占用保活**：CPU 突发 + 网络心跳 + 控制台心跳，防面板冻结空闲容器（平均 CPU <1%）
- **常用网络工具全家桶烧进镜像**：容器重启不丢
- **兼容面板机制**：识别 Wings 注入的 `STARTUP` 环境变量（支持 `{{VAR}}` 替换）
- GitHub Actions 自动构建并推送 GHCR

## 镜像地址

| Tag | 内容 |
|---|---|
| `ghcr.io/nxcoom/debian-sandbox:latest` | Debian 12 bookworm-slim（推荐） |
| `ghcr.io/nxcoom/debian-sandbox:bookworm` | 同 latest |
| `ghcr.io/nxcoom/debian-sandbox:trixie` | Debian 13 trixie-slim |

## 面板里怎么填

**Docker 镜像**：
```
ghcr.io/nxcoom/debian-sandbox:latest
```

**启动命令**（二选一）：

1. `sandbox-init` —— **守护模式（推荐）**：init 管理 + 保活 + 平台 SSH 自动拉起
2. `./.sandbox/start.sh` —— **兼容模式**：保留平台原有启动脚本，仅换底座镜像（同样有 init + 保活）

## SSH 说明（重要）

平台限制（只读根文件系统 + 非 root）下，标准 sshd 无法以 root 运行。所以：

- **SSH 由平台自带 `altare-sshd` 提供**，端口/凭据和你平时用的完全一样，无需任何配置
- 守护模式（`sandbox-init`）会自动拉起它（`SANDBOX_ALTARE_SSHD=0` 可关闭）
- SSH 会话落在平台的 proot 环境里；容器本体的文件可以通过 **`/proc/1/root/home/container/`** 前缀访问编辑（例如编辑服务配置）

## init 工作方式

```
PID1  tini -g ── sandbox-init
                 ├─ prestart 钩子（镜像内置 + /home/container/sandbox/prestart.d/）
                 ├─ 守护模式: 拉起平台 altare-sshd
                 ├─ 生成 keepalive 服务配置 → /home/container/sandbox/supervisor.d/
                 ├─ supervisord（nodaemon，带看门狗自动重启）
                 └─ 有 STARTUP → 前台执行启动命令；无 → 常驻守护
```

## 防冻结保活（内置）

| 活跃信号 | 实现 | 默认占用 |
|---|---|---|
| CPU | 每轮短促计算突发（纯 bash 忙询，无 fork） | ~500ms/60s，平均 **<1%** |
| 网络 | HTTPS 心跳（`cdn-cgi/trace` / `generate_204`，端点轮换） | KB 级/分钟 |
| 终端 | 周期性向容器控制台输出一行 + touch 心跳文件 | 每 5 分钟一行 |

```bash
supervisorctl status           # keepalive 应为 RUNNING
supervisorctl tail keepalive   # 看保活输出（心跳同时直接打在容器控制台上）
```

心跳文件：`/home/container/sandbox/.keepalive`（mtime 即最近一轮心跳时间）。

## 内置工具清单

- **网络诊断**：ip(iproute2) / ss / net-tools / ping / traceroute / mtr / dig+nslookup / nc / socat / tcpdump / nmap / iperf3 / lsof / ethtool / whois / iftop
- **下载/传输**：curl / wget / aria2 / rsync / openssl
- **代理隧道**：cloudflared（最新版）/ iptables / wireguard-tools / proxychains4
- **开发常用**：git / python3 + pip / jq / vim / nano / less / tree / file / unzip / zip / xz
- **系统**：tini / supervisord / cron / sudo / strace / htop / procps / speedtest-cli / openssh-client + openssh-server

## 加服务（supervisor）

```bash
# SSH 会话里（proot 环境），通过 /proc/1/root 前缀编辑容器级配置：
vi /proc/1/root/home/container/sandbox/services/myapp.conf
# 然后在面板重启容器生效（或等下次重启）
```

配置示例见 [examples/services/](examples/services/)（含 cloudflared 隧道示例）。

## 目录约定（持久卷 `/home/container`）

```
/home/container/sandbox/
├── services/       supervisord 用户服务配置 (*.conf)
├── supervisor.d/   镜像运行时生成的服务配置（keepalive）
├── prestart.d/     每次启动前执行的钩子 (*.sh)
├── logs/           supervisord 与服务日志
├── supervisor.sock / supervisor.pid
└── .keepalive      保活心跳文件（看 mtime）
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `SANDBOX_KEEPALIVE` | `1` | 保活脚本开关 |
| `SANDBOX_ALTARE_SSHD` | `1` | 守护模式是否拉起平台 altare-sshd |
| `KEEPALIVE_INTERVAL` | `60` | 保活循环间隔（秒），仍被冻结就调小 |
| `KEEPALIVE_CPU_MS` | `500` | 每轮 CPU 突发毫秒数 |
| `KEEPALIVE_NET` | `1` | 网络心跳开关 |
| `KEEPALIVE_CONSOLE` | `1` | 控制台心跳开关 |
| `KEEPALIVE_EVERY` | `5` | 每 N 轮打印一行控制台输出 |
| `SERVER_PORT` | `22` | sshd 监听端口（面板自动注入） |
| `TZ` | 面板注入（UTC） | 想用东八区就在面板加 `TZ=Asia/Shanghai` |

## 构建

- 推送到 `main` 自动构建并推送 GHCR（bookworm + trixie 两个变体）
- 手动触发：Actions → build → Run workflow
- 本地：`docker build --build-arg BASE_IMAGE=debian:bookworm-slim -t debian-sandbox .`
