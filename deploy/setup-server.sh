#!/usr/bin/env bash
# ==============================================================
# qr-app 服务器端一键安装脚本(需 root)
# 用法(在项目根目录执行,源码也可直接放在 /opt/qr-app 下):
#   sudo bash deploy/setup-server.sh
# 脚本会:安装 Node.js(如缺失)→ 准备项目文件到 /opt/qr-app → 安装依赖
#        → 生成 .env → 安装并启动 systemd 服务
# ==============================================================
set -euo pipefail

APP_NAME=qr-app
INSTALL_DIR=/opt/qr-app
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "请以 root 运行: sudo bash $0"
  exit 1
fi

# 1) 检查/安装 Node.js(要求 18+)
if ! command -v node >/dev/null 2>&1; then
  echo "[1/6] 未检测到 Node.js,开始安装(NodeSource LTS)..."
  if command -v yum >/dev/null 2>&1; then
    curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash -
    yum install -y nodejs
  elif command -v dnf >/dev/null 2>&1; then
    curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash -
    dnf install -y nodejs
  elif command -v apt-get >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt-get install -y nodejs
  else
    echo "无法识别包管理器,请手动安装 Node.js 18+ 后重新执行本脚本"
    exit 1
  fi
fi
NODE_BIN="$(command -v node)"
echo "[1/6] Node $("$NODE_BIN" -v) -> $NODE_BIN"

# 2) 准备项目文件到安装目录(不含 node_modules)
SRC_DIR="$PROJECT_DIR"
[[ -f "$SRC_DIR/server.js" ]] || SRC_DIR="$(pwd)"
echo "[2/6] 准备项目文件到 $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
if [[ "$(cd "$SRC_DIR" 2>/dev/null && pwd -P)" == "$(cd "$INSTALL_DIR" 2>/dev/null && pwd -P)" ]]; then
  echo "      源码已位于 $INSTALL_DIR,跳过复制"
else
  cp -f "$SRC_DIR/server.js" "$SRC_DIR/package.json" "$INSTALL_DIR/"
  [[ -f "$SRC_DIR/package-lock.json" ]] && cp -f "$SRC_DIR/package-lock.json" "$INSTALL_DIR/"
fi

# 3) 安装依赖(仅生产依赖)
echo "[3/6] 安装依赖..."
cd "$INSTALL_DIR"
npm install --omit=dev

# 4) 生成环境变量文件
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  [[ -f "$SRC_DIR/deploy/qr-app.env.example" ]] && cp -f "$SRC_DIR/deploy/qr-app.env.example" "$INSTALL_DIR/.env"
  echo "[4/6] 已生成 $INSTALL_DIR/.env —— 请编辑填入 SERVER_IP/UUID/PUBLIC_KEY/ACCESS_TOKEN 后重启服务"
else
  echo "[4/6] .env 已存在,保持不变"
fi
chmod 600 "$INSTALL_DIR/.env"

# 5) 安装并启动 systemd 服务
echo "[5/6] 安装 systemd 服务..."
sed "s|^ExecStart=.*|ExecStart=$NODE_BIN server.js|" "$SRC_DIR/deploy/qr-app.service" > /etc/systemd/system/qr-app.service
systemctl daemon-reload
systemctl enable --now qr-app

# 6) 自检
sleep 2
echo "[6/6] 自检:"
systemctl --no-pager --lines=5 status qr-app || true
curl -s -o /dev/null -w "  本机访问 http://127.0.0.1:8080/ -> %{http_code}\n" \
  -A "Mozilla/5.0 (qr-app-setup)" http://127.0.0.1:8080/ || true

echo ""
echo "部署完成。常用命令:"
echo "  查看状态: systemctl status qr-app"
echo "  查看日志: journalctl -u qr-app -f (应用日志: $INSTALL_DIR/logs)"
echo "  修改配置: vi $INSTALL_DIR/.env && systemctl restart qr-app"
