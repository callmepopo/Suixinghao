# 日常测试、正式发布与源码追溯

源码只维护在本仓库。日常开发使用本地 `develop` 分支；`main` 接收已完成手机开发测试的变更。未验证的本地分支不自动推送公开仓库。首次整理的提交只是准备稿，不能据此标记稳定版。

| 阶段 | 代码或产物 | 通过标准 |
|---|---|---|
| 本地开发 | develop；标明版本、提交及 dirty 状态 | 源码检查、构建、相关自动测试 |
| 手机开发测试 | 开发签名 IPA；可放仓库外的 private/testing | 用户按验收单验证新身份和真实功能 |
| 合入 main | 同一轮已验证源码；保留验证记录 | 未决项明确，修改已提交，暂存隐私检查通过 |
| 正式候选 | 固定 main 提交/候选标签；Release、production APNs | TestFlight 使用该正式构建做真机验收 |
| 正式发布 | TestFlight 已通过的同一正式构建 | 提交美区审核；发布对应 GitHub 标签与说明 |

开发签名包不能直接视为商店候选：Debug/Release、签名、权限与 APNs 环境不同。正式候选出现问题，回到 develop 修复、分配新版本并重新验证，不替换已经发布的版本内容。原生产服务、旧 App 与旧签名包不在本轮自动切换。

## 日常操作

从本地 develop 修改代码，先运行模块检查。手机测试使用 `ios/scripts/archive.sh --testing`：Team、已有签名资产由开发者私有配置提供；默认本地输出，也可用 `SXH_BUILD_OUTPUT` 指向仓库外的测试目录。该脚本不注册账号、不安装手机、不上传、不部署服务器。

自动签名归档不强制指定 Apple Distribution；正式导出使用 `app-store-connect`，由 Xcode 选择分发证书及描述文件并重新签名。归档和导出默认只用本机已有签名资产。已授权 Xcode 用本机登录账号向 Apple 补配新 App 身份时，显式设置 `SXH_ALLOW_PROVISIONING_UPDATES=1`；仅签名模式支持，归档与导出都会启用 `-allowProvisioningUpdates`。这会访问 Apple 开发服务并可能创建/更新签名资产，仍不上传产物或改服务端 APNs。所需能力无法配齐时停止，不能跳过权限校验或使用旧 App 的描述文件代替。账号、Team 与诊断日志只留本机私有区。

测试构建的归档目录保存脚本生成的 `source.json`，另记测试项目和通过/待验结果。测试只能记录脱敏结论；真实短信、号码、Key、签名配置和 IPA 不进入仓库。新 App 身份需要先在 Apple 登记并配置本机签名；不能套用旧 App 的描述文件。

手机测试通过后，在没有未提交修改时将 develop 合入 main，固定提交并制作候选标签。App功能／修复更新使用 `python3 ios/scripts/version.py --module ios --next`；服务端使用 `--module server --next`，各自递增补丁版本。App同产品版本的新构建使用 `--module ios --build-only`，只递增内部构建号。App的权威配置为根Version.xcconfig，服务为server/Version.xcconfig；纯文档不升号。

## 来源证据

`scripts/source-metadata.py` 从实际 Git HEAD 和工作区状态读取来源。未提交显示 uncommitted；脏源码显示 SHA-dirty 并不提供误导的源码链接。只有干净提交且 origin 为 GitHub 仓库时，才生成精确提交链接。此字段是可检查的构建记录，不是源码等价的独立密码学证明。

正式签名归档和服务正式候选要求干净提交。构建脚本在编译前冻结版本、源码和工具环境，编译后核对源码未变，再把文件相对路径、大小及 SHA-256 写入 `source.json`。构建中改动源码或版本时拒绝生成完成记录。记录需要从 Git 工作区构建，允许本地尚未提交的测试源码；产物目录使用 `.build/` 或仓库外私有目录。

App 关于页及服务 health 展示构建来源；完整来源记录在服务产物目录或 iOS 归档目录。清单必须引用该产物的构建记录：

```sh
python3 scripts/release-manifest.py <导出的IPA或服务二进制> --source-record <对应构建目录>/source.json --output <私有产物目录>/release-manifest.json
```

本地测试可加 `--testing`，其清单始终标记 testing。缺少完成的构建记录、文件名/相对路径不符或文件大小/哈希变化时拒绝生成；正式清单拒绝 testing、unsigned 及 dirty 来源。构建以后即使 HEAD、版本或本机环境已经改变，清单仍使用该次构建冻结的值，不能拿当前源码给旧包重新贴标签。旧产物没有这份记录时必须重新构建，不能补造来源。

清单记录源码、环境、产物 SHA-256 和版本，不包含 Team、Key、设备列表或本机绝对路径。清单默认只表示候选，不能因为文件存在就宣布已提交商店。`source.json` 与清单是可校验的构建流程记录，尚无独立签名或可信构建方背书，不能单独证明源码和商店包等价。

正式上架阶段应使用受保护构建流程，从固定标签一次构建、签名、导出；生成 GitHub artifact attestation 并在上传前验证。上传并提交该产物，保留私有上传回执，再将 TestFlight 与商店版本/构建号对应到公开来源清单。签名秘密仅放受保护环境，产物不得混入普通源码仓库。当前 verify workflow 只做检查和无签名构建，不执行自动上架。

GitHub Release 公开标签、完整提交、版本、构建号、环境、脱敏摘要、变更和实际限制。已发布标签和产物不可原地替换，启用不可变发布和标签保护时使用 GitHub 当前支持的设置。

## 验证范围

[GitHub artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations)把产物和构建工作流、源码提交联系起来；可复现构建还要求相同条件得到相同指定产物，本项目尚未实现或验收这种保证。

App Store 的设备适配与处理会改变分发包，不能把用户下载包与上传 IPA 的整体哈希不同直接判为源码不同，也不能仅凭哈希、版本号、商店签名或源码链接证明所有代码一致。[Apple 设备适配说明](https://developer.apple.com/documentation/xcode/reducing-your-app-s-size)。公开流程提供可追溯证据，避免宣称已完成商店下载包的独立等价验证。

从接通前音频更新起，App与服务分别采用三段产品版本，各组件自行递增；历史日期编号及原产物记录保持原值。源码预览可在用户明确授权下公开已冻结的develop提交并标记prerelease；不得据此声称main、真机、TestFlight或商店验收通过。正式发布仍按上文验收门槛执行。

0.1.2诊断候选按App与服务分别构建。日常开发验收目标包含15Pro和SE3，两机描述文件覆盖、同身份覆盖安装与配置保留分别核验。既有安装页已切换为Suixinghao新身份测试包，旧身份历史产物保留；后续更新核验同身份签名、设备覆盖及实际构建来源，再按软件更新默认部署范围更新安装页。不得继续发布旧源码，也不得把测试包当正式商店包。 Safari安装入口更新还须核对线上manifest.plist的title与IPA产品版本一致、bundle-version与IPA构建号一致，并核验下载IPA的SHA-256；不能只检查网页版本和构建号。


## 商店更新节奏（2026-10-10起）

日常已验收更新继续同步GitHub；App Store按周汇总变更，制作正式候选和提交前另行讨论确认。0.1.6／0.1.7及0.1.8拨号页面完成日常源码同步。后续用户于2026-10-10明确授权上传0.1.8 TestFlight，使用同产品版本的新正式构建build37；本次不提交App Store审核，既有0.1.5/build32审核保持。每周节奏不代表自动创建定时任务或未经确认自动提交；正式候选仍按本文件的签名、来源和Production验收流程执行。
