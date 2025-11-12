#!/bin/sh
export LANG=en_US.UTF-8

# --- 用户需配置的变量 ---
# 在运行脚本前，必须通过环境变量提供这些值
# 示例:
export ARGO_AUTH="eyJhIjoiNTFhZWVmNTkyMGVhZTE4NzE5NzVkMzdmNTRjODc1ZTYiLCJ0IjoiNzhkNWVmM2EtODVhOS00YWRjLTgwMmQtYzY1NDFjZTE3N2MzIiwicyI6Ik9XRTRaV0V6WVdZdE5UaGxNQzAwT0dFd0xXRXlOekV0WlRKa05URmlabU5rTldJMiJ9"
export CLIENT_PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
export WG_PORT="51820"

# WireGuard 内部监听的 UDP 端口，默认为 51820
: "${WG_PORT:=51820}"
# 检查 Cloudflare 隧道 Token 是否已设置
: "${ARGO_AUTH:?错误: 环境变量 ARGO_AUTH (Cloudflare 隧道 Token) 未设置。}"
# 检查 WireGuard 客户端公钥是否已设置
: "${CLIENT_PUBLIC_KEY:?错误: 环境变量 CLIENT_PUBLIC_KEY (你的客户端公钥) 未设置。}"

# --- 脚本主要逻辑 ---
WORKDIR="$HOME/agsbx"
echo "工作目录: $WORKDIR"
mkdir -p "$WORKDIR"

# 函数：判断 CPU 架构
get_arch() {
  case $(uname -m) in
    aarch64) cpu=arm64;;
    x86_64) cpu=amd64;;
    *) echo "错误: 不支持的 CPU 架构 $(uname -m)." && exit 1;;
  esac
  echo "$cpu"
}

# 下载并解压 Sing-box
download_singbox() {
  local arch=$(get_arch)
  if [ ! -f "$WORKDIR/sing-box" ]; then
    echo "正在下载最新版 Sing-box..."
    # 从官方 GitHub Releases 下载，确保是最新版本
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_VERSION" ]; then
        echo "错误: 无法获取 Sing-box 最新版本号，请检查网络。"
        exit 1
    fi
    echo "最新版本为: $LATEST_VERSION"
    URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VERSION}/sing-box-${LATEST_VERSION#v}-linux-${arch}.tar.gz"
    
    # 下载并直接解压到工作目录
    if command -v curl >/dev/null 2>&1; then
      curl -Ls "$URL" | tar -xz -C "$WORKDIR" --strip-components=1 "sing-box-${LATEST_VERSION#v}-linux-${arch}/sing-box"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- "$URL" | tar -xz -C "$WORKDIR" --strip-components=1 "sing-box-${LATEST_VERSION#v}-linux-${arch}/sing-box"
    else
      echo "错误: 系统中没有 curl 或 wget，无法下载所需工具。"
      exit 1
    fi
    chmod +x "$WORKDIR/sing-box"
  fi
}


# 下载 Cloudflared
download_cloudflared() {
    local arch=$(get_arch)
    if [ ! -f "$WORKDIR/cloudflared" ]; then
        echo "正在下载 Cloudflared..."
        URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch"
        if command -v curl >/dev/null 2>&1; then
            curl -Ls -o "$WORKDIR/cloudflared" "$URL"
        elif command -v wget >/dev/null 2>&1; then
            wget -q -O "$WORKDIR/cloudflared" "$URL"
        fi
        chmod +x "$WORKDIR/cloudflared"
    fi
}

# 生成 Sing-box 配置和 WireGuard 密钥
generate_config() {
  echo "正在生成 Sing-box 配置文件和 WireGuard 密钥..."

  # 如果服务端的密钥不存在，则使用 sing-box 生成新的
  if [ ! -f "$WORKDIR/server_private.key" ]; {
    echo "生成新的服务端密钥对..."
    KEY_PAIR=$("$WORKDIR/sing-box" generate wireguard-keypair)
    echo "$KEY_PAIR" | grep "private_key" | awk -F '"' '{print $4}' > "$WORKDIR/server_private.key"
    echo "$KEY_PAIR" | grep "public_key" | awk -F '"' '{print $4}' > "$WORKDIR/server_public.key"
  }
  fi

  SERVER_PRIVATE_KEY=$(cat "$WORKDIR/server_private.key")
  SERVER_PUBLIC_KEY=$(cat "$WORKDIR/server_public.key")

  # 创建 Sing-box 配置文件 config.json
  cat > "$WORKDIR/config.json" << EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "wireguard",
      "tag": "wg-in",
      "listen_port": ${WG_PORT},
      "private_key": "${SERVER_PRIVATE_KEY}",
      "peers": [
        {
          "public_key": "${CLIENT_PUBLIC_KEY}",
          "allowed_ips": [
            "10.0.0.2/32"
          ],
          "reserved": [0, 0, 0]
        }
      ]
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
  echo "服务端公钥: ${SERVER_PUBLIC_KEY}"
}

# 停止所有正在运行的相关服务
stop_services() {
  echo "正在停止旧的服务进程..."
  pkill -f "$WORKDIR/sing-box"
  pkill -f "$WORKDIR/cloudflared"
  sleep 2
}

# 运行服务
run_services() {
  stop_services

  echo "正在启动 Sing-box 服务..."
  nohup "$WORKDIR/sing-box" run -c "$WORKDIR/config.json" > "$WORKDIR/sing-box.log" 2>&1 &
  sleep 3
  if ! pgrep -f "$WORKDIR/sing-box" > /dev/null; then
    echo "错误: Sing-box 启动失败。请检查日志: $WORKDIR/sing-box.log"
    cat "$WORKDIR/sing-box.log"
    exit 1
  fi

  echo "正在启动 Cloudflared Argo 隧道..."
  # 关键：使用 --url udp://localhost:PORT 来转发UDP流量
  nohup "$WORKDIR/cloudflared" tunnel --no-autoupdate --edge-ip-version auto --protocol quic run --url udp://localhost:${WG_PORT} --token "${ARGO_AUTH}" > "$WORKDIR/argo.log" 2>&1 &
  sleep 8
  if ! pgrep -f "$WORKDIR/cloudflared" > /dev/null; then
    echo "错误: cloudflared 启动失败。请检查日志: $WORKDIR/argo.log"
    cat "$WORKDIR/argo.log"
    exit 1
  fi

  echo "服务启动成功。"
}

# 显示客户端配置文件
display_client_config() {
  SERVER_PUBLIC_KEY=$(cat "$WORKDIR/server_public.key")
  TUNNEL_HOSTNAME=$(grep -oE '[a-z0-9-]+\.cfargotunnel\.com' "$WORKDIR/argo.log" | head -n 1)

  if [ -z "$TUNNEL_HOSTNAME" ]; then
      echo "未能自动从日志中检测到隧道主机名。"
      echo "请登录 Cloudflare Zero Trust 仪表板查看你的隧道 CNAME 地址。"
      echo "它通常是 '你的隧道ID.cfargotunnel.com' 这种格式。"
      TUNNEL_HOSTNAME="<你的隧道主机名>"
  fi

  echo
  echo "--- WireGuard 客户端配置 ---"
  echo "请将以下内容复制到你的 WireGuard 客户端中:"
  echo
  echo "[Interface]"
  echo "# 客户端私钥"
  echo "PrivateKey = [请粘贴你的客户端私钥]"
  echo "# 客户端IP地址"
  echo "Address = 10.0.0.2/32"
  echo "DNS = 1.1.1.1, 8.8.8.8"
  echo
  echo "[Peer]"
  echo "# 服务端公钥"
  echo "PublicKey = ${SERVER_PUBLIC_KEY}"
  echo "# 允许路由的IP (全局流量)"
  echo "AllowedIPs = 0.0.0.0/0, ::/0"
  echo "# Argo 隧道端点地址"
  echo "Endpoint = ${TUNNEL_HOSTNAME}:${WG_PORT}"
  echo "# 保持连接，防止断线"
  echo "PersistentKeepalive = 25"
  echo "----------------------------------------"
}

# --- 主程序执行流程 ---
download_singbox
download_cloudflared
generate_config
run_services
display_client_config
