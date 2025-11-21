# iMonitor 中文指南

iMonitor 是一套开箱即用的服务器资源监控平台，包含 Rust 控制中心、Vue 3 + Tailwind UI、极轻量 Rust Agent（二进制，免 Python）以及分离的安装脚本。支持本机/远程节点统一展示 CPU、内存、磁盘、负载、网络速率等指标，并可随时下发新的接入令牌。

## 架构组成
- **控制中心 (`src/main.rs`)**：Axum + SQLite，提供 `/api/nodes`、`/api/report`、`/install.sh` 等接口。
- **前端 (`public/index.html`)**：玻璃拟态风格的看板，实时轮询节点状态并提供详情抽屉和“节点接入”弹窗。
- **Agent (`scripts/agent`)**：静态编译的 Rust 可执行文件，直接读取 `/proc` 与文件系统获取指标，无需 Python/依赖，默认每 5 秒上报。
- **主控安装脚本 (`scripts/install-panel.sh`)**：独立脚本，root 运行，拷贝当前目录到目标路径、写入 `imonitor-lite` systemd 单元并输出访问地址/管理员账号。
- **Agent 接入脚本 (`scripts/install.sh`)**：下载 Agent 与 musl loader（若目标机缺失），写入 `imonitor-agent.service`，在低配/旧系统上也可部署。
- **运维 CLI (`i-mo`)**：只负责已安装主控/Agent 的状态、日志、启停、配置查看等，不再用于安装。

## 安装主控面板（不依赖 i-mo）
```bash
git clone https://github.com/616310/imonitor.git
cd imonitor
# 如需自行构建可执行文件：cargo build --release
sudo bash scripts/install-panel.sh
```
按提示填写安装目录/端口/公共地址/管理员账号后，脚本会输出最终访问地址与凭据，systemd 服务名为 `imonitor-lite`。

## 本地开发运行
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
- `imonitor-lite.service`：托管控制中心，监听 `0.0.0.0:8080`。
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

# 运维 CLI（已安装后）
sudo i-mo   # 在主控或 Agent 机器上查看状态/日志/启停，若未安装会提示使用 install-panel.sh
```

欢迎根据实际需求扩展数据库、权限控制或图表展示。
