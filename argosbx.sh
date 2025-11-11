#!/usr/bin/env bash
set -e

# --- 配置区 ---
# 通过环境变量设置: agn="你的域名" agk="你的TOKEN" ./脚本.sh
ARGO_DOMAIN=${agn:-''}
ARGO_AUTH=${agk:-''}
# 用于存放所有生成文件的本地目录
CONFIG_DIR="./wg-argo-config"
PID_DIR="$CONFIG_DIR/pids"


# --- 依赖检查与自我重新执行 ---
# 如果我们尚未处于 nix-shell 环境中，则检查依赖项。
if [ -z "$_IN_NIX_SHELL" ]; then
  # 检查所需命令是否存在
  if ! command -v wg >/dev/null || ! command -v cloudflared >/dev/null || ! command -v iptables >/dev/null; then
    echo "--> 依赖项 (wireguard-tools, cloudflared, iptables) 未找到。"
    echo "--> 正在进入一个临时的 Nix 环境以提供这些依赖..."
    
    # 在一个包含所有依赖的 nix-shell 中重新执行此脚本
    # 将所有原始参数 ($@) 传递给内部脚本
    nix-shell -p nixpkgs.wireguard-tools nixpkgs.cloudflared nixpkgs.iptables --run "export _IN_NIX_SHELL=1; bash $0 $@"
    
    # 退出外部脚本，因为内部脚本已经完成了所有工作
    exit 0
  fi
fi


# --- 函数定义 ---

# 停止服务并清理所有文件的函数
uninstall_script() {
    echo "========= 开始卸载 ========="
    if [ ! -d "$CONFIG_DIR" ]; then
        echo "--> 未找到配置目录，无需任何操作。"
        exit 0
    fi

    # 使用 PID 文件停止 cloudflared
    if [ -f "$PID_DIR/cloudflared.pid" ]; then
        echo "--> 正在停止 Argo 隧道..."
        kill "$(cat "$PID_DIR/cloudflared.pid")" 2>/dev/null || echo "    Argo 进程已经停止。"
    fi

    # 优雅地关闭 WireGuard
    echo "--> 正在停止 WireGuard (wg0) 接口..."
    # 必须在配置目录内执行，wg-quick 才能找到相对路径的配置文件
    (cd "$CONFIG_DIR" && sudo wg-quick down wg0.conf 2>/dev/null || echo "    WireGuard 接口已经关闭。")

    echo "--> 正在清理配置目录..."
    rm -rf "$CONFIG_DIR"

    echo "✅ 卸载完成。"
}

# 设置并运行所有服务的主函数
main_setup() {
    if [ -d "$CONFIG_DIR" ]; then
        echo "错误：配置目录 '$CONFIG_DIR' 已存在。"
        echo "如果需要重新安装，请先运行 '$0 del' 来移除现有配置。"
        exit 1
    fi

    echo "========= 1. 生成密钥和配置文件 ========="
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$PID_DIR"
    
    wg genkey | tee "$CONFIG_DIR/wg_server_private.key" | wg pubkey > "$CONFIG_DIR/wg_server_public.key"
    wg genkey | tee "$CONFIG_DIR/wg_client_private.key" | wg pubkey > "$CONFIG_DIR/wg_client_public.key"
    
    SERVER_PRIVATE_KEY=$(cat "$CONFIG_DIR/wg_server_private.key")
    SERVER_PUBLIC_KEY=$(cat "$CONFIG_DIR/wg_server_public.key")
    CLIENT_PUBLIC_KEY=$(cat "$CONFIG_DIR/wg_client_public.key")
    CLIENT_PRIVATE_KEY=$(cat "$CONFIG_DIR/wg_client_private.key")
    
    # 自动获取默认网络接口名，用于NAT转发，如果失败则回退到 eth0
    INTERFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1 || echo "eth0")

    cat > "$CONFIG_DIR/wg0.conf" <<EOF
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = ${SERVER_PRIVATE_KEY}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${INTERFACE} -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = 10.0.0.2/32
EOF

    echo "✅ 服务端配置已创建于: $CONFIG_DIR/wg0.conf"

    echo
    echo "========= 2. 使用 nohup 启动后台服务 ========="
    echo "--> 正在启动 WireGuard 接口... (可能需要您输入 sudo 密码)"
    # 使用配置文件的绝对路径来启动 wg-quick
    nohup sudo wg-quick up "$(realpath "$CONFIG_DIR/wg0.conf")" > "$CONFIG_DIR/wg.log" 2>&1 &
    sleep 2 # 等待服务启动

    echo "--> 正在后台启动 Cloudflare Argo 隧道..."
    if [ -n "$ARGO_AUTH" ] && [ -n "$ARGO_DOMAIN" ]; then
        nohup cloudflared tunnel --no-autoupdate run --token "${ARGO_AUTH}" > "$CONFIG_DIR/argo.log" 2>&1 &
    else
        nohup cloudflared tunnel --url udp://localhost:51820 --no-autoupdate > "$CONFIG_DIR/argo.log" 2>&1 &
    fi
    # 保存 cloudflared 进程的 PID，方便后续停止
    echo $! > "$PID_DIR/cloudflared.pid"

    echo "--> 正在等待 Argo 隧道建立连接 (约 10 秒)..."
    sleep 10

    # 从日志文件中提取 Argo 域名
    ARGODOMAIN=$(grep -o 'Proxying UDP traffic from .*' "$CONFIG_DIR/argo.log" | sed -n 's/Proxying UDP traffic from \(.*\).trycloudflare.com to .*/\1.trycloudflare.com/p' | head -n 1)
    if [ -z "$ARGODOMAIN" ]; then
      ARGODOMAIN="${ARGO_DOMAIN}" # 如果日志解析失败，则回退到固定域名
    fi
    
    if [ -z "$ARGODOMAIN" ]; then
        echo "❌ 严重错误：无法确定 Argo 隧道的域名。"
        echo "请检查日志文件以获取更多信息: $CONFIG_DIR/argo.log"
        uninstall_script
        exit 1
    fi
    
    echo "✅ Argo 隧道已成功连接，域名为: ${ARGODOMAIN}"

    echo
    echo "========= 3. 生成最终客户端配置 ========="
    ARGO_PORT="2408" # 一个用于 WireGuard over Argo 的通用 UDP 端口
    CLIENT_CONFIG_FILE="$CONFIG_DIR/client.conf"

    cat > "${CLIENT_CONFIG_FILE}" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = 10.0.0.2/32
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${ARGODOMAIN}:${ARGO_PORT}
PersistentKeepalive = 25
EOF

    echo "✅ 设置完成！您的客户端配置如下。"
    echo "   配置文件已保存至: ${CLIENT_CONFIG_FILE}"
    echo "---------------------------------------------------------"
    cat "${CLIENT_CONFIG_FILE}"
    echo "---------------------------------------------------------"

    if command -v qrencode >/dev/null; then
        qrencode -t ansiutf8 < "${CLIENT_CONFIG_FILE}"
    else
        echo "(在您的 Nix 环境中安装 'qrencode' 包即可显示二维码)"
    fi
}


# --- 主程序逻辑 ---
# 解析命令行参数以决定执行何种操作
case "$1" in
    del|uninstall)
        uninstall_script
        ;;
    ""|install)
        main_setup
        ;;
    *)
        echo "用法: $0 [install|del]"
        echo "  - install: (默认) 安装并运行服务。"
        echo "  - del:     停止服务并删除所有生成的文件。"
        ;;
esac
