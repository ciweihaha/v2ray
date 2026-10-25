# v2ray-deploy

V2Ray 服务端一键部署脚本（`xf.sh`）：在 Linux 主机或 Alpine 容器内安装 V2Ray 并写入 VMess + WebSocket 配置。

## 特性

- **固定版本安装**：默认 `v5.53.0`，可用 `V2RAY_VERSION` 覆盖，SHA512 校验通过才落盘
- **失败回滚**：安装前自动备份，任何步骤失败自动恢复原状（`trap EXIT`）
- **fail-closed**：`VMESS_UUID` 未设置时拒绝写入配置并退出，UUID 不会打印到日志；已设置的 UUID 须为 8-4-4-4-12 十六进制格式
- **路径可覆盖**：`V2RAY_BIN_DIR` / `V2RAY_SHARE_DIR` / `V2RAY_CONFIG_FILE`，便于演练与 CI
- **仅安装不启动**：`V2RAY_SKIP_RUN=1`

## 用法

```bash
VMESS_UUID=<your-uuid> sh xf.sh
```

安装位置：

| 文件 | 路径 |
| --- | --- |
| 二进制 | `/usr/bin/v2ray`、`/usr/bin/v2ctl` |
| 地理数据 | `/usr/local/share/v2ray/{geosite,geoip}.dat` |
| 配置 | `/etc/v2ray/config.json` |

入站：`0.0.0.0:8080` VMess + WebSocket（alterId 0）；出站：`freedom`。

## Docker

```bash
docker build -t v2ray-deploy .
docker run -d -p 8080:8080 -e VMESS_UUID=<your-uuid> v2ray-deploy
```

基于 `alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a`，镜像内自带 `openssl` / `ca-certificates` / `tzdata`。

## 公网监听面说明

- 8080 端口建议仅对可信客户端开放。
- 生产环境建议前置 TLS（Nginx / Caddy 反代 wss），或改用内网监听＋网关。
- UUID 一旦泄露即轮换。
- 说明：`0.0.0.0` 绑定是功能必需，VMess 层本身加密且配置中 `disableInsecureEncryption: true`，因此这不是脚本缺陷，而是部署者须知。

## Fly.io

脚本支持 `FLY_APP_NAME` / `FLY_REGION` 环境变量，部署时通过 `VMESS_UUID` secret 注入节点 UUID。

## License

[MIT](LICENSE)
