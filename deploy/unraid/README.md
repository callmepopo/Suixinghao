# Unraid 部署

这是随行号 202610094 的通用部署入口，只包含代码、配置示例与第三方获取说明。首次公开整理未在新服务器、硬件或新 iOS 签名身份上重新验收。

## 部署结果

| 对象 | 用途 | 暴露范围 |
|---|---|---|
| HiDeck 2.1.23 容器 | 模块发现、短信、统一 AT 队列 | 7577 仅可信网络/反代，不直接公网 |
| 随行号宿主服务 | 统一 API、电话控制、PCM 音频、App Key、测试网页 | 默认 127.0.0.1:7581，由 HTTPS 反代提供 `/voice-test/` |
| 网页 | 管理 Key，基础电话测试 | `https://voice.example.org/voice-test/` |
| App | 用户最终入口 | 设置中填 `https://voice.example.org` 和自己的 App Key |

短信测试使用 HiDeck 原网页或 App；本仓库内嵌网页集中于电话和 Key 管理。App Key 不是 Unraid 管理 Key、Apple API Key 或网页密码。接口及响应以 [API](../../docs/API.md) 为准。

## 前提

- 支持矩阵与驱动版本见 [硬件和第三方依赖](../../docs/hardware.md)。目前基线为 Unraid 内核 `6.1.126-Unraid`、QDC507/Baiwang 模块内核 `3.18.44`、已授权 root USB ADB/UAC。其他内核、模块和运营商不能直接视为可用。
- 宿主需要 Bash、`flock`、coreutils、ALSA 的 `arecord`/`aplay`、与内核匹配的串口/USB 声音驱动、ADB。模块语音驱动和 bridge 由用户从原项目获取，本仓库不分发二进制。
- 先确认没有其他工具占用同一 AT 接口及模块音频路由，整个运行期都须独占；已有语音工具由操作者明确停止后再接管，本脚本不替你停止已有业务。路由停止会关闭模块 UAC 并写入共享语音 FIFO，因此不能与其他语音方案同时运行，也不能保证在共享模块上停止本服务对另一方案无影响。不把 USB 身份转换、ADB 授权、USB/IMS/APN 或固件写入夹带在安装步骤中。
- 配置、Key 摘要、推送令牌、短信库、录音均存宿主运行目录，禁止保存到 Git checkout。HiDeck 配置沿用其独立目录；自有数据默认 `/mnt/user/appdata/suixinghao`。

## 步骤

1. 在可信开发机按 [服务 README](../../server/README.md) 构建 Linux amd64 二进制；只用仓库源码和根版本文件。上传你准备发布的版本及摘要到自己的 Unraid，保留旧版本备份。
2. 在 Unraid 创建 HiDeck 的 `config/data/logs` 目录，复制 `examples/hideck.yaml.example` 为运行目录的 `config.yaml`，将占位密码换成私有随机密码。不要直接拿示例密码上线。使用 [DockerMan 模板](dockerman/README.md) 或本目录 `docker-compose.yml` 二选一，固定 `yibaiba/hideck:2.1.23`。
3. 在 HiDeck 中检查模块在线和短信功能。电话只能复用 HiDeck AT 队列，不同时用额外串口进程。需要手动补串口绑定时，先检查内核与唯一目标，再设置 `HIDECK_USB_DEVICE` 后执行 `bind-dji-at.sh`；默认 VID/PID 为 `2c7c:0125`，其他身份必须明确设置。该脚本只添加宿主驱动绑定，不转换设备身份。
4. 按硬件文档获取和核验驱动。把三份模块文件放到 `$VOICE_WEB_DATA_DIR/drivers/module-voice/`；ADB 路径、ADB serial、USB sysfs 设备路径必须来自本机只读检查，填入自己的配置，不能盲目复用他人设备路径。
5. 将本目录五个 shell 脚本和 `module-voice.SHA256SUMS`、构建好的 `voice-web` 放到自己的自有数据目录。复制 `examples/service.env.example` 为 `service.env`，填写地址、设备 ID、ALSA 设备与路由目标。复制 `examples/recording.json.example` 为 `recording.json`。目录 `0700`，私有 env、JSON 和密钥 `0600`，二进制及 `module-route.sh` 等脚本 `0700`。复制此示例后本次部署的录音配置为关闭；服务代码在文件缺失/损坏时仍回到开启，不能用删除文件停录音。仅在参与通话者明确同意后开启。
6. 用 `bash /mnt/user/appdata/suixinghao/service.sh start` 启动。默认只绑定回环；检查 `/voice-test/health`，再配置既有 HTTPS 反代、网页认证、Key 签发与撤销。不把无认证的健康成功当作模块/语音验收。需要公网时使用有效证书与可信 DNS，具体基础设施由用户管理。
7. 自有脚本在磁盘数据目录，以 `bash` 运行；在你确认开机恢复行为后，才向 Unraid `/boot/config/go` 添加 `bash /mnt/user/appdata/suixinghao/service.sh start`。不要覆盖已有 go 文件。串口/声音驱动由对应插件随开机恢复，另做一次重启验收。
8. 在网页 `/voice-test/app-access/` 登录 HiDeck 管理账号，为每台手机签发独立 Key；仅显示一次。App 填 HTTPS 根地址与 Key，不填 `/voice-test/` 子路径。实际拨号、短信发送和硬件写入由操作者明确决定，每次限定目标与次数。

首次部署建议先完成只读状态、网页和 App 演示/前台验证；APNs 与锁屏按 [App Store 后续](../../docs/app-store.md) 单独处理。

## 配置唯一入口

以 `examples/service.env.example` 定义的名字为准，完成值仅维护在宿主 `service.env`。`service.sh` 默认读取 `$VOICE_WEB_DATA_DIR/service.env`；自定义位置用 `VOICE_WEB_ENV_FILE` 指定，启动/停止/状态必须使用同一位置。文件为 shell assignments，脚本会 source，须 root 拥有且不允许普通用户写入。

| 配置 | 默认或示例 | 说明 |
|---|---|---|
| `VOICE_WEB_UPSTREAM` | `http://127.0.0.1:7577` | HiDeck 服务 |
| `VOICE_WEB_CONFIG_FILE` | `/mnt/user/appdata/hideck/config/config.yaml` | 后台短期凭据适配用配置，仅宿主可读 |
| `VOICE_WEB_DEVICE_ID` | `eth1` | HiDeck 实际设备 ID；按发现结果调整 |
| `VOICE_WEB_DATA_DIR` | `/mnt/user/appdata/suixinghao` | 自有运行数据 |
| `VOICE_WEB_MODULE_ROUTE` | `$DATA_DIR/module-route.sh` | 服务执行 `start/stop` 的路由入口 |
| `VOICE_WEB_AUDIO_DEVICE` | `hw:CARD=Baiwang,DEV=0` | 宿主 ALSA 设备 |
| `VOICE_WEB_ADDR` | `127.0.0.1:7581` | 服务监听 |
| `VOICE_WEB_ALLOWED_ORIGINS` | `https://voice.example.org` | 浏览器合法来源，多个用逗号分隔 |
| `VOICE_WEB_BINARY` | `$DATA_DIR/voice-web` | 守护启动的二进制 |
| `VOICE_WEB_ADB` | `/usr/bin/adb` | 实际 ADB 路径 |
| `VOICE_WEB_ADB_SERIAL` | 必填，无默认 | USB ADB 目标；不上传值 |
| `VOICE_WEB_MODULE_USB_DEVICE` | 必填，无默认 | 已核验的 `/sys/bus/usb/devices/...` 路径 |
| `VOICE_WEB_MODULE_ASSETS` | `$DATA_DIR/drivers/module-voice` | 核验后的三个模块资源 |

自有数据文件默认跟随 DATA_DIR，可独立覆盖 `VOICE_WEB_APP_KEYS_FILE`、`VOICE_WEB_RECORDING_FILE`、`VOICE_WEB_CONNECTION_HISTORY_FILE`、`VOICE_WEB_VOIP_TOKENS_FILE`、`VOICE_WEB_SMS_PUSH_TOKENS_FILE`、`VOICE_WEB_SMS_CURSOR_FILE`。APNs 自签构建配置见 `examples/apns-self-build.env.example`，所有私钥示例值为空。

## HTTPS / NPM

`examples/nginx.conf.example` 适用于同宿主 nginx；`examples/npm-location.conf.example` 是 NPM Custom Location `/voice-test/` 的 Advanced 内容。保留完整路径、Bearer/Cookie、WebSocket 升级，关闭 SSE 缓冲，超时足够覆盖通话。NPM 自行生成 Host 与转发协议头，不要在 Advanced 再定义重复头；NPM 的 `$host` 不保留非默认公网端口，使用此类端口时必须在 `VOICE_WEB_ALLOWED_ORIGINS` 配置完整的 HTTPS 来源，并实测网页 Cookie/声音握手。

若 NPM 在独立容器，`127.0.0.1` 指该容器，无法访问宿主回环服务。此时仅在可信内网将服务监听改为宿主可达地址，并用防火墙限制 7581 的调用方为反代；在 NPM UI 填自己的宿主地址与 7581。不要直接暴露 7577、7581 或开放 Unraid 管理面。所有对外 API 统一为 `https://voice.example.org/voice-test/...`。反代访问日志应排除查询字符串中的号码/卡片标识，示例直接关闭这一路径的访问日志。

## 运行与回退

`service.sh status` 查看守护；`stop` 优雅停止并等待最多 90 秒；`start` 启动，服务退出约 5 秒后恢复。不要直接 kill 子进程，否则守护会再次拉起。日志在服务运行间隙超过 5 MiB 时轮转，不是运行中硬上限。

升级前确认电话 idle，备份二进制、脚本和配置；停止 → 替换二进制/脚本 → 启动 → 核对版本、鉴权和 idle。失败按相同顺序恢复旧二进制和脚本，保留 Key、短信、令牌与历史数据，避免整库回退。路由恢复不改变 USB/IMS/APN，不刷机；不匹配内核、无 root ADB 或缺资源时拒绝启动声音。

更完整的日常维护与验收见 [运行说明](../../docs/operations.md) 和 [需求与验收](../../docs/requirements.md)。
