# iMonitor 中文指南

**语言 / Language** · [中文](README.md) | [English](README.en.md)

iMonitor 是一套开箱即用的服务器资源监控平台，包含 FastAPI 控制中心、Vue 3 + Tailwind UI、**极轻量 Rust Agent（二进制，免 Python）** 以及一键安装脚本。支持本机/远程节点统一展示 CPU、内存、磁盘、负载、网络速率等指标，并可随时下发新的接入令牌。

## 架构组成
- **FastAPI 控制中心 (`app/`)**：管理节点元数据与指标，提供 `/api/nodes`、`/api/report`、`/install.sh` 等接口。
- **Vue 前端 (`public/index.html`)**：复刻 iOS 玻璃拟态风格的看板，实时轮询节点状态并提供详情抽屉和“节点接入”弹窗。
- **Agent (`scripts/agent`)**：静态编译的 Rust 可执行文件，直接读取 `/proc` 与文件系统获取指标，无需 Python/依赖，默认每 5 秒上报。
- **一键安装脚本 (`scripts/install.sh`)**：下载 Agent 与 musl loader（如目标机缺失），写入 `systemd` 服务 `imonitor-agent.service`，在低配/旧系统上也可部署。

## 快速部署主控（无编译）
```bash
git clone https://github.com/616310/imonitor.git
cd imonitor
sudo bash scripts/setup.sh    # 按提示填写公开 URL，可保留默认
```
脚本会复制当前目录到 `/opt/imonitor-lite`，创建 `imonitor-lite` systemd 服务并启动。默认监听 `0.0.0.0:8080`，如有反代请在提示里填写公网访问的 `IMONITOR_PUBLIC_URL`。

## 本地部署
```bash
cargo build --release
./target/release/imonitor
```
浏览器访问 `http://服务器IP:8080`。首次默认只有本机，可在 UI 中点“节点接入”生成接入命令。

## 接入新服务器
1. 在控制台点击“节点接入”，生成包含 `token` 的命令。
2. 将命令复制到目标服务器（需要 root 权限）执行，例如：
   ```bash
   curl -fsSL https://monitor.example.com/install.sh | bash -s -- --token=xxxx --endpoint=https://monitor.example.com
   ```
3. 安装完成后 `imonitor-agent.service` 会常驻运行，数秒后即可在面板看到实时指标。

## systemd & Nginx 示例
- `imonitor.service`：托管 FastAPI，监听 `0.0.0.0:8080`。
- `imonitor-agent.service`：每个节点本地的指标采集服务。
- `monitor.example.com` Nginx 配置：80 强制跳转 HTTPS，443 反代到本地 8080，使用 Let’s Encrypt 证书。

## 实用命令
```bash
# 查看控制中心日志
journalctl -u imonitor -f

# 查看某台服务器的 Agent 状态
journalctl -u imonitor-agent -f

# 清理/重置节点
curl -X DELETE https://monitor.example.com/api/nodes/<token>
```

欢迎根据实际需求扩展数据库、权限控制或图表展示。
