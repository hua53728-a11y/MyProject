# MyProject

二维码订阅页服务（Node.js）。页面会展示 Reality 节点二维码，并提供通用 VLESS 和 Clash 订阅地址。

## 在 Linux 服务器上部署

需要一台已运行并正确配置 Xray Reality 入站的服务器。此项目只提供二维码/订阅 HTTP 页面，**不会安装或启动 Xray 代理服务**。

```bash
sudo bash deploy/setup-server.sh
```

安装脚本会生成 `/opt/qr-app/.env`，自动检测服务器公网 IPv4，并为应用生成 UUID、Reality X25519 公钥、随机 Short ID 和访问令牌。Reality 私钥保存在 `/opt/qr-app/reality-private-key`（权限 600），不会写进仓库。请将该私钥配置到你现有 Xray Reality 入站的 `privateKey`，并确保入站的 UUID、Short ID、监听端口和 SNI 与 `.env` 中的值一致。更改 Xray 配置后按需重启 Xray。

如果服务器无法通过公网服务自动检测 IP，可先运行：

```bash
sudo SERVER_IP_OVERRIDE=你的服务器公网IP bash deploy/generate-runtime-config.sh /opt/qr-app/.env
```

已有有效的 SERVER_IP、UUID 或 PUBLIC_KEY 会保留；如果指定了已有 PUBLIC_KEY，脚本不会生成与其对应的私钥，请自行确认 Xray 的密钥对匹配。运行配置生成器会设置 `.env` 权限为 600。

## 访问页面

默认服务仅监听 `127.0.0.1:8080`。在服务器本机可用以下地址访问：

```text
http://127.0.0.1:8080/?k=<.env中的ACCESS_TOKEN>
```

公网访问建议配置 HTTPS 反向代理。仓库提供 `deploy/nginx-qr-app.conf` 的 HTTP 示例；正式使用时应配置 TLS 并使用你自己的域名。代理场景请在 `.env` 设置 `TRUST_PROXY=1`，然后重启服务：

```bash
sudo systemctl restart qr-app
```

端点：

- 二维码页面：`/`
- VLESS 订阅：`/sub`
- Clash 订阅：`/clash`

通过反向代理的实际地址例如 `https://你的域名/?k=<ACCESS_TOKEN>`。不要把访问令牌、Reality 私钥或含令牌的订阅 URL 发到公开位置。

## 检查服务

```bash
sudo systemctl status qr-app
sudo journalctl -u qr-app -n 100 --no-pager
curl -i -A 'Mozilla/5.0' 'http://127.0.0.1:8080/?k=<ACCESS_TOKEN>'
curl -i -A 'Mozilla/5.0' 'http://127.0.0.1:8080/sub?k=<ACCESS_TOKEN>'
```

`SERVER_IP`/`UUID`/`PUBLIC_KEY` 配置只会让二维码和订阅内容带上对应参数；节点连通还要求 Xray Reality 服务端入站与客户端参数一致，并且服务器防火墙开放相应代理端口。
