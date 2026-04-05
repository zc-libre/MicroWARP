# MicroWARP IP 轮换功能设计

## 概述

为 MicroWARP 添加 IP 池化 + 轮换功能。通过 Linux Network Namespace 实现连接级隔离，每个连接独享一个 WARP 隧道，轮换某个隧道不影响其他连接。支持信号触发和 HTTP API 触发。集成 WARP+ 自动获取。

## 架构

```
Client → :1080 → iptables round-robin (statistic --mode nth)
                    ├→ [netns warp0] veth0 ↔ wg0 + microsocks → IP_A
                    ├→ [netns warp1] veth1 ↔ wg1 + microsocks → IP_B
                    ├→ ...
                    └→ [netns warpN] vethN ↔ wgN + microsocks → IP_N

PID 1: tini → entrypoint.sh (shell, 信号处理)
  ├─ microsocks × N (各 netns 内)
  ├─ busybox httpd (管理 API, 可选)
  └─ wg0..wgN (各 netns 内)
```

### 网络拓扑（单个池成员）

```
主命名空间                    netns warp$i
┌──────────┐  veth pair  ┌──────────────────┐
│ veth$i   │◄───────────►│ veth${i}_ns      │
│10.200.i.1│             │ 10.200.i.2       │
└──────────┘             │                  │
                         │ wg$i (WireGuard) │
                         │ microsocks :1080 │
                         └──────────────────┘
```

iptables DNAT 将 :1080 的新连接轮询分发到各 netns 的 veth IP。

## 触发方式

### 1. 信号触发

```bash
docker kill -s SIGUSR1 microwarp          # 轮换随机一个池成员
```

### 2. HTTP API 触发

```bash
curl http://localhost:9090/cgi-bin/rotate          # 轮换随机一个
curl http://localhost:9090/cgi-bin/rotate?id=0     # 轮换指定成员
curl http://localhost:9090/cgi-bin/ip              # 查询所有池成员的出口 IP
```

API 默认不启用，需设置 `API_PORT` 环境变量。

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `POOL_SIZE` | `1` | IP 池大小，`1` 时退化为单实例模式（向后兼容） |
| `API_PORT` | (空，不启用) | 管理 API 监听端口 |
| `WARP_LICENSE` | (空) | 手动指定 WARP+ License Key，最高优先级 |
| `WARP_KEY_API` | (空) | 自动获取 WARP+ Key 的 API 地址 |
| `ENDPOINT_IP` | (空) | 固定 Cloudflare Endpoint，设置后不自动轮换 Endpoint |
| `BIND_ADDR` | `0.0.0.0` | SOCKS5 监听地址 |
| `BIND_PORT` | `1080` | SOCKS5 监听端口 |
| `SOCKS_USER` | (空) | SOCKS5 认证用户名 |
| `SOCKS_PASS` | (空) | SOCKS5 认证密码 |
| `GH_PROXY` | (空) | GitHub 代理前缀 |
| `TAILSCALE_CIDR` | `100.64.0.0/10` | Tailscale 回程路由 CIDR |

## WARP+ Key 获取优先级

1. `WARP_LICENSE` 手动设置 → 直接使用
2. `WARP_KEY_API` 设置 → 从 API 拉取 key 列表，随机取一个尝试 `wgcf update --license <key>`，失败换下一个，最多 5 次
3. 都不设置 → 免费 WARP

全部失败则回退免费 WARP 并打印警告。

## 进程模型

- `tini` 作为 PID 1（解决僵尸进程回收）
- entrypoint.sh 由 tini 启动，负责初始化和信号处理
- microsocks × N 在各 netns 中后台运行
- `trap SIGUSR1` 触发随机池成员轮换
- `trap SIGTERM SIGINT` 清理所有子进程并退出
- `while wait` 循环保持 shell 存活

## 文件清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `entrypoint.sh` | 修改 | 池化初始化、netns/veth 创建、信号处理、httpd 启动 |
| `rotate.sh` | 新增 | 核心轮换逻辑（加锁、从 DNAT 摘除、重注册、WARP+ key、清洗配置、重启 wg、恢复 DNAT） |
| `cgi-bin/rotate` | 新增 | CGI 脚本，调用 rotate.sh，返回 JSON |
| `cgi-bin/ip` | 新增 | CGI 脚本，返回所有池成员出口 IP |
| `httpd.conf` | 新增 | busybox httpd 配置 |
| `Dockerfile` | 修改 | 安装 util-linux/tini，构建阶段固化 wgcf |
| `docker-compose.yml` | 修改 | 添加 SYS_ADMIN cap、新环境变量、API 端口 |

## 启动流程

```
1. 对 i in 0..POOL_SIZE-1:
   a. ip netns add warp$i
   b. 创建 veth pair (veth$i ↔ veth${i}_ns)
   c. 分配 IP: 主空间 10.200.$i.1/24, netns 10.200.$i.2/24
   d. 在 netns 内: wgcf register → apply WARP+ key → wgcf generate
   e. 清洗配置 (sanitize_wg_conf)
   f. wg-quick up wg$i.conf
   g. 启动 microsocks (带可选认证)
   h. 注册间加 2 秒延迟 (防 CF 速率限制)

2. 配置 iptables DNAT round-robin:
   对 i in 0..POOL_SIZE-1:
     iptables -t nat -A PREROUTING -p tcp --dport $BIND_PORT \
       -m statistic --mode nth --every $(POOL_SIZE-i) --packet 0 \
       -j DNAT --to 10.200.$i.2:1080

3. 如设置 API_PORT, 启动 busybox httpd

4. 进入 wait 循环, 处理信号
```

## 轮换流程（rotate.sh $pool_id）

```
1. 验证 pool_id 为合法数字 (0 ~ POOL_SIZE-1)
2. flock /tmp/rotate.$pool_id.lock (防并发)
3. 从 iptables DNAT 规则中摘除该成员 (避免新连接分发到 down 的隧道)
4. ip netns exec warp$i wg-quick down wg$i
5. 在 netns 内重新注册:
   a. rm wgcf-account.toml
   b. wgcf register --accept-tos
   c. apply_warp_key (按优先级逻辑)
   d. wgcf generate
6. 清洗配置 (sanitize_wg_conf)
7. 选择 Endpoint (用户指定 or 随机从池中选)
8. ip netns exec warp$i wg-quick up wg$i
9. 恢复 iptables DNAT 规则
10. 输出新出口 IP
```

## 内置 Cloudflare Endpoint 池

```
162.159.192.1:2408
162.159.192.1:4500
188.114.96.1:2408
188.114.96.1:4500
188.114.97.1:2408
188.114.97.1:4500
188.114.98.1:2408
188.114.98.1:4500
188.114.99.1:2408
188.114.99.1:4500
```

用户设置 `ENDPOINT_IP` 时始终使用指定值。

## 权限要求

```yaml
cap_add:
  - NET_ADMIN    # WireGuard、iptables、veth
  - SYS_MODULE   # 内核模块加载
  - SYS_ADMIN    # ip netns add (mount namespace 操作)
```

## 约束与注意事项

- `POOL_SIZE=1` 时完全向后兼容，不创建 netns，行为与原版一致
- 轮换期间该池成员从 DNAT 摘除，新连接不会分发到 down 的隧道
- 已建立的连接在 wg-quick down 时会断开（仅影响该池成员）
- Cloudflare 注册速率限制 ~15-30 分钟冷却期，启动时池成员间加 2 秒延迟
- flock 文件锁防止同一池成员并发轮换
- CGI pool_id 参数严格验证为数字，防注入
- httpd 建议仅映射到 127.0.0.1，防外部滥用触发轮换
