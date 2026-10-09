# 随行号 iOS 客户端

随行号是连接自建电话服务的原生 SwiftUI 客户端。使用者填写自己的 HTTPS 服务根地址和该服务签发的 App Key，电话声音、短信与控制请求直连该服务。HiDeck 是服务端上游依赖，随行号工程不使用 HiDeck 作为 App 身份。

公开源码当前版本以根目录 `Version.xcconfig` 为准。工程、target 和 scheme 为 `Suixinghao`，发布用 Bundle ID 为 `com.junpo.suixinghao`，最低 iOS 18。这个新身份独立于早期开发 App；新安装需要重新填写服务地址和独立 Key，不会自动迁移旧 App 的本机记录。

## 配置与能力

1. 自行部署本仓库服务，先用测试网页核对模块、电话和短信接口。
2. 在 `<HTTPS 服务根地址>/voice-test/app-access/` 使用服务管理账号为本机签发 App Key；Key 只显示一次。
3. 在随行号设置填写 `https://your-service.example`（可带端口，不追加 `/api` 或 `/voice-test`）和 App Key。Key 与网页密码、Unraid 管理 Key 均不同。

主要功能：电话拨打、接听、挂断、DTMF、静音与音频路由；短信列表、会话及发送；本机联系人匹配、通话记录、断线恢复和连接历史。手机 SIM 系统拨号与远端模块拨号是不同线路。

锁屏来电依赖 PushKit、CallKit、APNs 和配套服务配置。官方 App Store 包的推送属于发布者的 App 身份，自建部署者自己的 Apple Key 无法给官方包直接推送；发布者私钥不能分发。公开源码保留客户端与直连 APNs 的实现，公共推送中继尚未实现。自行签名者需使用自己的 App ID、签名、推送凭据及相匹配的服务配置。不得将模拟器构建记为真机或锁屏通过。

号码规则目前对 11 位国内手机号补 `+86`；国际号码需以 `+` 和国家码输入。中国短号、座机、400/800 支持属于现有逻辑，不能据此宣称美区本地号码、美国硬件或所有运营商均已验证。

## 本地构建与检查

需要 macOS、已有 Xcode 与命令行工具；工程仅使用系统框架，无需安装第三方包。构建脚本默认使用 `/Applications/Xcode.app/Contents/Developer`，可通过 `DEVELOPER_DIR` 指定另一份现有 Xcode。

在 `ios/` 目录运行：

```sh
./scripts/check.sh
./scripts/build.sh
./scripts/build.sh --release
```

检查使用合成数据，覆盖号码、地址和 Key 边界、音频帧与节拍、取消/重连、通话状态及本机连接历史。构建目标是通用 iOS 模拟器，无需开发者账号，不会连接个人服务或操作模块。产物位于 `.build/`，不得提交到 GitHub。

也可打开 `Suixinghao.xcodeproj`，选 `Suixinghao` scheme 和模拟器运行。脚本构建调用 `../scripts/source-metadata.py`，将真实源码 commit 和对应源码链接写入安装包；手工 Xcode 构建未传这些设置时显示“未关联”。脏源码显示真实 commit 后的 `-dirty` 标记并不生成公开链接；没有 Git 提交或 GitHub remote 时不编造链接。关于页只展示安装包元数据，不查询外部更新站点或触发 Safari 安装。

## Release 归档与签名

```sh
./scripts/archive.sh
```

默认创建未签名 Release 归档，用于本地检查，不能安装或提交商店。归档位于 `.build/release-<九位版本>-unsigned/`，同一路径已有归档时拒绝覆盖。归档目录统一保存 `source.json`：冻结该次构建的版本、源码和 Xcode/SDK 环境，并绑定生成文件的相对路径、大小及 SHA-256；未签名归档绑定主程序，签名导出绑定 `ipa/Suixinghao.ipa`。

需要签名时，先在本机配置自己的现有证书、已注册 App ID、匹配的描述文件及所需权限，并显式提供 Team：

```sh
SXH_DEVELOPMENT_TEAM=YOUR_TEAM_ID ./scripts/archive.sh --signed
```

正式签名归档要求干净且已提交的源码，使用 Release/production APNs，同时以 `app-store-connect` 方法导出本地 IPA；脚本不会联网申请签名资产、导出 OTA、上传 TestFlight 或部署。归档完成后通过 Xcode Organizer 人工核对身份、隐私报告和版本，再执行另行授权的分发。自行构建者需在 Xcode 中配置自己拥有的 Bundle ID，并与后端推送身份保持一致。

日常手机测试包可使用本机已经安装的开发签名资产：

```sh
SXH_DEVELOPMENT_TEAM=YOUR_TEAM_ID ./scripts/archive.sh --testing
```

该命令使用 Debug/sandbox，允许尚未提交的开发改动，保留源码 dirty/未关联状态，在关于页标为“本地测试”；只生成归档和开发签名 IPA，不安装到设备或发布更新。默认产物位于 `.build/testing-<九位版本>/`。可显式设置 `SXH_BUILD_OUTPUT` 为仓库外的私有测试目录，保存 IPA、`source.json`、签名导出参数、日志及验收材料。构建中修改源码或版本时拒绝生成完成记录；构建结束后 HEAD/版本再变化，也不改变旧包的记录。清单必须通过 [发布流程](../docs/releasing.md#来源证据) 校验旧包及它自己的记录。已有归档拒绝覆盖，后续测试请分配新版本或指定新的私有输出目录。新 App ID 与设备权限需要在 Apple 账号侧另外准备；缺少本机证书/描述文件时命令失败，不会自动联网补配。

App Store 分发还需要新的 App ID/商店记录、生产推送方案、隐私政策和 App Privacy 声明、可用审核服务与独立临时 Key、硬件互动演示及完整真机测试。这些条件尚未完成，不宣称已经上架或通过审核。商店安装版通过 App Store 更新。

## 数据与隐私

- 服务地址、App Key 及最近通话记录保存到 `ThisDeviceOnly` 本机钥匙串，不通过 iCloud 同步。新 Bundle ID 使用独立访问组。断开并更换服务清除连接配置；远端 Key 的撤销由服务管理者操作。
- 通讯录匹配在本机内存进行，不上传整本通讯录。麦克风仅用于已授权通话，短信正文与会话不作为客户端持久缓存。
- 连接历史保存于受保护且排除备份的本机应用数据目录；诊断事件在空闲且联网时上传到使用者配置的服务。通话和短信经该服务与运营商处理，服务端是否录音、如何保留短信与日志由该部署配置决定。
- `Suixinghao/PrivacyInfo.xcprivacy` 声明文件时间戳 API 的 `C617.1` 原因：连接历史仅读取本 App 沙盒文件的时间戳和大小，用于日志合并和存储管理。[Apple 官方原因清单](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- 该清单覆盖已知 required-reason API，不代表“无数据收集”的 App Privacy 声明。正式分发前根据最终直连/推送服务的数据流填写政策、收集类别、留存和删除方式。

证书、描述文件、APNs `.p8`、现场设备标识、真实地址与 Key、构建日志、签名归档和运行截图留在本地私有材料中。`develop` 的手机开发测试成功后合入 `main`，再对正式 Release 候选包进行 TestFlight/production APNs 真机验证；验证成功后使用同一个正式构建提交美区审核并发布 GitHub Release，开发 IPA 不直接进入商店。完整分支与发布流程见仓库文档。提交代码前执行仓库的公开内容扫描。
