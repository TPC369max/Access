# 1. 清理旧文件
rm -rf $HOME/idx.sh $HOME/bin/agsbx $HOME/agsbx/xr.json

# 2. 写入 VLESS-WS 稳定伪装版脚本
cat > $HOME/idx.sh << 'SCRIPT_EOF'
#!/bin/bash

# --- 环境变量与默认设置 ---
export LANG=en_US.UTF-8
WORKDIR="$HOME/agsbx"
BINDIR="$HOME/bin"
mkdir -p "$WORKDIR" "$BINDIR"

# 读取配置
[ -f "$WORKDIR/conf.env" ] && source "$WORKDIR/conf.env"

# 参数定义
export uuid=${uuid:-''}
export vmpt=${vmpt:-''}     # VMess 端口
export vwpt=${vwpt:-''}     # VLESS 端口
# 默认使用 VLESS (vwpt)
export argo=${argo:-'vwpt'} 
export agn=${agn:-''}       # 固定域名
export agk=${agk:-''}       # 固定 Token
export name=${name:-'IDX'}

# --- 深度伪装路径 (修改处) ---
# 模拟系统更新接口，看起来更像正常流量
export vl_path="/api/v4/system/updates"
export vm_path="/api/v3/video-stream"

# --- 架构检测 ---
case $(uname -m) in
    aarch64) cpu=arm64;;
    x86_64) cpu=amd64;;
    *) echo "错误: 不支持的CPU架构" && exit 1;;
esac

# --- 功能函数 ---

# 1. 初始化配置
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
vl_path="$vl_path"
vm_path="$vm_path"
EOF
}

# 2. 下载内核
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

# 3. 生成 Xray 配置 (VLESS-WS)
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
            "headers": {
                "Host": ""
            }
        } 
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
}

# 4. 启动进程
start_process(){
    pkill -f "$WORKDIR/xray"
    pkill -f "$WORKDIR/cloudflared"
    
    nohup "$WORKDIR/xray" run -c "$WORKDIR/xr.json" >/dev/null 2>&1 &
    
    if [ "$argo" == "vmpt" ]; then target_port=$vmpt; else target_port=$vwpt; fi
    
    rm -f "$WORKDIR/argo.log"
    # 使用 http2 协议连接 Argo 边缘，但内部流量是 WS
    ARGS="tunnel --no-autoupdate --edge-ip-version auto --protocol http2"
    
    if [ -n "$agn" ] && [ -n "$agk" ]; then
        nohup "$WORKDIR/cloudflared" $ARGS run --token "$agk" >/dev/null 2>&1 &
        echo "正在启动 Argo 固定隧道 ($agn)..."
    else
        nohup "$WORKDIR/cloudflared" $ARGS --url http://localhost:$target_port > "$WORKDIR/argo.log" 2>&1 &
        echo "正在启动 Argo 临时隧道，获取域名中..."
        sleep 5
    fi
}

# 5. IP信息
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

# 6. 显示列表
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
        echo "❌ 错误: Argo 域名获取失败，请重试。"
        return
    fi

    echo "状态: Xray (WS模式) | Argo: $domain"
    echo "---------------------------------------------------------"

    # VLESS-WS (稳定推荐)
    if [ "$argo" == "vwpt" ]; then
        echo "✅ [推荐] VLESS-WS 节点 (伪装路径: $vl_path):"
        # 构造标准 VLESS 链接
        echo "vless://${uuid}@www.visa.com.sg:443?encryption=none&security=tls&sni=${domain}&type=ws&host=${domain}&path=${vl_path}#${name}-VLESS-WS"
        echo
    fi

    # VMess-WS
    if [ "$argo" == "vmpt" ]; then
        echo "✅ VMess-WS 节点:"
        vjson="{\"v\":\"2\",\"ps\":\"${name}-VMess-WS\",\"add\":\"www.visa.com.sg\",\"port\":\"443\",\"id\":\"${uuid}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${domain}\",\"path\":\"${vm_path}\",\"tls\":\"tls\",\"sni\":\"${domain}\"}"
        vlink="vmess://$(echo -n "$vjson" | base64 -w0)"
        echo "$vlink"
        echo
    fi
    echo "========================================================="
}

# 7. 持久化
install_persistence(){
    cp "$0" "$HOME/idx.sh" && chmod +x "$HOME/idx.sh"
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
    "res") 
        echo "重启服务..."
        check_config; gen_xray_json; start_process; sleep 2; echo "完成"; show_list ;;
    "del") 
        pkill -f "$WORKDIR/xray"; pkill -f "$WORKDIR/cloudflared"
        rm -rf "$WORKDIR" "$HOME/idx.sh" "$BINDIR/agsbx"
        sed -i '/agsbx/d' ~/.bashrc; echo "卸载完成。" ;;
    *) 
        check_config; install_core; gen_xray_json; start_process; install_persistence; sleep 3; show_list ;;
esac
SCRIPT_EOF

# 3. 运行
chmod +x $HOME/idx.sh && $HOME/idx.sh
