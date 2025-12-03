# 1. 清理旧文件
rm -rf $HOME/idx.sh $HOME/agsbx

# 2. 写入修复版脚本 (VLESS-WS 版)
cat > $HOME/idx.sh << 'SCRIPT_EOF'
#!/bin/bash

# --- 环境变量处理 ---
export LANG=en_US.UTF-8
WORKDIR="$HOME/agsbx"
BINDIR="$HOME/bin"
mkdir -p "$WORKDIR" "$BINDIR"

[ -f "$WORKDIR/conf.env" ] && source "$WORKDIR/conf.env"

# 参数定义
export uuid=${uuid:-''}
export vmpt=${vmpt:-''}     
export vwpt=${vwpt:-''}     
# 默认优先使用 VLESS (vwpt)
export argo=${argo:-'vwpt'} 
export agn=${agn:-''}       
export agk=${agk:-''}       
export name=${name:-'IDX'}

# --- 高度伪装路径 (Websocket) ---
# 模拟普通的文件下载或API流
export vm_path="/api/v3/video-stream"    
export vl_path="/api/v3/download/assets" 

# 架构检测
case $(uname -m) in
    aarch64) cpu=arm64;;
    x86_64) cpu=amd64;;
    *) echo "错误: 不支持的架构" && exit 1;;
esac

# --- 功能模块 ---

check_config(){
    if [ -z "$uuid" ]; then uuid=$(cat /proc/sys/kernel/random/uuid); fi
    if [ -z "$vmpt" ]; then vmpt=$(shuf -i 10000-65535 -n 1); fi
    if [ -z "$vwpt" ]; then vwpt=$(shuf -i 10000-65535 -n 1); fi

    cat > "$WORKDIR/conf.env" <<EOF
uuid="$uuid"
vmpt="$vmpt"
vwpt="$vwpt"
argo="$argo"
agn="$agn"
agk="$agk"
name="$name"
vm_path="$vm_path"
vl_path="$vl_path"
EOF
}

install_core(){
    if [ ! -f "$WORKDIR/xray" ]; then
        echo "正在下载 Xray..."
        url="https://github.com/yonggekkk/argosbx/releases/download/argosbx/xray-$cpu"
        wget -qO "$WORKDIR/xray" "$url" || curl -Lso "$WORKDIR/xray" "$url"
        chmod +x "$WORKDIR/xray"
    fi
    if [ ! -f "$WORKDIR/cloudflared" ]; then
        echo "正在下载 Cloudflared..."
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cpu"
        wget -qO "$WORKDIR/cloudflared" "$url" || curl -Lso "$WORKDIR/cloudflared" "$url"
        chmod +x "$WORKDIR/cloudflared"
    fi
}

gen_xray_json(){
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
      "streamSettings": { 
        "network": "ws", 
        "wsSettings": { "path": "$vm_path" } 
      }
    },
    {
      "tag": "vless-in",
      "port": $vwpt,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { 
        "clients": [ { "id": "$uuid", "flow": "xtls-rprx-vision" } ], 
        "decryption": "none" 
      },
      "streamSettings": { 
        "network": "ws", 
        "wsSettings": { "path": "$vl_path" } 
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
}

start_process(){
    pkill -f "$WORKDIR/xray"
    pkill -f "$WORKDIR/cloudflared"
    
    nohup "$WORKDIR/xray" run -c "$WORKDIR/xr.json" >/dev/null 2>&1 &
    
    if [ "$argo" == "vmpt" ]; then target_port=$vmpt; else target_port=$vwpt; fi
    
    rm -f "$WORKDIR/argo.log"
    # 标准 http2 协议，完美支持 WS
    ARGS="tunnel --no-autoupdate --edge-ip-version auto --protocol http2"
    
    if [ -n "$agn" ] && [ -n "$agk" ]; then
        nohup "$WORKDIR/cloudflared" $ARGS run --token "$agk" >/dev/null 2>&1 &
        echo "启动 Argo 固定隧道 ($agn)..."
    else
        nohup "$WORKDIR/cloudflared" $ARGS --url http://localhost:$target_port > "$WORKDIR/argo.log" 2>&1 &
        echo "启动 Argo 临时隧道，获取域名中..."
        sleep 5
    fi
}

check_ip_info(){
    echo
    echo "========= 服务器 IP 信息 ========="
    info=$(curl -s -m 4 http://ip-api.com/json?fields=query,country,isp,status)
    if [[ "$info" == *"success"* ]]; then
        ip=$(echo "$info" | grep -o '"query":"[^"]*"' | cut -d'"' -f4)
        c=$(echo "$info" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
        isp=$(echo "$info" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
        echo "IP: $ip | 地区: $c | ISP: $isp"
    else
        echo "IP信息获取超时 (不影响节点使用)"
    fi
    echo "=================================="
}

show_list(){
    source "$WORKDIR/conf.env" 2>/dev/null
    check_ip_info

    if [ -n "$agn" ] && [ -n "$agk" ]; then
        domain="$agn"
        type_txt="固定隧道"
    else
        for i in {1..10}; do
            domain=$(grep -a trycloudflare.com "$WORKDIR/argo.log" | grep -v 'cloudflared' | head -n 1 | sed 's|.*https://||;s|.*http://||')
            [ -n "$domain" ] && break
            sleep 1
        done
        type_txt="临时隧道"
    fi

    if [ -z "$domain" ]; then
        echo "❌ 无法获取 Argo 域名，请稍后重试。"
        return
    fi

    echo "协议: Xray + Cloudflared ($type_txt)"
    echo "域名: $domain"
    echo "---------------------------------------------------------"

    if [ "$argo" == "vwpt" ]; then
        echo "✅ [稳定] VLESS-WS 节点 (伪装路径):"
        echo "Path: $vl_path"
        # 构造 VLESS-WS 链接 (去掉流控参数，因为过CDN/Tunnel时Vision流控不生效且会导致问题)
        echo "vless://${uuid}@www.visa.com.sg:443?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${vl_path}#${name}-VLESS-WS"
        echo
    fi

    if [ "$argo" == "vmpt" ]; then
        echo "✅ VMess-WS 节点:"
        vjson="{\"v\":\"2\",\"ps\":\"${name}-VMess-WS\",\"add\":\"www.visa.com.sg\",\"port\":\"443\",\"id\":\"${uuid}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${domain}\",\"path\":\"${vm_path}\",\"tls\":\"tls\",\"sni\":\"${domain}\"}"
        echo "vmess://$(echo -n "$vjson" | base64 -w0)"
        echo
    fi
    
    echo "========================================================="
    echo "提示: 当前指向端口为 [$argo]。如连不上请检查域名是否被墙。"
}

install_persistence(){
    cp "$0" "$HOME/idx.sh"
    chmod +x "$HOME/idx.sh"
    cat > "$BINDIR/agsbx" <<EOF
#!/bin/bash
export PATH="$HOME/bin:\$PATH"
bash "$HOME/idx.sh" "\$1"
EOF
    chmod +x "$BINDIR/agsbx"

    if ! grep -q "agsbx_auto_start" ~/.bashrc; then
        echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
        echo 'agsbx_auto_start() {' >> ~/.bashrc
        echo '  if ! pgrep -f "agsbx/xray" >/dev/null; then' >> ~/.bashrc
        echo '     nohup bash "$HOME/idx.sh" res >/dev/null 2>&1 &' >> ~/.bashrc
        echo '  fi' >> ~/.bashrc
        echo '}' >> ~/.bashrc
        echo 'agsbx_auto_start' >> ~/.bashrc
    fi
}

case "$1" in
    "list") show_list ;;
    "res") echo "重启中..."; check_config; gen_xray_json; start_process; sleep 2; echo "完成"; show_list ;;
    "del") pkill -f "$WORKDIR/xray"; pkill -f "$WORKDIR/cloudflared"; rm -rf "$WORKDIR" "$HOME/idx.sh" "$BINDIR/agsbx"; sed -i '/agsbx/d' ~/.bashrc; echo "已卸载" ;;
    *) check_config; install_core; gen_xray_json; start_process; install_persistence; sleep 3; show_list ;;
esac
SCRIPT_EOF

# 3. 运行
chmod +x $HOME/idx.sh && $HOME/idx.sh
