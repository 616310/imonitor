#!/usr/bin/env bash
set -euo pipefail

# Interactive installer for the controller (server) on machines without Rust toolchain.

if [[ "$EUID" -ne 0 ]]; then
  echo "请使用 root 权限运行此脚本 (sudo bash scripts/setup.sh)" >&2
  exit 1
fi

default_dir="/opt/imonitor-lite"
default_user="imonitor"
default_port="8080"
default_admin_user="admin"

read -r -p "安装目录 [${default_dir}]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-$default_dir}

read -r -p "运行用户 (将自动创建) [${default_user}]: " RUN_USER
RUN_USER=${RUN_USER:-$default_user}

read -r -p "服务监听端口 [${default_port}]: " PORT
PORT=${PORT:-$default_port}

read -r -p "管理用户名 [${default_admin_user}]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-$default_admin_user}
read -r -s -p "管理密码（留空自动生成随机密码）: " ADMIN_PASS
echo
if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
  echo "生成的管理密码：$ADMIN_PASS"
fi

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

detect_public_addr() {
  local v4_public="" v4_any="" v6_public="" addr
  if command -v ip >/dev/null 2>&1; then
    v4_public=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | while read -r ip; do is_private_v4 "$ip" || { echo "$ip"; break; }; done)
    v4_any=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
    v6_public=$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  fi
  if [[ -n "$v4_public" ]]; then echo "$v4_public"; return; fi
  if [[ -n "$v6_public" ]]; then echo "$v6_public"; return; fi
  # Fallback to external services（适用于只有私网地址时）
  for cmd in \
    "curl -4 -s https://ifconfig.co" \
    "curl -4 -s https://api.ipify.org"
  do
    addr=$(bash -lc "$cmd" 2>/dev/null | tr -d ' \n\r')
    if [[ -n "$addr" ]]; then echo "$addr"; return; fi
  done
  if [[ -n "$v4_any" ]]; then echo "$v4_any"; return; fi
  echo "127.0.0.1"
}

normalize_host() {
  local host="$1"
  host=${host#http://}
  host=${host#https://}
  host=${host%%/*}
  # If IPv6 without brackets, wrap.
  if [[ "$host" == *:*:* && "$host" != \[* ]]; then
    host="[$host]"
  fi
  echo "$host"
}

detect_private_v4() {
  if ! command -v ip >/dev/null 2>&1; then
    return 0
  fi
  ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | while read -r ip; do
    if is_private_v4 "$ip"; then
      echo "$ip"
      break
    fi
  done
}

detect_public_v4() {
  if ! command -v ip >/dev/null 2>&1; then
    return 0
  fi
  ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | while read -r ip; do
    if ! is_private_v4 "$ip"; then
      echo "$ip"
      break
    fi
  done
}

detect_public_v6() {
  if ! command -v ip >/dev/null 2>&1; then
    return 0
  fi
  ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

ask_yes() {
  local msg="$1" default="$2" ans
  local hint="[Y/n]"
  if [[ "$default" =~ ^[Yy]$ ]]; then
    hint="[Y/n]"
  else
    hint="[y/N]"
  fi
  read -r -p "$msg $hint: " ans
  if [[ -z "$ans" ]]; then
    ans="$default"
  fi
  [[ "$ans" =~ ^[Yy]$ ]]
}

format_bind() {
  local host="$1" port="$2"
  if [[ "$host" == *:* && "$host" != \[* ]]; then
    echo "[${host}]:${port}"
  else
    echo "${host}:${port}"
  fi
}

format_url() {
  local host="$1" port="$2"
  if [[ "$host" == *:* && "$host" != \[* ]]; then
    echo "http://[${host}]:${port}"
  else
    echo "http://${host}:${port}"
  fi
}

LAN_V4=$(detect_private_v4 || true)
PUB_V4=$(detect_public_v4 || true)
PUB_V6=$(detect_public_v6 || true)
BIND_LIST=()
PUBLIC_URLS=()

add_binding() {
  local host_input="$1"
  [[ -z "$host_input" ]] && return
  local host
  host=$(normalize_host "$host_input")
  BIND_LIST+=("$(format_bind "$host" "$PORT")")
  PUBLIC_URLS+=("$(format_url "$host" "$PORT")")
}

if [[ -n "$LAN_V4" ]]; then
  if ask_yes "绑定内网 IPv4 (${LAN_V4})" "Y"; then
    read -r -p "内网 IPv4 地址 [${LAN_V4}]: " v; v=${v:-$LAN_V4}
    add_binding "$v"
  fi
fi

if [[ -n "$PUB_V4" ]]; then
  if ask_yes "绑定公网 IPv4 (${PUB_V4})" "Y"; then
    read -r -p "公网 IPv4 地址 [${PUB_V4}]: " v; v=${v:-$PUB_V4}
    add_binding "$v"
  fi
else
  read -r -p "未检测到公网 IPv4，如需绑定请输入（留空跳过）: " v
  add_binding "$v"
fi

if [[ -n "$PUB_V6" ]]; then
  if ask_yes "绑定公网 IPv6 (${PUB_V6})" "Y"; then
    read -r -p "公网 IPv6 地址 [${PUB_V6}]: " v; v=${v:-$PUB_V6}
    add_binding "$v"
  fi
else
  read -r -p "未检测到公网 IPv6，如需绑定请输入（留空跳过）: " v
  add_binding "$v"
fi

if [[ ${#BIND_LIST[@]} -eq 0 ]]; then
  read -r -p "未选择任何地址，默认绑定所有接口 [0.0.0.0]: " v
  v=${v:-0.0.0.0}
  add_binding "$v"
fi

PUBLIC_URLS_STR=$(IFS=,; echo "${PUBLIC_URLS[*]}")
BIND_ADDR=$(IFS=,; echo "${BIND_LIST[*]}")

echo "[1/5] 创建系统用户 ${RUN_USER}"
if ! id -u "$RUN_USER" >/dev/null 2>&1; then
  useradd --system --create-home --shell /usr/sbin/nologin "$RUN_USER"
fi

echo "[2/5] 拷贝程序到 ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"
tar cf - --exclude='.git' --exclude='target' . | tar xf - -C "$INSTALL_DIR"
chown -R "$RUN_USER":"$RUN_USER" "$INSTALL_DIR"

SERVICE_FILE="/etc/systemd/system/imonitor-lite.service"
install -m 0755 "$INSTALL_DIR/scripts/i-mo" /usr/local/bin/i-mo

echo "[3/5] 写入 systemd 单元 ${SERVICE_FILE}"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=iMonitor Lite Central Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
WorkingDirectory=${INSTALL_DIR}
Environment=IMONITOR_PUBLIC_URL=${PUBLIC_URLS_STR}
Environment=IMONITOR_BIND=${BIND_ADDR}
Environment=IMONITOR_ADMIN_USER=${ADMIN_USER}
Environment=IMONITOR_ADMIN_PASS=${ADMIN_PASS}
ExecStart=${INSTALL_DIR}/bin/imonitor
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "[4/5] 重新加载并启动服务"
systemctl daemon-reload
systemctl enable --now imonitor-lite.service

echo "[5/5] 状态查看"
systemctl --no-pager status imonitor-lite.service || true

echo
echo "安装完成。可通过以下地址访问："
for url in "${PUBLIC_URLS[@]}"; do
  echo "  - ${url}"
done
echo "接入节点命令："
for url in "${PUBLIC_URLS[@]}"; do
  echo "  curl -fsSL ${url}/install.sh | bash -s -- --token=<TOKEN> --endpoint=${url}"
done
echo "若需更新 IMONITOR_PUBLIC_URL/管理员账号：编辑 ${SERVICE_FILE} 然后 systemctl daemon-reload && systemctl restart imonitor-lite"
