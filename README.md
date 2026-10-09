# 随行号 · Suixinghao

自托管的蜂窝电话与短信服务：在 Unraid 上连接 DJI 第一代 QDC507 4G 模块，使用网页完成基础验证，使用原生 iOS 随行号作为日常客户端。用户自行部署服务，在 App 中填写 HTTPS 根地址和该服务签发的 App Key。

将家里的蜂窝通信模块接入自建服务，在 iPhone 上使用自己的号码收发短信、拨打和接听电话。网页用于验证部署，随行号 App 是日常使用入口。

> **当前状态：源码已整理为 main 首次公开版本。** 开发包已实测锁屏来电提醒、接听、双向声音及后台通话。App Store 正式构建已上传，尚未提交审核，目前没有商店下载链接。锁屏接听后的系统免提会自动回退，作为已知问题保留；App 内扬声器切换此前已验证正常。Production／TestFlight 推送仍需独立验证。

[部署指南](deploy/unraid/README.md) · [iOS 客户端](ios/README.md) · [接口规范](docs/API.md) · [已知限制](docs/limitations.md) · [问题反馈](https://github.com/callmepopo/Suixinghao/issues)

## 能做什么

- **电话**：拨号、来电接听、挂断，以及通过 CallKit 显示系统来电界面；App／服务端0.1.1支持接通前模块音频，维护者已确认本轮开发包真机验证通过。
- **短信**：在 iPhone 中查看和发送短信；数据来自用户自己的服务。
- **自定义接入**：用户填写自己的 HTTPS 服务地址和独立 App Key，App 不内置个人账号或服务配置。
- **网页验证**：先验证电话与部署是否可用，再使用 App；网页也提供 App Key 管理入口。
- **部署与推送**：提供 Unraid 部署适配、驱动来源说明和受控 APNs 推送中继代码。

需要兼容模块、SIM 卡、Unraid 及可用的 HTTPS 服务；本项目不提供号码、套餐或公共电话托管。运营商费用由用户自行承担，支持环境见[硬件说明](docs/hardware.md)。

## 项目组成

| 部分 | 职责 | 在本仓库中的位置 |
|---|---|---|
| [HiDeck](https://github.com/yibaiba/hideck) | 上游设备管理、短信及 AT 指令队列 | 外部依赖，固定参考版本 2.1.23 |
| Unraid 部署与驱动适配 | 容器、宿主服务、声卡及模块音频运行时 | [deploy/unraid](deploy/unraid/README.md) |
| 电话/API 服务与测试网页 | App Key、电话控制、音频、短信代理、推送适配；网页验证部署 | [server](server/README.md)，网页源码在 server/web |
| 随行号 iOS App | 用户手工配置服务，完成日常电话和短信操作 | [ios](ios/README.md) |

网页和 App 共用一套服务、一个模块和一路通话。多把 App Key 代表多个授权客户端，不代表可以同时拨打多路电话。

## 开始使用

1. 阅读 [硬件与依赖](docs/hardware.md) 和 [第三方声明](THIRD_PARTY_NOTICES.md)。只有已验证环境可以按本方案使用；驱动包由原来源取得，本仓库不分发固件或驱动二进制。
2. 按 [Unraid 部署说明](deploy/unraid/README.md) 配置 HiDeck、服务和 HTTPS 反代。模板中的凭据均由部署者自行设置。
3. 在 `https://voice.example.org/voice-test/` 测试网页电话；通过 `/voice-test/app-access/` 登录并签发一把设备专用 App Key。
4. 按 [iOS 构建说明](ios/README.md) 构建新客户端，填写根地址 `https://voice.example.org` 和自己的 Key。地址不要包含 `/voice-test/`，也不是 Unraid 管理接口。

只检查源码、预览页面不需要硬件，参见 [服务端说明](server/README.md) 和 [iOS 说明](ios/README.md)。正式部署涉及设备和驱动写入，务必先核对支持环境并按分步说明执行。

## 仓库目录

```text
server/          电话与 API 服务，web/ 为测试网页
deploy/          部署材料：unraid/ 为宿主适配，relay/ 为推送中继
ios/             原生随行号 iOS App 与构建脚本
docs/            架构、硬件、接口、隐私、运行及发布说明
licenses/        自有服务依赖的许可证文本
Version.xcconfig App版本配置（服务端独立在server/Version.xcconfig）
```

HiDeck 是独立上游依赖，不包含其源码；部署者从原项目获取。日常在 develop 开发，main 维护公开版本；本地签名、测试包、服务配置及真实数据不上传。发布流程见[开发与发布说明](docs/releasing.md)。

## 接口与隐私

- [API 规范](docs/API.md)：鉴权、电话状态、事件、音频、短信与错误码。
- [隐私说明](docs/privacy.md)：本机保存、服务器处理、录音、推送与数据清除边界。
- [运行与回退](docs/operations.md)、[需求与验收](docs/requirements.md)、[已知限制](docs/limitations.md)。

App 不内置个人服务地址或 Key，Key 保存在本机钥匙串；服务端只持久化 App Key 摘要。录音是服务器侧功能，启用前应告知通信参与者；新部署示例关闭录音，既有服务逻辑仍须按文档核对默认行为。

## 官方 App 与源码版本

新 App 身份为 **Suixinghao / com.junpo.suixinghao**，显示名称为“随行号”。它按新 App 安装，需重新配置服务；旧 App 的本机数据不会自动迁移。

首版分发范围为美国、香港、印度、土耳其、菲律宾，免费提供下载，不包含中国大陆。官方 App 的自托管锁屏推送需要受控 APNs 中继；现已提供候选实现，已在独立生产环境实例完成启动、HTTPS及授权检查，Sandbox开发包已由用户确认锁屏来电、接听和双向声音；系统免提复验仍回退、已延期，正式候选已上传但Production／TestFlight验收及审核未完成；自行签名者可使用自己的 Apple 身份配置 APNs。详见 [App Store 后续步骤](docs/app-store.md) 和 [推送中继](docs/push-relay.md)。

正式版本将对应固定源码标签、提交、构建环境和产物证明。App 关于页显示源码身份；未提交或有修改的本地构建会明确标记。详见 [发布与源码追溯](docs/releasing.md)。

## 许可与协作

本仓库自有代码采用 [MIT](LICENSE)。**HiDeck 的 PolyForm Noncommercial 许可和第三方驱动许可独立适用；MIT 不代表整套依赖允许商用。** 本项目不是 DJI、HiDeck、MaVo 或 Unraid 的官方产品。

贡献方式见 [CONTRIBUTING](CONTRIBUTING.md)，安全反馈见 [SECURITY](SECURITY.md)，变更见 [CHANGELOG](CHANGELOG.md)。提交问题时仅使用合成数据，删除号码、短信、设备标识和凭据。
