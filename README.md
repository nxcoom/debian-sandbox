# debian-sandbox

面向 **Pterodactyl / Pelican (Wings) 类游戏面板沙箱容器**的自定义 Debian 底座镜像。

- **init 管理**：`tini -g` 作 PID1 + `supervisord` 管理常驻服务（`supervisorctl` 可查可控）
- **常用网络工具全家桶烧进镜像**：容器重启不丢（面板容器只有 `/home/container` 是持久卷，容器本身每次重启还原，所以工具必须打进镜像）
- **兼容面板机制**：识别 Wings 注入的 `STARTUP` 环境变量（支持 `{{VAR}}` 替换），面板自带启动脚本可无缝继续用
- **内置真实 root sshd**：不走 proot，直接 SSH 进容器本体
- GitHub Actions 自动构建并推送 GHCR

## 镜像地址

| Tag | 内容 |
|---|---|
| `ghcr.io/nxcoom/debian-sandbox:latest` | Debian 12 bookworm-slim（推荐） |
| `ghcr.io/nxcoom/debian-sandbox:bookworm` | 同 latest |
| `ghcr.io/nxcoom/debian-sandbox:trixie` | Debian 13 trixie-slim |

> ⚠️ GHCR 包首次发布默认是**私有**的，需要到 GitHub → Packages → `debian-sandbox` → Package settings → Danger Zone → Change visibility → **Public**，面板才能匿名拉取。

## 面板里怎么填

**Docker 镜像**：
```
ghcr.io/nxcoom/debian-sandbox:latest
```

**启动命令**（二选一）：

1. `sandbox-init` —— **完全接管（推荐）**
   真实 root 环境 + supervisord 服务管理 + 内置 sshd，不再经过 proot。
2. `./.sandbox/start.sh` —— **兼容模式**
   保留平台原有 proot 沙箱栈（数据不受影响），仅把底座镜像换成定制版。

## root 登录（完全接管模式）

| 方式 | 说明 |
|---|---|
| 密码 | 首次启动**控制台会打印随机 root 密码**，并持久保存到 `/home/container/sandbox/.rootpass`；编辑该文件后重启容器生效 |
| 公钥 | 把公钥追加到 `/home/container/sandbox/authorized_keys`（一行一个） |
| 端口 | 面板分配的 `SERVER_PORT`（即你平时 SSH 用的那个端口） |

SSH host key 持久化在 `/home/container/sandbox/hostkeys/`，重启不会变，客户端不会报 host key 变更警告。

## 内置工具清单

- **网络诊断**：ip(iproute2) / ss / net-tools / ping / traceroute / mtr / dig+nslookup / nc / socat / tcpdump / nmap / iperf3 / lsof / ethtool / whois / iftop
- **下载/传输**：curl / wget / aria2 / rsync / openssl
- **代理隧道**：cloudflared（最新版）/ iptables / wireguard-tools / proxychains4
- **开发常用**：git / python3 + pip / jq / vim / nano / less / tree / file / unzip / zip / xz
- **系统**：tini / supervisord / cron / sudo / strace / htop / procps / speedtest-cli / openssh-client + openssh-server

## init 工作方式

```
PID1  tini -g ── sandbox-init
                 ├─ 预处理：host key / root 密码 / authorized_keys
                 ├─ 执行 /etc/sandbox/prestart.d/*.sh 和 /home/container/sandbox/prestart.d/*.sh
                 ├─ 启动 supervisord（内置 sshd + 用户服务）
                 └─ 有 STARTUP → 前台执行启动命令；无 → 守护模式常驻
```

- 有 `STARTUP`（面板启动命令）：当作主进程前台运行，退出码透传给面板，`docker stop` 会先优雅关闭 supervisord
- `STARTUP` 为空或等于 `sandbox-init`：守护模式，常驻运行

## 加服务（supervisor）

```bash
mkdir -p /home/container/sandbox/services
cp examples/services/user-app.conf.example /home/container/sandbox/services/myapp.conf
# 编辑后：
supervisorctl reread && supervisorctl update
supervisorctl status
```

示例见 [examples/services/](examples/services/)（含 cloudflared 隧道示例）。

## 目录约定（持久卷 `/home/container`）

```
/home/container/sandbox/
├── services/         supervisord 用户服务配置 (*.conf)
├── prestart.d/       每次启动前执行的钩子 (*.sh)
├── logs/             自定义服务日志
├── hostkeys/         SSH host keys
├── authorized_keys   root 公钥（可选）
└── .rootpass         root 密码（600，root 可读）
```

## 防冻结保活（内置）

免费面板会冻结"不活跃"的容器，镜像内置 `keepalive` 服务（supervisor 托管，两种启动模式都会跑，重启自动拉起）：

| 活跃信号 | 实现 | 默认占用 |
|---|---|---|
| CPU | 每轮短促计算突发（纯 bash 忙询，无 fork） | ~500ms/60s，平均 **<1%** |
| 网络 | HTTPS 心跳（`cdn-cgi/trace` / `generate_204`，端点轮换） | KB 级/分钟 |
| 终端 | 周期性向容器控制台输出一行 + touch 心跳文件 | 每 5 分钟一行 |

```bash
supervisorctl tail keepalive     # 看保活日志
supervisorctl status             # keepalive 应为 RUNNING
```

**调节**（面板环境变量，或改完 `supervisorctl restart keepalive`）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `SANDBOX_KEEPALIVE` | `1` | `0` 关闭保活 |
| `KEEPALIVE_INTERVAL` | `60` | 循环间隔（秒），被冻结就调小 |
| `KEEPALIVE_CPU_MS` | `500` | 每轮 CPU 突发毫秒数，调大 = 平均 CPU 更高 |
| `KEEPALIVE_NET` | `1` | 网络心跳开关 |
| `KEEPALIVE_CONSOLE` | `1` | 控制台心跳开关 |
| `KEEPALIVE_EVERY` | `5` | 每 N 轮打印一行控制台输出 |

心跳文件：`/home/container/sandbox/.keepalive`（mtime 即最近一轮心跳时间）。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `SANDBOX_SSHD` | `auto` | 内置 sshd 开关：`always` / `never` / `auto`（auto=守护模式开、脚本模式关，避免和面板自带 sshd 抢端口） |
| `SANDBOX_KEEPALIVE` | `1` | 保活脚本开关（见上节） |
| `SERVER_PORT` | `22` | sshd 监听端口（面板自动注入） |
| `TZ` | `Asia/Shanghai` | 时区 |

## 构建

- 推送到 `main` 自动构建并推送 GHCR（bookworm + trixie 两个变体）
- 手动触发：Actions → build → Run workflow
- 本地：`docker build --build-arg BASE_IMAGE=debian:bookworm-slim -t debian-sandbox .`

## 注意

- 容器内 `apt install` **不持久**（重启还原）：临时软件放 `prestart.d`，常驻工具直接改本仓库 `Dockerfile` 重新构建
- 只有 `/home/container` 是持久卷，重要数据放这里
