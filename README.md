# 🚀 Access-IDX：容器专属无公网代理节点脚本

本项目专为 **Google IDX、Dev Containers、GitHub Codespaces、Replit** 等**无公网 IP、无 Root 权限、无 Systemd** 的容器环境打造。基于 Xray 内核与 Cloudflare Argo Tunnel，一键生成高匿名的 VLESS/VMess 代理节点。

这是对原版[Argosbx](https://github.com/yonggekkk/argosbx) 的深度精简与重构版本，移除了所有容器内无法运行的直连协议与 WARP 依赖，极致轻量，抗封锁能力拉满。

## ✨ 核心特性

- 🛡️ **极强抗封锁**：默认采用 `VLESS + WebSocket + TLS` 协议架构。
- 🎭 **深度伪装**：流量路径深度伪装为企业级 API 接口（如 `/api/v4/system/updates`），规避特征审查。
- 🔗 **内网穿透**：完美整合 Cloudflare Argo Tunnel，支持**临时随机域名**与**固定 Token 域名**。
- ♻️ **自动保活**：无需 `systemd`，通过注入 `.bashrc` 实现终端唤醒/重启时自动恢复进程。
- ⚡ **极致轻量**：仅保留单协议双端口（VLESS / VMess）流转，大幅降低容器 CPU 占用。

---

## 🛠️ 快速开始

在 Google IDX 或任意 Linux 终端中，直接复制执行以下一键安装命令：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/TPC369max/Access/main/IDX.sh)
