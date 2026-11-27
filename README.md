# debian-sandbox

面向 **Pterodactyl / Pelican (Wings) / Altare 类面板沙箱容器**的自定义 Debian 底座镜像。

**适配平台实测约束**（tryaltare 验证）：

- 容器根文件系统**只读**，唯一可写卷 = `/home/container`
- 容器以非 root 运行；PID1 的 stdin 是面板控制台 tty
- 平台 SSH（altare-sshd）落在 proot rootfs（`/home/container/rootfs`，平台安装脚本维护，容器重建会重置）
- supervisor / SSH / 保活的全部状态放在 `/home/container/sandbox/` 下（可写、持久）

## 特性（v9）

- **init 管理**：`tini -g` 作 PID1 + `supervisord`（看门狗自动重启）
- **双 SSH 共存**（核心）：
  - **主端口（SERVER_PORT，如 25412）** → 平台 altare-sshd → **proot 世界**，用面板密码登录（保持原样）
  - **第二端口（SANDBOX_DROPBEAR_PORT，默认 25270）** → dropbear → **容器层**，公钥登录，全部镜像工具可用
  - 两者互不冲突，不再需要牺牲密码登录
- **低占用保活**：CPU 突发 + 网络心跳 + 控制台心跳，防面板冻结空闲容器（平均 CPU <1%）
- **常用网络工具烧进镜像**：ping/dig/nmap/tcpdump/socat/nc/iperf3/mtr/git/python3/cloudflared 等
- **兼容面板 STARTUP** 变量（`{{VAR}}` 替换）
- GitHub Actions 自动构建并推送 GHCR

## 镜像 tag

| Tag | 内容 |
|---|---|
| `ghcr.io/nxcoom/debian-sandbox:v9` | 当前版（Debian 12，推荐） |
| `ghcr.io/nxcoom/debian-sandbox:latest` | 同 v9 |
| `ghcr.io/nxcoom/debian-sandbox:v9-trixie` | Debian 13 |

> ⚠️ 面板宿主机会缓存镜像，改版时**换新版本 tag** 强制拉取。

## 面板里怎么填

- Docker 镜像：`ghcr.io/nxcoom/debian-sandbox:v9`
- 启动命令：`sandbox-init`

## SSH 用法（v9 双端口）

### 1) 容器层 SSH（推荐，全部工具）

先放公钥到 `/home/container/.ssh/authorized_keys`（用面板文件管理或 Altare API）：

```
ssh-ed25519 AAAA...你的公钥
```

重启容器后，第二端口 dropbear 自动启用：

```bash
ssh -p 25270 container@<host> -i ~/.ssh/你的私钥
```

登录进去是青色 `[sandbox] /home/container $` 提示符，`ping`/`dig`/`supervisorctl status`/`cloudflared --version` 全部可用。

### 2) 平台 SSH（proot，面板密码）

```bash
ssh -p 25412 root@<host>   # 密码 = 面板给你的
```

落在 `root@UUID:~#`，是平台 rootfs 世界（tunxx 原来的家），**看不到镜像工具**——这是平台设计，不是镜像缺工具。

### 3) Altare API 直接读写文件

有 `servers:files` 权限的 API token 可直接读写 `/home/container` 下文件，不依赖 SSH/控制台。

## v9 关于控制台 REPL

v4-v7 的控制台 REPL 因把读 stdin 的循环放进后台子 shell（`&` 会让 bash 把 stdin 接到 `/dev/null`）导致 `read` 读到 EOF 空转、每 5 秒打印一个空提示符——**网页控制台刷屏**。

- v8 改为前台 REPL（不再刷屏）
- **v9 默认关闭控制台 REPL**（`SANDBOX_CONSOLE_SHELL=0`）：网页控制台只显示启动日志，不再刷屏；容器层操作走 25270 SSH 或 API
- 需要控制台 REPL 时，面板加环境变量 `SANDBOX_CONSOLE_SHELL=1`（前台 read，不会刷屏）

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `SANDBOX_DROPBEAR` | `1` | 第二端口 dropbear 开关 |
| `SANDBOX_DROPBEAR_PORT` | `25270` | dropbear 监听端口（填面板第二 allocation 的端口） |
| `SANDBOX_ALTARE_SSHD` | `1` | 主端口平台 altare-sshd 开关 |
| `SANDBOX_CONSOLE_SHELL` | `0` | 控制台 REPL（默认关，防刷屏） |
| `SANDBOX_KEEPALIVE` | `1` | 保活开关 |
| `KEEPALIVE_INTERVAL` | `60` | 保活循环间隔（秒） |
| `KEEPALIVE_CPU_MS` | `500` | 每轮 CPU 突发毫秒数 |
| `KEEPALIVE_NET` | `1` | 网络心跳开关 |
| `KEEPALIVE_CONSOLE` | `1` | 控制台心跳开关 |
| `KEEPALIVE_EVERY` | `5` | 每 N 轮打印一行心跳 |
| `SERVER_PORT` | 面板注入 | 主端口（altare-sshd 用） |

## 内置工具清单（容器层）

- **网络诊断**：ip / ss / net-tools / ping / traceroute / mtr / dig / nc / socat / tcpdump / nmap / iperf3 / lsof / ethtool / whois / iftop
- **下载/传输**：curl / wget / aria2 / rsync / openssl
- **代理隧道**：cloudflared / iptables / wireguard-tools / proxychains4
- **SSH**：dropbear（容器层公钥）/ openssh-client / openssh-server
- **开发**：git / python3 + pip / jq / vim / nano / less / tree / unzip / zip / xz
- **系统**：tini / supervisord / cron / sudo / strace / htop / procps / speedtest-cli

## 加服务（supervisor）

```bash
# 容器层（25270 SSH）里：
vi /home/container/sandbox/services/myapp.conf
# 重启容器生效
```

示例见 [examples/services/](examples/services/)。

## 目录约定（持久卷 `/home/container`）

```
/home/container/
├── sandbox/
│   ├── services/       用户服务配置 (*.conf)
│   ├── supervisor.d/   运行时生成（keepalive / dropbear）
│   ├── prestart.d/     启动前钩子 (*.sh)
│   ├── logs/           服务日志
│   ├── hostkeys/       dropbear host keys（重启不变）
│   └── .keepalive      保活心跳文件
├── .ssh/authorized_keys  容器层 SSH 公钥
└── rootfs/             平台 proot 世界（sandbox-proot 进入；重建会重置）
```

## 构建

- 推送 `main` 自动构建 GHCR（bookworm + trixie + 版本 tag）
- 本地：`docker build --build-arg BASE_IMAGE=debian:bookworm-slim -t debian-sandbox .`
