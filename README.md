# iMonitor 中文指南

**语言 / Language** · [中文](README.md) | [English](README.en.md)

iMonitor 是一套开箱即用的服务器资源监控平台，包含 FastAPI 控制中心、Vue 3 + Tailwind UI、轻量级 Python Agent 以及一键安装脚本。支持本机/远程节点统一展示 CPU、内存、磁盘、负载、网络速率等指标，并可随时下发新的接入令牌。

## 架构组成
- **FastAPI 控制中心 (`app/`)**：管理节点元数据与指标，提供 `/api/nodes`、`/api/report`、`/install.sh` 等接口。
- **Vue 前端 (`public/index.html`)**：复刻 iOS 玻璃拟态风格的看板，实时轮询节点状态并提供详情抽屉和“节点接入”弹窗。
- **Agent (`scripts/agent.py`)**：依赖 `psutil`/`requests`，按固定频率上报主机指标，支持命令行参数或环境变量定制。
- **一键安装脚本 (`scripts/install.sh`)**：下载 Agent、创建 venv、写入 `systemd` 服务 `imonitor-agent.service`，真正实现“在目标服务器执行一条命令即可接入”。

## 本地部署
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8080
```
浏览器访问 `http://服务器IP:8080`。首次默认只有本机，可在 UI 中点“节点接入”生成接入命令。

## 接入新服务器
1. 在控制台点击“节点接入”，生成包含 `token` 的命令。
2. 将命令复制到目标服务器（需要 root 权限）执行，例如：
   ```bash
   curl -fsSL https://bbb.bjut.me/install.sh | bash -s -- --token=xxxx --endpoint=https://bbb.bjut.me
   ```
3. 安装完成后 `imonitor-agent.service` 会常驻运行，数秒后即可在面板看到实时指标。

## systemd & Nginx 示例
- `imonitor.service`：托管 FastAPI，监听 `0.0.0.0:8080`。
- `imonitor-agent.service`：每个节点本地的指标采集服务。
- `bbb.bjut.me` Nginx 配置：80 强制跳转 HTTPS，443 反代到本地 8080，使用 Let’s Encrypt 证书。

## 实用命令
```bash
# 查看控制中心日志
journalctl -u imonitor -f

# 查看某台服务器的 Agent 状态
journalctl -u imonitor-agent -f

# 清理/重置节点
curl -X DELETE https://bbb.bjut.me/api/nodes/<token>
```

欢迎根据实际需求扩展数据库、权限控制或图表展示。
