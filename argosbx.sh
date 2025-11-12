#!/bin/sh
export LANG=en_US.UTF-8

# --- 用户需配置的变量 ---
# 在运行前，必须通过环境变量提供这些值
# 示例:
export ARGO_AUTH="eyJhIjoiNTFhZWVmNTkyMGVhZTE4NzE5NzVkMzdmNTRjODc1ZTYiLCJ0IjoiNzhkNWVmM2EtODVhOS00YWRjLTgwMmQtYzY1NDFjZTE3N2MzIiwicyI6Ik9XRTRaV0V6WVdZdE5UaGxNQzAwT0dFd0xXRXlOekV0WlRKa05URmlabU5rTldJMiJ9"
export CLIENT_PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

: "${WG_PORT:=51820}"
: "${ARGO_AUTH:?错误: 环境变量 ARGO_AUTH (Cloudflare 隧道 Token) 未设置。}"
: "${CLIENT_PUBLIC_KEY:?错误: 环境变量 CLIENT_PUBLIC_KEY (你的客户端公钥) 未设置。}"

# --- 脚本主要逻辑 ---
WORKDIR="$HOME/agsbx"
echo "工作目录: $WORKDIR"

# 函数：判断 CPU 架构
get_arch() {
  # sing-box 使用的架构名称
  case $(uname -m) in
    aarch64) cpu=armv8;;
    x86_64) cpu=amd64;;
    *) echo "错误: 不支持的 CPU 架构 $(uname -m)." && exit 1;;
  esac
  echo "$cpu"
}

# 函数：下载并解压 sing-box (已修复404问题)
download_and_extract_singbox() {
  if [ -f "$WORKDIR/sing-box" ]; then
    echo "sing-box 已存在，跳过下载和解压。"
    return
  fi

  local arch=$(get_arch)
  local API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
  local ARCHIVE_PATH="$WORKDIR/sing-box.tar.gz"

  echo "正在通过 GitHub API 获取最新版 sing-box 的下载链接..."
  
  # 通过API获取包含版本号的精确下载链接
  local DOWNLOAD_URL=$(curl -s "$API_URL" | grep "browser_download_url" | grep "linux-${arch}.tar.gz" | grep -v "pre-release" | cut -d '"' -f 4 | head -n 1)

  if [ -z "$DOWNLOAD_URL" ]; then
    echo "错误: 未能从 GitHub API 获取到有效的下载链接！"
    echo "请检查网络或稍后再试。"
    exit 1
  fi

  echo "获取到下载链接: $DOWNLOAD_URL"
  echo "正在下载最新版 sing-box..."
  curl -L --fail -o "$ARCHIVE_PATH" "$DOWNLOAD_URL"

  if [ $? -ne 0 ] || ! gzip -t "$ARCHIVE_PATH" >/dev/null 2>&1; then
    echo "错误: sing-box 下载失败或压缩包已损坏！"
    rm -f "$ARCHIVE_PATH"
    exit 1
  fi
  
  echo "下载成功，正在解压..."
  tar -xzf "$ARCHIVE_PATH" -C "$WORKDIR" --strip-components=1
  if [ $? -ne 0 ]; then
    echo "错误: 解压 sing-box 失败！"
    rm -f "$ARCHIVE_PATH"
    exit 1
  fi
  
  if [ ! -f "$WORKDIR/sing-box" ]; then
    echo "错误: 解压后未找到 sing-box 可执行文件！"
    exit 1
  fi
  
  echo "sing-box 安装成功。"
  rm -f "$ARCHIVE_PATH"
}

# 函数：下载 cloudflared
download_cloudflared() {
    local arch_cf
    case $(uname -m) in aarch64) arch_cf=arm64;; x86_64) arch_cf=amd64;; esac
    if [ -f "$WORKDIR/cloudflared" ]; then echo "cloudflared 已存在，跳过下载。"; return; fi
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch_cf}"
    echo "正在下载 cloudflared..."
    curl -L --fail -o "$WORKDIR/cloudflared" "$url" && chmod +x "$WORKDIR/cloudflared" || { echo "错误: cloudflared 下载失败！"; exit 1; }
    echo "cloudflared 下载成功。"
}

# 函数：使用 sing-box 生成配置
generate_singbox_config() {
  echo "正在生成 sing-box 配置文件..."
  KEY_PAIR=$("$WORKDIR/sing-box" generate wireguard-keypair)
  SERVER_PRIVATE_KEY=$(echo "$KEY_PAIR" | grep "Private Key" | awk '{print $3}')
  SERVER_PUBLIC_KEY=$(echo "$KEY_PAIR" | grep "Public Key" | awk '{print $3}')
  echo "$SERVER_PUBLIC_KEY" > "$WORKDIR/server_public.key"

  cat > "$WORKDIR/config.json" << EOF
{"log":{"level":"info","timestamp":true},"inbounds":[{"type":"wireguard","tag":"wg-in","listen_port":${WG_PORT},"private_key":"${SERVER_PRIVATE_KEY}","peers":[{"public_key":"${CLIENT_PUBLIC_KEY}","allowed_ips":["10.0.0.2/32"],"reserved":[0,0,0]}]}],"outbounds":[{"type":"direct","tag":"direct"}]}
EOF
  echo "配置文件 config.json 生成完毕。"
}

# 停止服务
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
  if ! pgrep -f "$WORKDIR/sing-box" > /dev/null; then echo "错误: sing-box 启动失败。请检查日志: $WORKDIR/sing-box.log"; cat "$WORKDIR/sing-box.log"; exit 1; fi
  echo "正在启动 Cloudflared Argo 隧道..."
  nohup "$WORKDIR/cloudflared" tunnel --no-autoupdate --edge-ip-version auto --protocol quic run --token "${ARGO_AUTH}" > "$WORKDIR/argo.log" 2>&1 &
  sleep 8
  if ! pgrep -f "$WORKDIR/cloudflared" > /dev/null; then echo "错误: cloudflared 启动失败。请检查日志: $WORKDIR/argo.log"; cat "$WORKDIR/argo.log"; exit 1; fi
  echo "服务启动成功。"
}

# 显示客户端配置
display_client_config() {
  SERVER_PUBLIC_KEY=$(cat "$WORKDIR/server_public.key")
  TUNNEL_HOSTNAME=$(grep -oE '[a-z0-9-]+\.cfargotunnel\.com' "$WORKDIR/argo.log" | head -n 1)
  if [ -z "$TUNNEL_HOSTNAME" ]; then TUNNEL_HOSTNAME="<请从Cloudflare仪表板或argo.log中查找隧道主机名>"; fi
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
stop_services
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

download_and_extract_singbox
download_cloudflared
generate_singbox_config
run_services
display_client_config
