# 1. 强制删除损坏的旧文件
rm -rf $HOME/idx.sh $HOME/bin/agsbx $HOME/agsbx/xr.json

# 2. 写入完整的修复版脚本
cat > $HOME/idx.sh << 'SCRIPT_EOF'
#!/bin/bash

# --- 环境变量与默认设置 ---
export LANG=en_US.UTF-8
WORKDIR="$HOME/agsbx"
BINDIR="$HOME/bin"
mkdir -p "$WORKDIR" "$BINDIR"

# 读取保存的配置 (如果存在)
[ -f "$WORKDIR/conf.env" ] && source "$WORKDIR/conf.env"

# 接收外部参数或使用默认值
export uuid=${uuid:-''}
export vmpt=${vmpt:-''}     # VMess 端口
export vwpt=${vwpt:-''}     # VLESS 端口
# 关键: 默认优先使用 VLESS (vwpt) 配合 gRPC，因为抗封锁更强。
# 如果你想用 VMess，请在运行脚本前设置 argo="vmpt"
export argo=${argo:-'vwpt'} 
export agn=${agn:-''}       # 固定域名
export agk=${agk:-''}       # 固定 Token
export name=${name:-'IDX'}

# --- 伪装参数 ---
export vm_path="/api/v3/video-stream"    # VMess-WS 路径
export vl_service="GrpcAssetService"     # VLESS-gRPC 服务名

# --- 架构检测 ---
case $(uname -m) in
    aarch64) cpu=arm64;;
    x86_64) cpu=amd64;;
    *) echo "错误: 不支持的CPU架构" && exit 1;;
esac

# --- 功能函数 ---

# 1. 初始化配置
check_config(){
    # 如果没有ID，生成一个
    if [ -z "$uuid" ]; then uuid=$(cat /proc/sys/kernel/random/uuid); fi
    # 如果没有端口，随机生成
    if [ -z "$vmpt" ]; then vmpt=$(shuf -i 10000-65535 -n 1); fi
    if [ -z "$vwpt" ]; then vwpt=$(shuf -i 10000-65535 -n 1); fi

    # 保存配置，供重启使用
    cat > "$WORKDIR/conf.env" <<EOF
uuid="$uuid"
vmpt="$vmpt"
vwpt="$vwpt"
argo="$argo"
agn="$agn"
agk="$agk"
name="$name"
vm_path="$vm_path"
vl_service="$vl_service"
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

# 3. 生成 Xray 配置 (VMess-WS + VLESS-gRPC)
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
        "clients": [ { "id": "$uuid" } ], 
        "decryption": "none" 
      },
      "streamSettings": { 
        "network": "grpc", 
        "grpcSettings": { "serviceName": "$vl_service" } 
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
}

# 4. 启动进程
start_process(){
    # 清理旧进程
    pkill -f "$WORKDIR/xray"
    pkill -f "$WORKDIR/cloudflared"
    
    # 启动 Xray
    nohup "$WORKDIR/xray" run -c "$WORKDIR/xr.json" >/dev/null 2>&1 &
    
    # 判断 Argo 隧道应该转发哪个端口
    if [ "$argo" == "vmpt" ]; then 
        target_port=$vmpt
        echo "Argo 指向: VMess (端口 $vmpt)"
    else 
        target_port=$vwpt
        echo "Argo 指向: VLESS-gRPC (端口 $vwpt)"
    fi
    
    # 启动 Argo
    rm -f "$WORKDIR/argo.log"
    # 必须开启 http2 以支持 gRPC
    ARGS="tunnel --no-autoupdate --edge-ip-version auto --protocol http2"
    
    if [ -n "$agn" ] && [ -n "$agk" ]; then
        # 固定隧道
        nohup "$WORKDIR/cloudflared" $ARGS run --token "$agk" >/dev/null 2>&1 &
        echo "正在启动 Argo 固定隧道 ($agn)..."
    else
        # 临时隧道
        nohup "$WORKDIR/cloudflared" $ARGS --url http://localhost:$target_port > "$WORKDIR/argo.log" 2>&1 &
        echo "正在启动 Argo 临时隧道，获取域名中..."
        sleep 5
    fi
}

# 5. 显示服务器 IP 信息
check_ip_info(){
    echo
    echo "========= 当前服务器 IP 信息 ========="
    # 尝试获取IP信息
    info=$(curl -s -m 4 http://ip-api.com/json?fields=query,country,isp,status)
    if [[ "$info" == *"success"* ]]; then
        ip=$(echo "$info" | grep -o '"query":"[^"]*"' | cut -d'"' -f4)
        c=$(echo "$info" | grep -o '"country":"[^"]*"' | cut -d'"' -f4)
        isp=$(echo "$info" | grep -o '"isp":"[^"]*"' | cut -d'"' -f4)
        echo "IP地址: $ip"
        echo "地  区: $c"
        echo "运营商: $isp"
    else
        # 备用接口
        v4=$(curl -s4m4 https://api.ip.sb/ip -k)
        echo "IP地址: $v4 (备用接口)"
    fi
    echo "======================================"
}

# 6. 显示节点链接
show_list(){
    source "$WORKDIR/conf.env" 2>/dev/null
    check_ip_info

    # 获取 Argo 域名
    if [ -n "$agn" ] && [ -n "$agk" ]; then
        domain="$agn"
        type_txt="固定隧道"
    else
        # 循环读取日志获取临时域名
        for i in {1..10}; do
            domain=$(grep -a trycloudflare.com "$WORKDIR/argo.log" | grep -v 'cloudflared' | head -n 1 | sed 's|.*https://||;s|.*http://||')
            [ -n "$domain" ] && break
            sleep 1
        done
        type_txt="临时隧道"
    fi

    if [ -z "$domain" ]; then
        echo "❌ 错误: 无法获取 Argo 域名。请检查网络或稍后运行 'agsbx res' 重试。"
        return
    fi

    echo "核心状态: Xray 运行中 | Argo $type_txt"
    echo "Argo域名: $domain"
    echo "---------------------------------------------------------"

    # 1. VLESS-gRPC (推荐)
    # 只有当 argo="vwpt" 时，隧道才通向 VLESS 端口
    if [ "$argo" == "vwpt" ]; then
        echo "✅ [推荐] VLESS-gRPC 节点 (抗封锁强):"
        echo "Service Name: $vl_service"
        # 构造 VLESS 链接
        echo "vless://${uuid}@www.visa.com.sg:443?encryption=none&security=tls&sni=${domain}&type=grpc&serviceName=${vl_service}&mode=gun&fp=chrome#${name}-VLESS-gRPC"
        echo
    fi

    # 2. VMess-WS
    # 只有当 argo="vmpt" 时，隧道才通向 VMess 端口
    if [ "$argo" == "vmpt" ]; then
        echo "✅ VMess-WS 节点 (伪装路径):"
        echo "Path: $vm_path"
        # 构造 VMess JSON
        vjson="{\"v\":\"2\",\"ps\":\"${name}-VMess-WS\",\"add\":\"www.visa.com.sg\",\"port\":\"443\",\"id\":\"${uuid}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${domain}\",\"path\":\"${vm_path}\",\"tls\":\"tls\",\"sni\":\"${domain}\"}"
        vlink="vmess://$(echo -n "$vjson" | base64 -w0)"
        echo "$vlink"
        echo
    fi
    
    echo "========================================================="
    echo "提示: 当前隧道转发协议为 [$(echo $argo | tr 'a-z' 'A-Z')]"
    if [ "$argo" == "vwpt" ]; then
        echo "如需切换为 VMess，请运行: export argo=vmpt && agsbx res"
    else
        echo "如需切换为 VLESS(gRPC)，请运行: export argo=vwpt && agsbx res"
    fi
}

# 7. 系统持久化 (快捷命令 + 开机自启)
install_persistence(){
    # 复制自身到标准路径，确保 agsbx 命令能找到文件
    cp "$0" "$HOME/idx.sh"
    chmod +x "$HOME/idx.sh"

    # 创建 agsbx 命令
    cat > "$BINDIR/agsbx" <<EOF
#!/bin/bash
export PATH="$HOME/bin:\$PATH"
bash "$HOME/idx.sh" "\$1"
EOF
    chmod +x "$BINDIR/agsbx"

    # 注入 .bashrc
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

# --- 主程序逻辑 ---

# 确保以脚本文件形式运行时参数传递正确
if [ "$0" != "$HOME/idx.sh" ] && [ -f "$0" ]; then
    cp "$0" "$HOME/idx.sh"
    chmod +x "$HOME/idx.sh"
fi

case "$1" in
    "list")
        show_list
        ;;
    "res")
        echo "正在重启服务..."
        check_config
        gen_xray_json
        start_process
        sleep 2
        echo "重启完成！"
        show_list
        ;;
    "del")
        pkill -f "$WORKDIR/xray"
        pkill -f "$WORKDIR/cloudflared"
        rm -rf "$WORKDIR" "$HOME/idx.sh" "$BINDIR/agsbx"
        sed -i '/agsbx/d' ~/.bashrc
        echo "卸载完成，清理完毕。"
        ;;
    *)
        # 首次安装流程
        check_config
        install_core
        gen_xray_json
        start_process
        install_persistence
        sleep 3
        show_list
        ;;
esac
SCRIPT_EOF

# 3. 赋予执行权限并启动
chmod +x $HOME/idx.sh && $HOME/idx.sh
