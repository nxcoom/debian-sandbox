# debian-sandbox

面向 **Pterodactyl / Pelican (Wings) 类游戏面板沙箱容器**的自定义 Debian 底座镜像。

**适配平台实测约束**（tryaltare 验证）：

- 容器根文件系统**只读**，唯一可写卷 = `/home/container`
- 容器强制以 **uid 988（container 用户）**运行，无 root
- 平台 SSH 落在 proot rootfs（平台安装脚本维护的独立系统，容器重建时会被**重置**）
- 所以：supervisor / SSH / 保活的全部状态都放在 `/home/container/sandbox/` 下（可写、持久）

## 特性

- **init 管理**：`tini -g` 作 PID1 + `supervisord`（看门狗自动重启）管理常驻服务
- **两个容器层入口**：面板控制台 = 容器层 shell；dropbear 公钥 SSH 直达容器层
- **低占用保活**：CPU 突发 + 网络心跳 + 控制台心跳，防面板冻结空闲容器（平均 CPU <1%）
- **常用网络工具全家桶烧进镜像**：容器层直接可用，重启不丢
- **兼容面板机制**：识别 Wings 注入的 `STARTUP` 环境变量（支持 `{{VAR}}` 替换）

## 重要：两个"世界"的区别

| | 容器层（镜像本体） | proot 世界（rootfs） |
|---|---|---|
| 文件系统 | 镜像（只读根） | `/home/container/rootfs`（平台维护） |
| 工具 | **全量**（本镜像烧入） | 平台安装的最小集，重建会重置 |
| 进入方式 | 面板控制台 / dropbear 公钥 SSH / `sandbox-proot` 命令反着进 | 平台 altare-sshd 的 SSH（面板凭据） |
| 持久性 | 只有 `/home/container` 可写 | rootfs 整个目录持久，但**容器重建时被重置** |

tunxx 等装在 proot 世界里的东西，容器重建（换镜像/换启动命令触发重装）时会丢——建议把常用服务迁到容器层（配置放 `/home/container` 持久）。

## 面板里怎么填

**Docker 镜像**：
```
ghcr.io/nxcoom/debian-sandbox:v3
```
> ⚠️ Wings 只在本地没有镜像时才 pull，宿主机会缓存 `:latest`。**更新版本时换新版本 tag（v3、v4…）强制拉取**。

**启动命令**：`sandbox-init`（守护模式，推荐）

## SSH 三种姿势

| 姿势 | 进入方式 | 环境 |
|---|---|---|
| **1. 面板控制台**（最简单） | 守护模式下面板控制台就是容器层 shell，直接敲命令 | 容器层 |
| **2. dropbear 公钥 SSH**（推荐） | 控制台里放公钥后：`ssh container@<host> -p $SERVER_PORT` | 容器层 |
| **3. 平台 SSH**（兼容回退） | `ssh root@<host> -p 31565` + 面板密码 | proot 世界 |

**启用 dropbear**（容器层直达，所有工具 + supervisorctl 可用）：

```bash
# 在面板控制台（容器层 shell）里执行：
mkdir -p ~/.ssh && echo 'ssh-ed25519 AAAA...你的公钥' >> ~/.ssh/authorized_keys
```

然后本机连接（注意用户是 `container`，平台非 root 限制；host key 换了会有提示，清一下即可）：

```bash
ssh-keygen -R "[sg-sgp11.tryaltare.ai]:31565"   # 清旧 host key
ssh container@sg-sgp11.tryaltare.ai -p 31565 -i ~/.ssh/id_ed25519
```

- 有 `~/.ssh/authorized_keys` 时自动用 dropbear；没有时自动回退平台 altare-sshd
- dropbear host key 持久化在 `/home/container/sandbox/hostkeys/`，重启不变
- 容器层里执行 `sandbox-proot` 可随时进入旧 proot 世界（tunxx 等）

## init 工作方式

```
PID1  tini -g ── sandbox-init
                 ├─ prestart 钩子（/etc/sandbox/prestart.d/ + /home/container/sandbox/prestart.d/）
                 ├─ 守护模式: 选 SSH 通道（dropbear/altare-sshd）+ 接管控制台为容器层 shell
                 ├─ 生成 keepalive / ssh 服务配置 → /home/container/sandbox/supervisor.d/
                 ├─ supervisord（nodaemon，带看门狗）
                 └─ 有 STARTUP → 前台执行启动命令；无 → 常驻守护
```

## 防冻结保活（内置）

| 活跃信号 | 实现 | 默认占用 |
|---|---|---|
| CPU | 每轮短促计算突发（纯 bash 忙询，无 fork） | ~500ms/60s，平均 **<1%** |
| 网络 | HTTPS 心跳（`cdn-cgi/trace` / `generate_204`，端点轮换） | KB 级/分钟 |
| 终端 | 周期性向容器控制台输出一行 + touch 心跳文件 | 每 5 分钟一行 |

```bash
supervisorctl status           # keepalive / sshd 应为 RUNNING
supervisorctl tail keepalive
```

心跳文件：`/home/container/sandbox/.keepalive`（mtime 即最近一轮心跳时间）。

## 内置工具清单（容器层）

- **网络诊断**：ip(iproute2) / ss / net-tools / ping / traceroute / mtr / dig+nslookup / nc / socat / tcpdump / nmap / iperf3 / lsof / ethtool / whois / iftop
- **下载/传输**：curl / wget / aria2 / rsync / openssl
- **代理隧道**：cloudflared（最新版）/ iptables / wireguard-tools / proxychains4
- **SSH 服务端**：dropbear（容器层公钥 SSH）/ openssh-client / openssh-server
- **开发常用**：git / python3 + pip / jq / vim / nano / less / tree / file / unzip / zip / xz
- **系统**：tini / supervisord / cron / sudo / strace / htop / procps / speedtest-cli

## 加服务（supervisor）

```bash
# 容器层 shell（面板控制台或 dropbear SSH）里：
vi /home/container/sandbox/services/myapp.conf
# 然后在面板重启容器生效
```

示例见 [examples/services/](examples/services/)（含 cloudflared 隧道示例）。

## 目录约定（持久卷 `/home/container`）

```
/home/container/
├── sandbox/
│   ├── services/       supervisord 用户服务配置 (*.conf)
│   ├── supervisor.d/   镜像运行时生成的服务配置（keepalive / sshd）
│   ├── prestart.d/     每次启动前执行的钩子 (*.sh)
│   ├── logs/           supervisord 与服务日志
│   ├── hostkeys/       dropbear host keys
│   ├── supervisor.sock / supervisor.pid
│   └── .keepalive      保活心跳文件（看 mtime）
├── .ssh/authorized_keys   dropbear 公钥（你放）
└── rootfs/                平台 proot 世界（sandbox-proot 进入；重建会被重置）
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `SANDBOX_SSH` | `auto` | `auto`（有公钥→dropbear，否则→altare）/ `dropbear` / `altare` / `none` |
| `SANDBOX_CONSOLE_SHELL` | `1` | 面板控制台接管为容器层 shell |
| `SANDBOX_KEEPALIVE` | `1` | 保活脚本开关 |
| `KEEPALIVE_INTERVAL` | `60` | 保活循环间隔（秒），仍被冻结就调小 |
| `KEEPALIVE_CPU_MS` | `500` | 每轮 CPU 突发毫秒数 |
| `KEEPALIVE_NET` | `1` | 网络心跳开关 |
| `KEEPALIVE_CONSOLE` | `1` | 控制台心跳开关 |
| `KEEPALIVE_EVERY` | `5` | 每 N 轮打印一行控制台输出 |
| `SERVER_PORT` | `22` | SSH 监听端口（面板自动注入） |
| `TZ` | 面板注入（UTC） | 想用东八区就在面板加 `TZ=Asia/Shanghai` |

## 构建

- 推送到 `main` 自动构建并推送 GHCR（bookworm + trixie 两个变体 + 版本 tag）
- 更新版本时记得**加新版本 tag**（见上方 Wings 缓存说明）
- 本地：`docker build --build-arg BASE_IMAGE=debian:bookworm-slim -t debian-sandbox .`
