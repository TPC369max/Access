#!/usr/bin/env sh
#
# WireGuard-Go + Argo Tunnel - Nix Environment Configurator & Launcher
#
# This script is designed for pure, non-root Nix/NixOS environments.
# It does NOT install software. It configures and launches processes
# using the tools you provide in your Nix shell.
#

# --- 1. 初始化和环境设置 ---
export LANG=en_US.UTF-8
export argo=${argo:-'yes'}
export ARGO_DOMAIN=${agn:-''}
export ARGO_AUTH=${agk:-''}
export name=${name:-''}
CONFIG_DIR="./wg-argo-config" # All state is stored locally

# --- 2. 函数定义 ---

# 卸载/清理功能
uninstall_script() {
    echo "--- 开始清理 WireGuard-Go Argo 配置 ---"
    
    echo "正在终止所有后台进程..."
    # Use pkill with a specific pattern to avoid killing unrelated processes
    pkill -f "${CONFIG_DIR}/wg0.conf"
    pkill -f "cloudflared.*--url udp://127.0.0.1:51820"
    pkill -f "cloudflared.*run --token ${ARGO_AUTH}"

    echo "正在删除本地配置目录..."
    rm -rf "$CONFIG_DIR"

    echo ""
    echo "✅ 清理完成。"
}

# 检查环境是否准备就绪
check_environment() {
    echo "--- 正在检查Nix环境依赖 ---"
    local missing_pkg=false
    for pkg in wg wireguard-go cloudflared; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            echo "❌ 错误: 命令 '$pkg' 未找到。"
            missing_pkg=true
        fi
    done

    if [ "$missing_pkg" = true ]; then
        echo ""
        echo "请确保您的Nix环境提供了所有必需的包。"
        echo "例如，使用以下命令启动一个临时的Nix Shell:"
        echo "nix-shell -p wireguard-go wireguard-tools cloudflared"
        exit 1
    fi
    echo "✅ 环境依赖检查通过。"
}

# 运行服务
run_services() {
    echo; echo "--- 正在生成配置并使用 nohup 启动服务 ---"
    
    mkdir -p "$CONFIG_DIR"
    
    # 终止旧进程
    uninstall_script >/dev/null 2>&1
    mkdir -p "$CONFIG_DIR"
    
    # 生成密钥和配置
    wg genkey | tee "$CONFIG_DIR/wg_server_private.key" | wg pubkey > "$CONFIG_DIR/wg_server_public.key"
    wg genkey | tee "$CONFIG_DIR/wg_client_private.key" | wg pubkey > "$CONFIG_DIR/wg_client_public.key"
    SERVER_PRIVATE_KEY=$(cat "$CONFIG_DIR/wg_server_private.key")
    CLIENT_PUBLIC_KEY=$(cat "$CONFIG_DIR/wg_client_public.key")

    cat > "$CONFIG_DIR/wg0.conf" <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
ListenPort = 51820

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = 10.0.0.2/32
EOF
    
    # 启动 wireguard-go
    echo "使用 nohup 启动 wireguard-go..."
    # wireguard-go will create a TUN device named 'wg0' by default
    nohup wireguard-go -f "$CONFIG_DIR/wg0.conf" > "$CONFIG_DIR/wireguard.log" 2>&1 &
    sleep 3

    if ! pgrep -f "${CONFIG_DIR}/wg0.conf" >/dev/null; then
        echo "❌ 错误: wireguard-go 启动失败！"
        echo "   常见原因: 您的Nix容器没有被授予网络管理权限 (CAP_NET_ADMIN)。"
        echo "   请检查日志: cat $CONFIG_DIR/wireguard.log"
        exit 1
    fi
    echo "✅ wireguard-go 已在后台启动。"
    
    # 启动 Argo 隧道
    if [ -n "${ARGO_DOMAIN}" ] && [ -n "${ARGO_AUTH}" ]; then
        argoname='固定'; echo "启动Argo固定隧道..."
        nohup cloudflared tunnel --no-autoupdate run --token "${ARGO_AUTH}" > "$CONFIG_DIR/argo.log" 2>&1 &
    else
        argoname='临时'; echo "启动Argo临时隧道..."
        nohup cloudflared tunnel --url udp://127.0.0.1:51820 --no-autoupdate > "$CONFIG_DIR/argo.log" 2>&1 &
    fi
    
    echo "正在向Cloudflare申请 $argoname 隧道... 请等待约8秒钟。"
    sleep 8
    
    if [ -n "${ARGO_DOMAIN}" ]; then argodomain=$(echo "$ARGO_DOMAIN"); else argodomain=$(grep -o 'Proxying UDP traffic from .*' "$CONFIG_DIR/argo.log" | sed -n 's/Proxying UDP traffic from \(.*\).trycloudflare.com to .*/\1.trycloudflare.com/p' | head -n 1); fi
    
    if [ -n "${argodomain}" ]; then echo "${argodomain}" > "$CONFIG_DIR/argodomain.log"; echo "✅ Argo $argoname 隧道已建立，域名: ${argodomain}"; else echo "❌ 错误: Argo隧道建立失败！请查看日志: cat $CONFIG_DIR/argo.log"; exit 1; fi
}

# 显示客户端配置
display_client_config() {
    echo; echo "--- 生成客户端配置信息 ---";
    CLIENT_PRIVATE_KEY=$(cat "$CONFIG_DIR/wg_client_private.key")
    SERVER_PUBLIC_KEY=$(cat "$CONFIG_DIR/wg_server_public.key")
    argodomain=$(cat "$CONFIG_DIR/argodomain.log")
    hostname=$(uname -n)
    
    echo ""; echo "===================== 客户端配置 ====================="
    argo_port="2408" # Cloudflare推荐的UDP端口
    client_config_file="$CONFIG_DIR/${name}wg-argo-${hostname}.conf"
    
    cat > "${client_config_file}" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = 10.0.0.2/32
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
# Since we are not running as root, we cannot control all routing.
# This configures the client to send ONLY traffic destined for the peer's internal network (10.0.0.1) through the tunnel.
# Change to '0.0.0.0/0, ::/0' if your container's networking setup correctly routes all traffic.
AllowedIPs = 10.0.0.1/32

Endpoint = ${argodomain}:${argo_port}
PersistentKeepalive = 25
EOF
    cat "${client_config_file}"
    echo "========================================================"
    echo "✅ 客户端配置文件已保存到: ${client_config_file}"
}

# --- 3. 主程序逻辑 ---

if [ "$1" = "del" ] || [ "$1" = "uninstall" ]; then
    uninstall_script; exit 0;
fi

check_environment
run_services
display_client_config

echo; echo "🚀 配置与启动完成！"
echo "⚠️ 警告: 所有进程均以 nohup 方式运行，无法开机自启或在崩溃后自动重启。"
