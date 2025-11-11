#!/bin/sh
#
# Vless-ws + Cloudflare Argo Tunnel - All-in-One Smart Installer
#
# This script intelligently detects user privileges:
# - With root: Installs as a robust systemd service (Recommended).
# - Without root: Runs processes in the background using nohup (for non-critical use).
#

# --- 1. 初始化和环境设置 ---
export LANG=en_US.UTF-8
export port_vl_ws=${vlwpt:-''}
export argo=${argo:-'yes'}
export ARGO_DOMAIN=${agn:-''}
export ARGO_AUTH=${agk:-''}
export uuid=${uuid:-''}
export name=${name:-''}
AGSBX_HOME="$HOME/agsbx"
IS_ROOT=false
if [ "$(id -u)" -eq 0 ]; then
    IS_ROOT=true
fi

# --- 2. 函数定义 ---

uninstall_script() {
    echo "--- 开始卸载 Argosbx VLESS 脚本 ---"
    
    # 停止并禁用 systemd 服务 (如果以root方式安装过)
    if [ "$IS_ROOT" = true ]; then
        echo "正在停止和禁用 systemd 服务..."
        systemctl stop xray.service >/dev-null 2>&1
        systemctl disable xray.service >/dev-null 2>&1
        rm -f /etc/systemd/system/xray.service
        systemctl daemon-reload
    fi

    echo "正在终止所有相关进程..."
    pkill -f 'agsbx/xray'
    pkill -f 'agsbx/cloudflared'

    echo "正在删除安装文件和配置..."
    rm -rf "$AGSBX_HOME"

    echo ""
    echo "✅ 卸载完成。"
}

insuuid(){
    mkdir -p "$AGSBX_HOME"
    if [ -z "$uuid" ] && [ ! -e "$AGSBX_HOME/uuid" ]; then
        if command -v uuidgen >/dev/null 2>&1; then uuid=$(uuidgen); else uuid=$(cat /proc/sys/kernel/random/uuid); fi
        echo "$uuid" > "$AGSBX_HOME/uuid"
    elif [ -n "$uuid" ]; then
        echo "$uuid" > "$AGSBX_HOME/uuid"
    fi
    uuid=$(cat "$AGSBX_HOME/uuid")
    echo "UUID: $uuid"
}

install_xray_service() {
    echo; echo "--- 正在设置 VLESS-WS 服务 (Xray Core) ---"
    
    insuuid
    if [ -z "$port_vl_ws" ] || [ "$port_vl_ws" = "yes" ]; then
        port_vl_ws=$(shuf -i 10000-65535 -n 1)
    fi
    echo "$port_vl_ws" > "$AGSBX_HOME/port_vl_ws"
    echo "Vless-ws 本地监听端口: $port_vl_ws"

    if [ ! -f "$AGSBX_HOME/xray" ]; then
        echo "未检测到Xray核心，正在下载..."
        case $(uname -m) in
        aarch64) cpu=arm64;; x86_64) cpu=amd64;;
        *) echo "错误: 不支持的CPU架构 $(uname -m)" && exit 1
        esac
        url="https://github.com/yonggekkk/argosbx/releases/download/argosbx/xray-$cpu"
        (command -v curl >/dev/null 2>&1 && curl -Lo "$AGSBX_HOME/xray" -# --retry 2 "$url") || \
        (command -v wget >/dev/null 2>&1 && wget -O "$AGSBX_HOME/xray" --tries=2 "$url")
        chmod +x "$AGSBX_HOME/xray"
    fi

    cat > "$AGSBX_HOME/xr.json" <<EOF
{"log":{"loglevel":"warning"},"inbounds":[{"listen":"127.0.0.1","port":${port_vl_ws},"protocol":"vless","settings":{"clients":[{"id":"${uuid}"}],"decryption":"none"},"streamSettings":{"network":"ws","wsSettings":{"path":"/${uuid}-vlws"}}}],"outbounds":[{"protocol":"freedom","tag":"direct"}]}
EOF

    # 终止旧进程，准备启动新的
    pkill -f 'agsbx/xray' >/dev/null 2>&1
    sleep 1

    # 根据权限选择启动方式
    if [ "$IS_ROOT" = true ]; then
        echo "以Root权限运行，将Xray安装为 systemd 服务..."
        cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service for Argosbx
After=network.target
[Service]
Type=simple
ExecStart=$AGSBX_HOME/xray run -c $AGSBX_HOME/xr.json
Restart=on-failure
RestartSec=5s
User=$(whoami)
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray.service
        systemctl restart xray.service
        sleep 2
        if systemctl is-active --quiet xray.service; then
            echo "✅ Xray已作为 systemd 服务成功启动。"
        else
            echo "❌ 错误: Xray服务启动失败。请检查日志: journalctl -u xray.service"
            exit 1
        fi
    else
        echo "以普通用户权限运行，使用 nohup 启动Xray..."
        nohup "$AGSBX_HOME/xray" run -c "$AGSBX_HOME/xr.json" > "$AGSBX_HOME/xray.log" 2>&1 &
        sleep 2
        if pgrep -f 'agsbx/xray' >/dev/null; then
            echo "✅ Xray已在后台启动。"
            echo "⚠️ 警告: 非Root模式下，服务无法开机自启或自动重启。"
        else
            echo "❌ 错误: Xray启动失败。请检查日志: cat $AGSBX_HOME/xray.log"
            exit 1
        fi
    fi
}

run_argo_tunnel() {
    echo; echo "--- 正在启动 Cloudflare Argo 隧道 ---"
    port_vl_ws=$(cat "$AGSBX_HOME/port_vl_ws")

    if [ ! -f "$AGSBX_HOME/cloudflared" ]; then
        echo "正在下载 Cloudflared..."
        case $(uname -m) in
        aarch64) cpu=arm64;; x86_64) cpu=amd64;;
        *) echo "错误: 不支持的CPU架构 $(uname -m)" && exit 1
        esac
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cpu"
        (command -v curl >/dev/null 2>&1 && curl -Lo "$AGSBX_HOME/cloudflared" -# --retry 2 "$url") || \
        (command -v wget >/dev/null 2>&1 && wget -O "$AGSBX_HOME/cloudflared" --tries=2 "$url")
        chmod +x "$AGSBX_HOME/cloudflared"
    fi
    
    pkill -f 'agsbx/cloudflared' >/dev/null 2>&1
    sleep 1

    if [ -n "${ARGO_DOMAIN}" ] && [ -n "${ARGO_AUTH}" ]; then
        argoname='固定'; echo "启动Argo固定隧道..."
        nohup "$AGSBX_HOME/cloudflared" tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token "${ARGO_AUTH}" > "$AGSBX_HOME/argo.log" 2>&1 &
        echo "${ARGO_DOMAIN}" > "$AGSBX_HOME/sbargoym.log"
    else
        argoname='临时'; echo "启动Argo临时隧道..."
        nohup "$AGSBX_HOME/cloudflared" tunnel --url http://127.0.0.1:"${port_vl_ws}" --edge-ip-version auto --no-autoupdate --protocol http2 > "$AGSBX_HOME/argo.log" 2>&1 &
    fi

    echo "正在向Cloudflare申请 $argoname 隧道... 请等待约8秒钟。"
    sleep 8
    
    if [ -n "${ARGO_DOMAIN}" ]; then argodomain=$(cat "$AGSBX_HOME/sbargoym.log" 2>/dev/null); else argodomain=$(grep -o -E 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$AGSBX_HOME/argo.log" | head -n 1 | sed 's/https:\/\///'); fi
    
    if [ -n "${argodomain}" ]; then echo "✅ Argo $argoname 隧道已建立，域名: ${argodomain}"; else echo "❌ 错误: Argo隧道建立失败！请查看日志: cat $AGSBX_HOME/argo.log"; exit 1; fi
}

display_argo_nodes() {
    # ... (此函数无需修改) ...
    echo; echo "--- 生成节点配置信息 ---"; hostname=$(uname -n); uuid=$(cat "$AGSBX_HOME/uuid"); sxname=$(echo "$name" | sed 's/ /_/g');
    argodomain=$(cat "$AGSBX_HOME/sbargoym.log" 2>/dev/null); [ -z "$argodomain" ] && argodomain=$(grep -o -E 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$AGSBX_HOME/argo.log" | head -n 1 | sed 's/https:\/\///');
    path_encoded="%2F${uuid}-vlws";
    if [ -n "$argodomain" ]; then
        vl_tls_link1="vless://${uuid}@yg1.ygkkk.dpdns.org:443?type=ws&security=tls&path=${path_encoded}&host=${argodomain}&sni=${argodomain}#${sxname}vless-ws-tls-argo-$hostname-443";
        vl_link7="vless://${uuid}@yg6.ygkkk.dpdns.org:80?type=ws&security=none&path=${path_encoded}&host=${argodomain}#${sxname}vless-ws-argo-$hostname-80";
        echo ""; echo "===================== 节点配置信息 ====================="; echo "Argo 域名: $argodomain"; echo;
        echo "💣 (TLS加密) 推荐节点:"; echo "$vl_tls_link1"; echo; echo "💣 (普通HTTP) 推荐节点:"; echo "$vl_link7";
        echo "==========================================================";
    fi
}


# --- 3. 主程序逻辑 ---

if [ "$1" = "del" ] || [ "$1" = "uninstall" ]; then
    uninstall_script; exit 0;
fi

[ -z "${vlwpt+x}" ] && vlp_ws="" || vlp_ws="yes"
if [ -z "$vlp_ws" ]; then
    echo "错误：缺少必要的配置。"; echo "用法:";
    echo "  安装/更新: vlwpt=yes ./argo_vless_final.sh [其他变量...] (推荐使用sudo)";
    echo "  卸载:       ./argo_vless_final.sh uninstall (推荐使用sudo)";
    exit 1
fi

install_xray_service
run_argo_tunnel
display_argo_nodes

echo; echo "🚀 部署完成！"
