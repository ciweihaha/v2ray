# v2ray-deploy

V2Ray 服务端一键部署脚本（`xf.sh`）：在 Linux 主机或 Alpine 容器内安装 V2Ray 并写入 VMess + WebSocket 配置。

## 特性

- **固定版本安装**：默认 `v5.56.0`，可用 `V2RAY_VERSION` 覆盖，SHA512 校验通过才落盘
- **架构自动检测**：按 `uname -m` 选择上游对应包（x86_64、aarch64、armv7l、riscv64 等），可用 `V2RAY_ARCH` 覆盖；未知架构直接报错，不下载错架构的包
- **下载限时**：每次下载总时长上限 300 秒（`V2RAY_DOWNLOAD_TIMEOUT` 覆盖，单位秒），连接停滞不再无限挂起
- **依赖预检**：启动即检查 `wget` / `unzip` / `openssl` / `timeout` 是否可用，缺失时直接报错，不跑到一半才失败
- **失败回滚**：安装前自动备份，任何步骤失败自动恢复原状（`trap EXIT`）
- **fail-closed**：`VMESS_UUID` 未设置时拒绝写入配置并退出，UUID 不会打印到日志；已设置的 UUID 须为 8-4-4-4-12 十六进制格式
- **路径可覆盖**：`V2RAY_BIN_DIR` / `V2RAY_SHARE_DIR` / `V2RAY_CONFIG_FILE`，便于演练与 CI
- **仅安装不启动**：`V2RAY_SKIP_RUN=1`

## 用法

主机需预装 `wget`、`unzip`、`openssl`、`timeout`（Debian/Ubuntu 精简镜像可能缺 `unzip`，先 `apt-get install -y unzip`；Alpine 容器内由 BusyBox 提供 `wget`/`unzip`/`timeout`，`openssl` 已装进镜像）。

```bash
VMESS_UUID=<your-uuid> sh xf.sh
```

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `VMESS_UUID` | （必填） | VMess 客户端 UUID，须为 8-4-4-4-12 十六进制格式 |
| `V2RAY_VERSION` | `v5.56.0` | 上游 release tag，只允许字母、数字、点、横线、下划线 |
| `V2RAY_ARCH` | 自动检测 | 上游包后缀（`64`、`arm64-v8a`、`arm32-v7a` 等），或 `uname -m` 值 |
| `V2RAY_DOWNLOAD_TIMEOUT` | `300` | 每次下载总时长上限（秒） |
| `V2RAY_DOWNLOAD_BASE` | 上游 release 地址 | 下载源覆盖（演练用） |
| `V2RAY_BIN_DIR` / `V2RAY_SHARE_DIR` / `V2RAY_CONFIG_FILE` | `/usr/bin` 等 | 安装路径覆盖（演练用） |
| `V2RAY_SKIP_RUN=1` | — | 只安装不启动 v2ray |

## 测试

```bash
bash tests/drill.sh          # 本地演练：假 release 安装、zip-slip 拒绝、输入校验、黑洞超时等
BUSYBOX=/path/to/busybox bash tests/drill.sh   # 另测 BusyBox unzip 的列表与解压路径
```

CI 在每次 push/PR 跑 `shellcheck` 与 `tests/drill.sh`（见 `.github/workflows/docker-image.yml`）。

## 安装位置

| 文件 | 路径 |
| --- | --- |
| 二进制 | `/usr/bin/v2ray` |
| 地理数据 | `/usr/local/share/v2ray/{geosite,geoip}.dat` |
| 配置 | `/etc/v2ray/config.json` |

入站：`0.0.0.0:8080` VMess + WebSocket（alterId 0）；出站：`freedom`。

## Docker

```bash
docker build -t v2ray-deploy .
docker run -d -p 8080:8080 -e VMESS_UUID=<your-uuid> v2ray-deploy
```

基于 `alpine:3.24.4@sha256:93b41ef40b1677fce8fcc64ff4af09daddfacf5040afde618bc46c1e2d1cc7d4`，镜像内自带 `openssl` / `ca-certificates` / `tzdata`。

## 公网监听面说明

- 8080 端口建议仅对可信客户端开放。
- 生产环境建议前置 TLS（Nginx / Caddy 反代 wss），或改用内网监听＋网关。
- UUID 一旦泄露即轮换。
- 说明：`0.0.0.0` 绑定是功能必需，VMess 层本身加密且配置中 `disableInsecureEncryption: true`，因此这不是脚本缺陷，而是部署者须知。

## Fly.io

脚本支持 `FLY_APP_NAME` / `FLY_REGION` 环境变量，部署时通过 `VMESS_UUID` secret 注入节点 UUID。

## License

[MIT](LICENSE)
