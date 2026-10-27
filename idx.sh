#!/bin/bash
# ==============================================================================
# Project: Xray + Cloudflare Argo Tunnel (Nix / Linux Container Edition)
# Open Source & Clean Edition (No Hardcoded Credentials)
# ==============================================================================

# 1. 终止旧进程，防止重新部署时端口或 Token 冲突
pkill -9 -f "$HOME/agsbx/xray" 2>/dev/null
pkill -9 -f "$HOME/agsbx/cloudflared" 2>/dev/null

# 2. 清理旧内核与日志，确保拉取最新版 Cloudflared
rm -rf "$HOME/idx.sh" "$HOME/bin/agsbx" "$HOME/agsbx/cloudflared" "$HOME/agsbx/xr.json" "$HOME/agsbx/argo.log"

# 3. 写入最新主程序
cat > "$HOME/idx.sh" << 'SCRIPT_EOF'
#!/bin/bash

export LANG=en_US.UTF-8
WORKDIR="$HOME/agsbx"
BINDIR="$HOME/bin"
mkdir -p "$WORKDIR" "$BINDIR"

# 架构检测
case "$(uname -m)" in
    x86_64|amd64) cpu="amd64" ;;
    aarch64|arm64) cpu="arm64" ;;
    *) echo "❌ 错误: 不支持的 CPU 架构: $(uname -m)" && exit 1 ;;
esac

# 辅助生成函数
get_uuid() {
    if [ -f /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        od -x /dev/urandom 2>/dev/null | head -n 1 | awk '{print $2$3"-"$4"-"$5"-"$6"-"$7$8$9}'
    fi
}

get_port() {
    if command -v shuf >/dev/null 2>&1; then
        shuf -i 10000-65535 -n 1
    else
        awk 'BEGIN{srand(); print int(rand()*(65535-10000+1))+10000}'
    fi
}

# 参数配置与合并（命令行传入的参数优先于 conf.env）
_IN_UUID="$uuid"
_IN_VMPT="$vmpt"
_IN_VWPT="$vwpt"
_IN_ARGO="$argo"
_IN_AGN="$agn"
_IN_AGK="$agk"
_IN_NAME="$name"
_IN_VLPATH="$vl_path"
_IN_VMPATH="$vm_path"

[ -f "$WORKDIR/conf.env" ] && source "$WORKDIR/conf.env"

export uuid="${_IN_UUID:-${uuid:-$(get_uuid)}}"
export vmpt="${_IN_VMPT:-${vmpt:-$(get_port)}}"
export vwpt="${_IN_VWPT:-${vwpt:-$(get_port)}}"
export argo="${_IN_ARGO:-${argo:-'vwpt'}}"
export agn="${_IN_AGN:-${agn:-''}}"
export agk="${_IN_AGK:-${agk:-''}}"
export name="${_IN_NAME:-${name:-'IDX'}}"
export vl_path="${_IN_VLPATH:-${vl_path:-'/api/v4/system/updates'}}"
export vm_path="${_IN_VMPATH:-${vm_path:-'/api/v3/video-stream'}}"

check_config() {
    cat > "$WORKDIR/conf.env" <<EOF
uuid="$uuid"
vmpt="$vmpt"
vwpt="$vwpt"
argo="$argo"
agn="$agn"
agk="$agk"
name="$name"
vl_path="$vl_path"
vm_path="$vm_path"
EOF
}

download_bin() {
    local target="$1"
    local url="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fLso "$target" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$target" "$url"
    else
        return 1
    fi
}

# 内核安装与强制更新
install_core() {
    local force="$1"

    # Xray 安装
    if [ ! -f "$WORKDIR/xray" ] || [ "$force" == "1" ]; then
        echo "正在下载 Xray 内核..."
        rm -f "$WORKDIR/xray"
        local url="https://github.com/yonggekkk/argosbx/releases/download/argosbx/xray-$cpu"
        download_bin "$WORKDIR/xray" "$url"
        chmod +x "$WORKDIR/xray"
        if ! "$WORKDIR/xray" version >/dev/null 2>&1; then
            echo "❌ Xray 下载失败，请检查网络。"
            rm -f "$WORKDIR/xray"
            exit 1
        fi
    fi

    # Cloudflared 安装（拉取官方最新 Release）
    if [ ! -f "$WORKDIR/cloudflared" ] || [ "$force" == "1" ]; then
        echo "正在拉取最新版 Cloudflared..."
        rm -f "$WORKDIR/cloudflared"
        local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cpu"
        download_bin "$WORKDIR/cloudflared" "$url"
        chmod +x "$WORKDIR/cloudflared"
        if ! "$WORKDIR/cloudflared" --version >/dev/null 2>&1; then
            echo "❌ Cloudflared 下载失败或在当前容器环境无法执行。"
            rm -f "$WORKDIR/cloudflared"
            exit 1
        fi
        echo "✅ Cloudflared 已更新至: $("$WORKDIR/cloudflared" --version 2>&1 | head -n 1)"
    fi
}

gen_xray_json() {
    cat > "$WORKDIR/xr.json" <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "tag": "vmess-in",
      "port": $vmpt,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": { "clients": [ { "id": "$uuid" } ] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "$vm_path" } }
    },
    {
      "tag": "vless-in",
      "port": $vwpt,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { 
        "clients": [ { "id": "$uuid" } ], 
        "decryption": "none" 
      },
      "streamSettings": { 
        "network": "ws", 
        "wsSettings": { 
            "path": "$vl_path",
            "headers": { "Host": "" }
        } 
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
}

stop_process() {
    pkill -9 -f "$WORKDIR/xray" 2>/dev/null
    pkill -9 -f "$WORKDIR/cloudflared" 2>/dev/null
}

start_process() {
    stop_process
    [ -f "$WORKDIR/xr.json" ] || gen_xray_json

    nohup "$WORKDIR/xray" run -c "$WORKDIR/xr.json" >/dev/null 2>&1 &
    
    if [ "$argo" == "vmpt" ]; then target_port=$vmpt; else target_port=$vwpt; fi
    
    rm -f "$WORKDIR/argo.log"
    ARGS="tunnel --no-autoupdate --edge-ip-version auto --protocol http2"
    
    if [ -n "$agn" ] && [ -n "$agk" ]; then
        nohup "$WORKDIR/cloudflared" $ARGS run --token "$agk" >/dev/null 2>&1 &
        echo "正在启动 Argo 固定隧道 ($agn)..."
    else
        nohup "$WORKDIR/cloudflared" $ARGS --url "http://localhost:$target_port" > "$WORKDIR/argo.log" 2>&1 &
        echo "正在启动 Argo 临时隧道，获取域名中..."
        sleep 5
    fi
}

check_ip_info() {
    echo
    echo "========= 服务器 IP 信息 ========="
    local info=$(curl -s -m 4 http://ip-api.com/json?fields=query,country,isp,status)
    if [[ "$info" == *"success"* ]]; then
        local ip=$(echo "$info" | grep -o '"query":"[^"]*"' | cut -d'"' -f4)
        local c=$(echo "$info" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
        local isp=$(echo "$info" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
        echo "IP: $ip | 地区: $c | ISP: $isp"
    else
        echo "IP 信息获取超时 (不影响节点使用)"
    fi
    echo "=================================="
}

show_list() {
    [ -f "$WORKDIR/conf.env" ] && source "$WORKDIR/conf.env"
    check_ip_info

    local domain=""
    if [ -n "$agn" ] && [ -n "$agk" ]; then
        domain="$agn"
    else
        for i in {1..10}; do
            domain=$(grep -a trycloudflare.com "$WORKDIR/argo.log" 2>/dev/null | grep -v 'cloudflared' | head -n 1 | sed 's|.*https://||;s|.*http://||')
            [ -n "$domain" ] && break
            sleep 1
        done
    fi

    if [ -z "$domain" ]; then
        echo "❌ 错误: Argo 域名未就绪或获取失败，请检查网络/Token。"
        return
    fi

    echo "状态: Xray 运行中 | Argo 隧道: $domain"
    echo "---------------------------------------------------------"

    if [ "$argo" == "vwpt" ]; then
        echo "✅ [推荐] VLESS-WS 节点 (伪装路径: $vl_path):"
        echo "vless://${uuid}@www.visa.com.sg:443?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${vl_path}#${name}-VLESS-WS"
        echo
    fi

    if [ "$argo" == "vmpt" ]; then
        echo "✅ VMess-WS 节点:"
        local vjson="{\"v\":\"2\",\"ps\":\"${name}-VMess-WS\",\"add\":\"www.visa.com.sg\",\"port\":\"443\",\"id\":\"${uuid}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${domain}\",\"path\":\"${vm_path}\",\"tls\":\"tls\",\"sni\":\"${domain}\"}"
        local vlink="vmess://$(echo -n "$vjson" | base64 -w0)"
        echo "$vlink"
        echo
    fi
    echo "========================================================="
}

install_persistence() {
    cat > "$BINDIR/agsbx" << 'EOF'
#!/bin/bash
export PATH="$HOME/bin:$PATH"
bash "$HOME/idx.sh" "$@"
EOF
    chmod +x "$BINDIR/agsbx"

    # 使用单行标签注入，避免多行删除导致 bashrc 语法报错
    sed -i '/agsbx-autostart-hook/d' ~/.bashrc
    echo 'export PATH="$HOME/bin:$PATH" # agsbx-autostart-hook' >> ~/.bashrc
    echo 'pgrep -f "agsbx/xray" >/dev/null 2>&1 || nohup bash "$HOME/idx.sh" res >/dev/null 2>&1 & # agsbx-autostart-hook' >> ~/.bashrc
}

uninstall() {
    echo "正在彻底卸载服务..."
    stop_process
    rm -rf "$WORKDIR" "$HOME/idx.sh" "$BINDIR/agsbx"
    sed -i '/agsbx-autostart-hook/d' ~/.bashrc
    sed -i '/agsbx/d' ~/.bashrc
    echo "✅ 卸载与清理完成。"
}

case "$1" in
    "list")
        show_list ;;
    "res")
        echo "重启服务..."
        check_config; gen_xray_json; start_process; sleep 2; echo "完成"; show_list ;;
    "up"|"update")
        echo "正在强制升级内核..."
        check_config; install_core "1"; gen_xray_json; start_process; sleep 2; echo "升级完毕"; show_list ;;
    "del")
        uninstall ;;
    *)
        check_config; install_core; gen_xray_json; start_process; install_persistence; sleep 3; show_list ;;
esac
SCRIPT_EOF

# 4. 赋予权限并初次执行
chmod +x "$HOME/idx.sh"
bash "$HOME/idx.sh" "$@"
