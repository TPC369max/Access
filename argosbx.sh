#!/usr/bin/env bash
set -e

# --- 配置区 ---
# 使用固定隧道时设置
ARGO_DOMAIN=${agn:-''}
ARGO_AUTH=${agk:-''}
# 本地配置目录
CONFIG_DIR="./wg-argo-config"

# --- 函数定义 ---

# 卸载功能
uninstall_script() {
    echo "--> 正在清除生成的配置目录..."
    rm -rf "$CONFIG_DIR"
    echo "✅ 清理完成。"
    echo "请手动停止所有正在运行的 wg-quick 和 cloudflared 进程。"
}

# 主安装/配置流程
main_setup() {
    if [ -d "$CONFIG_DIR" ]; then
        echo "错误：配置目录 '$CONFIG_DIR' 已存在。"
        echo "如果需要重新生成，请先运行: ./nix-wireguard-argo.sh del"
        exit 1
    fi

    echo "========= 1. 检查所需命令是否存在于环境中 ========="
    if ! command -v wg >/dev/null || ! command -v cloudflared >/dev/null; then
        echo "错误：wg 或 cloudflared 命令未找到。"
        echo "请在一个包含 wireguard-tools 和 cloudflared 的 Nix Shell 中运行此脚本。"
        echo "例如: nix-shell -p wireguard-tools cloudflared --run \"./nix-wireguard-argo.sh\""
        exit 1
    fi

    echo "========= 2. 生成密钥和配置文件 ========="
    mkdir -p "$CONFIG_DIR"
    wg genkey | tee "$CONFIG_DIR/wg_server_private.key" | wg pubkey > "$CONFIG_DIR/wg_server_public.key"
    wg genkey | tee "$CONFIG_DIR/wg_client_private.key" | wg pubkey > "$CONFIG_DIR/wg_client_public.key"
    
    SERVER_PRIVATE_KEY=$(cat "$CONFIG_DIR/wg_server_private.key")
    SERVER_PUBLIC_KEY=$(cat "$CONFIG_DIR/wg_server_public.key")
    CLIENT_PUBLIC_KEY=$(cat "$CONFIG_DIR/wg_client_public.key")
    CLIENT_PRIVATE_KEY=$(cat "$CONFIG_DIR/wg_client_private.key")

    cat > "$CONFIG_DIR/wg0.conf" <<EOF
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = ${SERVER_PRIVATE_KEY}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = 10.0.0.2/32
EOF

    echo "✅ 服务端配置已生成: $CONFIG_DIR/wg0.conf"

    echo
    echo "========= 3. 生成客户端配置 ========="
    ARGO_PORT="2408" # Cloudflare 推荐的 UDP 端口
    cat > "$CONFIG_DIR/client.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = 10.0.0.2/32
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
AllowedIPs = 0.0.0.0/0, ::/0
# Endpoint 将在下一步中填入
PersistentKeepalive = 25
EOF
    echo "✅ 客户端配置模板已生成: $CONFIG_DIR/client.conf"

    echo
    echo "========= 4. 打印手动执行命令 ========="
    echo "配置已全部生成。由于在 Nix 环境中无法自动管理服务，请按以下步骤手动启动："
    echo
    echo "---"
    echo "STEP A: 启动 WireGuard 服务 (需要 root 权限)"
    echo "请在一个终端中运行以下命令:"
    echo "sudo wg-quick up $CONFIG_DIR/wg0.conf"
    echo "---"
    echo
    echo "---"
    echo "STEP B: 启动 Argo 隧道"
    echo "请在另一个终端中运行以下命令:"
    
    ARGO_CMD="cloudflared tunnel --url udp://localhost:51820 --no-autoupdate > $CONFIG_DIR/argo.log 2>&1 &"
    if [ -n "$ARGO_AUTH" ] && [ -n "$ARGO_DOMAIN" ]; then
        ARGO_CMD="cloudflared tunnel --no-autoupdate run --token ${ARGO_AUTH} > $CONFIG_DIR/argo.log 2>&1 &"
    fi
    echo "$ARGO_CMD"
    echo "---"
    echo
    echo "等待约 10 秒让 Argo 隧道连接，然后检查 '$CONFIG_DIR/argo.log' 获取隧道域名。"
    echo "最后，将获取到的域名填入客户端配置文件 ('$CONFIG_DIR/client.conf') 的 Endpoint 字段中。"
    echo "例如: Endpoint = your-random-name.trycloudflare.com:${ARGO_PORT}"
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
