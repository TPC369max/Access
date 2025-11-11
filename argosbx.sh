#!/bin/sh
#
# WireGuard + Cloudflare Argo Tunnel - All-in-One Smart Installer
#
# This script intelligently detects user privileges:
# - With root: Installs as a robust systemd service (Recommended).
# - Without root: Generates all configs and provides instructions for manual activation.
#

# --- 1. 初始化和环境设置 ---
export LANG=en_US.UTF-8
export argo=${argo:-'yes'}
export ARGO_DOMAIN=${agn:-''}
export ARGO_AUTH=${agk:-''}
export name=${name:-''}
AGSBX_HOME="$HOME/agsbx" # Centralized installation directory
IS_ROOT=false
if [ "$(id -u)" -eq 0 ]; then
    IS_ROOT=true
fi

# --- 2. 函数定义 ---

# 卸载脚本
uninstall_script() {
    echo "--- 开始卸载 WireGuard-Argo 脚本 ---"
    
    # 停止并禁用 systemd 服务 (如果以root方式安装过)
    if [ "$IS_ROOT" = true ]; then
        echo "正在停止和禁用 systemd 服务..."
        systemctl stop wg-quick@wg0 >/dev/null 2>&1
        systemctl disable wg-quick@wg0 >/dev/null 2>&1
        rm -f /etc/systemd/system/wg-quick@wg0.service # Clean up link
        rm -f /etc/wireguard/wg0.conf
        systemctl daemon-reload
    fi

    echo "正在终止所有相关进程..."
    pkill -f 'agsbx/cloudflared'

    echo "正在删除安装文件和配置..."
    rm -rf "$AGSBX_HOME"

    echo ""
    echo "✅ 卸载完成。"
}

# 检查并安装依赖
install_dependencies() {
    echo; echo "--- 正在检查并安装依赖 ---"
    mkdir -p "$AGSBX_HOME"

    # 1. 下载 Cloudflared
    if [ ! -f "$AGSBX_HOME/cloudflared" ]; then
        echo "正在下载 Cloudflared..."
        case $(uname -m) in
        aarch64) cpu=arm64;; x86_64) cpu=amd64;;
        *) echo "错误: 不支持的CPU架构 $(uname -m)" && exit 1
        esac
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cpu"
        (command -v curl >/dev/null 2>&1 && curl -Lo "$AGSBX_HOME/cloudflared" -# --retry 2 "$url") || \
        (command -v wget >/dev/null 2>&1 && wget -qO "$AGSBX_HOME/cloudflared" --tries=2 "$url")
        chmod +x "$AGSBX_HOME/cloudflared"
    fi

    # 2. 检查并安装 WireGuard-tools (需要Root)
    if ! command -v wg >/dev/null 2>&1; then
        if [ "$IS_ROOT" = true ]; then
            echo "正在安装 wireguard-tools..."
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update -y && apt-get install -y wireguard-tools
            elif command -v yum >/dev/null 2>&1; then
                yum install -y epel-release && yum install -y wireguard-tools
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y wireguard-tools
            else
                echo "❌ 错误: 无法确定包管理器，请手动安装 'wireguard-tools'。"
                exit 1
            fi
        else
            echo "❌ 错误: 'wireguard-tools' 未安装。"
            echo "此脚本需要以 root 权限首次运行以安装系统依赖。"
            echo "请运行: sudo ./wireguard-argo.sh"
            exit 1
        fi
    fi
    echo "✅ 所有依赖均已满足。"
}

# 设置WireGuard并启动服务
setup_wireguard() {
    echo; echo "--- 正在配置 WireGuard ---"

    # 生成密钥对
    wg genkey | tee "$AGSBX_HOME/wg_server_private.key" | wg pubkey > "$AGSBX_HOME/wg_server_public.key"
    wg genkey | tee "$AGSBX_HOME/wg_client_private.key" | wg pubkey > "$AGSBX_HOME/wg_client_public.key"
    SERVER_PRIVATE_KEY=$(cat "$AGSBX_HOME/wg_server_private.key")

    # 根据权限选择安装方式
    if [ "$IS_ROOT" = true ]; then
        echo "以Root权限运行，将WireGuard配置为 systemd 服务..."
        main_interface=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
        mkdir -p /etc/wireguard
        cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.0.0.1/24
PrivateKey = ${SERVER_PRIVATE_KEY}
ListenPort = 51820
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${main_interface} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${main_interface} -j MASQUERADE
EOF
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard-forward.conf
        
        systemctl enable --now wg-quick@wg0
        sleep 2
        if systemctl is-active --quiet wg-quick@wg0; then
            echo "✅ WireGuard已作为 systemd 服务成功启动。"
        else
            echo "❌ 错误: WireGuard服务启动失败。请检查日志: journalctl -u wg-quick@wg0"
            exit 1
        fi
    else
        echo "以普通用户权限运行，仅生成配置文件..."
        cat > "$AGSBX_HOME/wg0.conf" <<EOF
[Interface]
Address = 10.0.0.1/24
PrivateKey = ${SERVER_PRIVATE_KEY}
ListenPort = 51820
# PostUp/Down rules require root and must be run with wg-quick
[Peer]
# Peers will be added here
EOF
        echo "✅ WireGuard 配置文件已生成于: $AGSBX_HOME/wg0.conf"
    fi
}

# 启动Argo隧道
run_argo_tunnel() {
    echo; echo "--- 正在启动 Cloudflare Argo 隧道 ---"
    
    pkill -f 'agsbx/cloudflared' >/dev/null 2>&1; sleep 1

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

# 生成并显示客户端配置
display_client_config() {
    echo; echo "--- 生成客户端配置信息 ---";
    CLIENT_PUBLIC_KEY=$(cat "$AGSBX_HOME/wg_client_public.key")
    CLIENT_PRIVATE_KEY=$(cat "$AGSBX_HOME/wg_client_private.key")
    SERVER_PUBLIC_KEY=$(cat "$AGSBX_HOME/wg_server_public.key")
    argodomain=$(cat "$AGSBX_HOME/argodomain.log")
    hostname=$(uname -n)
    
    # 将客户端公钥添加到服务端
    if [ "$IS_ROOT" = true ]; then
        wg set wg0 peer "${CLIENT_PUBLIC_KEY}" allowed-ips 10.0.0.2/32
    else
        # 对于非root用户，在生成的配置文件中追加peer信息
        echo "[Peer]" >> "$AGSBX_HOME/wg0.conf"
        echo "PublicKey = ${CLIENT_PUBLIC_KEY}" >> "$AGSBX_HOME/wg0.conf"
        echo "AllowedIPs = 10.0.0.2/32" >> "$AGSBX_HOME/wg0.conf"
    fi

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
    
    # 非Root模式下的最终说明
    if [ "$IS_ROOT" = false ]; then
        echo
        echo "!!!!!!!!!!!!!!!!!!!!!! 重要操作 !!!!!!!!!!!!!!!!!!!!!!"
        echo "由于您以非root用户运行，服务未自动启动。"
        echo "请让有 sudo 权限的用户执行以下命令来激活WireGuard接口:"
        echo ""
        echo "sudo wg-quick up $AGSBX_HOME/wg0.conf"
        echo ""
        echo "要关闭接口，请运行:"
        echo "sudo wg-quick down $AGSBX_HOME/wg0.conf"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    fi
}

# --- 3. 主程序逻辑 ---

if [ "$1" = "del" ] || [ "$1" = "uninstall" ]; then
    uninstall_script; exit 0;
fi

# 开始安装流程
install_dependencies
setup_wireguard
run_argo_tunnel
display_client_config

echo; echo "🚀 部署完成！"
