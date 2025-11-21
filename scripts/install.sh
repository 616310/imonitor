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

cat > /usr/local/bin/i-mo <<'EOF_I_MO'
#!/usr/bin/env bash
set -euo pipefail
SERVICE_CTRL="imonitor-lite"
SERVICE_AGENT="imonitor-agent"
CTRL_UNIT="/etc/systemd/system/${SERVICE_CTRL}.service"
AGENT_ENV="/opt/imonitor-agent/agent.env"
CTRL_DIR="/opt/imonitor-lite"
REPO_URL="https://github.com/616310/imonitor.git"

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "请使用 root 权限运行 (sudo i-mo)" >&2
    exit 1
  fi
}

has_service() {
  systemctl list-unit-files | grep -q "^${1}.service"
}

detect_public_addr() {
  addr=$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  if [[ -n "$addr" ]]; then echo "[$addr]"; return; fi
  addr=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  if [[ -n "$addr" ]]; then echo "$addr"; return; fi
  echo "127.0.0.1"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "缺少依赖：$cmd，尝试自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update && apt-get install -y "$cmd"
    elif command -v yum >/dev/null 2>&1; then
      yum install -y "$cmd"
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y "$cmd"
    else
      echo "无法自动安装 $cmd，请手动安装后重试。" >&2
      exit 1
    fi
  fi
}

prompt() {
  local msg="$1" default="$2" var
  read -r -p "$msg [$default]: " var
  echo "${var:-$default}"
}

line_in_file() {
  local pattern="$1" file="$2" replacement="$3"
  if grep -q "^${pattern}" "$file"; then
    sed -i "s?^${pattern}.*?${replacement}?" "$file"
  else
    echo "$replacement" >>"$file"
  fi
}

ctrl_env() {
  local key="$1"
  [[ -f "$CTRL_UNIT" ]] || return
  grep -o "^Environment=${key}=.*" "$CTRL_UNIT" | head -n1 | sed 's/^Environment='"$key"'=//;s/"//g'
}

ctrl_bind_port() {
  local bind
  bind=$(ctrl_env "IMONITOR_BIND")
  echo "${bind##*:}" | tr -d ']'
}

ctrl_status() {
  local state since host port
  state=$(systemctl is-active "$SERVICE_CTRL" 2>/dev/null || true)
  since=$(systemctl show "$SERVICE_CTRL" -p ActiveEnterTimestamp --value 2>/dev/null)
  host=$(ctrl_env "IMONITOR_PUBLIC_URL")
  port=$(ctrl_bind_port)
  [[ -z "$host" && -n "$port" ]] && host="http://127.0.0.1:${port}"
  echo "面板状态：${state:-unknown}"
  [[ -n "$since" ]] && echo "运行起始：$since"
  [[ -n "$host" ]] && echo "访问地址：$host"
  if [[ "$state" != "active" ]]; then
    echo "提示：使用 i-mo 菜单启动/重启，或运行 systemctl start ${SERVICE_CTRL}.service"
  fi
}

ctrl_logs() {
  echo "面板最新日志（最近 50 行）："
  journalctl -u "$SERVICE_CTRL" -n 50 --no-pager
}

ctrl_start() { systemctl start "$SERVICE_CTRL" && ctrl_status; }
ctrl_stop() { systemctl stop "$SERVICE_CTRL" && ctrl_status; }
ctrl_restart() { systemctl restart "$SERVICE_CTRL" && ctrl_status; }

ctrl_settings() {
  local port host admin_user admin_pass
  port=$(grep -o "IMONITOR_BIND=.*:" "$CTRL_UNIT" | head -n1 | sed 's/.*://;s/].*//;s/\"//g')
  host=$(grep -o "IMONITOR_PUBLIC_URL=.*" "$CTRL_UNIT" | head -n1 | sed 's/.*=//;s/\"//g')
  admin_user=$(grep -o "IMONITOR_ADMIN_USER=.*" "$CTRL_UNIT" | head -n1 | sed 's/.*=//;s/\"//g')
  admin_pass=$(grep -o "IMONITOR_ADMIN_PASS=.*" "$CTRL_UNIT" | head -n1 | sed 's/.*=//;s/\"//g')
  echo "当前设置："
  echo "  端口: ${port:-未知}"
  echo "  公共地址: ${host:-未知}"
  echo "  管理员: ${admin_user:-未知}"
  echo "  管理员密码: ${admin_pass:-<未设置>}"
}

ctrl_set_port() {
  require_root
  local port
  port=$(prompt "新的服务端口" "8080")
  local bind="[::]:${port}"
  sed -i "s?^Environment=IMONITOR_BIND=.*?Environment=IMONITOR_BIND=${bind}?g" "$CTRL_UNIT"
  echo "端口已更新为 ${port}"
  systemctl daemon-reload
  ctrl_restart
}

ctrl_set_public() {
  require_root
  local host
  host=$(prompt "新的公共地址（含 http/https）" "http://127.0.0.1:8080")
  sed -i "s?^Environment=IMONITOR_PUBLIC_URL=.*?Environment=IMONITOR_PUBLIC_URL=${host}?g" "$CTRL_UNIT"
  echo "公共地址已更新为 ${host}"
  systemctl daemon-reload
  ctrl_restart
}

ctrl_set_admin() {
  require_root
  local admin_user admin_pass
  admin_user=$(prompt "管理员用户名" "admin")
  read -r -s -p "管理员密码: " admin_pass; echo
  line_in_file "Environment=IMONITOR_ADMIN_USER" "$CTRL_UNIT" "Environment=IMONITOR_ADMIN_USER=${admin_user}"
  line_in_file "Environment=IMONITOR_ADMIN_PASS" "$CTRL_UNIT" "Environment=IMONITOR_ADMIN_PASS=${admin_pass}"
  echo "管理员账号已更新"
  systemctl daemon-reload
  ctrl_restart
}

agent_status() {
  local state since token endpoint interval flag
  state=$(systemctl is-active "$SERVICE_AGENT" 2>/dev/null || true)
  since=$(systemctl show "$SERVICE_AGENT" -p ActiveEnterTimestamp --value 2>/dev/null)
  if [[ -f "$AGENT_ENV" ]]; then
    token=$(grep "^IMONITOR_TOKEN" "$AGENT_ENV" | cut -d= -f2-)
    endpoint=$(grep "^IMONITOR_ENDPOINT" "$AGENT_ENV" | cut -d= -f2-)
    interval=$(grep "^IMONITOR_INTERVAL" "$AGENT_ENV" | cut -d= -f2-)
    flag=$(grep "^IMONITOR_FLAG" "$AGENT_ENV" | cut -d= -f2-)
  fi
  echo "Agent 状态：${state:-unknown}"
  [[ -n "$since" ]] && echo "运行起始：$since"
  [[ -n "$endpoint" ]] && echo "上报地址：$endpoint"
  if [[ -n "$token" ]]; then
    local short="${token:0:6}...${token: -6}"
    echo "上报令牌：$short"
  fi
  [[ -n "$interval" ]] && echo "上报间隔：${interval} 秒"
  [[ -n "$flag" ]] && echo "节点标识：$flag"
  if [[ "$state" != "active" ]]; then
    echo "提示：使用 i-mo 菜单启动/重启，或运行 systemctl restart ${SERVICE_AGENT}.service"
  fi
}

agent_logs() {
  echo "Agent 最新日志（最近 50 行）："
  journalctl -u "$SERVICE_AGENT" -n 50 --no-pager
}

agent_restart() { systemctl restart "$SERVICE_AGENT" && agent_status; }

agent_settings() {
  if [[ ! -f "$AGENT_ENV" ]]; then
    echo "未找到 $AGENT_ENV" >&2
    return
  fi
  echo "当前 Agent 设置："
  cat "$AGENT_ENV"
}

uninstall_agent() {
  require_root
  systemctl disable --now "${SERVICE_AGENT}.service" 2>/dev/null || true
  rm -f /etc/systemd/system/${SERVICE_AGENT}.service
  systemctl daemon-reload
  rm -rf /opt/imonitor-agent
  echo "Agent 已卸载"
}

install_panel() {
  require_root
  echo "== 安装主控面板 =="
  local install_dir="$CTRL_DIR"
  local run_user="imonitor"
  local port="8080"
  local host Detect
  host=$(detect_public_addr)
  read -r -p "安装目录 [${install_dir}]: " input; install_dir=${input:-$install_dir}
  read -r -p "运行用户 [${run_user}]: " input; run_user=${input:-$run_user}
  read -r -p "服务端口 [${port}]: " input; port=${input:-$port}
  read -r -p "公共访问地址/域名（可留空自动检测） [${host}]: " input; host=${input:-$host}
  read -r -p "管理员用户名 [admin]: " admin_user; admin_user=${admin_user:-admin}
  read -r -s -p "管理员密码（留空随机）: " admin_pass; echo
  if [[ -z "$admin_pass" ]]; then admin_pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16); echo "生成密码：$admin_pass"; fi
  local public_host="http://${host}:${port}"

  require_cmd git
  tmpdir=$(mktemp -d)
  git clone "$REPO_URL" "$tmpdir"
  mkdir -p "$install_dir"
  tar cf - --exclude='.git' --exclude='target' -C "$tmpdir" . | tar xf - -C "$install_dir"
  useradd --system --create-home --shell /usr/sbin/nologin "$run_user" 2>/dev/null || true
  chown -R "$run_user":"$run_user" "$install_dir"
  install -m 0755 "$install_dir/scripts/i-mo" /usr/local/bin/i-mo

  cat >/etc/systemd/system/${SERVICE_CTRL}.service <<EOF
[Unit]
Description=iMonitor Lite Central Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${run_user}
Group=${run_user}
WorkingDirectory=${install_dir}
Environment=IMONITOR_PUBLIC_URL=${public_host}
Environment=IMONITOR_BIND=[::]:${port}
Environment=IMONITOR_ADMIN_USER=${admin_user}
Environment=IMONITOR_ADMIN_PASS=${admin_pass}
ExecStart=${install_dir}/bin/imonitor
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ${SERVICE_CTRL}.service
  ctrl_status
  echo "----------------------------------"
  echo "主控面板已部署完成"
  echo "访问地址：${public_host}"
  echo "管理员账号：${admin_user}"
  echo "管理员密码：${admin_pass}"
  echo "如需修改地址/端口/凭据，可通过 i-mo 菜单或编辑 ${SERVICE_CTRL}.service 后重启。"
}

uninstall_panel() {
  require_root
  systemctl disable --now "${SERVICE_CTRL}.service" 2>/dev/null || true
  rm -f /etc/systemd/system/${SERVICE_CTRL}.service
  systemctl daemon-reload
  echo "已卸载面板服务（文件未删除，目录：$CTRL_DIR）"
}

update_panel() {
  require_root
  if [[ ! -d "$CTRL_DIR/.git" ]]; then
    echo "未找到 $CTRL_DIR/.git，无法更新" >&2
    return
  fi
  git -C "$CTRL_DIR" pull --rebase
  (cd "$CTRL_DIR" && cargo build --release --target x86_64-unknown-linux-musl || true)
  if [[ -f "$CTRL_DIR/target/x86_64-unknown-linux-musl/release/imonitor" ]]; then
    cp "$CTRL_DIR/target/x86_64-unknown-linux-musl/release/imonitor" "$CTRL_DIR/bin/imonitor"
  fi
  ctrl_restart
}

choose_role() {
  local has_ctrl=0 has_agent=0
  has_service "$SERVICE_CTRL" && has_ctrl=1
  has_service "$SERVICE_AGENT" && has_agent=1
  if [[ $has_ctrl -eq 1 && $has_agent -eq 1 ]]; then echo "both"; return; fi
  if [[ $has_ctrl -eq 1 ]]; then echo "server"; return; fi
  if [[ $has_agent -eq 1 ]]; then echo "agent"; return; fi
  echo "none"
}

server_menu() {
  while true; do
    cat <<'MENU'
[i-mo 主控] 请选择操作:
 1) 查看状态（面板运行情况）
 2) 查看最近日志
 3) 启动面板
 4) 停止面板
 5) 重启面板
 6) 修改端口
 7) 修改公共地址
 8) 修改管理员账号/密码
 9) 查看设置
10) 更新版本（git pull + 重启）
11) 卸载面板
12) 退出
MENU
    read -r -p "> " sel
    case "$sel" in
      1) ctrl_status ;;
      2) ctrl_logs ;;
      3) ctrl_start ;;
      4) ctrl_stop ;;
      5) ctrl_restart ;;
      6) ctrl_set_port ;;
      7) ctrl_set_public ;;
      8) ctrl_set_admin ;;
      9) ctrl_settings ;;
      10) update_panel ;;
      11) uninstall_panel ;;
      12) exit 0 ;;
    esac
  done
}

agent_menu() {
  while true; do
    cat <<'MENU'
[i-mo Agent] 请选择操作:
 1) 查看状态（Agent 运行情况）
 2) 查看最近日志
 3) 启动 Agent
 4) 停止 Agent
 5) 重启 Agent
 6) 查看当前设置
 7) 卸载 Agent
 8) 退出
MENU
    read -r -p "> " sel
    case "$sel" in
      1) agent_status ;;
      2) agent_logs ;;
      3) systemctl start "$SERVICE_AGENT" && agent_status ;;
      4) systemctl stop "$SERVICE_AGENT" && agent_status ;;
      5) agent_restart ;;
      6) agent_settings ;;
      7) uninstall_agent ;;
      8) exit 0 ;;
    esac
  done
}

main() {
  role=$(choose_role)
  case "$role" in
    server) server_menu ;;
    agent) agent_menu ;;
    both)
      echo "检测到主控和 Agent，选择要管理的角色："
      echo " 1) 主控面板"
      echo " 2) Agent"
      read -r -p "> " sel
      if [[ "$sel" == "1" ]]; then server_menu; else agent_menu; fi
      ;;
    none)
      echo "未检测到已安装的面板或 Agent。"
      echo "选择操作："
      echo " 1) 全自动安装主控面板"
      echo " 2) 退出"
      read -r -p "> " sel
      if [[ "$sel" == "1" ]]; then install_panel; else exit 0; fi
      ;;
  esac
}

main "$@"
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
