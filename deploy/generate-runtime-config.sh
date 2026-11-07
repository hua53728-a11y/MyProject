#!/usr/bin/env bash
# Generate runtime credentials for qr-app on the target server.
# Usage: sudo bash deploy/generate-runtime-config.sh [/opt/qr-app/.env]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${1:-${APP_DIR:-/opt/qr-app}/.env}"
APP_DIR="$(cd "$(dirname "$ENV_FILE")" && pwd)"
PRIVATE_KEY_FILE="${REALITY_PRIVATE_KEY_FILE:-$APP_DIR/reality-private-key}"
TEMPLATE="$PROJECT_DIR/deploy/qr-app.env.example"

command -v node >/dev/null 2>&1 || { echo "错误：需要 Node.js 18+。" >&2; exit 1; }
mkdir -p "$APP_DIR"
if [[ ! -f "$ENV_FILE" ]]; then
  [[ -f "$TEMPLATE" ]] || { echo "错误：找不到环境变量模板 $TEMPLATE" >&2; exit 1; }
  cp "$TEMPLATE" "$ENV_FILE"
fi

# Preserve an already configured address. Otherwise discover the public IPv4,
# or let an operator provide SERVER_IP_OVERRIDE (useful on restricted networks).
CURRENT_SERVER_IP="$(grep -E '^SERVER_IP=' "$ENV_FILE" | tail -n 1 | cut -d= -f2- | tr -d '\"' | tr -d "'")"
SERVER_IP_VALUE="${SERVER_IP_OVERRIDE:-$CURRENT_SERVER_IP}"
if [[ -z "$SERVER_IP_VALUE" || "$SERVER_IP_VALUE" == *'你的'* || "$SERVER_IP_VALUE" == "1.2.3.4" ]]; then
  SERVER_IP_VALUE="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
fi
if [[ -z "$SERVER_IP_VALUE" || "$SERVER_IP_VALUE" == *'你的'* || "$SERVER_IP_VALUE" == "1.2.3.4" ]]; then
  echo "错误：无法自动获取公网 IPv4。请在 $ENV_FILE 中手动设置 SERVER_IP，或使用 SERVER_IP_OVERRIDE=你的公网IP 重新运行。" >&2
  exit 1
fi

export ENV_FILE PRIVATE_KEY_FILE SERVER_IP_VALUE
node <<'NODE'
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const envFile = process.env.ENV_FILE;
const privateKeyFile = process.env.PRIVATE_KEY_FILE;
let lines = fs.readFileSync(envFile, 'utf8').split(/\r?\n/);
const get = (key) => {
  const line = [...lines].reverse().find((item) => item.startsWith(`${key}=`));
  return line ? line.slice(key.length + 1).replace(/^['"]|['"]$/g, '') : '';
};
const set = (key, value) => {
  const index = lines.findLastIndex((item) => item.startsWith(`${key}=`));
  const line = `${key}=${value}`;
  if (index >= 0) lines[index] = line;
  else lines.push(line);
};
const isPlaceholder = (value) => !value || value.includes('你的') || value === '1.2.3.4';
const hasPlaceholderUuid = (value) => !value || value === '00000000-0000-0000-0000-000000000000';
const isPlaceholderKey = (value) => !value || value === 'YOUR_PUBLIC_KEY' || value.includes('你的');

if (isPlaceholder(get('SERVER_IP'))) set('SERVER_IP', process.env.SERVER_IP_VALUE);
if (hasPlaceholderUuid(get('UUID'))) set('UUID', crypto.randomUUID());
if (!get('SHORT_ID') || get('SHORT_ID') === 'abcd1234') set('SHORT_ID', crypto.randomBytes(4).toString('hex'));
if (!get('ACCESS_TOKEN')) set('ACCESS_TOKEN', crypto.randomBytes(32).toString('base64url'));

let generatedKeyPair = false;
if (isPlaceholderKey(get('PUBLIC_KEY'))) {
  let privateKey;
  try {
    const rawPrivateKey = fs.readFileSync(privateKeyFile, 'utf8').trim();
    const raw = Buffer.from(rawPrivateKey, 'base64url');
    if (raw.length !== 32) throw new Error('private key must be 32 bytes');
    privateKey = crypto.createPrivateKey({
      key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), raw]),
      format: 'der',
      type: 'pkcs8',
    });
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    const pair = crypto.generateKeyPairSync('x25519');
    privateKey = pair.privateKey;
    const privateDer = privateKey.export({ format: 'der', type: 'pkcs8' });
    fs.mkdirSync(path.dirname(privateKeyFile), { recursive: true });
    fs.writeFileSync(privateKeyFile, privateDer.subarray(-32).toString('base64url') + '\n', { mode: 0o600 });
    fs.chmodSync(privateKeyFile, 0o600);
    generatedKeyPair = true;
  }
  const publicDer = crypto.createPublicKey(privateKey).export({ format: 'der', type: 'spki' });
  set('PUBLIC_KEY', publicDer.subarray(-32).toString('base64url'));
}

fs.writeFileSync(envFile, lines.join('\n').replace(/\n*$/, '\n'), { mode: 0o600 });
fs.chmodSync(envFile, 0o600);
console.log(`已配置 SERVER_IP、UUID、SHORT_ID、ACCESS_TOKEN 和 PUBLIC_KEY：${envFile}`);
if (generatedKeyPair) {
  console.log(`Reality 私钥已安全保存到 ${privateKeyFile}（权限 600）。请将其配置到你现有 Xray Reality 入站的 privateKey；此文件不要提交或公开。`);
} else if (!isPlaceholderKey(get('PUBLIC_KEY'))) {
  console.log('检测到已有 PUBLIC_KEY，未生成/替换密钥对。请确认它与 Xray 上的 privateKey 匹配。');
}
NODE
