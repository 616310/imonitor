#!/usr/bin/env bash
set -euo pipefail

# 独立的主控面板安装脚本（可直接 curl | bash，一键自拉代码）。

if [[ "$EUID" -ne 0 ]]; then
  echo "请使用 root 权限运行此脚本 (sudo bash install-panel.sh)" >&2
  exit 1
fi

REPO_URL="https://github.com/616310/imonitor.git"
TMP_CLONE=""

detect_public_addr() {
  local addr
  addr=$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  if [[ -n "$addr" ]]; then echo "[$addr]"; return; fi
  addr=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  if [[ -n "$addr" ]]; then echo "$addr"; return; fi
  echo "127.0.0.1"
}

normalize_host() {
  local host="$1"
  host=${host#http://}
  host=${host#https://}
  host=${host%%/*}
  if [[ "$host" == *:*:* && "$host" != \[* ]]; then
    host="[$host]"
  fi
  echo "$host"
}

# 定位源码目录：优先使用当前目录的上级（已在仓库内运行），否则自动下载仓库（支持无 git）
SCRIPT_SELF="${BASH_SOURCE[0]:-}"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SELF:-.}")" 2>/dev/null && pwd || pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || true)"
if [[ ! -x "$SOURCE_DIR/bin/imonitor" ]]; then
  TMP_CLONE="$(mktemp -d)"
  trap '[[ -n "$TMP_CLONE" ]] && rm -rf "$TMP_CLONE"' EXIT
  if command -v git >/dev/null 2>&1; then
    echo "[clone] 拉取仓库：$REPO_URL"
    git clone --depth 1 "$REPO_URL" "$TMP_CLONE/imonitor"
    SOURCE_DIR="$TMP_CLONE/imonitor"
  else
    echo "[download] git 未安装，使用压缩包下载仓库"
    curl -fsSL "${REPO_URL%.*}/archive/refs/heads/main.tar.gz" | tar xz -C "$TMP_CLONE"
    SOURCE_DIR="$TMP_CLONE/imonitor-main"
  fi
  if [[ ! -x "$SOURCE_DIR/bin/imonitor" ]]; then
    echo "未找到可执行文件 $SOURCE_DIR/bin/imonitor ，请先在源码根目录构建：cargo build --release" >&2
    exit 1
  fi
fi

INSTALL_DIR="/opt/imonitor-lite"
RUN_USER="imonitor"
PORT="8080"
ADMIN_USER="admin"

HOST_DETECTED=$(detect_public_addr)
read -r -p "安装目录 [${INSTALL_DIR}]: " input; INSTALL_DIR=${input:-$INSTALL_DIR}
read -r -p "运行用户 (将自动创建) [${RUN_USER}]: " input; RUN_USER=${input:-$RUN_USER}
read -r -p "服务监听端口 [${PORT}]: " input; PORT=${input:-$PORT}
read -r -p "公网访问地址/域名（留空自动检测） [${HOST_DETECTED}]: " input; input=${input:-$HOST_DETECTED}
HOST_NORMALIZED=$(normalize_host "$input")
read -r -p "管理员用户名 [${ADMIN_USER}]: " input; ADMIN_USER=${input:-$ADMIN_USER}
read -r -s -p "管理员密码（留空自动生成随机密码）: " ADMIN_PASS; echo
if [[ -z "$ADMIN_PASS" ]]; then
  ADMIN_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
  echo "生成的管理员密码：$ADMIN_PASS"
fi

PUBLIC_URL="http://${HOST_NORMALIZED}:${PORT}"
BIND_ADDR="[::]:${PORT}"

echo "[1/4] 创建系统用户 ${RUN_USER}"
if ! id -u "$RUN_USER" >/dev/null 2>&1; then
  useradd --system --create-home --shell /usr/sbin/nologin "$RUN_USER"
fi

echo "[2/4] 拷贝程序到 ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"
tar cf - --exclude='.git' --exclude='target' -C "$SOURCE_DIR" . | tar xf - -C "$INSTALL_DIR"
chown -R "$RUN_USER":"$RUN_USER" "$INSTALL_DIR"
install -m 0755 "$INSTALL_DIR/scripts/i-mo" /usr/local/bin/i-mo

SERVICE_FILE="/etc/systemd/system/imonitor-lite.service"
echo "[3/4] 写入 systemd 单元 ${SERVICE_FILE}"
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

echo "[4/4] 重新加载并启动服务"
systemctl daemon-reload
systemctl enable --now imonitor-lite.service

echo
echo "安装完成。访问地址：${PUBLIC_URL}"
echo "管理员账号：${ADMIN_USER}"
echo "管理员密码：${ADMIN_PASS}"
echo "如需修改地址/端口/凭据：编辑 ${SERVICE_FILE} 后 systemctl daemon-reload && systemctl restart imonitor-lite.service"
