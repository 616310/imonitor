#!/usr/bin/env bash
set -euo pipefail

DEFAULT_ENDPOINT="__DEFAULT_ENDPOINT__"
SERVICE_NAME="imonitor-agent"
INSTALL_DIR="/opt/imonitor-agent"
ENV_FILE="$INSTALL_DIR/agent.env"
TOKEN=""
ENDPOINT=""
INTERVAL="3"
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

is_private_v4() {
  local ip="$1"
  [[ "$ip" =~ ^10\. ]] && return 0
  [[ "$ip" =~ ^192\.168\. ]] && return 0
  if [[ "$ip" =~ ^172\. ]]; then
    local second="${ip#172.}"
    second="${second%%.*}"
    [[ "$second" -ge 16 && "$second" -le 31 ]] && return 0
  fi
  return 1
}

detect_ip() {
  local prefer="$1" ip4 ip4_public ip6
  if command -v ip >/dev/null 2>&1; then
    ip4_public=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | while read -r ip; do is_private_v4 "$ip" || { echo "$ip"; break; }; done)
    ip4=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
    ip6=$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  fi
  if [[ "$prefer" == "v6" ]]; then
    [[ -n "$ip6" ]] && echo "[$ip6]" && return
    [[ -n "$ip4_public" ]] && echo "$ip4_public" && return
    [[ -n "$ip4" ]] && echo "$ip4" && return
  else
    [[ -n "$ip4_public" ]] && echo "$ip4_public" && return
    [[ -n "$ip4" ]] && echo "$ip4" && return
    [[ -n "$ip6" ]] && echo "[$ip6]" && return
  fi
  echo "127.0.0.1"
}

ctrl_env() {
  local key="$1"
  [[ -f "$CTRL_UNIT" ]] || return
  grep -o "^Environment=${key}=.*" "$CTRL_UNIT" | head -n1 | sed 's/^Environment='"$key"'=//;s/"//g'
}

ctrl_public_url() {
  ctrl_env "IMONITOR_PUBLIC_URL"
}

ctrl_bind_port() {
  local bind
  bind=$(ctrl_env "IMONITOR_BIND")
  [[ -z "$bind" ]] && return
  echo "${bind##*:}" | tr -d ']'
}

rewrite_public_url_port() {
  local url="$1" port="$2"
  [[ -z "$url" ]] && url="http://127.0.0.1:${port}"
  local scheme="http" rest host path
  if [[ "$url" == *"://"* ]]; then
    scheme="${url%%://*}"
    rest="${url#*://}"
  else
    rest="$url"
  fi
  host="${rest%%/*}"
  path="${rest#"$host"}"
  [[ "$path" == "$rest" ]] && path=""
  if [[ "$host" == \[*\]* ]]; then
    local closing="${host%%]*}"
    local closing_len=${#closing}
    local suffix="${host:$((closing_len+1))}"
    if [[ "$suffix" == :* ]]; then
      host="${host:0:$((closing_len+1))}"
    fi
  else
    host="${host%%:*}"
  fi
  echo "${scheme}://${host}:${port}${path}"
}

ctrl_status() {
  local state since host port
  state=$(systemctl is-active "$SERVICE_CTRL" 2>/dev/null || true)
  since=$(systemctl show "$SERVICE_CTRL" -p ActiveEnterTimestamp --value 2>/dev/null)
  host=$(ctrl_public_url)
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
  port=$(ctrl_bind_port)
  host=$(ctrl_public_url)
  admin_user=$(ctrl_env "IMONITOR_ADMIN_USER")
  admin_pass=$(ctrl_env "IMONITOR_ADMIN_PASS")
  echo "当前设置："
  echo "  端口: ${port:-未知}"
  echo "  公共地址: ${host:-未知}"
  echo "  管理员: ${admin_user:-未知}"
  echo "  管理员密码: ${admin_pass:-<未设置>}"
}

ctrl_set_port() {
  require_root
  local port default_port
  default_port=$(ctrl_bind_port)
  port=$(prompt "新的服务端口" "${default_port:-8080}")
  local bind="[::]:${port}"
  sed -i "s?^Environment=IMONITOR_BIND=.*?Environment=IMONITOR_BIND=${bind}?g" "$CTRL_UNIT"
  local cur_public new_public
  cur_public=$(ctrl_public_url)
  new_public=$(rewrite_public_url_port "$cur_public" "$port")
  sed -i "s?^Environment=IMONITOR_PUBLIC_URL=.*?Environment=IMONITOR_PUBLIC_URL=${new_public}?g" "$CTRL_UNIT"
  echo "端口已更新为 ${port}"
  systemctl daemon-reload
  ctrl_restart
}

ctrl_set_bind_mode() {
  require_root
  local port bind choice host_default cur_public
  port=$(ctrl_bind_port)
  port=${port:-8080}
  echo "选择监听模式:"
  echo " 1) IPv4+IPv6 (默认)"
  echo " 2) 仅 IPv4"
  echo " 3) 仅 IPv6"
  read -r -p "> " choice
  case "$choice" in
    2) bind="0.0.0.0:${port}"; host_default=$(detect_ip "v4"); host_default="http://${host_default}:${port}" ;;
    3) bind="[::]:${port}"; host_default=$(detect_ip "v6"); host_default="http://${host_default}:${port}" ;;
    *) bind="[::]:${port}"; host_default=$(detect_ip "v4"); host_default="http://${host_default}:${port}" ;;
  esac
  line_in_file "Environment=IMONITOR_BIND" "$CTRL_UNIT" "Environment=IMONITOR_BIND=${bind}"
  cur_public=$(ctrl_env "IMONITOR_PUBLIC_URL")
  line_in_file "Environment=IMONITOR_PUBLIC_URL" "$CTRL_UNIT" "Environment=IMONITOR_PUBLIC_URL=${host_default}"
  echo "监听已更新为 ${bind}"
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
  local keep_cli=0
  has_service "$SERVICE_CTRL" && keep_cli=1
  systemctl disable --now "${SERVICE_AGENT}.service" 2>/dev/null || true
  rm -f /etc/systemd/system/${SERVICE_AGENT}.service
  systemctl daemon-reload
  local agent_dir="/opt/imonitor-agent"
  local loader_sys="/lib/ld-musl-x86_64.so.1"
  local loader_pkg="${agent_dir}/ld-musl-x86_64.so.1"
  if [[ -f "$loader_sys" && -f "$loader_pkg" ]] && cmp -s "$loader_sys" "$loader_pkg"; then
    rm -f "$loader_sys"
  fi
  pkill -f "${agent_dir}/agent" 2>/dev/null || true
  rm -rf "$agent_dir"
  if [[ $keep_cli -eq 0 ]]; then
    rm -f /usr/local/bin/i-mo
  fi
  echo "Agent 已彻底卸载（目录、systemd、残留进程与 i-mo 清理完成）"
}

uninstall_panel() {
  require_root
  local keep_cli=0
  has_service "$SERVICE_AGENT" && keep_cli=1
  systemctl disable --now "${SERVICE_CTRL}.service" 2>/dev/null || true
  rm -f /etc/systemd/system/${SERVICE_CTRL}.service
  systemctl daemon-reload
  rm -rf "$CTRL_DIR"
  if [[ $keep_cli -eq 0 ]]; then
    rm -f /usr/local/bin/i-mo
  fi
  echo "已彻底卸载面板（目录、systemd、残留进程与 i-mo 清理完成）"
}

update_panel() {
  require_root
  local tmp_dir src_dir tarball
  tmp_dir=$(mktemp -d)
  tarball="${REPO_URL%.git}/archive/refs/heads/main.tar.gz"
  echo "下载最新版本..."
  if ! curl -fSL --retry 3 --retry-delay 1 "$tarball" -o "$tmp_dir/main.tar.gz"; then
    echo "下载失败，无法更新" >&2
    rm -rf "$tmp_dir"
    return 1
  fi
  tar -xzf "$tmp_dir/main.tar.gz" -C "$tmp_dir"
  src_dir=$(find "$tmp_dir" -maxdepth 1 -type d -name "imonitor*" | head -n1)
  if [[ -z "$src_dir" ]]; then
    echo "解压失败，未找到源码目录" >&2
    rm -rf "$tmp_dir"
    return 1
  fi
  echo "同步文件到 $CTRL_DIR（保留 data/）..."
  tar cf - --exclude='data' --exclude='.git' --exclude='target' -C "$src_dir" . | tar xf - -C "$CTRL_DIR"
  chown -R imonitor:imonitor "$CTRL_DIR" 2>/dev/null || true
  rm -rf "$tmp_dir"
  systemctl daemon-reload
  ctrl_restart
  echo "更新完成"
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
 7) 修改监听地址族 (IPv4/IPv6)
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
      7) ctrl_set_bind_mode ;;
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
    agent)
      echo "提示：如需安装主控面板，请使用独立脚本 scripts/install-panel.sh"
      agent_menu
      ;;
    both)
      echo "检测到主控和 Agent，选择要管理的角色："
      echo " 1) 主控面板"
      echo " 2) Agent"
      read -r -p "> " sel
      if [[ "$sel" == "1" ]]; then server_menu; else agent_menu; fi
      ;;
    none)
      echo "未检测到已安装的面板或 Agent。"
      echo "请使用独立安装脚本部署主控面板（示例）："
      echo "  git clone https://github.com/616310/imonitor.git"
      echo "  cd imonitor/scripts && sudo bash install-panel.sh"
      echo "或使用已发布的安装包内 scripts/install-panel.sh"
      exit 0
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
ExecStart=$AGENT_BIN --token=\${IMONITOR_TOKEN} --endpoint=\${IMONITOR_ENDPOINT} --interval=\${IMONITOR_INTERVAL} --flag=\${IMONITOR_FLAG}
KillMode=control-group
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
