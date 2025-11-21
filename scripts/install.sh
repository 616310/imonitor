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

# 安装 i-mo CLI（Agent 侧）
cat > /usr/local/bin/i-mo <<'EOF_I_MO'
#!/usr/bin/env bash
set -euo pipefail
SERVICE_AGENT="imonitor-agent"
AGENT_ENV="/opt/imonitor-agent/agent.env"
require_root() { if [[ "$EUID" -ne 0 ]]; then echo "请使用 root 权限运行 (sudo i-mo)"; exit 1; fi; }
prompt() { local msg="$1" default="$2" var; read -r -p "$msg [$default]: " var; echo "${var:-$default}"; }
agent_status(){ echo "Agent 状态："; systemctl status "$SERVICE_AGENT" --no-pager | head -n 5; }
agent_logs(){ echo "Agent 最新日志："; journalctl -u "$SERVICE_AGENT" -n 50 --no-pager; }
agent_restart(){ systemctl restart "$SERVICE_AGENT" && agent_status; }
agent_settings(){ [[ -f "$AGENT_ENV" ]] && { echo "当前 Agent 设置："; cat "$AGENT_ENV"; } || echo "未找到 $AGENT_ENV"; }
agent_edit_env(){
  require_root
  [[ -f "$AGENT_ENV" ]] || { echo "未找到 $AGENT_ENV"; return; }
  local token endpoint interval flag
  token=$(grep "^IMONITOR_TOKEN" "$AGENT_ENV" | cut -d= -f2-)
  endpoint=$(grep "^IMONITOR_ENDPOINT" "$AGENT_ENV" | cut -d= -f2-)
  interval=$(grep "^IMONITOR_INTERVAL" "$AGENT_ENV" | cut -d= -f2-)
  flag=$(grep "^IMONITOR_FLAG" "$AGENT_ENV" | cut -d= -f2-)
  token=$(prompt "Token" "$token")
  endpoint=$(prompt "Endpoint" "$endpoint")
  interval=$(prompt "上报间隔(秒)" "$interval")
  flag=$(prompt "标识 Emoji" "$flag")
  cat >"$AGENT_ENV" <<EOF_ENV
IMONITOR_TOKEN=$token
IMONITOR_ENDPOINT=$endpoint
IMONITOR_INTERVAL=$interval
IMONITOR_FLAG=$flag
EOF_ENV
  agent_restart
}
while true; do
cat <<'MENU'
[i-mo Agent] 请选择操作:
 1) 查看状态
 2) 查看最近日志
 3) 重启 Agent
 4) 修改 token/endpoint/间隔/flag
 5) 查看当前设置
 6) 退出
MENU
read -r -p "> " sel
case "$sel" in
 1) agent_status ;;
 2) agent_logs ;;
 3) agent_restart ;;
 4) agent_edit_env ;;
 5) agent_settings ;;
 6) exit 0 ;;
esac
done
EOF_I_MO
chmod +x /usr/local/bin/i-mo

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
