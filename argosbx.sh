#!/bin/sh
export LANG=en_US.UTF-8

# --- 用户需配置的变量 ---
# 示例:
export ARGO_AUTH="eyJhIjo...你的...token...7In0="
export CLIENT_PUBLIC_KEY="bCeh...你的客户端公钥...="

: "${WG_PORT:=51820}"
: "${ARGO_AUTH:?错误: 环境变量 ARGO_AUTH (Cloudflare 隧道 Token) 未设置。}"
: "${CLIENT_PUBLIC_KEY:?错误: 环境变量 CLIENT_PUBLIC_KEY (你的客户端公钥) 未设置。}"

# --- 脚本主要逻辑 ---
WORKDIR="$HOME/agsbx"
echo "工作目录: $WORKDIR"

# 函数：判断 CPU 架构
get_arch() {
  case $(uname -m) in
    aarch64) cpu=arm64;;
    x86_64) cpu=amd64;;
    *) echo "错误: 不支持的 CPU 架构 $(uname -m)." && exit 1;;
  esac
  echo "$cpu"
}

# 函数：下载 sing-box 并进行验证
download_singbox() {
  local out_path="$WORKDIR/sing-box"
  if [ -f "$out_path" ]; then
    echo "sing-box 已存在，跳过下载。"
    return
  fi

  local arch=$(get_arch)
  # 使用官方 GitHub Release 的下载链接，但需要解压，这里为了方便继续用 argosbx 作者提供的直链
  local url="https://github.com/yonggekkk/argosbx/releases/download/argosbx/sing-box-linux-$arch"

  echo "正在下载 sing-box..."
  if command -v curl >/dev/null 2>&1; then
    curl -L --fail -o "$out_path" "$url"
  else
    wget -q -O "$out_path" "$url"
  fi

  if [ -f "$out_path" ] && head -c 4 "$out_path" | grep -q $'\x7fELF'; then
    echo "sing-box 下载成功并验证为有效的可执行文件。"
    chmod +x "$out_path"
  else
    echo "错误: sing-box 下载失败或文件格式不正确！"
    rm -f "$out_path"
    exit 1
  fi
}

# 使用 sing-box 生成 WireGuard 服务端配置
generate_config() {
  echo "正在生成 WireGuard 服务端配置..."

  # 如果密钥不存在，则使用 sing-box 生成
  if [ ! -f "$WORKDIR/server_private.key" ]; then
    key_pair=$("$WORKDIR/sing-box" generate wireguard-keypair)
    echo "$key_pair" | awk '/private_key/ {print $2}' | tr -d ',"' > "$WORKDIR/server_private.key"
    echo "$key_pair" | awk '/public_key/ {print $2}' | tr -d ',"' > "$WORKDIR/server_public.key"
  fi

  SERVER_PRIVATE_KEY=$(cat "$WORKDIR/server_private.key")
  SERVER_PUBLIC_KEY=$(cat "$WORKDIR/server_public.key")

  # 创建 sing-box 的 JSON 配置文件
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
      "peer_public_key": "${CLIENT_PUBLIC_KEY}",
      "reserved": [0,0,0],
      "server_address": "10.0.0.1/24",
      "peer_address": "10.0.0.2/32"
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
  sleep 1
}

# 运行服务
run_services() {
  stop_services
  echo "正在启动 sing-box 服务..."
  nohup "$WORKDIR/sing-box" run -c "$WORKDIR/config.json" > "$WORKDIR/sing-box.log" 2>&1 &
  sleep 2
  if ! pgrep -f "$WORKDIR/sing-box" > /dev/null; then
    echo "错误: sing-box 启动失败。请检查日志: $WORKDIR/sing-box.log"
    cat "$WORKDIR/sing-box.log"
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

# 显示客户端配置文件
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
  echo "Address = 10.0.0.2/24"
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
if [ "$1" = "clean" ]; then
    echo "正在执行清理..."
    stop_services
    rm -rf "$WORKDIR"
    echo "清理完成。"
    exit
fi

stop_services
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

download_singbox
# Cloudflared 仍然需要下载
download_binary() {
    local url="$1" out_path="$2" binary_name=$(basename "$out_path")
    if [ ! -f "$out_path" ]; then echo "正在下载 ${binary_name}..."; if command -v curl >/dev/null 2>&1; then curl -L --fail -o "$out_path" "$url"; else wget -q -O "$out_path" "$url"; fi; if [ -f "$out_path" ] && head -c 4 "$out_path" | grep -q $'\x7fELF'; then echo "${binary_name} 下载成功并验证为有效的可执行文件。"; chmod +x "$out_path"; else echo "错误: ${binary_name} 下载失败或文件格式不正确！"; rm -f "$out_path"; exit 1; fi; else echo "${binary_name} 已存在，跳过下载。"; fi
}
download_binary "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$(get_arch)" "$WORKDIR/cloudflared"

generate_config
run_services
display_client_config
