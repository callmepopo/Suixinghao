# 随行号电话/API 服务

独立 Go 服务，通过 HiDeck 的 HTTP 接口及统一 AT 队列管理单模块通话；宿主 ALSA 与模块临时音频运行时处理 PCM。`web/` 是嵌入的电话测试和 App Key 管理页面，不需要单独安装前端依赖。

需要 Go 1.23 或更新版本；模块依赖由 go.mod/go.sum 固定。部署硬件、ALSA 和驱动要求见 [部署说明](../deploy/unraid/README.md)，接口以 [API](../docs/API.md) 为准。

## 不接硬件的本地检查

从本目录执行：

```sh
GOCACHE="$PWD/.build/go-cache" go test -race ./...
GOCACHE="$PWD/.build/go-cache" go vet ./...
bash build.sh
```

构建脚本从 Git 工作区生成 `.build/<九位版本>/voice-web`（Linux amd64）与 `source.json`。编译前冻结版本、源码和 Go 环境，编译后核对源码未变并记录文件相对路径、大小及 SHA-256。普通构建标为 testing；正式候选使用 `bash build.sh --require-clean`，拒绝未提交或脏源码。后续发布清单必须校验本次 `source.json` 与二进制，不从当时的 HEAD 或版本推测旧文件来源；旧产物没有记录时重新构建。具体命令见 [发布流程](../docs/releasing.md#来源证据)。

只看页面可运行：

```sh
GOCACHE="$PWD/.build/go-cache" VOICE_WEB_ADDR=127.0.0.1:17581 go run . serve-page
```

打开 `http://127.0.0.1:17581/voice-test/`。这个命令不启动来电 worker、AT 查询或模块路由；不要在纯预览中填写真实账号或操作生产接口。浏览器电话需要可信 HTTPS、麦克风授权和实际后端，纯页面预览不能视为电话验收。

`cmd/pacingcheck` 与 `cmd/localvoicecheck` 仅供本机 loopback/模拟器检查，使用合成音频和数据。旧的 SSH、真实短信/拨号、签名注入及原始串口工具不包含在公共仓库。

## 配置与运行

参数以 [service.env.example](../deploy/unraid/examples/service.env.example) 和 [部署说明配置表](../deploy/unraid/README.md#配置唯一入口) 为唯一说明。服务默认监听 `127.0.0.1:7581`；上游为 `127.0.0.1:7577`；个人值由部署者提供。

网页登录用 HiDeck 账号密码；手机用独立 App Key。Key 摘要、录音设置、推送令牌和历史落盘到指定数据目录。健康接口是只读进程检查，成功不表示模块、SIM、音频或 APNs 已可用。

现有录音实现缺少或损坏配置时默认开启。新部署务必先复制 `recording.json.example`（关闭）到私有运行目录；开启前取得适用授权。这个行为没有在本轮隐式改变，不能仅因复制了代码就认为录音关闭。

本轮编译、无端口 race 子集和 vet 已验证；完整 HTTP/WebSocket 测试需本地端口绑定权限，受限环境未能运行。公共 CI 配置包含完整测试，当前尚未在 GitHub 执行。已知限制及分层验收见 [需求与验收](../docs/requirements.md)。
