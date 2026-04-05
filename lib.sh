#!/bin/sh
# ==========================================
# MicroWARP 公共函数库
# 被 entrypoint.sh 和 rotate.sh 共用
# ==========================================

# Cloudflare Endpoint 池
ENDPOINTS="
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
"

# 选择 Endpoint: 用户指定 > 随机
random_endpoint() {
    if [ -n "${ENDPOINT_IP:-}" ]; then
        echo "$ENDPOINT_IP"
        return
    fi
    echo "$ENDPOINTS" | grep -v '^$' | shuf -n 1
}

# 在主命名空间内解析 Endpoint hostname 为 IP，避免 netns 内无 DNS 导致 wg-quick 卡住
resolve_endpoint() {
    local endpoint="$1"
    local host="${endpoint%:*}"
    local port="${endpoint##*:}"

    case "$host" in
        *[!0-9.]*)
            # 是 hostname，需要解析
            local resolved
            resolved=$(nslookup "$host" 2>/dev/null | awk '/^Address: / {print $2}' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n 1)
            if [ -n "$resolved" ]; then
                printf '%s:%s\n' "$resolved" "$port"
            else
                return 1
            fi
            ;;
        *)
            # 已经是 IP
            printf '%s\n' "$endpoint"
            ;;
    esac
}

# 清洗 wgcf 生成的配置文件
# 参数: $1=配置路径  $2=是否强制替换 endpoint (rotate 时传 "rotate")
sanitize_wg_conf() {
    local conf="$1"
    local mode="${2:-init}"

    local ipv4_addr
    ipv4_addr=$(grep '^Address' "$conf" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}' | head -n 1)

    sed -i '/^Address/d' "$conf"
    sed -i '/^AllowedIPs/d' "$conf"
    sed -i '/^DNS.*/d' "$conf"

    if [ -n "$ipv4_addr" ]; then
        sed -i "/\[Interface\]/a Address = $ipv4_addr" "$conf"
    fi
    sed -i "/\[Peer\]/a AllowedIPs = 0.0.0.0\/0" "$conf"

    if ! grep -q "PersistentKeepalive" "$conf"; then
        sed -i '/\[Peer\]/a PersistentKeepalive = 15' "$conf"
    else
        sed -i 's/PersistentKeepalive.*/PersistentKeepalive = 15/g' "$conf"
    fi

    # Endpoint 策略:
    # - 用户设置了 ENDPOINT_IP → 始终使用
    # - 轮换模式 (mode=rotate) → 随机选择新 endpoint
    # - 初始化模式 (mode=init) → 保留原始 endpoint，但解析 hostname 为 IP
    if [ -n "${ENDPOINT_IP:-}" ]; then
        sed -i "s/^Endpoint.*/Endpoint = $ENDPOINT_IP/g" "$conf"
    elif [ "$mode" = "rotate" ]; then
        local endpoint
        endpoint=$(random_endpoint)
        sed -i "s/^Endpoint.*/Endpoint = $endpoint/g" "$conf"
    else
        # 初始化模式: 解析 hostname 防止 netns 内无 DNS
        local endpoint resolved_endpoint
        endpoint=$(sed -n 's/^Endpoint *= *//p' "$conf" | head -n 1)
        if [ -n "$endpoint" ]; then
            resolved_endpoint=$(resolve_endpoint "$endpoint") || {
                echo "==> [MicroWARP] ⚠️ 无法解析 Endpoint: $endpoint" >&2
                return 1
            }
            sed -i "s/^Endpoint.*/Endpoint = $resolved_endpoint/g" "$conf"
        fi
    fi
}

# 获取出口 IP (纯 IP 字符串，已清洗)
get_exit_ip() {
    local ns="${1:-}"
    local raw
    if [ -n "$ns" ]; then
        raw=$(ip netns exec "$ns" curl -s -m 5 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep ip= | sed 's/ip=//')
    else
        raw=$(curl -s -m 5 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep ip= | sed 's/ip=//')
    fi
    # 清洗: 仅保留合法 IP 字符
    echo "$raw" | tr -dc '0-9a-fA-F.:'
}

# 应用 WARP+ key
# 返回 0 表示成功，1 表示失败/无 key
apply_warp_key() {
    if [ -n "${WARP_LICENSE:-}" ]; then
        if wgcf update --license "$WARP_LICENSE" > /dev/null 2>&1; then
            echo "==> [MicroWARP] WARP+ License 应用成功"
            return 0
        fi
        echo "==> [MicroWARP] ⚠️ WARP+ License 无效"
        return 1
    fi

    if [ -n "${WARP_KEY_API:-}" ]; then
        local keys
        keys=$(curl -s -m 10 "$WARP_KEY_API" 2>/dev/null || true)
        if [ -z "$keys" ]; then
            echo "==> [MicroWARP] ⚠️ 无法访问 WARP+ Key API"
            return 1
        fi

        local shuffled_keys
        shuffled_keys=$(echo "$keys" | shuf)
        local try_count=0
        local applied=0
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            try_count=$((try_count + 1))
            [ $try_count -gt 5 ] && break
            if wgcf update --license "$key" > /dev/null 2>&1; then
                echo "==> [MicroWARP] WARP+ Key 应用成功 (第 ${try_count} 个)"
                applied=1
                break
            fi
        done <<EOF
$shuffled_keys
EOF
        if [ "$applied" = "1" ]; then
            return 0
        fi
        echo "==> [MicroWARP] ⚠️ 所有 WARP+ Key 均无效"
        return 1
    fi

    return 1
}

# 注册 WARP 账号 (在指定工作目录中)
register_warp_account() {
    local workdir="$1"

    cd "$workdir"
    rm -f wgcf-account.toml wgcf-profile.conf

    echo "==> [MicroWARP] 正在注册 WARP 账号..."
    wgcf register --accept-tos > /dev/null 2>&1

    apply_warp_key || true

    wgcf generate > /dev/null 2>&1
    rm -f wgcf-account.toml
    cd /app
}
