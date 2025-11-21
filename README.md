# iMonitor 中文指南

**语言 / Language** · [中文](README.md) | [English](README.en.md)

iMonitor 是一套开箱即用的服务器资源监控平台，后端 Rust（Axum + SQLite），前端 Vue + Tailwind，极轻量 Rust Agent（静态二进制，免依赖），配套独立的安装脚本与交互式 `i-mo` 运维工具。可统一展示 CPU/内存/磁盘/负载/网络等指标，并在线下发接入令牌。

## 功能与组件
- **控制面板**：`src/main.rs`（Axum），静态文件 `public/`。
- **Agent**：`scripts/agent`，读取 `/proc` 与文件系统，默认 3 秒上报。
- **主控安装**：`scripts/install-panel.sh` 独立脚本，root 运行，拷贝程序并写入 `imonitor-lite` systemd，输出访问地址与管理员账号。
- **一键接入**：`/install.sh` 会下发 Agent + musl loader，并生成 `imonitor-agent` systemd。
- **交互式 CLI (`i-mo`)**：仅用于已安装后的运维（查看状态/日志、启停、修改配置、卸载等），不再承担安装主控。

## 快速开始
### 1）安装面板（独立脚本）
```bash
git clone https://github.com/616310/imonitor.git
cd imonitor
# 如需自行构建可执行文件：cargo build --release
sudo bash scripts/install-panel.sh   # 按提示选择目录/端口/公共地址/管理员账号
```
默认安装到 `/opt/imonitor-lite`，systemd 服务名 `imonitor-lite`，脚本结束会打印访问地址和管理员凭据。

### 2）接入新节点
1. 打开控制台点击“节点接入”，复制生成的命令。
2. 在目标服务器（root）执行，例如：
   ```bash
   curl -fsSL https://your-domain/install.sh | bash -s -- --token=xxxx --endpoint=https://your-domain
   ```
   安装时会自动写入 `/usr/local/bin/i-mo`（Agent 管理菜单）。
3. `imonitor-agent` 服务启动后数秒即可在面板看到数据。

### 3）命令行管理
- **面板**：`sudo i-mo`（在主控机器），支持启动/停止/重启、改端口/地址/管理员、查看设置、更新版本（git pull + 重启）、卸载。
- **Agent**：`sudo i-mo`（在安装了 Agent 的机器），支持启动/停止/重启、查看设置、卸载。未安装主控时会提示使用 `scripts/install-panel.sh`。

## 手动编译/运行（可选）
```bash
git clone https://github.com/616310/imonitor.git
cd imonitor
cargo build --release
./target/release/imonitor   # 本地调试
```

## 主要环境变量（面板）
- `IMONITOR_PUBLIC_URL`：外网访问地址（含协议）。
- `IMONITOR_BIND`：监听地址，默认 `[::]:8080`。
- `IMONITOR_OFFLINE_TIMEOUT`：离线判定秒数，默认 30。

## 实用命令
```bash
# 面板日志
journalctl -u imonitor-lite -f
# Agent 日志
journalctl -u imonitor-agent -f
```

欢迎根据需求扩展数据库、权限或图表。***
