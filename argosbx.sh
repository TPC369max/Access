#!/bin/sh
export LANG=en_US.UTF-8

# --- 用户需配置的变量 ---
# 示例:
export ARGO_AUTH="eyJhIjoiNTFhZWVmNTkyMGVhZTE4NzE5NzVkMzdmNTRjODc1ZTYiLCJ0IjoiNzhkNWVmM2EtODVhOS00YWRjLTgwMmQtYzY1NDFjZTE3N2MzIiwicyI6Ik9XRTRaV0V6WVdZdE5UaGxNQzAwT0dFd0xXRXlOekV0WlRKa05URmlabU5rTldJMiJ9"
export CLIENT_PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

: "${WG_PORT:=51820}"
: "${ARGO_AUTH:?错误: 环境变量 ARGO_AUTH (Cloudflare 隧道 Token) 未设置。}"
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

# 函数：下载二进制文件并验证
download_binary() {
  local url="$1"
  local out_path="$2"
  local binary_name=$(basename "$out_path")

  if [ -f "$out_path" ]; then
    echo "${binary_name} 已存在，跳过下载。"
    return
  fi

  echo "--> 正在从以下链接下载 ${binary_name}:"
  echo "    ${url}"
  
  # 使用 curl 的 -fsSL 选项: f=失败时报错, s=静默, S=显示错误, L=跟随跳转
  if command -v curl >/dev/null 2>&1; then
    if ! curl -fsSL -o "$out_path" "$url"; then
      echo "!!! 错误: 使用 curl 下载 ${binary_name} 失败。"
      echo "    请手动复制上面的链接到浏览器，检查它是否可以访问。"
      exit 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget -q -O "$out_path" "$url"; then
      echo "!!! 错误: 使用 wget 下载 ${binary_name} 失败。"
      exit 1
    fi
  else
    echo "错误: 系统中没有 curl 或 wget。"
    exit 1
  fi

  # 验证下载的文件大小是否 > 0
  if [ -s "$out_path" ]; then
    chmod +x "$out_path"
    echo "${binary_name} 下载成功。"
  else
    echo "!!! 错误: ${binary_name} 下载失败，文件为空或下载不完整。"
    rm -f "$out_path"
    exit 1
  fi
}

# 下载所有必需的工具
setup_tools() {
  local arch=$(get_arch)
  echo "检测到架构: $arch"
  download_binary "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch" "$WORKDIR/cloudflared"

  # --- [核心修改] 更换为 nekohasekai 维护的、更稳定的 wireguard-go 链接 ---
  download_binary "https://github.com/nekohasekai/wireguard-go/releases/download/v0.0.20220316/wireguard-go-linux-$arch" "$WORKDIR/wireguard-go"

  # wg 工具的链接目前仍然有效，暂时保留
  download_binary "https://github.com/yonggekkk/argosbx/releases/download/argosbx/wg-linux-$arch" "$WORKDIR/wg"
}

# 生成 WireGuard 服务端配置
generate_wireguard_config() {
  echo "正在生成 WireGuard 服务端配置..."
  if [ ! -f "$WORKDIR/server_private.key" ]; then
    "$WORKDIR/wg" genkey > "$WORKDIR/server_private.key"
    "$WORKDIR/wg" pubkey < "$WORKDIR/server_private.key" > "$WORKDIR/server_public.key"
  fi
  SERVER_PRIVATE_KEY=$(cat "$WORKDIR/server_private.key")
  SERVER_PUBLIC_KEY=$(cat "$WORKDIR/server_public.key")
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

# 停止服务
stop_services() {
  echo "正在停止旧的服务进程..."
  pkill -f "$WORKDIR/wireguard-go"
  pkill -f "$WORKDIR/cloudflared"
  sleep 1
}

# 运行服务
run_services() {
  stop_services
  echo "正在启动 wireguard-go 服务..."
  nohup "$WORKDIR/wireguard-go" "$WORKDIR/wg0.conf" > "$WORKDIR/wg.log" 2>&1 &
  sleep 3
  if ! pgrep -f "$WORKDIR/wireguard-go" > /dev/null; then
    echo "错误: wireguard-go 启动失败。请检查日志: $WORKDIR/wg.log"
    cat "$WORKDIR/wg.log"
    exit 1
  fi
  echo "正在启动 Cloudflared Argo 隧道..."
  nohup "$WORKDIR/cloudflared" tunnel --no-autoupdate --edge-ip-version auto --protocol quic run --token "${ARGO_AUTH}" > "$WORKDIR/argo.log" 2>&1 &
  sleep 8
  if ! pgrep -f "$WORKDIR/cloudflared" > /dev/null; then
    echo "错误: cloudflared 启动失败。请检查日志: $WORKDIR/argo.log"
    cat "$WORKDIR/argo.log"
    exit 1
  fi
  echo "服务启动成功。"
}

# 显示客户端配置
display_client_config() {
  SERVER_PUBLIC_KEY=$(cat "$WORKDIR/server_public.key")
  TUNNEL_HOSTNAME=$(grep -oE '[a-z0-9-]+\.cfargotunnel\.com' "$WORKDIR/argo.log" | head -n 1)
  if [ -z "$TUNNEL_HOSTNAME" ]; then
      TUNNEL_HOSTNAME="<请从Cloudflare仪表板或argo.log中查找隧道主机名>"
  fi
  echo
  echo "--- WireGuard 客户端配置 ---"
  echo "[Interface]"
  echo "PrivateKey = [请粘贴你的客户端私钥]"
  echo "Address = 10.0.0.2/32"
  echo "DNS = 1.1.1.1, 8.8.8.8"
  echo
  echo "[Peer]"
  echo "PublicKey = ${SERVER_PUBLIC_KEY}"
  echo "AllowedIPs = 0.0.0.0/0, ::/0"
  echo "Endpoint = ${TUNNEL_HOSTNAME}:${WG_PORT}"
  echo "PersistentKeepalive = 25"
  echo "----------------------------------------"
}

# --- 主程序执行流程 ---
if [ -d "$WORKDIR" ]; then
    echo "检测到旧目录，正在清理..."
    stop_services
    rm -rf "$WORKDIR"
fi
mkdir -p "$WORKDIR"

setup_tools
generate_wireguard_config
run_services
display_client_config
