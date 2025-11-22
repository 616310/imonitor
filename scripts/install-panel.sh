#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[error] 安装失败 (行 ${LINENO}): ${BASH_COMMAND}" >&2' ERR

# 独立的主控面板安装脚本（可直接 curl | bash，一键自拉代码）。

if [[ "$EUID" -ne 0 ]]; then
  echo "请使用 root 权限运行此脚本 (sudo bash install-panel.sh)" >&2
  exit 1
fi

REPO_URL="https://github.com/616310/imonitor.git"
TMP_CLONE=""

prompt_default() {
  local msg="$1" default="$2" var=""
  if [[ -n "${IMONITOR_AUTO:-}" || ! -t 0 ]]; then
    echo "$default"
    return
  fi
  if read -r -p "$msg [$default]: " var < /dev/tty 2>/dev/null; then
    echo "${var:-$default}"
  else
    echo "$default"
  fi
}

prompt_secret() {
  local msg="$1" default="$2" var=""
  if [[ -n "${IMONITOR_AUTO:-}" || ! -t 0 ]]; then
    echo "$default"
    return
  fi
  if read -r -s -p "$msg (留空随机): " var < /dev/tty 2>/dev/null; then
    echo
    echo "${var:-$default}"
  else
    echo
    echo "$default"
  fi
}

generate_random_pass() {
  (
    set +e +E +o pipefail
    raw=$(od -An -N16 -t x1 /dev/urandom 2>/dev/null | tr -d ' \n')
    echo "${raw:0:16}"
  )
}

install_git_if_needed() {
  if command -v git >/dev/null 2>&1; then
    return
  fi
  echo "[git] 未检测到 git，尝试自动安装..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y git || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y git || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y git || true
  fi
}

detect_public_addr() {
  if ! command -v ip >/dev/null 2>&1; then
    echo "127.0.0.1"
    return 0
  fi
  local addr
  addr=$(
    set +e +o pipefail
    v6=$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
    if [[ -n "$v6" ]]; then
      echo "[$v6]"
      exit 0
    fi
    v4=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
    if [[ -n "$v4" ]]; then
      echo "$v4"
      exit 0
    fi
    echo "127.0.0.1"
  )
  echo "$addr"
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

ensure_binary() {
  local bin="$SOURCE_DIR/bin/imonitor"
  if [[ -x "$bin" ]]; then
    return
  fi
  echo "[download] 未找到 bin/imonitor，尝试从仓库下载预编译二进制..."
  local tmp_bin
  tmp_bin="$(mktemp -t imonitor-bin.XXXXXX)"
  local raw_url="${REPO_URL%.git}/raw/main/bin/imonitor"
  if curl -fSL --retry 3 --retry-delay 1 "$raw_url" -o "$tmp_bin"; then
    mkdir -p "$SOURCE_DIR/bin"
    install -m 0755 "$tmp_bin" "$bin"
    rm -f "$tmp_bin"
    return
  fi
  echo "[download] 获取 bin/imonitor 失败，请使用包含预编译二进制的发布包，或手动将可执行文件放到 $bin 后重试" >&2
  exit 1
}

# 定位源码目录：优先使用当前目录的上级（已在仓库内运行），否则自动下载仓库（支持无 git）
SCRIPT_SELF="${BASH_SOURCE[0]:-}"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SELF:-.}")" 2>/dev/null && pwd || pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd || true)"
if [[ ! -x "$SOURCE_DIR/bin/imonitor" ]]; then
  TMP_CLONE="$(mktemp -d)"
  trap '[[ -n "$TMP_CLONE" ]] && rm -rf "$TMP_CLONE"' EXIT
  install_git_if_needed
  if command -v git >/dev/null 2>&1; then
    echo "[clone] 拉取仓库：$REPO_URL"
    git clone --depth 1 "$REPO_URL" "$TMP_CLONE/imonitor"
    SOURCE_DIR="$TMP_CLONE/imonitor"
  else
    echo "[download] git 未安装或安装失败，使用压缩包下载仓库"
    curl -fsSL "${REPO_URL%.*}/archive/refs/heads/main.tar.gz" | tar xz -C "$TMP_CLONE"
    SOURCE_DIR="$TMP_CLONE/imonitor-main"
  fi
fi
ensure_binary

INSTALL_DIR="/opt/imonitor-lite"
RUN_USER="imonitor"
PORT="8080"
ADMIN_USER="admin"
OFFLINE_TIMEOUT="10"

HOST_DETECTED=$(detect_public_addr)
INSTALL_DIR=$(prompt_default "安装目录" "${INSTALL_DIR}")
RUN_USER=$(prompt_default "运行用户 (将自动创建)" "${RUN_USER}")
PORT=$(prompt_default "服务监听端口" "${PORT}")
ADDR_INPUT=$(prompt_default "公网访问地址/域名（留空自动检测）" "${HOST_DETECTED}")
HOST_NORMALIZED=$(normalize_host "$ADDR_INPUT")
ADMIN_USER=$(prompt_default "管理员用户名" "${ADMIN_USER}")
ADMIN_PASS_INPUT=$(prompt_secret "管理员密码" "")
if [[ -z "$ADMIN_PASS_INPUT" ]]; then
  ADMIN_PASS=$(generate_random_pass)
  echo "生成的管理员密码：$ADMIN_PASS"
else
  ADMIN_PASS="$ADMIN_PASS_INPUT"
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
Environment=IMONITOR_OFFLINE_TIMEOUT=${OFFLINE_TIMEOUT}
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
