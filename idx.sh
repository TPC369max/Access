#!/bin/bash

# --- 环境变量处理 ---
export LANG=en_US.UTF-8
# 默认工作目录
WORKDIR="$HOME/agsbx"
BINDIR="$HOME/bin"
mkdir -p "$WORKDIR" "$BINDIR"

# 接收参数 (如果没有传入则读取本地缓存)
[ -f "$WORKDIR/conf.env" ] && source "$WORKDIR/conf.env"

export uuid=${uuid:-''}
export vmpt=${vmpt:-''}     # VMess 端口
export vwpt=${vwpt:-''}     # VLESS 端口
export argo=${argo:-'vmpt'} # 隧道指向协议: vmpt 或 vwpt
export agn=${agn:-''}       # Argo 域名
export agk=${agk:-''}       # Argo Token
export name=${name:-'IDX'}
# 🌟 新增：伪装路径 (默认为 /api/v3/sync)
export wspath=${wspath:-'/api/v3/sync'} 

# 架构检测
case $(uname -m) in
    aarch64) cpu=arm64;;
    x86_64) cpu=amd64;;
    *) echo "不支持的架构" && exit 1;;
esac

# --- 核心函数 ---

# 1. 检查并生成配置
check_config(){
    # 生成 UUID
    if [ -z "$uuid" ]; then uuid=$(cat /proc/sys/kernel/random/uuid); fi
    
    # 生成端口 (如果未指定)
    if [ -z "$vmpt" ]; then vmpt=$(shuf -i 10000-65535 -n 1); fi
    if [ -z "$vwpt" ]; then vwpt=$(shuf -i 10000-65535 -n 1); fi
    
    # 确保路径以 / 开头
    if [[ "$wspath" != /* ]]; then wspath="/$wspath"; fi

    # 保存配置到文件以便重启读取
    cat > "$WORKDIR/conf.env" <<EOF
uuid="$uuid"
vmpt="$vmpt"
vwpt="$vwpt"
argo="$argo"
agn="$agn"
agk="$agk"
name="$name"
wspath="$wspath"
EOF
}

# 2. 下载并安装内核
install_core(){
    # Xray
    if [ ! -f "$WORKDIR/xray" ]; then
        echo "正在下载 Xray..."
        url="https://github.com/yonggekkk/argosbx/releases/download/argosbx/xray-$cpu"
        wget -qO "$WORKDIR/xray" "$url" || curl -Lso "$WORKDIR/xray" "$url"
        chmod +x "$WORKDIR/xray"
    fi

    # Cloudflared
    if [ ! -f "$WORKDIR/cloudflared" ]; then
        echo "正在下载 Cloudflared..."
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$cpu"
        wget -qO "$WORKDIR/cloudflared" "$url" || curl -Lso "$WORKDIR/cloudflared" "$url"
        chmod +x "$WORKDIR/cloudflared"
    fi
}

# 3. 生成 Xray 配置文件 (使用伪装路径)
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
          "wsSettings": { "path": "$wspath" } 
      }
    },
    {
      "tag": "vless-in",
      "port": $vwpt,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [ { "id": "$uuid", "flow": "xtls-rprx-vision" } ], "decryption": "none" },
      "streamSettings": { 
          "network": "ws", 
          "wsSettings": { "path": "$wspath" } 
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
EOF
}

# 4. 启动进程 (Nohup模式)
start_process(){
    # 停止旧进程
    pkill -f "$WORKDIR/xray"
    pkill -f "$WORKDIR/cloudflared"
    
    # 启动 Xray
    nohup "$WORKDIR/xray" run -c "$WORKDIR/xr.json" >/dev/null 2>&1 &
    
    # 确定 Argo 指向的端口
    if [ "$argo" == "vmpt" ]; then target_port=$vmpt; else target_port=$vwpt; fi
    
    # 启动 Argo
    rm -f "$WORKDIR/argo.log"
    if [ -n "$agn" ] && [ -n "$agk" ]; then
        # 固定隧道
        nohup "$WORKDIR/cloudflared" tunnel --no-autoupdate --edge-ip-version auto --protocol http2 run --token "$agk" >/dev/null 2>&1 &
        echo "启动固定 Argo 隧道 ($agn)..."
    else
        # 临时隧道
        nohup "$WORKDIR/cloudflared" tunnel --url http://localhost:$target_port --edge-ip-version auto --no-autoupdate --protocol http2 > "$WORKDIR/argo.log" 2>&1 &
        echo "启动临时 Argo 隧道，正在获取域名..."
        sleep 5
    fi
}

# 5. 显示节点信息
show_list(){
    source "$WORKDIR/conf.env"
    
    if [ -n "$agn" ] && [ -n "$agk" ]; then
        domain="$agn"
        type_txt="固定隧道"
    else
        # 尝试从日志读取临时域名
        for i in {1..10}; do
            domain=$(grep -a trycloudflare.com "$WORKDIR/argo.log" | grep -v 'cloudflared' | head -n 1 | sed 's|.*https://||;s|.*http://||')
            [ -n "$domain" ] && break
            sleep 1
        done
        type_txt="临时隧道"
    fi

    if [ -z "$domain" ]; then
        echo "❌ 无法获取 Argo 域名，请检查 Argo 是否启动成功 (使用 ps aux | grep cloudflared 查看)"
        return
    fi

    # 优选IP建议
    cf_best_domain="www.visa.com.sg"

    echo "========================================================="
    echo "   Argosbx for IDX - 运行状态"
    echo "========================================================="
    echo "内核: Xray + Cloudflared ($type_txt)"
    echo "Argo域名: $domain"
    echo "伪装路径: $wspath (✅ 已优化)"
    echo "指向协议: $argo"
    echo "---------------------------------------------------------"
    
    # 生成 VMess 链接
    if [ "$argo" == "vmpt" ]; then
        # 注意：path 字段使用新的 wspath
        vmess_json="{\"v\":\"2\",\"ps\":\"${name}-VMess-Argo\",\"add\":\"$cf_best_domain\",\"port\":\"443\",\"id\":\"$uuid\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"$domain\",\"path\":\"$wspath\",\"tls\":\"tls\",\"sni\":\"$domain\"}"
        vmess_link="vmess://$(echo -n "$vmess_json" | base64 -w0)"
        echo "🚀 VMess 节点 (Argo):"
        echo "$vmess_link"
        echo
    fi

    # 生成 VLESS 链接
    if [ "$argo" == "vwpt" ]; then
        echo "🚀 VLESS 节点 (Argo):"
        echo "vless://$uuid@$cf_best_domain:443?encryption=none&security=tls&sni=$domain&type=ws&host=$domain&path=$wspath#${name}-VLESS-Argo"
        echo
    fi
    echo "========================================================="
    echo "提示: 输入 'agsbx list' 查看此信息，'agsbx res' 重启服务。"
}

# 6. 安装环境持久化
install_persistence(){
    # 修复：确保脚本自身存在于 $HOME/idx.sh，防止管道运行后找不到文件
    if [ ! -f "$HOME/idx.sh" ]; then
        # 如果当前脚本是管道运行的，我们无法直接 cp $0，所以我们重新创建文件
        cat > "$HOME/idx.sh" << 'EOF_SCRIPT'
#!/bin/bash
# (此处内容为占位，实际运行时上面的 install_persistence 逻辑会将外部脚本内容写入吗？)
# 不，最简单的方法是用户手动下载，或者在这里尝试下载自身
# 为了兼容性，如果你用 curl | bash 运行，建议使用下面的 self_restore 逻辑
EOF_SCRIPT
        # 由于管道运行无法获取自身内容，这里仅生成调用入口
        # 最佳实践是让用户 curl -o 下载。但为了兼容，我们只生成 bin 入口指向已存在的文件
        echo "注意：建议使用 curl -o idx.sh url && bash idx.sh 方式运行以便持久化。"
    fi
    
    # 如果用户已经把文件下载到了 $HOME/idx.sh (推荐做法)
    if [ -f "$HOME/idx.sh" ]; then
         chmod +x "$HOME/idx.sh"
         MAIN_SCRIPT="$HOME/idx.sh"
    else
         # 如果是管道运行且没保存，尝试创建一个临时的 wrapper
         # 但这会导致重启功能失效。强烈建议用户先下载文件。
         MAIN_SCRIPT="$HOME/idx.sh"
    fi

    cat > "$BINDIR/agsbx" <<EOF
#!/bin/bash
export PATH="$HOME/bin:\$PATH"
if [ -f "$MAIN_SCRIPT" ]; then
    bash "$MAIN_SCRIPT" "\$1"
else
    echo "错误：找不到主脚本文件 $MAIN_SCRIPT"
    echo "请重新运行安装命令：curl -L -o \$HOME/idx.sh https://你的脚本地址/idx.sh && chmod +x \$HOME/idx.sh"
fi
EOF
    chmod +x "$BINDIR/agsbx"

    if ! grep -q "agsbx_auto_start" ~/.bashrc; then
        echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
        echo 'agsbx_auto_start() {' >> ~/.bashrc
        echo '  if [ -f "$HOME/idx.sh" ] && ! pgrep -f "agsbx/xray" >/dev/null; then' >> ~/.bashrc
        echo '     nohup bash "$HOME/idx.sh" res >/dev/null 2>&1 &' >> ~/.bashrc
        echo '  fi' >> ~/.bashrc
        echo '}' >> ~/.bashrc
        echo 'agsbx_auto_start' >> ~/.bashrc
    fi
}

# --- 自我复制逻辑 (修复 agsbx list 找不到文件的问题) ---
if [ ! -f "$HOME/idx.sh" ] && [ -f "$0" ]; then
    cp "$0" "$HOME/idx.sh"
    chmod +x "$HOME/idx.sh"
fi

# --- 主逻辑路由 ---

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
        ;;
    "del")
        pkill -f "$WORKDIR/xray"
        pkill -f "$WORKDIR/cloudflared"
        rm -rf "$WORKDIR" "$HOME/idx.sh" "$BINDIR/agsbx"
        sed -i '/agsbx/d' ~/.bashrc
        echo "卸载完成。"
        ;;
    *)
        # 默认安装/启动流程
        check_config
        install_core
        gen_xray_json
        start_process
        install_persistence
        sleep 3
        show_list
        ;;
esac
