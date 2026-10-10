# App Store后续与推送边界

GitHub公开iOS源码、用户通过App Store安装、填写自己服务地址/Key的模式可行。已有官方案例 [Nextcloud iOS源码](https://github.com/nextcloud/ios) 直接链接 [美区App Store](https://apps.apple.com/us/app/nextcloud/id1125420102)，其商店说明允许用户自行托管。开源与Apple签名/审核是独立流程，开源不等于上架已通过。

## 新身份与当前状态

公共工程名称Suixinghao，Bundle ID为 `com.junpo.suixinghao`，已完成匹配开发签名包的实际装机验证；0.1.4构建30已正式上传并由Apple处理为VALID，已加入内部TestFlight，未提交审核，SE3正式TestFlight本轮已获维护者验收，双机接听协调延期。开发者账号、证书、APNs私钥、登记设备、App Store Connect凭据只在发布者私有资料维护，不进入GitHub。身份迁移后使用新版及其独立凭据，不把旧身份的锁屏验收自动转移到新身份。

iOS工程最低目标18.0。当前保留前台通话、CallKit/PushKit、直接APNs实现，新身份已完成开发签名、装机及前台服务接入；开发包Sandbox锁屏来电、接听、双向声音及后台通话已由用户确认；锁屏原生免提候选修复复验仍回退，已登记延期。SE3正式候选0.1.4/build30已获维护者确认其他测试内容通过；双机接听协调另验，未提交正式审核。

首版计划免费提供于美国、香港、印度、土耳其、菲律宾，已在后台保存并核对，不含中国大陆，新地区不自动开放。主要类别为工具，年龄问卷按通话／短信功能声明，Apple评级4+。[公开隐私政策](privacy-policy.md)、三张真实演示态界面截图、审核联系人与测试接入、外拍／录屏／硬件照片附件已保存；App Privacy问卷尚未完成；本轮SE3正式验收通过，双机协调延期。审核接入为独立业务Key，短信库仍共享；用户已明确接受此范围，凭据只在私有资料与Apple审核说明保存。

0.1.5外部号码交接修复已在15Pro开发包验收，新的正式候选需SE3复验，不沿用0.1.4的正式验收结论。

后续更新复用仍然有效的政策、地区、审核接入、截图及视频；每个版本仍需构建上传、验证、更新说明和审核。核心功能、权限或数据流变化时同步相关材料。此处上传状态不代表已具备所有提交条件。

## 自建服务与锁屏推送

URL与App Key足以表达用户的业务服务接入。锁屏来电还需要对该App签名身份/topic有效的APNs授权：

| 使用方式 | APNs责任 |
|---|---|
| 用户自己构建并签名App | 用户注册自己的App ID，用自己Apple账号的私钥配置自己的服务；Debug sandbox，TestFlight/App Store production |
| 从发布者App Store下载App | App属于发布者签名/topic；不能让用户的普通Apple Key给发布者App直接推送，也不能分发发布者.p8给用户 |

正式商店版自建服务的推送relay已有 [受限候选实现](push-relay.md)，**Sandbox开发包锁屏接听和双向声音已由用户确认，系统免提切换经开发包复验仍自动回退，已登记延期问题，SE3正式TestFlight本轮验收通过，双机协调延期**。在支持商店锁屏能力前，仍需联调与审核relay：由发布者安全持有APNs私钥、以受限路由授权转发来电/固定短信通知，隔离用户服务器，不开放任意推送topic/任意payload；定义最小token/路由数据、撤销、限流和保留策略并更新隐私政策。候选接口、发布者配置和用户服务适配见中继文档；服务0.1.4已部署双环境路由，自动检查通过，不能代替Production真机验收。若先以前台功能上线，必须明确无relay时的锁屏能力限制，不能在商店描述中承诺完整锁屏来电。

私钥示例仅 [apns-self-build.env.example](../deploy/unraid/examples/apns-self-build.env.example)，所有值留空，仅供自行签名者填入私有service.env。开发者私钥始终留服务器，不进App和源码。

## 发布准备

1. 日常在同一repo的develop开发；private/testing保存开发签名测试包、签名配置和手机验收记录，不维护第二份源码。手机通过对应版本验收后合main/tag。
2. 使用正式Release构建候选包进TestFlight，验证production APNs、真实来电/锁屏、双向声音/后台、短信提示、弱网/强退边界；开发签名sandbox不能代替这些检查。验证后的同一正式构建用于美区审核和版本映射。
3. 准备商店文案、截图、公开支持页、隐私政策与App Privacy回答；声明需自建兼容服务及模块，明确当前支持范围和限制。给审核人员可用的测试接入和演示说明，审核私有Key不能进公开repo。
4. 核对CallKit/PushKit、麦克风/通知/通讯录用途、后台模式与默认通话能力是否符合实际；只用真实来电的VoIP推送，收到后按Apple要求及时报告系统来电。新ID权限/推送并未因旧ID通过而自动通过。
5. 建立商店版本/构建号→源码tag/commit→固定Xcode和依赖→CI产物/摘要/证明→上传构建的发布链；App关于页显示源码标识。详细流程以 [发布说明](releasing.md) 为准。

源码与商店软件的关系应表述为“该版本对应公开源码及可追溯构建”。[GitHub产物证明](https://docs.github.com/en/actions/concepts/security/artifact-attestations)绑定提交和构建流程，[可复现构建](https://reproducible-builds.org/docs/definition/)还需要固定环境与独立复建比对；Apple会制作 [设备包变体](https://developer.apple.com/documentation/Xcode/reducing-your-app-s-size)，不能用商店下载包与提交IPA简单哈希相等证明源码一致。不要把签名/版本号一致写成未经验证的字节级证明。

Apple提交与审核的当前规范参见 [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) 和 [上传构建](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)。依赖上游非商业限制与App Store目标应单独核对；自有MIT许可不覆盖HiDeck、GPL驱动或Apple协议。
