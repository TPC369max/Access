#!/bin/sh
#
# WireGuard-Go + Argo Tunnel - True Non-Root Installer
#
# This script runs entirely without root privileges. It downloads pre-compiled
# binaries and runs them in the background using nohup.
#

# --- 0. 重要：一次性系统准备工作 (必须由管理员完成) ---
#
# 在您运行此脚本之前，一个有sudo权限的用户必须在您的服务器上执行以下两个准备步骤：
#
# 步骤 1: 启用 IP 转发 (用于NAT)
#   sudo sysctl -w net.ipv4.ip_forward=1
#   # (可选，但推荐) 使其永久生效:
#   echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-wireguard-forward.conf
#
# 步骤 2: 授予 wireguard-go 程序网络管理权限
#   此脚本会自动下载 wireguard-go, 假设它将被放在 $HOME/agsbx/wireguard-go。
#   请在脚本首次运行并下载文件后，让管理员执行此命令：
#   sudo setcap cap_net_admin+eip "$HOME/agsbx/wireguard-go"
#
# ---

# --- 1. 初始化和环境设置 ---
export LANG=en_US.UTF-8
export argo=${argo:-'yes'}
export ARGO_DOMAIN=${agn:-''}
export ARGO_AUTH=${agk:-''}
export name=${name:-''}
AGSBX_HOME="$HOME/agsbx" # 安装目录

# --- 2. 函数定义 ---

# 卸载脚本
uninstall_script() {
    echo "--- 开始卸载 WireGuard-Go Argo 脚本 ---"
    
    echo "正在终止所有相关进程..."
    pkill -f 'agsbx/wireguard-go'
    pkill -f 'agsbx/cloudflared'

    echo "正在删除安装文件和配置..."
    rm -rf "$AGSBX_HOME"

    echo ""
    echo "✅ 卸载完成。"
}

# 下载并准备依赖
install_dependencies() {
    echo; echo "--- 正在下载所需的可执行文件 ---"
    mkdir -p "$AGSBX_HOME"
    
    case $(uname -m) in
    aarch64) cpu=arm64;; x86_64) cpu=amd64;;
    *) echo "❌ 错误: 不支持的CPU架构 $(uname -m)" && exit 1
    esac

    # 1. 下载 Cloudflared
    if [ ! -f "$AGSBX_HOME/cloudflared" ]; then
        echo "正在下载 Cloudflared..."
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cpu"
        (command -v curl >/dev/null 2>&1 && curl -Lo "$AGSBX_HOME/cloudflared" -# --retry 2 "$url") || \
        (command -v wget >/dev/null 2>&1 && wget -qO "$AGSBX_HOME/cloudflared" --tries=2 "$url")
        chmod +x "$AGSBX_HOME/cloudflared"
    fi

    # 2. 下载 wireguard-go
    if [ ! -f "$AGSBX_HOME/wireguard-go" ]; then
        echo "正在下载 wireguard-go..."
        wg_go_url="https://github.com/PonderMobility/wireguard-go-binaries/releases/download/v0.0.20220316/wireguard-go-linux-$cpu"
        (command -v curl >/dev/null 2>&1 && curl -Lo "$AGSBX_HOME/wireguard-go" -# --retry 2 "$wg_go_url") || \
        (command -v wget >/dev/null 2>&1 && wget -qO "$AGSBX_HOME/wireguard-go" --tries=2 "$wg_go_url")
        chmod +x "$AGSBX_HOME/wireguard-go"
        
        echo
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!! 管理员操作提醒 !!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "wireguard-go 已下载。请让管理员运行以下命令来授予其必要权限:"
        echo
        echo "sudo setcap cap_net_admin+eip \"$AGSBX_HOME/wireguard-go\""
        echo
        echo "在执行上述命令之前，脚本将无法成功启动WireGuard。"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    fi
    echo "✅ 所有文件准备就绪。"
}

# 运行服务
run_services() {
    echo; echo "--- 正在生成配置并启动服务 ---"
    
    # 终止旧进程
    pkill -f 'agsbx/wireguard-go' >/dev/null 2>&1
    pkill -f 'agsbx/cloudflared' >/dev/null 2>&1
    sleep 1

    # 生成密钥和配置
    wg genkey | tee "$AGSBX_HOME/wg_server_private.key" | wg pubkey > "$AGSBX_HOME/wg_server_public.key"
    wg genkey | tee "$AGSBX_HOME/wg_client_private.key" | wg pubkey > "$AGSBX_HOME/wg_client_public.key"
    SERVER_PRIVATE_KEY=$(cat "$AGSBX_HOME/wg_server_private.key")
    CLIENT_PUBLIC_KEY=$(cat "$AGSBX_HOME/wg_client_public.key")

    cat > "$AGSBX_HOME/wg0.conf" <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
ListenPort = 51820

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = 10.0.0.2/32
EOF
    
    # 启动 wireguard-go
    echo "使用 nohup 启动 wireguard-go..."
    export WG_TUN_NAME_FILE="$AGSBX_HOME/wg0.name" # 告诉wireguard-go接口名称
    nohup "$AGSBX_HOME/wireguard-go" -f "$AGSBX_HOME/wg0.conf" > "$AGSBX_HOME/wireguard.log" 2>&1 &
    sleep 3

    if ! pgrep -f 'agsbx/wireguard-go' >/dev/null; then
        echo "❌ 错误: wireguard-go 启动失败！"
        echo "   常见原因: 管理员尚未运行 'sudo setcap' 命令 (请见上方提示)。"
        echo "   请检查日志: cat $AGSBX_HOME/wireguard.log"
        exit 1
    fi
    echo "✅ wireguard-go 已在后台启动。"
    
    # 启动 Argo 隧道
    if [ -n "${ARGO_DOMAIN}" ] && [ -n "${ARGO_AUTH}" ]; then
        argoname='固定'; echo "启动Argo固定隧道..."
        nohup "$AGSBX_HOME/cloudflared" tunnel --no-autoupdate run --token "${ARGO_AUTH}" > "$AGSBX_HOME/argo.log" 2>&1 &
        echo "${ARGO_DOMAIN}" > "$AGSBX_HOME/argodomain.log"
    else
        argoname='临时'; echo "启动Argo临时隧道..."
        nohup "$AGSBX_HOME/cloudflared" tunnel --url udp://127.0.0.1:51820 --no-autoupdate > "$AGSBX_HOME/argo.log" 2>&1 &
    fi
    
    echo "正在向Cloudflare申请 $argoname 隧道... 请等待约8秒钟。"
    sleep 8
    
    if [ -n "${ARGO_DOMAIN}" ]; then argodomain=$(cat "$AGSBX_HOME/argodomain.log" 2>/dev/null); else argodomain=$(grep -o 'Proxying UDP traffic from .*' "$AGSBX_HOME/argo.log" | sed -n 's/Proxying UDP traffic from \(.*\).trycloudflare.com to .*/\1.trycloudflare.com/p' | head -n 1); fi
    
    if [ -n "${argodomain}" ]; then echo "${argodomain}" > "$AGSBX_HOME/argodomain.log"; echo "✅ Argo $argoname 隧道已建立，域名: ${argodomain}"; else echo "❌ 错误: Argo隧道建立失败！请查看日志: cat $AGSBX_HOME/argo.log"; exit 1; fi
}

# 显示客户端配置
display_client_config() {
    echo; echo "--- 生成客户端配置信息 ---";
    CLIENT_PRIVATE_KEY=$(cat "$AGSBX_HOME/wg_client_private.key")
    SERVER_PUBLIC_KEY=$(cat "$AGSBX_HOME/wg_server_public.key")
    argodomain=$(cat "$AGSBX_HOME/argodomain.log")
    hostname=$(uname -n)
    
    echo ""; echo "===================== 客户端配置 ====================="
    argo_port="2408" # Cloudflare推荐的UDP端口
    client_config_file="$AGSBX_HOME/${name}wg-argo-${hostname}.conf"
    
    cat > "${client_config_file}" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = 10.0.0.2/32
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
AllowedIPs = 0.0.0.0/0, ::/0
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

install_dependencies
run_services
display_client_config

echo; echo "🚀 部署完成！"
echo "⚠️ 警告: 进程以 nohup 方式运行，无法开机自启或在崩溃后自动重启。"
