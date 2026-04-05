#!/bin/sh
set -e

# ==========================================
# MicroWARP 入口脚本 (池化版)
# 支持 POOL_SIZE 个独立 WARP 隧道，连接级隔离
# ==========================================

. /app/lib.sh

POOL_SIZE=${POOL_SIZE:-1}
LISTEN_ADDR=${BIND_ADDR:-"0.0.0.0"}
LISTEN_PORT=${BIND_PORT:-"1080"}
WG_DIR="/etc/wireguard"
POOL_DIR="${WG_DIR}/pool"

if [ "${MICROWARP_TEST_MODE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# ==========================================
# 单实例模式 (POOL_SIZE=1, 向后兼容)
# ==========================================
start_single_mode() {
    echo "==> [MicroWARP] 单实例模式"

    local WG_CONF="${WG_DIR}/wg0.conf"
    mkdir -p "$WG_DIR"

    if [ ! -f "$WG_CONF" ]; then
        local tmpdir
        tmpdir=$(mktemp -d)
        register_warp_account "$tmpdir"
        mv "$tmpdir/wgcf-profile.conf" "$WG_CONF"
        rm -rf "$tmpdir"
        echo "==> [MicroWARP] 节点配置生成成功！"
    else
        echo "==> [MicroWARP] 检测到已有持久化配置，跳过注册。"
    fi

    sanitize_wg_conf "$WG_CONF"

    # 删除 wg-quick 中不兼容的路由标记
    sed -i '/src_valid_mark/d' /usr/bin/wg-quick 2>/dev/null || true

    # 记录 Tailscale 回程路由
    local pre_warp_route pre_warp_gw pre_warp_dev
    pre_warp_route=$(ip route get 100.64.0.1 2>/dev/null | head -n 1 || true)
    pre_warp_gw=$(printf '%s\n' "$pre_warp_route" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')
    pre_warp_dev=$(printf '%s\n' "$pre_warp_route" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')

    echo "==> [MicroWARP] 正在启动 wg0..."
    wg-quick up wg0 > /dev/null 2>&1

    # 恢复 Tailscale 回程路由
    local ts_cidr="${TAILSCALE_CIDR:-100.64.0.0/10}"
    if [ -n "$pre_warp_gw" ] && [ -n "$pre_warp_dev" ]; then
        if ip route replace "$ts_cidr" via "$pre_warp_gw" dev "$pre_warp_dev" > /dev/null 2>&1; then
            echo "==> [MicroWARP] 已恢复 ${ts_cidr} 回程路由"
        fi
    fi

    local exit_ip
    exit_ip=$(get_exit_ip)
    echo "==> [MicroWARP] 当前出口 IP: ${exit_ip:-unknown}"

    # 启动 microsocks
    local socks_args="-i $LISTEN_ADDR -p $LISTEN_PORT"
    if [ -n "${SOCKS_USER:-}" ] && [ -n "${SOCKS_PASS:-}" ]; then
        echo "==> [MicroWARP] 身份认证已开启 (User: $SOCKS_USER)"
        socks_args="$socks_args -u $SOCKS_USER -P $SOCKS_PASS"
    else
        echo "==> [MicroWARP] ⚠️ 未设置密码，当前为公开访问模式"
    fi

    echo "==> [MicroWARP] MicroSOCKS 启动，监听 ${LISTEN_ADDR}:${LISTEN_PORT}"
    microsocks $socks_args &
    MAIN_PIDS="$!"
}

# ==========================================
# 池化模式 (POOL_SIZE > 1)
# ==========================================

init_pool_member() {
    local id="$1"
    local ns="warp${id}"
    local veth="veth${id}"
    local veth_ns="veth${id}_ns"
    local main_ip="10.200.${id}.1"
    local ns_ip="10.200.${id}.2"
    local conf_dir="${POOL_DIR}/${id}"

    echo "==> [MicroWARP] 初始化池成员 #${id}..."
    mkdir -p "$conf_dir"

    # 清理残留的 netns 和 veth (容器重启后可能存在)
    ip netns delete "$ns" 2>/dev/null || true
    ip link delete "$veth" 2>/dev/null || true

    # 创建网络命名空间 + veth pair
    ip netns add "$ns"
    ip link add "$veth" type veth peer name "$veth_ns"
    ip link set "$veth_ns" netns "$ns"

    # 配置主命名空间端
    ip addr add "${main_ip}/24" dev "$veth"
    ip link set "$veth" up

    # 配置 netns 端
    ip netns exec "$ns" ip link set lo up
    ip netns exec "$ns" ip addr add "${ns_ip}/24" dev "$veth_ns"
    ip netns exec "$ns" ip link set "$veth_ns" up
    ip netns exec "$ns" ip route add default via "$main_ip"

    # 启用转发
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true

    # 注册 WARP 账号 (在主命名空间注册，因为 netns 此时无外网)
    if [ ! -f "${conf_dir}/wg0.conf" ]; then
        local tmpdir
        tmpdir=$(mktemp -d)
        register_warp_account "$tmpdir"
        mv "$tmpdir/wgcf-profile.conf" "${conf_dir}/wg0.conf"
        rm -rf "$tmpdir"
    else
        echo "==> [MicroWARP] 池成员 #${id} 已有配置，跳过注册"
    fi

    if ! sanitize_wg_conf "${conf_dir}/wg0.conf"; then
        echo "==> [MicroWARP] ❌ 池成员 #${id} 配置清洗失败" >&2
        return 1
    fi

    # 删除 wg-quick 不兼容标记
    sed -i '/src_valid_mark/d' /usr/bin/wg-quick 2>/dev/null || true

    # 在 netns 中启动 WireGuard
    ip netns exec "$ns" wg-quick up "${conf_dir}/wg0.conf" > /dev/null 2>&1

    # 添加 Docker 子网回程路由 (DNAT 回程需要走 veth 而非 wg0)
    local docker_subnet
    docker_subnet=$(ip route show dev eth0 proto kernel | head -1 | cut -d' ' -f1)
    if [ -n "$docker_subnet" ]; then
        ip netns exec "$ns" ip route add "$docker_subnet" via "$main_ip" dev "$veth_ns" 2>/dev/null || true
    fi

    # 在 netns 中启动 microsocks
    local socks_args="-i 0.0.0.0 -p 1080"
    if [ -n "${SOCKS_USER:-}" ] && [ -n "${SOCKS_PASS:-}" ]; then
        socks_args="$socks_args -u $SOCKS_USER -P $SOCKS_PASS"
    fi
    ip netns exec "$ns" microsocks $socks_args &
    echo "$!" >> /tmp/microsocks_pids

    local exit_ip
    exit_ip=$(get_exit_ip "$ns")
    echo "==> [MicroWARP] 池成员 #${id} 出口 IP: ${exit_ip:-unknown}"
}

setup_iptables_loadbalance() {
    local pool_size="$1"
    local port="$2"
    local i=0

    # 清理旧规则
    iptables -t nat -F MICROWARP_POOL 2>/dev/null || true
    iptables -t nat -D PREROUTING -p tcp --dport "$port" -j MICROWARP_POOL 2>/dev/null || true
    iptables -t nat -X MICROWARP_POOL 2>/dev/null || true

    # 创建自定义链
    iptables -t nat -N MICROWARP_POOL
    iptables -t nat -A PREROUTING -p tcp --dport "$port" -j MICROWARP_POOL

    while [ $i -lt "$pool_size" ]; do
        local remaining=$((pool_size - i))
        local target_ip="10.200.${i}.2"

        if [ $remaining -eq 1 ]; then
            iptables -t nat -A MICROWARP_POOL -p tcp -j DNAT --to-destination "${target_ip}:1080"
        else
            iptables -t nat -A MICROWARP_POOL -p tcp \
                -m statistic --mode nth --every "$remaining" --packet 0 \
                -j DNAT --to-destination "${target_ip}:1080"
        fi
        i=$((i + 1))
    done

    # FORWARD 规则: 允许 veth ↔ eth0 转发 (nf_tables 后端需要显式规则)
    iptables -A FORWARD -i veth+ -o eth0 -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i eth0 -o veth+ -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

    # MASQUERADE: netns 出站流量 (WireGuard endpoint UDP)
    iptables -t nat -A POSTROUTING -s 10.200.0.0/16 -j MASQUERADE

    echo "==> [MicroWARP] iptables 轮询负载均衡已配置 (${pool_size} 个成员)"
}

start_pool_mode() {
    echo "==> [MicroWARP] 池化模式 (POOL_SIZE=${POOL_SIZE})"

    mkdir -p "$POOL_DIR"
    rm -f /tmp/microsocks_pids

    local i=0
    while [ $i -lt "$POOL_SIZE" ]; do
        init_pool_member "$i"
        i=$((i + 1))
        # 注册间延迟，防 CF 速率限制
        if [ $i -lt "$POOL_SIZE" ]; then
            sleep 2
        fi
    done

    setup_iptables_loadbalance "$POOL_SIZE" "$LISTEN_PORT"

    echo "==> [MicroWARP] 池化 SOCKS5 代理已启动，监听 :${LISTEN_PORT}"
}

# ==========================================
# 信号处理
# ==========================================

handle_sigusr1() {
    local random_id
    if [ "$POOL_SIZE" -le 1 ]; then
        random_id=0
    else
        random_id=$(shuf -i 0-$((POOL_SIZE - 1)) -n 1)
    fi
    echo "==> [MicroWARP] 轮换池成员 #${random_id}..."
    /app/rotate.sh "$random_id" || true
}

handle_exit() {
    echo "==> [MicroWARP] 正在清理..."

    # 停止 microsocks
    if [ -f /tmp/microsocks_pids ]; then
        while IFS= read -r pid; do
            kill "$pid" 2>/dev/null || true
        done < /tmp/microsocks_pids
    fi
    [ -n "${MAIN_PIDS:-}" ] && kill $MAIN_PIDS 2>/dev/null || true
    [ -n "${HTTPD_PID:-}" ] && kill "$HTTPD_PID" 2>/dev/null || true

    # 停止 WireGuard
    if [ "$POOL_SIZE" -le 1 ]; then
        wg-quick down wg0 2>/dev/null || true
    else
        local i=0
        while [ $i -lt "$POOL_SIZE" ]; do
            ip netns exec "warp${i}" wg-quick down "${POOL_DIR}/${i}/wg0.conf" 2>/dev/null || true
            ip netns delete "warp${i}" 2>/dev/null || true
            i=$((i + 1))
        done
    fi

    echo "==> [MicroWARP] 已停止"
    exit 0
}

# ==========================================
# 主流程
# ==========================================

# 导出变量供 rotate.sh 和 CGI 使用
export POOL_SIZE POOL_DIR LISTEN_PORT
export ENDPOINT_IP WARP_LICENSE WARP_KEY_API
export SOCKS_USER SOCKS_PASS TAILSCALE_CIDR

if [ "$POOL_SIZE" -le 1 ]; then
    start_single_mode
else
    start_pool_mode
fi

# 启动管理 API
if [ -n "${API_PORT:-}" ]; then
    echo "==> [MicroWARP] 管理 API 启动，监听 :${API_PORT}"
    httpd -f -p "0.0.0.0:${API_PORT}" -h /app -c /app/httpd.conf &
    HTTPD_PID=$!
fi

# 注册信号
trap handle_sigusr1 USR1
trap handle_exit TERM INT

echo "==> [MicroWARP] 初始化完成"
set +e
while true; do
    # 等待任意子进程退出
    wait -n 2>/dev/null || wait
    # 检测关键进程是否存活
    if [ "$POOL_SIZE" -le 1 ]; then
        if [ -n "${MAIN_PIDS:-}" ] && ! kill -0 "$MAIN_PIDS" 2>/dev/null; then
            echo "==> [MicroWARP] microsocks 进程异常退出，容器终止"
            handle_exit
        fi
    else
        # 池化模式: 检测是否还有存活的 microsocks
        if [ -f /tmp/microsocks_pids ]; then
            alive=0
            while IFS= read -r pid; do
                kill -0 "$pid" 2>/dev/null && alive=$((alive + 1))
            done < /tmp/microsocks_pids
            if [ "$alive" -eq 0 ]; then
                echo "==> [MicroWARP] 所有 microsocks 进程已退出，容器终止"
                handle_exit
            fi
        fi
    fi
done
