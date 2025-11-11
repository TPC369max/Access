#!/bin/sh
export LANG=en_US.UTF-8

# --- 用户需配置的变量 ---
# 在运行脚本前，必须通过环境变量提供这些值
# 示例:
export ARGO_AUTH="eyJhIjoiNTFhZWVmNTkyMGVhZTE4NzE5NzVkMzdmNTRjODc1ZTYiLCJ0IjoiNzhkNWVmM2EtODVhOS00YWRjLTgwMmQtYzY1NDFjZTE3N2MzIiwicyI6Ik9XRTRaV0V6WVdZdE5UaGxNQzAwT0dFd0xXRXlOekV0WlRKa05URmlabU5rTldJMiJ9"
export CLIENT_PUBLIC_KEY="VPkUM1Ida1ID/TDK1rfU7WoBB41AKKwPXvOj7deQDjU="
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

# 函数：如果二进制文件不存在，则下载它
download_binary() {
  local url="$1"
  local out_path="$2"
  if [ ! -f "$out_path" ]; then
    echo "正在下载 $(basename "$out_path")..."
    # 自动选择 curl 或 wget 进行下载
    if command -v curl >/dev/null 2>&1; then
      curl -L -# -o "$out_path" "$url"
    elif command -v wget >/dev/null 2>&1; then
      wget -q -O "$out_path" "$url"
    else
      echo "错误: 系统中没有 curl 或 wget，无法下载所需工具。"
      exit 1
    fi
    chmod +x "$out_path"
  fi
}

# 下载所有必需的工具
setup_tools() {
  local arch=$(get_arch)
  echo "检测到架构: $arch"
  # 下载 Cloudflared
  download_binary "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch" "$WORKDIR/cloudflared"
  # 下载 wireguard-go
  download_binary "https://github.com/yonggekkk/argosbx/releases/download/argosbx/wireguard-go-linux-$arch" "$WORKDIR/wireguard-go"
  # 下载 wg 工具用于生成密钥
  download_binary "https://github.com/yonggekkk/argosbx/releases/download/argosbx/wg-linux-$arch" "$WORKDIR/wg"
}

# 生成 WireGuard 服务端配置
generate_wireguard_config() {
  echo "正在生成 WireGuard 服务端配置..."

  # 如果服务端的密钥不存在，则生成新的
  if [ ! -f "$WORKDIR/server_private.key" ]; then
    echo "生成新的服务端密钥对..."
    "$WORKDIR/wg" genkey > "$WORKDIR/server_private.key"
    "$WORKDIR/wg" pubkey < "$WORKDIR/server_private.key" > "$WORKDIR/server_public.key"
  fi

  SERVER_PRIVATE_KEY=$(cat "$WORKDIR/server_private.key")
  SERVER_PUBLIC_KEY=$(cat "$WORKDIR/server_public.key")

  # 创建 WireGuard 配置文件 wg0.conf
  cat > "$WORKDIR/wg0.conf" << EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
ListenPort = ${WG_PORT}

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = 10.0.0.2/32
EOF

  echo "服务端公钥: ${SERVER_PUBLIC_KEY}"
}

# 停止所有正在运行的相关服务
stop_services() {
  echo "正在停止旧的服务进程..."
  pkill -f "$WORKDIR/wireguard-go"
  pkill -f "$WORKDIR/cloudflared"
  sleep 2
}

# 运行 wireguard-go 和 cloudflared 服务
run_services() {
  stop_services

  echo "正在启动 wireguard-go 服务..."
  # 运行 wireguard-go 进程到后台
  nohup "$WORKDIR/wireguard-go" "$WORKDIR/wg0.conf" > "$WORKDIR/wg.log" 2>&1 &
  sleep 3

  # 检查 wireguard-go 是否成功启动
  if ! pgrep -f "$WORKDIR/wireguard-go" > /dev/null; then
    echo "错误: wireguard-go 启动失败。请检查日志: $WORKDIR/wg.log"
    cat "$WORKDIR/wg.log"
    exit 1
  fi

  echo "正在启动 Cloudflared Argo 隧道..."
  # 运行 cloudflared 进程到后台，协议使用 quic 以获得更好的 UDP 性能
  nohup "$WORKDIR/cloudflared" tunnel --no-autoupdate --edge-ip-version auto --protocol quic run --token "${ARGO_AUTH}" > "$WORKDIR/argo.log" 2>&1 &
  sleep 8 # 等待隧道建立连接

  # 检查 cloudflared 是否成功启动
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

  # 尝试从 Argo 日志中自动获取隧道的 CNAME 主机名
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
  echo "# 允许路由的IP"
  echo "AllowedIPs = 0.0.0.0/0, ::/0"
  echo "# Argo 隧道端点地址"
  echo "Endpoint = ${TUNNEL_HOSTNAME}:${WG_PORT}"
  echo "# 保持连接"
  echo "PersistentKeepalive = 25"
  echo "----------------------------------------"
}

# --- 主程序执行流程 ---
setup_tools
generate_wireguard_config
run_services
display_client_config
