# 随行号 iOS 工程规则

- 本目录是唯一公开 iOS 源码，继承仓库根规则。上游 HiDeck 仅作为服务端依赖引用，不修改或混入其源码。
- 工程、target、scheme、源码目录、产品名称、App 主入口统一使用 `Suixinghao`；App 显示名称为“随行号”，正式公开身份为 `com.junpo.suixinghao`。发布身份与 Apple 账号凭据分开管理，严禁在源码写入 Team ID、证书或私钥。
- 产品版本遵循仓库根 `AGENTS.md` 的版本管理规则；App版本只读根 `Version.xcconfig`，服务端独立使用server/Version.xcconfig；纯文档不递增。构建源码信息由根 `scripts/source-metadata.py` 提供，不维护重复版本值或伪造GitHub地址；未配置时关于页显示“未关联”。
- App 服务地址与 Key 必须由用户手工配置；仅接受 HTTPS 根地址。禁止内置个人电话服务、OTA 域名、账号、号码或 Key。
- Key 与通话记录写 `ThisDeviceOnly` Keychain；通讯录匹配在本机内存中，短信正文不缓存。诊断日志不得写入地址、Key、号码、短信、设备身份或推送 token。
- 新 Bundle ID 是独立安装，不迁移旧开发 App 的沙盒、Keychain 或推送 token。不得把新客户端接入既有线上模块或修改现网推送身份作为本地验收步骤。
- 本地构建仅使用已有 Xcode，无第三方包依赖。产物、日志、签名与临时配置全部放 `.build/`；它们不属于公开源码。
- `scripts/build.sh` 用无签名模拟器；`scripts/archive.sh` 默认无签名 Release。`--signed` 是干净源码的正式 Release 归档与 App Store Connect 本地 IPA 导出；`--testing` 是允许 dirty 源码的 Debug/sandbox 本地 IPA。两者均显式读取 `SXH_DEVELOPMENT_TEAM`，默认仅使用本机已有资产。只有明确授权且设置 `SXH_ALLOW_PROVISIONING_UPDATES=1` 时允许 Xcode 联网补配该 App 身份的签名资产。测试输出可通过 `SXH_BUILD_OUTPUT` 指向仓库外私有目录；归档脚本不安装、上传、OTA 或部署。
- 修改后运行 `scripts/check.sh` 与相应模拟器构建，区分合成检查、编译、真机通话、生产推送、锁屏及商店审核。没有对应证据不得记通过。
- 修改数据流或 required-reason API 时同步 `PrivacyInfo.xcprivacy`、本目录 README 与仓库隐私/分发材料。正式 App Store 资料需要另外验证实际收集类别，不能从无广告或无 SDK 推断“无数据收集”。
