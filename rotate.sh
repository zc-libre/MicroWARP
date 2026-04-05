#!/bin/sh
# ==========================================
# MicroWARP IP 轮换脚本
# 用法: rotate.sh <pool_id>
# ==========================================

. /app/lib.sh

POOL_SIZE="${POOL_SIZE:-1}"
POOL_DIR="${POOL_DIR:-/etc/wireguard/pool}"
LISTEN_PORT="${LISTEN_PORT:-1080}"

# 全局锁：保护 iptables 链的并发修改
GLOBAL_LOCK="/tmp/rotate.global.lock"

# ==========================================
# 参数验证
# ==========================================

POOL_ID="$1"

if [ -z "$POOL_ID" ]; then
    echo '{"error":"missing pool_id"}'
    exit 1
fi

case "$POOL_ID" in
    *[!0-9]*) echo '{"error":"invalid pool_id"}'; exit 1 ;;
esac

if [ "$POOL_ID" -ge "$POOL_SIZE" ]; then
    echo "{\"error\":\"pool_id out of range (0-$((POOL_SIZE-1)))\"}"
    exit 1
fi

# ==========================================
# iptables DNAT 重建 (事务性)
# 每次轮换后完整重建 MICROWARP_POOL 链，
# 避免规则堆积和 nth 分布不均
# ==========================================

rebuild_dnat_chain() {
    local pool_size="$1"
    local i=0

    iptables -t nat -F MICROWARP_POOL 2>/dev/null || true

    while [ $i -lt "$pool_size" ]; do
        local remaining=$((pool_size - i))
        local target_ip="10.200.${i}.2"

        # 跳过正在轮换中的成员 (wg 已 down)
        if [ -f "/tmp/rotate.${i}.down" ]; then
            i=$((i + 1))
            continue
        fi

        # 重新计算有效成员数以正确设置 nth
        local active_remaining=0
        local j=$i
        while [ $j -lt "$pool_size" ]; do
            if [ ! -f "/tmp/rotate.${j}.down" ]; then
                active_remaining=$((active_remaining + 1))
            fi
            j=$((j + 1))
        done

        if [ $active_remaining -le 1 ]; then
            iptables -t nat -A MICROWARP_POOL -j DNAT --to-destination "${target_ip}:1080"
        else
            iptables -t nat -A MICROWARP_POOL \
                -m statistic --mode nth --every "$active_remaining" --packet 0 \
                -j DNAT --to-destination "${target_ip}:1080"
        fi
        i=$((i + 1))
    done
}

# ==========================================
# 主轮换流程
# ==========================================

(
    # 全局锁：同一时刻只允许一个轮换操作
    flock -n 9 || { echo '{"error":"rotation already in progress"}'; exit 1; }

    echo "==> [Rotate] 开始轮换池成员 #${POOL_ID}..." >&2

    if [ "$POOL_SIZE" -le 1 ]; then
        # 单实例模式：先备份旧配置，失败可回滚
        CONF="/etc/wireguard/wg0.conf"
        cp "$CONF" "${CONF}.bak" 2>/dev/null || true

        wg-quick down wg0 2>/dev/null || true

        tmpdir=$(mktemp -d)
        cd "$tmpdir"
        wgcf register --accept-tos > /dev/null 2>&1
        apply_warp_key || true
        wgcf generate > /dev/null 2>&1
        mv wgcf-profile.conf "$CONF"
        rm -f wgcf-account.toml
        cd /app
        rm -rf "$tmpdir"

        sanitize_wg_conf "$CONF"

        if ! wg-quick up wg0 > /dev/null 2>&1; then
            echo "==> [Rotate] ⚠️ wg-quick up 失败，回滚旧配置..." >&2
            if [ -f "${CONF}.bak" ]; then
                mv "${CONF}.bak" "$CONF"
                wg-quick up wg0 > /dev/null 2>&1 || true
            fi
            echo '{"error":"wg-quick up failed, rolled back"}'
            exit 1
        fi
        rm -f "${CONF}.bak"

        NEW_IP=$(get_exit_ip)
        echo "{\"pool_id\":0,\"ip\":\"${NEW_IP:-unknown}\"}"
    else
        # 池化模式：事务性轮换
        NS="warp${POOL_ID}"
        CONF="${POOL_DIR}/${POOL_ID}/wg0.conf"
        cp "$CONF" "${CONF}.bak" 2>/dev/null || true

        # 标记成员为 down，重建 DNAT 链 (摘除该成员)
        touch "/tmp/rotate.${POOL_ID}.down"
        rebuild_dnat_chain "$POOL_SIZE"

        ip netns exec "$NS" wg-quick down "${CONF}" 2>/dev/null || true

        tmpdir=$(mktemp -d)
        cd "$tmpdir"
        wgcf register --accept-tos > /dev/null 2>&1
        apply_warp_key || true
        wgcf generate > /dev/null 2>&1
        mv wgcf-profile.conf "${CONF}"
        rm -f wgcf-account.toml
        cd /app
        rm -rf "$tmpdir"

        sanitize_wg_conf "${CONF}"

        if ! ip netns exec "$NS" wg-quick up "${CONF}" > /dev/null 2>&1; then
            echo "==> [Rotate] ⚠️ wg-quick up 失败，回滚旧配置..." >&2
            if [ -f "${CONF}.bak" ]; then
                mv "${CONF}.bak" "$CONF"
                ip netns exec "$NS" wg-quick up "${CONF}" > /dev/null 2>&1 || true
            fi
            # 无论回滚是否成功，都恢复 DNAT (用旧隧道总比没有好)
            rm -f "/tmp/rotate.${POOL_ID}.down"
            rebuild_dnat_chain "$POOL_SIZE"
            echo '{"error":"wg-quick up failed, rolled back"}'
            exit 1
        fi

        # 成功：移除 down 标记，重建 DNAT 链 (恢复该成员)
        rm -f "/tmp/rotate.${POOL_ID}.down"
        rm -f "${CONF}.bak"
        rebuild_dnat_chain "$POOL_SIZE"

        NEW_IP=$(get_exit_ip "$NS")
        echo "{\"pool_id\":${POOL_ID},\"ip\":\"${NEW_IP:-unknown}\"}"
    fi

) 9>"$GLOBAL_LOCK"
