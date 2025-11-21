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

detect_public_addr() {
  # Prefer local global addresses to avoid NAT误判
  addr=$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  if [[ -n "$addr" ]]; then echo "$addr"; return; fi
  addr=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  if [[ -n "$addr" ]]; then echo "$addr"; return; fi
  # Fallback to external services
  for cmd in \
    "curl -4 -s https://ifconfig.co" \
    "curl -4 -s https://api.ipify.org"
  do
    addr=$(bash -lc "$cmd" 2>/dev/null | tr -d ' \n\r')
    if [[ -n "$addr" ]]; then echo "$addr"; return; fi
  done
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

AUTO_HOST=$(detect_public_addr || echo "127.0.0.1")
read -r -p "公网访问地址/域名（留空自动检测） [${AUTO_HOST}]: " INPUT_HOST
INPUT_HOST=${INPUT_HOST:-$AUTO_HOST}
HOST_NORMALIZED=$(normalize_host "$INPUT_HOST")

PUBLIC_URL="http://${HOST_NORMALIZED}:${PORT}"
BIND_ADDR="[::]:${PORT}"

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
Environment=IMONITOR_PUBLIC_URL=${PUBLIC_URL}
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
echo "安装完成。请确保 ${PORT} 端口（或前置反代）开放，并通过 ${PUBLIC_URL} 访问。"
echo "若需更新 IMONITOR_PUBLIC_URL/管理员账号：编辑 ${SERVICE_FILE} 然后 systemctl daemon-reload && systemctl restart imonitor-lite"
