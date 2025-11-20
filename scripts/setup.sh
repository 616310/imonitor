#!/usr/bin/env bash
set -euo pipefail

# Interactive installer for the controller (server) on machines without Rust toolchain.

if [[ "$EUID" -ne 0 ]]; then
  echo "请使用 root 权限运行此脚本 (sudo bash scripts/setup.sh)" >&2
  exit 1
fi

default_dir="/opt/imonitor-lite"
default_user="imonitor"
default_public_url="http://127.0.0.1:8080"

read -r -p "安装目录 [${default_dir}]: " INSTALL_DIR
INSTALL_DIR=${INSTALL_DIR:-$default_dir}

read -r -p "运行用户 (将自动创建) [${default_user}]: " RUN_USER
RUN_USER=${RUN_USER:-$default_user}

read -r -p "公开访问地址 (IMONITOR_PUBLIC_URL) [${default_public_url}]: " PUBLIC_URL
PUBLIC_URL=${PUBLIC_URL:-$default_public_url}

echo "[1/5] 创建系统用户 ${RUN_USER}"
if ! id -u "$RUN_USER" >/dev/null 2>&1; then
  useradd --system --create-home --shell /usr/sbin/nologin "$RUN_USER"
fi

echo "[2/5] 拷贝程序到 ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"
tar cf - --exclude='.git' --exclude='target' . | tar xf - -C "$INSTALL_DIR"
chown -R "$RUN_USER":"$RUN_USER" "$INSTALL_DIR"

SERVICE_FILE="/etc/systemd/system/imonitor-lite.service"

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
echo "安装完成。请确保 8080 端口（或前置反代）开放，并通过 ${PUBLIC_URL} 访问。"
echo "若需更新 IMONITOR_PUBLIC_URL：编辑 ${SERVICE_FILE} 然后 systemctl daemon-reload && systemctl restart imonitor-lite"
