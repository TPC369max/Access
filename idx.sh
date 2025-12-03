#!/bin/bash

# --- 环境变量处理 ---
export LANG=en_US.UTF-8
# 默认路径
WORKDIR="$HOME/agsbx"
BINDIR="$HOME/bin"
mkdir -p "$WORKDIR" "$BINDIR"

# 接收参数 (如果没有传入则读取本地缓存)
[ -f "$WORKDIR/conf.env" ] && source "$WORKDIR/conf.env"
export uuid=${uuid:-''}
export vmpt=${vmpt:-''}  # VMess 端口
export vwpt=${vwpt:-''}  # VLESS 端口
export argo=${argo:-'vmpt'} # 隧道指向协议: vmpt 或 vwpt
export agn=${agn:-''}    # Argo 域名
export agk=${agk:-''}    # Argo Token
export name=${name:-'IDX'}

# --- 高度伪装路径 & gRPC服务名 ---
# VMess 保持 WS (兼容性好)
export vm_path="/api/v3/video-stream"
# VLESS 改为 gRPC (抗封锁强)，这里是 ServiceName
export vl_service="GrpcAssetService"

# 架构检测
case $(uname -m) in
    aarch64) cpu=arm64;;
    x86_64) cpu=amd64;;
    *) echo "不支持的架构" && exit 1;;
esac

# --- 核心函数 ---

# 1. 检查并生成配置
check_config(){
    if [ -z "$uuid" ]; then uuid=$(cat /proc/sys/kernel/random/uuid); fi
    if [ -z "$vmpt" ]; then vmpt=$(shuf -i 10000-65535 -n 1); fi
    if [ -z "$vwpt" ]; then vwpt=$(shuf -i 10000-65535 -n 1); fi

    cat > "$WORKDIR/conf.env" <<EENV
uuid="$uuid"
vmpt="$vmpt"
vwpt="$vwpt"
argo="$argo"
agn="$agn"
agk="$agk"
name="$name"
vm_path="$vm_path"
vl_service="$vl_service"
EENV
}

# 2. 下载并安装内核
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

# 3. 生成 Xray 配置文件 (VLESS 修改为 gRPC)
gen_xray_json(){
    cat > "$WORKDIR/xr.json" <<EJSON
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
          "network": "grpc", 
          "grpcSettings": { 
              "serviceName": "$vl_service" 
          } 
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EJSON
}

# 4. 启动进程
start_process(){
    pkill -f "$WORKDIR/xray"
    pkill -f "$WORKDIR/cloudflared"
    
    nohup "$WORKDIR/xray" run -c "$WORKDIR/xr.json" >/dev/null 2>&1 &
    
    if [ "$argo" == "vmpt" ]; then target_port=$vmpt; else target_port=$vwpt; fi
    
    rm -f "$WORKDIR/argo.log"
    # Argo 必须启用 http2 协议以支持 gRPC 转发
    if [ -n "$agn" ] && [ -n "$agk" ]; then
        nohup "$WORKDIR/cloudflared" tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token "$agk" >/dev/null 2>&1 &
        echo "启动固定 Argo 隧道 ($agn)..."
    else
        nohup "$WORKDIR/cloudflared" tunnel --url http://localhost:$target_port --edge-ip-version auto --no-autoupdate --protocol http2 > "$WORKDIR/argo.log" 2>&1 &
        echo "启动临时 Argo 隧道，正在获取域名..."
        sleep 5
    fi
}

# 5. IP信息检测
check_ip_info(){
    echo
    echo "=========当前服务器本地IP情况========="
    ip_info=$(curl -s -m 5 http://ip-api.com/json?fields=query,country,isp,status)
    status=$(echo "$ip_info" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
    if [ "$status" == "success" ]; then
        ip=$(echo "$ip_info" | grep -o '"query":"[^"]*"' | cut -d'"' -f4)
        country=$(echo "$ip_info" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
        isp=$(echo "$ip_info" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
        echo "公网IPv4地址：$ip"
        echo "服务器地区：$country"
        echo "运营商(ISP)：$isp"
    else
        v4=$(curl -s4m5 https://api.ip.sb/ip -k)
        loc=$(curl -s4m5 https://api.ip.sb/geoip -k | grep country | cut -d'"' -f4)
        echo "公网IPv4地址：$v4"
        echo "服务器地区：$loc"
    fi
    echo "=========================================="
    echo
}

# 6. 显示节点信息
show_list(){
    source "$WORKDIR/conf.env"
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
        echo "❌ 无法获取 Argo 域名，请检查 Argo 是否启动成功"
        return
    fi

    echo "内核: Xray + Cloudflared ($type_txt)"
    echo "Argo域名: $domain"
    echo "指向协议: $argo (端口: $(if [ "$argo" == "vmpt" ]; then echo $vmpt; else echo $vwpt; fi))"
    echo "---------------------------------------------------------"
    
    # VMess (WS)
    if [ "$argo" == "vmpt" ]; then
        vmess_json="{\"v\":\"2\",\"ps\":\"${name}-VMess-WS\",\"add\":\"www.visa.com.sg\",\"port\":\"443\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$domain\",\"path\":\"$vm_path\",\"tls\":\"tls\",\"sni\":\"$domain\"}"
        vmess_link="vmess://$(echo -n "$vmess_json" | base64 -w0)"
        echo "🚀 VMess 节点 (WS + 伪装路径):"
        echo "$vmess_link"
        echo
    fi

    # VLESS (gRPC) - 修改处
    if [ "$argo" == "vwpt" ]; then
        echo "🚀 VLESS 节点 (gRPC + 抗封锁):"
        echo "Service Name: $vl_service"
        # 注意: type=grpc, mode=gun, serviceName=$vl_service
        echo "vless://$uuid@www.visa.com.sg:443?encryption=none&security=tls&sni=$domain&type=grpc&serviceName=$vl_service&mode=gun&fp=chrome#${name}-VLESS-gRPC"
        echo
    fi
    echo "========================================================="
    echo "提示: 如需使用VLESS-gRPC，请确保脚本启动参数包含 argo='vwpt'"
}

# 7. 持久化
install_persistence(){
    if [ "$0" != "$HOME/idx.sh" ]; then
        cp "$0" "$HOME/idx.sh"
        chmod +x "$HOME/idx.sh"
    fi
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
        check_config; gen_xray_json; start_process; sleep 2; echo "完成！" ;;
    "del") 
        pkill -f "$WORKDIR/xray"; pkill -f "$WORKDIR/cloudflared"
        rm -rf "$WORKDIR" "$HOME/idx.sh" "$BINDIR/agsbx"
        sed -i '/agsbx/d' ~/.bashrc; echo "卸载完成。" ;;
    *) 
        check_config; install_core; gen_xray_json; start_process; install_persistence; sleep 3; show_list ;;
esac
EOF
