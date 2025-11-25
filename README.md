# iMonitor Lite 使用指南

> 轻量级自建监控面板：Rust + Axum + SQLite + Vue 3，内置静态 Agent，与 `i-mo` 运维菜单配套。

**语言 / Language** · 中文（当前） | [English](README.en.md)

---

## 特性一览

- **一键部署**：`scripts/install-panel.sh` 自动创建 `/opt/imonitor-lite`、写入 systemd，并配置管理员账号。
- **极简架构**：后端单个二进制（Axum + SQLite），前端静态资源内嵌在 `public/`，Agent 为无依赖的静态可执行文件。
- **多地址监听**：`IMONITOR_BIND` 支持 IPv4/IPv6、多端口组合；`i-mo` 可交互式修改端口、绑定地址。
- **Basic Auth 防护**：所有写操作（添加节点、修改标签、上传背景）均需登录；展示节点列表支持匿名访问，便于分享。
- **可视化仪表**：Vue 3 + Tailwind UI，展示 CPU/内存/磁盘/负载/网络速率，并支持自定义背景（支持上传或外链）。
- **运维工具 `i-mo`**：面板与 Agent 都有同一个 CLI 工具用于查看状态、日志、重启、更新或卸载。
- **内置安装脚本**：`/install.sh` 负责 Agent 下发与 systemd 安装，可配合前端“一键接入”命令使用。

---

## 架构与目录

```
/opt/imonitor-lite
├── bin/                 # 控制面板与 Agent 的发布二进制
├── data/
│   ├── imonitor.db      # SQLite 数据，存储节点、指标、标签
│   ├── settings.json    # 前端背景等配置
│   └── background_upload.bin
├── public/              # Vue + Tailwind 静态文件
├── scripts/
│   ├── install-panel.sh # 主控安装脚本，可 curl | bash
│   ├── install.sh       # Agent 安装脚本（前端下载即得）
│   └── i-mo             # 运维 CLI，会被安装到 /usr/local/bin/i-mo
├── src/                 # Rust 源码（main.rs 面板，bin/agent.rs Agent）
└── target/              # Cargo 构建产物
```

Systemd 服务：
- `imonitor-lite.service`：主控面板，WorkingDirectory `/opt/imonitor-lite`
- `imonitor-agent.service`：节点 Agent

安装脚本会创建 `imonitor` 用户，并把数据目录的所有权交给它。

---

## 快速开始

### 环境要求
- 64 位 Linux，提供 systemd 与 `curl`
- root 权限（安装脚本与 `i-mo` 都需）
- Rust 仅在从源码构建/开发时需要（发布包附带编译好的 `bin/imonitor`）

### 安装主控面板

```bash
curl -fsSL https://raw.githubusercontent.com/616310/imonitor/main/scripts/install-panel.sh | sudo bash
```

脚本会：
1. 克隆仓库，复制到 `/opt/imonitor-lite`
2. 询问（或自动生成）管理员账号、访问地址
3. 写入 `/etc/systemd/system/imonitor-lite.service`
4. 运行 `systemctl daemon-reload && systemctl enable --now imonitor-lite`
5. 在 `/usr/local/bin/` 中放置 `i-mo`

结束时会显示访问地址、管理员用户名和随机密码。首次访问使用 Basic Auth 登录即可。

### 接入节点

1. 打开 Web 控制台，点击右上角 “节点接入” → 生成 curl 命令
2. 在目标服务器执行生成的命令，例如：
   ```bash
   curl -fsSL https://panel.example.com/install.sh | bash -s -- \
     --token=<TOKEN> \
     --endpoint=https://panel.example.com \
     --interval=5 \
     --flag="🖥️"
   ```
3. Agent 安装脚本会部署到 `/opt/imonitor-agent`，并写入 `/etc/systemd/system/imonitor-agent.service`
4. `systemctl status imonitor-agent` 查看运行状态，约 3 秒后面板即可显示该节点

> **参数说明**
> - `--token`：Web 面板生成的节点 token（必须）
> - `--endpoint`：主控地址，需与公网/内网访问方式一致
> - `--interval`：上报周期（秒），默认 5
> - `--flag`：节点展示的 Emoji

### 首次登录与背景设置

访问面板时会弹出登录框；登录后才能生成节点命令、修改标签或上传背景。背景配置保存在 `data/settings.json`，也可以在“背景”弹窗上传图片（文件存放于 `data/background_upload.bin`）。

---

## `i-mo` 运维命令

安装脚本会在服务器上自动执行 `i-mo`，后续可手动运行：

```bash
sudo i-mo
```

- 若同机既安装主控也安装 Agent，会提示选择“主控面板 / Agent”
- `i-mo` 以 systemd 状态为准，所有操作都会自动 `daemon-reload` 并打印生效后的配置

主控菜单包含：

| 序号 | 功能 | 说明 |
| ---- | ---- | ---- |
| 1 | 查看状态 | systemd 状态、运行时间、访问地址 |
| 2 | 查看日志 | `journalctl -u imonitor-lite` 最近 50 行 |
| 3-5 | 启动/停止/重启 | systemctl wrapper |
| 6 | 修改端口 | 更新 `IMONITOR_BIND`/`IMONITOR_PUBLIC_URL` 并重启 |
| 7 | 选择绑定地址 | 引导选择内网/公网 IPv4、IPv6，支持多地址 |
| 8 | 修改管理员账号/密码 | 更新 `IMONITOR_ADMIN_*` |
| 9 | 查看当前配置 | 打印 systemd unit 里的环境变量 |
| 10 | 更新版本 | 拉取最新版源码，同步除 `data/` 外的文件 |
| 11 | 卸载 | 停止服务、删除目录与 unit、移除 `i-mo` |

Agent 菜单可以查看上报状态、日志、重启或卸载 `imonitor-agent`。

---

## 配置参考

### 面板环境变量（写入 `/etc/systemd/system/imonitor-lite.service`）

| 变量 | 说明 | 默认值 |
| ---- | ---- | ---- |
| `IMONITOR_PUBLIC_URL` | 面板访问地址，可逗号分隔多个地址（用于“节点接入”命令） | `http://127.0.0.1:8080` |
| `IMONITOR_BIND` | 监听地址列表，支持 IPv4/IPv6，形如 `0.0.0.0:8080,[::]:8080` | `[::]:8080` |
| `IMONITOR_OFFLINE_TIMEOUT` | 节点离线判定阈值（秒） | `10` |
| `IMONITOR_ADMIN_USER` / `IMONITOR_ADMIN_PASS` | Basic Auth 凭据 | 安装时询问/随机生成 |

> 监听失败时，程序会跳过无法绑定的地址并在日志中给出警告。

### Agent 环境（`/opt/imonitor-agent/agent.env`）

| 变量 | 说明 |
| ---- | ---- |
| `IMONITOR_TOKEN` | 节点 token |
| `IMONITOR_ENDPOINT` | 主控面板地址（HTTP/HTTPS） |
| `IMONITOR_INTERVAL` | 上报周期（秒） |
| `IMONITOR_FLAG` | 前端展示用 Emoji |

修改 `agent.env` 后执行 `sudo systemctl restart imonitor-agent` 即可生效。

---

## Web 与 API 行为

- `GET /`：静态前端
- `GET /install.sh`、`/agent.bin`：Agent 安装脚本与二进制
- `GET /api/nodes`：返回节点列表（匿名可访问，便于分享状态墙）
- `POST /api/login`：Basic Auth 校验，前端用来保存 `Authorization` header
- `POST /api/nodes/reserve`、`PATCH`/`DELETE /api/nodes/:token`：需要登录
- `POST /api/report`：Agent 上报指标
- `GET/POST /api/settings/background*`：背景查询与更新（需登录）

后台使用 SQLite（`data/imonitor.db`），可通过 `sqlite3` 直接读取备份。

---

## 从源码构建

开发或自定义编译参数时，可自行构建：

```bash
git clone https://github.com/616310/imonitor.git
cd imonitor-lite
# Debug
cargo run
# 静态发行版（与安装包一致）
cargo build --release --target x86_64-unknown-linux-musl
cp target/x86_64-unknown-linux-musl/release/imonitor bin/imonitor
sudo systemctl restart imonitor-lite
```

Agent 同理，可运行 `cargo build --release --bin agent --target x86_64-unknown-linux-musl`。

---

## 常用运维命令

```bash
# 查看面板 / Agent 服务状态
systemctl status imonitor-lite
systemctl status imonitor-agent

# 持续查看日志
journalctl -fu imonitor-lite
journalctl -fu imonitor-agent

# 手动更换管理员密码（不经 i-mo）
sudo sed -i 's/IMONITOR_ADMIN_PASS=.*/IMONITOR_ADMIN_PASS=NewPass/' /etc/systemd/system/imonitor-lite.service
sudo systemctl daemon-reload && sudo systemctl restart imonitor-lite
```

升级建议使用 `i-mo` 菜单的“更新版本”或重新运行安装脚本（会自动覆盖旧代码并保留 `data/`）。

---

## 故障排查

1. **面板端口未变更**：使用 `sudo i-mo` 中的“修改端口/绑定地址”，工具会同步更新 `IMONITOR_BIND` 与 `IMONITOR_PUBLIC_URL`，若手动编辑 unit 文件请勿忘记 `systemctl daemon-reload`。
2. **Agent 无法连接**：确认 `agent.env` 中的 `IMONITOR_ENDPOINT` 与面板证书/协议一致；`journalctl -u imonitor-agent` 可查看上报报错。
3. **背景未立即更新**：前端会缓存上一次背景并在加载后快速替换。可在浏览器控制台执行 `localStorage.removeItem('imonitorBgCache')` 清除缓存。
4. **数据库备份**：面板可在不停机情况下复制 `data/imonitor.db`；若复制 `background_upload.bin` 和 `settings.json` 即可完整迁移。

---

## 贡献

项目结构简单，欢迎通过 PR 增强功能（新的图表、指标或认证方式等）。常见入口：

- 控制面板：`src/main.rs`（Axum 路由）、`public/index.html`（Vue 组件）
- Agent：`src/bin/agent.rs`
- 安装脚本 / 运维工具：`scripts/install-panel.sh`、`scripts/install.sh`、`scripts/i-mo`

感谢每一位贡献者。欢迎在 Issue 中反馈需求或问题 🙌
