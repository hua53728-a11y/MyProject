#!/usr/bin/env bash
# ==============================================================
# qr-app 服务器端一键安装脚本(需 root)
# 用法: sudo bash deploy/setup-server.sh
# ==============================================================
set -euo pipefail

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
NODE_MAJOR="$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')"
if (( NODE_MAJOR < 18 )); then
  echo "错误：需要 Node.js 18+，当前版本为 $("$NODE_BIN" -v)" >&2
  exit 1
fi
echo "[1/6] Node $("$NODE_BIN" -v) -> $NODE_BIN"

# 2) 准备项目文件到安装目录(不含 node_modules)
SRC_DIR="$PROJECT_DIR"
[[ -f "$SRC_DIR/server.js" ]] || SRC_DIR="$(pwd)"
[[ -f "$SRC_DIR/server.js" && -f "$SRC_DIR/package.json" ]] || { echo "错误：找不到 server.js/package.json" >&2; exit 1; }
echo "[2/6] 准备项目文件到 $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
if [[ "$(cd "$SRC_DIR" && pwd -P)" == "$(cd "$INSTALL_DIR" && pwd -P)" ]]; then
  echo "      源码已位于 $INSTALL_DIR,跳过复制"
else
  cp -f "$SRC_DIR/server.js" "$SRC_DIR/package.json" "$INSTALL_DIR/"
  [[ -f "$SRC_DIR/package-lock.json" ]] && cp -f "$SRC_DIR/package-lock.json" "$INSTALL_DIR/"
fi

# 3) 安装依赖(仅生产依赖)
echo "[3/6] 安装依赖..."
cd "$INSTALL_DIR"
npm ci --omit=dev 2>/dev/null || npm install --omit=dev

# 4) 创建并填充环境变量文件
if [[ ! -f "$INSTALL_DIR/.env" ]]; then
  cp "$SRC_DIR/deploy/qr-app.env.example" "$INSTALL_DIR/.env"
fi
echo "[4/6] 自动生成运行参数..."
bash "$SRC_DIR/deploy/generate-runtime-config.sh" "$INSTALL_DIR/.env"

# 5) 安装并启动 systemd 服务
 echo "[5/6] 安装 systemd 服务..."
NODE_DIR="$(dirname "$NODE_BIN")"
mkdir -p /etc/systemd/system
sed "s|^ExecStart=.*|ExecStart=$NODE_BIN server.js|" "$SRC_DIR/deploy/qr-app.service" > /etc/systemd/system/qr-app.service
systemctl daemon-reload
systemctl enable --now qr-app

# 6) 自检
sleep 2
echo "[6/6] 自检:"
systemctl --no-pager --lines=5 status qr-app || true
ACCESS_TOKEN="$(grep -E '^ACCESS_TOKEN=' "$INSTALL_DIR/.env" | tail -n 1 | cut -d= -f2-)"
HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -A 'Mozilla/5.0 (qr-app-setup)' "http://127.0.0.1:8080/?k=${ACCESS_TOKEN}" || true)"
echo "  本机二维码页面: HTTP ${HTTP_CODE:-无响应}"
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "错误：本机 HTTP 自检未通过，请检查 journalctl -u qr-app。" >&2
  exit 1
fi

echo
echo "部署完成。应用页面默认仅本机可访问： http://127.0.0.1:8080/?k=<ACCESS_TOKEN>"
echo "查看令牌: sudo grep '^ACCESS_TOKEN=' $INSTALL_DIR/.env"
echo "服务状态: sudo systemctl status qr-app"
echo "服务日志: sudo journalctl -u qr-app -f"
echo "请将 $INSTALL_DIR/reality-private-key 配置到你现有 Xray Reality 入站后，才能连接代理节点。"
echo "需要公网访问时，请配置 HTTPS 反向代理并按需设置 TRUST_PROXY=1。"
