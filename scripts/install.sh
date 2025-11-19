#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ENDPOINT="__DEFAULT_ENDPOINT__"
SERVICE_NAME="imonitor-agent"
INSTALL_DIR="/opt/imonitor-agent"
ENV_FILE="$INSTALL_DIR/agent.env"
VENV_DIR="$INSTALL_DIR/venv"
TOKEN=""
ENDPOINT=""
INTERVAL="5"

function log() {
  echo -e "[install] $1"
}

function usage() {
  cat <<USAGE
用法: bash install.sh --token=TOKEN [--endpoint=https://host] [--interval=秒]
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token=*) TOKEN="${1#*=}" ;;
    --token) shift; TOKEN="$1" ;;
    --endpoint=*) ENDPOINT="${1#*=}" ;;
    --endpoint) shift; ENDPOINT="$1" ;;
    --interval=*) INTERVAL="${1#*=}" ;;
    --interval) shift; INTERVAL="$1" ;;
    -h|--help) usage; exit 0 ;;
  esac
  shift || true
done

if [[ -z "$TOKEN" ]]; then
  echo "缺少 --token 参数" >&2
  exit 1
fi

if [[ -z "$ENDPOINT" ]]; then
  ENDPOINT="$DEFAULT_ENDPOINT"
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "请使用 root 权限执行安装脚本" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "需要 python3 环境" >&2
  exit 1
fi

log "安装目录：$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

if [ ! -d "$VENV_DIR" ]; then
  log "创建虚拟环境"
  python3 -m venv "$VENV_DIR"
fi

log "安装依赖"
"$VENV_DIR/bin/pip" install --upgrade pip >/dev/null
"$VENV_DIR/bin/pip" install --upgrade psutil requests >/dev/null

log "下载 Agent"
curl -fsSL "$ENDPOINT/agent.py" -o "$INSTALL_DIR/agent.py"
chmod +x "$INSTALL_DIR/agent.py"

cat > "$ENV_FILE" <<EOF_ENV
IMONITOR_TOKEN=$TOKEN
IMONITOR_ENDPOINT=$ENDPOINT
IMONITOR_INTERVAL=$INTERVAL
EOF_ENV

cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF_SERVICE
[Unit]
Description=iMonitor Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=$VENV_DIR/bin/python $INSTALL_DIR/agent.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE

log "刷新 systemd"
systemctl daemon-reload
systemctl enable --now $SERVICE_NAME.service
log "安装完成，服务状态："
systemctl --no-pager status $SERVICE_NAME.service
