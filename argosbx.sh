#!/usr/bin/env bash
set -e

# --- 配置区 ---
# 使用固定 Argo 隧道时设置
ARGO_DOMAIN=${agn:-''}
ARGO_AUTH=${agk:-''}
# 用于存放所有生成配置的本地目录
CONFIG_DIR="./wg-argo-config"

# --- 函数定义 ---

# 函数：检查所有必需的命令是否存在于环境中
check_dependencies() {
    echo "========= 1. 检验环境中所需的工具 ========="
    local missing_pkgs=()
    local all_ok=true

    # 定义所需的命令及其对应的 Nix 包名
    declare -A deps=(
        ["wg"]="wireguard-tools"
        ["wg-quick"]="wireguard-tools"
        ["cloudflared"]="cloudflared"
        ["iptables"]="iptables"
    )

    for cmd in "${!deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            all_ok=false
            # 避免重复添加包名
            if [[ ! " ${missing_pkgs[*]} " =~ " ${deps[$cmd]} " ]]; then
                missing_pkgs+=("${deps[$cmd]}")
            fi
            echo "❌ 命令未找到: $cmd (由 '${deps[$cmd]}' 包提供)"
        else
            echo "✅ 找到: $cmd"
        fi
    done

    if [ "$all_ok" = false ]; then
        echo
        echo "------------------------------------------------------------------"
        echo "错误：一个或多个必需的命令缺失。"
        echo "此脚本必须在一个提供了所有依赖项的 Nix 环境中运行。"
        echo
        echo "要创建正确的环境并运行此脚本，请使用以下命令："
        echo
        # 脚本可以自我重建正确的运行命令
        echo "  nix-shell -p ${missing_pkgs[*]} --run \"$0 $*\""
        echo
        echo "------------------------------------------------------------------"
        exit 1
    fi
    echo "✅ 所有必需的工具都已存在。"
}

# 函数：清理生成的配置文件
uninstall_script() {
    if [ ! -d "$CONFIG_DIR" ]; then
        echo "配置目录 '$CONFIG_DIR' 未找到，无需任何操作。"
        exit 0
    fi
    echo "--> 正在移除配置目录: $CONFIG_DIR"
    rm -rf "$CONFIG_DIR"
    echo "✅ 清理完成。"
    echo "注意：此操作不会停止正在运行的进程。请手动停止您已启动的 'wg-quick' 和 'cloudflared' 进程。"
}

# 主函数：生成所有配置
main_setup() {
    # 首先，运行依赖检查。如果缺少任何东西，脚本将在此处退出。
    check_dependencies "$@"

    if [ -d "$CONFIG_DIR" ]; then
        echo "错误：配置目录 '$CONFIG_DIR' 已存在。"
        echo "如果您想重新生成配置，请先运行以下命令删除旧目录："
        echo "  $0 del"
        exit 1
    fi

    echo
    echo "========= 2. 生成密钥和配置文件 ========="
    mkdir -p "$CONFIG_DIR"
    wg genkey | tee "$CONFIG_DIR/wg_server_private.key" | wg pubkey > "$CONFIG_DIR/wg_server_public.key"
    wg genkey | tee "$CONFIG_DIR/wg_client_private.key" | wg pubkey > "$CONFIG_DIR/wg_client_public.key"
    
    SERVER_PRIVATE_KEY=$(cat "$CONFIG_DIR/wg_server_private.key")
    SERVER_PUBLIC_KEY=$(cat "$CONFIG_DIR/wg_server_public.key")
    CLIENT_PUBLIC_KEY=$(cat "$CONFIG_DIR/wg_client_public.key")
    CLIENT_PRIVATE_KEY=$(cat "$CONFIG_DIR/wg_client_private.key")

    # 自动检测用于 NAT 的主网络接口，如果失败则默认为 'eth0'
    MAIN_INTERFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    if [ -z "$MAIN_INTERFACE" ]; then
        echo "警告：无法自动检测主网络接口，将默认使用 'eth0'。"
        MAIN_INTERFACE="eth0"
    fi

    # 创建服务端配置文件
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
    echo "✅ 服务端配置已创建: $CONFIG_DIR/wg0.conf"

    # Cloudflare Argo for WireGuard 推荐的 UDP 端口
    ARGO_PORT="2408" 
    
    # 创建客户端配置文件模板
    cat > "$CONFIG_DIR/client.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = 10.0.0.2/32
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
AllowedIPs = 0.0.0.0/0, ::/0
# 'Endpoint' (接入点) 将在下一步确定
# Endpoint = ARGO_DOMAIN_HERE:${ARGO_PORT}
PersistentKeepalive = 25
EOF
    echo "✅ 客户端配置模板已创建: $CONFIG_DIR/client.conf"

    echo
    echo "========= 3. 手动启动服务的说明 ========="
    echo "配置已全部生成。因为这是一个 Nix 环境，服务必须手动启动。"
    echo
    echo "---"
    echo "步骤 A: 启动 WireGuard 服务 (需要 root 权限)"
    echo "在一个独立的终端中，运行:"
    # 使用 PWD 确保路径正确
    echo "  sudo wg-quick up $PWD/$CONFIG_DIR/wg0.conf"
    echo "---"
    echo
    echo "---"
    echo "步骤 B: 启动 Cloudflare Argo 隧道"
    echo "在另一个终端中，运行:"
    
    ARGO_CMD="cloudflared tunnel --url udp://localhost:51820 --no-autoupdate > $CONFIG_DIR/argo.log 2>&1 &"
    if [ -n "$ARGO_AUTH" ] && [ -n "$ARGO_DOMAIN" ]; then
        ARGO_CMD="cloudflared tunnel --no-autoupdate run --token ${ARGO_AUTH} > $CONFIG_DIR/argo.log 2>&1 &"
    fi
    echo "  $ARGO_CMD"
    echo "---"
    echo
    echo "等待约 10 秒后，检查日志文件以获取 Argo 域名:"
    echo "  grep 'trycloudflare.com' $CONFIG_DIR/argo.log"
    echo
    echo "最后，编辑 '$CONFIG_DIR/client.conf' 文件，并将 'Endpoint' 设置为您找到的域名。"
}

# --- 主程序逻辑 ---
case "$1" in
    del|uninstall)
        uninstall_script
        ;;
    ""|install)
        # 将所有参数传递给函数，以便在出错时能重建正确的命令
        main_setup "$@"
        ;;
    *)
        echo "用法: $0 [install|del]"
        echo "  install: 检查依赖并生成配置文件。"
        echo "  del:     移除生成的配置目录。"
        ;;
esac
