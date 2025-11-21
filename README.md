# iMonitor 中文指南

**语言 / Language** · [中文](README.md) | [English](README.en.md)

iMonitor 是一套开箱即用的服务器资源监控平台，后端 Rust（Axum + SQLite），前端 Vue + Tailwind，极轻量 Rust Agent（静态二进制，免依赖），配套“一键脚本”和交互式 `i-mo` 管理工具。可统一展示 CPU/内存/磁盘/负载/网络等指标，并在线下发接入令牌。

## 功能与组件
- **控制面板**：`src/main.rs`（Axum），静态文件 `public/`。
- **Agent**：`scripts/agent`，读取 `/proc` 与文件系统，默认 3 秒上报。
- **一键接入**：`/install.sh` 会下发 Agent + musl loader，并生成 `imonitor-agent` systemd。
- **交互式 CLI (`i-mo`)**：
  - 面板侧：安装/更新/卸载面板，查看状态/日志，启动/停止/重启，修改端口/公共地址/管理员账号，查看当前设置。
  - Agent 侧：查看状态/日志，启动/停止/重启，查看设置，卸载 Agent。

## 快速开始
### 1）安装面板（推荐用 `i-mo`）
```bash
curl -fsSL https://raw.githubusercontent.com/616310/imonitor/main/scripts/i-mo -o /usr/local/bin/i-mo
chmod +x /usr/local/bin/i-mo
sudo i-mo          # 选择“全自动安装主控面板”，按提示填端口/公共地址/管理员账号
```
安装完成后默认目录 `/opt/imonitor-lite`，服务名 `imonitor-lite`，可通过 `i-mo` 管理。

### 2）接入新节点
1. 打开控制台点击“节点接入”，复制生成的命令。
2. 在目标服务器（root）执行，例如：
   ```bash
   curl -fsSL https://your-domain/install.sh | bash -s -- --token=xxxx --endpoint=https://your-domain
   ```
   安装时会自动写入 `/usr/local/bin/i-mo`（Agent 管理菜单）。
3. `imonitor-agent` 服务启动后数秒即可在面板看到数据。

### 3）命令行管理
- **面板**：`sudo i-mo`（可选角色选择），支持启动/停止/重启、改端口/地址/管理员、查看设置、更新版本（git pull + 重启）、卸载。
- **Agent**：`sudo i-mo`（在安装了 Agent 的机器），支持启动/停止/重启、查看设置、卸载。

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
