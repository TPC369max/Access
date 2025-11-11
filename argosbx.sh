#!/usr/bin/env bash
set -e

# --- 配置区 ---
# 使用固定隧道时通过环境变量传入 (agn=... agk=...)
ARGO_DOMAIN=${agn:-''}
ARGO_AUTH=${agk:-''}
# 本地配置和日志的目录
CONFIG_DIR="./wg-argo-config"

# --- 函数定义 ---

# 检查所需命令是否在当前 Nix 环境中可用
check_dependencies() {
    echo "========= 1. 检查所需命令是否存在于环境中 ========="
    local missing_pkg=0
    for cmd in wg cloudflared iptables; do
        if ! command -v "$cmd" > /dev/null; then
            echo "错误: 命令 '$cmd' 未找到。"
            missing_pkg=1
        fi
    done

    if [ "$missing_pkg" -eq 1 ]; then
        echo "请在一个包含 wireguard-tools, cloudflared, 和 iptables 的 Nix Shell 中运行此脚本。"
        echo "例如: nix-shell -p wireguard-tools cloudflared iptables --run \"./nix-wireguard-argo.sh\""
        exit 1
    fi
    echo "✅ 所有依赖命令均已找到。"
}

# 卸载并清理所有相关进程和文件
uninstall_script() {
    echo "========= 开始卸载并清理 WireGuard-Argo ========="
    
    if [ ! -d "$CONFIG_DIR" ]; then
        echo "配置目录 '$CONFIG_DIR' 未找到，无需清理。"
        exit 0
    fi

    # 1. 停止 Argo 隧道进程
    if [ -f "$CONFIG_DIR/argo.pid" ]; then
        echo "--> 正在停止 Argo 隧道进程..."
        kill "$(cat "$CONFIG_DIR/argo.pid")" 2>/dev/null || echo "Argo 进程已停止。"
    fi

    # 2. 停止 WireGuard 进程并清理网络接口
    if [ -f "$CONFIG_DIR/wg.pid" ]; then
        echo "--> 正在停止 WireGuard 进程..."
        sudo kill "$(cat "$CONFIG_DIR/wg.pid")" 2>/dev/null || echo "WireGuard 进程已停止。"
    fi
    echo "--> 正在关闭 wg0 网络接口并清理防火墙规则..."
    sudo wg-quick down "$CONFIG_DIR/wg0.conf" 2>/dev/null || echo "wg0 接口已关闭。"

    # 3. 删除配置目录
    echo "--> 正在删除配置和日志文件..."
    rm -rf "$CONFIG_DIR"

    echo "✅ 清理完成！"
}

# 主安装/配置流程
main_setup() {
    if [ -d "$CONFIG_DIR" ]; then
        echo "错误：配置目录 '$CONFIG_DIR' 已存在。"
        echo "如果需要重新安装，请先运行: ./nix-wireguard-argo.sh del"
        exit 1
    fi

    check_dependencies

    echo "========= 2. 生成密钥和配置文件 ========="
    mkdir -p "$CONFIG_DIR"
    wg genkey | tee "$CONFIG_DIR/wg_server_private.key" | wg pubkey > "$CONFIG_DIR/wg_server_public.key"
    wg genkey | tee "$CONFIG_DIR/wg_client_private.key" | wg pubkey > "$CONFIG_DIR/wg_client_public.key"
    
    SERVER_PRIVATE_KEY=$(cat "$CONFIG_DIR/wg_server_private.key")
    SERVER_PUBLIC_KEY=$(cat "$CONFIG_DIR/wg_server_public.key")
    CLIENT_PUBLIC_KEY=$(cat "$CONFIG_DIR/wg_client_public.key")
    CLIENT_PRIVATE_KEY=$(cat "$CONFIG_DIR/wg_client_private.key")

    # 获取主网络接口，用于NAT
    MAIN_INTERFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)

    cat > "$CONFIG_DIR/wg0.conf" <<EOF
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = ${SERVER_PRIVATE_KEY}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${MAIN_INTERFACE} -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = 10.0.0.2/32
EOF

    echo "✅ 服务端配置已生成: $CONFIG_DIR/wg0.conf"

    echo
    echo "========= 3. 使用 nohup 在后台启动服务 ========="
    echo "--> 启动 WireGuard 服务 (需要 root 权限)..."
    # 使用 sudo sh -c "..." 确保 nohup 和重定向都以 root 权限执行
    sudo sh -c "nohup wg-quick up '$PWD/$CONFIG_DIR/wg0.conf' > '$PWD/$CONFIG_DIR/wg.log' 2>&1 & echo \$! > '$PWD/$CONFIG_DIR/wg.pid'"
    sleep 2 # 等待接口启动

    if ! sudo wg show wg0 >/dev/null 2>&1; then
        echo "❌ WireGuard 启动失败. 请检查日志: $CONFIG_DIR/wg.log"
        uninstall_script
        exit 1
    fi
    echo "✅ WireGuard 服务已在后台启动 (PID: $(sudo cat $CONFIG_DIR/wg.pid))。"

    echo "--> 启动 Argo 隧道..."
    ARGO_CMD="cloudflared tunnel --url udp://localhost:51820 --no-autoupdate > $CONFIG_DIR/argo.log 2>&1"
    if [ -n "$ARGO_AUTH" ] && [ -n "$ARGO_DOMAIN" ]; then
        ARGO_CMD="cloudflared tunnel --no-autoupdate run --token ${ARGO_AUTH} > $CONFIG_DIR/argo.log 2>&1"
    fi
    
    nohup sh -c "$ARGO_CMD" &
    echo $! > "$CONFIG_DIR/argo.pid"
    echo "✅ Argo 隧道服务已在后台启动 (PID: $(cat $CONFIG_DIR/argo.pid))。"

    echo
    echo "========= 4. 自动获取域名并生成客户端配置 ========="
    echo "--> 等待 Argo 隧道连接并获取域名 (约 10 秒)..."
    sleep 10

    if [ -n "$ARGO_DOMAIN" ]; then
        # 固定域名场景
        TUNNEL_DOMAIN="$ARGO_DOMAIN"
    else
        # 临时域名场景，从日志中提取
        TUNNEL_DOMAIN=$(grep -o 'Proxying UDP traffic from .*' "$CONFIG_DIR/argo.log" | sed -n 's/Proxying UDP traffic from \(.*\).trycloudflare.com to .*/\1.trycloudflare.com/p' | head -n 1)
    fi

    if [ -z "$TUNNEL_DOMAIN" ]; then
        echo "❌ 获取 Argo 域名失败. 请检查日志: $CONFIG_DIR/argo.log"
        uninstall_script
        exit 1
    fi
    echo "✅ Argo 隧道已连接，域名为: $TUNNEL_DOMAIN"
    
    ARGO_PORT="2408" # Cloudflare 推荐的 UDP 端口
    CLIENT_CONFIG_FILE="$CONFIG_DIR/client.conf"

    cat > "$CLIENT_CONFIG_FILE" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = 10.0.0.2/32
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${TUNNEL_DOMAIN}:${ARGO_PORT}
PersistentKeepalive = 25
EOF

    echo
    echo "🎉 部署成功！"
    echo "客户端配置文件已生成并保存在: ${CLIENT_CONFIG_FILE}"
    echo "---------------------------------------------------------"
    cat "${CLIENT_CONFIG_FILE}"
    echo "---------------------------------------------------------"
    if command -v qrencode >/dev/null; then
        qrencode -t ansiutf8 < "${CLIENT_CONFIG_FILE}"
    fi
}

# --- 主程序逻辑 ---
case "$1" in
    del|uninstall)
        uninstall_script
        ;;
    ""|install)
        main_setup
        ;;
    *)
        echo "用法: $0 [install|del]"
        ;;
esac
