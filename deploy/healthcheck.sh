#!/usr/bin/env bash
# ==============================================================
# qr-app 健康检查脚本(在服务器上以 root 运行)
# 用法: sudo bash deploy/healthcheck.sh
# 检查: 环境 -> 文件 -> .env -> systemd -> 端口 -> HTTP -> 日志
# ==============================================================
set -uo pipefail

APP_DIR=/opt/qr-app
ENV_FILE=$APP_DIR/.env
SERVICE=qr-app

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
PASS=0; WARN=0; FAIL=0

ok()   { echo -e "${GREEN}[通过]${NC} $*"; PASS=$((PASS+1)); }
warn() { echo -e "${YELLOW}[警告]${NC} $*"; WARN=$((WARN+1)); }
fail() { echo -e "${RED}[失败]${NC} $*"; FAIL=$((FAIL+1)); }
info() { echo -e "${CYAN}[信息]${NC} $*"; }
section() { echo; echo "========== $* =========="; }

# 从 .env 读取变量(不存在时返回空)
get_env() {
  local key=$1
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'"
}

# 占位值(表示还没真正配置)
is_placeholder() {
  case "$1" in
    ""|"1.2.3.4"|"你的"*|"00000000-0000-0000-0000-000000000000"|"YOUR_PUBLIC_KEY"|"你的Reality公钥") return 0 ;;
    *) return 1 ;;
  esac
}

section "1. 基础环境"
if command -v node >/dev/null 2>&1; then
  ok "Node.js: $(node -v)  ($(command -v node))"
else
  fail "未找到 node,请先安装 Node.js 18+"
fi

section "2. 项目文件 ($APP_DIR)"
if [[ -d "$APP_DIR" ]]; then
  ok "目录存在: $APP_DIR"
else
  fail "目录不存在: $APP_DIR(项目未部署)"
fi
[[ -f "$APP_DIR/server.js" ]]    && ok "server.js 存在"    || fail "缺少 $APP_DIR/server.js"
[[ -f "$APP_DIR/package.json" ]] && ok "package.json 存在" || fail "缺少 $APP_DIR/package.json"
[[ -d "$APP_DIR/node_modules/qrcode" ]] && ok "依赖 qrcode 已安装" || fail "依赖未安装,请执行: cd $APP_DIR && npm install --omit=dev"

section "3. 环境变量 (.env)"
if [[ -f "$ENV_FILE" ]]; then
  ok ".env 存在"
  perm=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '?')
  [[ "$perm" == "600" ]] && ok ".env 权限为 600(安全)" || warn ".env 权限为 $perm,建议: chmod 600 $ENV_FILE"

  for key in SERVER_IP NODE_PORT UUID SNI PUBLIC_KEY; do
    val=$(get_env "$key")
    if is_placeholder "$val"; then
      fail "$key 未配置(当前值: '${val:-空}')"
    else
      ok "$key = $val"
    fi
  done
  [[ -n "$(get_env SHORT_ID)" ]] && ok "SHORT_ID = $(get_env SHORT_ID)" || warn "SHORT_ID 为空(需与 Xray 一致)"
  [[ -n "$(get_env ACCESS_TOKEN)" ]] && ok "ACCESS_TOKEN 已设置" || warn "ACCESS_TOKEN 为空,任何人都能访问二维码页"
else
  fail ".env 不存在,请先创建 $ENV_FILE"
fi

section "4. systemd 服务"
if [[ -f "/etc/systemd/system/$SERVICE.service" ]]; then
  ok "unit 文件存在"
else
  fail "unit 文件不存在(/etc/systemd/system/$SERVICE.service),需执行部署脚本或手动创建"
fi
if command -v systemctl >/dev/null 2>&1; then
  is_enabled=$(systemctl is-enabled "$SERVICE" 2>/dev/null || echo "missing")
  is_active=$(systemctl is-active "$SERVICE" 2>/dev/null || echo "inactive")
  [[ "$is_enabled" == "enabled" ]] && ok "开机自启: enabled" || warn "开机自启: $is_enabled(建议 systemctl enable $SERVICE)"
  [[ "$is_active" == "active" ]] && ok "服务状态: active(running)" || fail "服务状态: $is_active(未在运行)"
else
  warn "无 systemctl,跳过服务检查"
fi

section "5. 端口监听"
PORT=$(get_env PORT); PORT=${PORT:-8080}
if command -v ss >/dev/null 2>&1; then
  LISTEN=$(ss -tlnp 2>/dev/null | grep -E ":${PORT}[[:space:]]" || true)
elif command -v netstat >/dev/null 2>&1; then
  LISTEN=$(netstat -tlnp 2>/dev/null | grep -E ":${PORT}[[:space:]]" || true)
else
  LISTEN=""
fi
if [[ -n "$LISTEN" ]]; then
  ok "端口 $PORT 正在监听"
  info "$LISTEN"
else
  fail "端口 $PORT 未监听"
fi

section "6. HTTP 服务"
HOST=$(get_env HOST); HOST=${HOST:-127.0.0.1}
TOKEN=$(get_env ACCESS_TOKEN)
BASE="http://127.0.0.1:${PORT}/"
# 必须用浏览器 UA:server.js 会把 curl/python-requests 等 UA 当扫描器拦截(返回 404)
UA="Mozilla/5.0 (qr-app-healthcheck)"

if [[ -n "$TOKEN" ]]; then
  # 带令牌应返回 200
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -A "$UA" "${BASE}?k=${TOKEN}" || true)
  [[ "$code" == "200" ]] && ok "带令牌访问 -> 200" || fail "带令牌访问 -> ${code:-超时/无响应}"
  # 不带令牌应被拒绝(403/401)
  code2=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -A "$UA" "$BASE" || true)
  [[ "$code2" == "403" || "$code2" == "401" ]] && ok "无令牌访问被拦截 -> $code2" || warn "无令牌访问返回 $code2(应为 403)"
else
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -A "$UA" "$BASE" || true)
  [[ "$code" == "200" ]] && ok "访问 $BASE -> 200" || fail "访问 $BASE -> ${code:-超时/无响应}"
fi

# 页面内容是否含 vless 链接
BODY=$(curl -s --max-time 5 -A "$UA" "${BASE}?k=${TOKEN}" 2>/dev/null || true)
if echo "$BODY" | grep -q "vless://"; then
  ok "页面包含 vless:// 链接"
  info "链接: $(echo "$BODY" | grep -o 'vless://[^"<> ]*' | head -1)"
else
  warn "页面未找到 vless:// 链接(可能是内容/编码差异,手动打开页面确认)"
fi

# 订阅端点:以 text/plain 返回 vless 链接
SUB=$(get_env SUB_PATH); SUB=${SUB:-/sub}
SUB_URL="${BASE}${SUB#/}?k=${TOKEN}"
sub_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -A "$UA" "$SUB_URL" || true)
sub_body=$(curl -s --max-time 5 -A "$UA" "$SUB_URL" 2>/dev/null || true)
if [[ "$sub_code" == "200" ]] && echo "$sub_body" | grep -q "vless://"; then
  ok "订阅地址 ${SUB_URL} -> 200 且含 vless 链接"
else
  fail "订阅地址 ${SUB_URL} -> ${sub_code:-无响应}"
fi

section "7. 日志"
if command -v journalctl >/dev/null 2>&1; then
  echo "---- journalctl -u $SERVICE (最近 10 行) ----"
  journalctl -u "$SERVICE" -n 10 --no-pager 2>/dev/null || echo "(无日志)"
fi
echo "---- 应用日志(最近 5 行) ----"
tail -n 5 "$APP_DIR"/logs/*.log 2>/dev/null || echo "(无日志文件 $APP_DIR/logs)"

section "8. 汇总"
echo -e "通过: ${GREEN}${PASS}${NC}  警告: ${YELLOW}${WARN}${NC}  失败: ${RED}${FAIL}${NC}"
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}服务正常。${NC} 公网访问: http://<公网IP>:${PORT}/?k=${TOKEN}   (或 SSH 隧道: ssh -L ${PORT}:127.0.0.1:${PORT} root@服务器IP)"
  exit 0
else
  echo -e "${RED}存在 ${FAIL} 项失败,请按上面的 [失败] 提示逐项修复。${NC}"
  exit 1
fi
