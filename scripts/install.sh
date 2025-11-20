#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ENDPOINT="__DEFAULT_ENDPOINT__"
SERVICE_NAME="imonitor-agent"
INSTALL_DIR="/opt/imonitor-agent"
ENV_FILE="$INSTALL_DIR/agent.env"
TOKEN=""
ENDPOINT=""
INTERVAL="5"
FLAG="🖥️"
AGENT_BIN="$INSTALL_DIR/agent"
LOADER="$INSTALL_DIR/ld-musl-x86_64.so.1"

function log() {
  echo -e "[install] $1"
}

function usage() {
  cat <<USAGE
用法: bash install.sh --token=TOKEN [--endpoint=https://host] [--interval=秒] [--flag=Emoji]
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
    --flag=*) FLAG="${1#*=}" ;;
    --flag) shift; FLAG="$1" ;;
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

log "安装目录：$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
if ! touch "$INSTALL_DIR/.write_test" 2>/dev/null; then
  echo "安装目录不可写：$INSTALL_DIR" >&2
  exit 1
fi
rm -f "$INSTALL_DIR/.write_test"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

log "下载 Agent 二进制"
TMP_AGENT="$TMPDIR/agent.bin"
curl -fSL --retry 3 --retry-delay 1 "$ENDPOINT/agent.bin" -o "$TMP_AGENT"
install -m 0755 "$TMP_AGENT" "$AGENT_BIN"
log "下载运行时 (musl loader)"
TMP_LOADER="$TMPDIR/ld-musl-x86_64.so.1"
curl -fSL --retry 3 --retry-delay 1 "$ENDPOINT/ld-musl-x86_64.so.1" -o "$TMP_LOADER"
install -m 0755 "$TMP_LOADER" "$LOADER"
if [ ! -f /lib/ld-musl-x86_64.so.1 ]; then
  log "复制 musl loader 到 /lib"
  cp "$LOADER" /lib/ld-musl-x86_64.so.1
fi
rm -rf "$INSTALL_DIR/venv" "$INSTALL_DIR/agent.py"

cat > "$ENV_FILE" <<EOF_ENV
IMONITOR_TOKEN=$TOKEN
IMONITOR_ENDPOINT=$ENDPOINT
IMONITOR_INTERVAL=$INTERVAL
IMONITOR_FLAG=$FLAG
EOF_ENV

AGENT_CMD="$AGENT_BIN --token=\$IMONITOR_TOKEN --endpoint=\$IMONITOR_ENDPOINT --interval=\$IMONITOR_INTERVAL --flag=\$IMONITOR_FLAG"

cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF_SERVICE
[Unit]
Description=iMonitor Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=/bin/sh -c "$AGENT_CMD"
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
systemctl restart $SERVICE_NAME.service
log "安装完成，服务状态："
systemctl --no-pager status $SERVICE_NAME.service
