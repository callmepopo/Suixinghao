# App Store后续与推送边界

> 当前正式商店状态（2026-10-28核验）：**App 0.1.13/build63 已通过审核并自动上架，可下载。** [App Store下载](https://apps.apple.com/us/app/id6820851330)。Apple版本状态READY_FOR_SALE／READY_FOR_DISTRIBUTION，downloadable=true，原审核提交COMPLETE；关联构建63为VALID，来源仍为5c7b3ab。本次未重建或重新上传。以下早期构建描述保留为历史背景，以本段及文末最新状态为准。


GitHub公开iOS源码、用户通过App Store安装、填写自己服务地址/Key的模式可行。已有官方案例 [Nextcloud iOS源码](https://github.com/nextcloud/ios) 直接链接 [美区App Store](https://apps.apple.com/us/app/nextcloud/id1125420102)，其商店说明允许用户自行托管。开源与Apple签名/审核是独立流程，开源不等于上架已通过。

## 新身份与当前状态

公共工程名称Suixinghao，Bundle ID为 `com.junpo.suixinghao`，已完成匹配开发签名包的实际装机验证；当前App 0.1.5/build32已上传、由Apple处理为VALID并获SE3 TestFlight验收，已提交同一构建审核，状态为WAITING_FOR_REVIEW，尚未上架；双机接听协调延期。开发者账号、证书、APNs私钥、登记设备、App Store Connect凭据只在发布者私有资料维护，不进入GitHub。身份迁移后使用新版及其独立凭据，不把旧身份的锁屏验收自动转移到新身份。

iOS工程最低目标18.0。当前保留前台通话、CallKit/PushKit、直接APNs实现，新身份已完成开发签名、装机及前台服务接入；开发包Sandbox锁屏来电、接听、双向声音及后台通话已由用户确认；锁屏原生免提候选修复复验仍回退，已登记延期。SE3正式候选0.1.4/build30已获维护者确认其他测试内容通过；双机接听协调另验，未提交正式审核。

首版计划免费提供于美国、香港、印度、土耳其、菲律宾，已在后台保存并核对，不含中国大陆，新地区不自动开放。主要类别为工具，年龄问卷按通话／短信功能声明，Apple评级4+。[公开隐私政策](privacy-policy.md)、三张真实演示态界面截图、审核联系人与测试接入、外拍／录屏／硬件照片附件已保存；App Privacy问卷已完成并发布；本轮SE3正式验收通过，双机协调延期。审核接入为独立业务Key，短信库仍共享；用户已明确接受此范围，凭据只在私有资料与Apple审核说明保存。

当前App 0.1.5/build32已正式上传、由Apple处理为VALID并加入内部TestFlight，审核草稿已关联同一构建。外部号码交接修复已在15Pro开发包验收，SE3已由维护者确认这一正式构建验证通过。main与develop已同步公开源码；App Privacy已发布，正式提交已成功并读回WAITING_FOR_REVIEW，尚未上架。GitHub App 0.1.5标签与脱敏清单绑定实际构建来源。双机停止响铃协调与Apple Watch提醒延期。

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


## 2026-10-13 自动开通内部候选

按用户指定的SE3 TestFlight渠道，App0.1.9/build40已上传并在既有内部组可测试，Apple VALID／IN_BETA_TESTING；未提交商店或外部测试审核，原商店及网友外部包不由本轮替换。开发包build39通过既有网页渠道提供，自动授权服务0.1.5已部署。真实App Attest与锁屏仍待验，隐私数据新增须在正式提交前核对；细节及此次干净develop内部测试例外见[发布说明](releasing.md)。

## 2026-10-24 正式审核补充材料

Apple正式审核0.1.8/build37读回REJECTED，要求说明通讯录是否上传／保存（2.1）、更换缺少支持信息的Issues列表链接（1.5），并回答潜在付费服务的商业模式问题（2.1(b)）。维护者确认免费提供NAS软件代码、iOS客户端及官方中继，用户自备硬件和运营商套餐，无收费订阅或功能解锁。通讯录本地匹配，不上传或在服务器保存；用户主动拨号／发短信的目标号码仍交由自有NAS处理。

[公开支持页](support.md)提供中英文求助入口、使用步骤、常见问题与隐私提醒，商店Support URL指向该页的GitHub main渲染地址。此次仅修正文档和支持元数据，不换构建、不递增版本；审核答复和重新提交分别记录实际结果，不能将准备完成记为审核通过。

## 2026-10-24 使用build63重新提交

按维护者明确指令将原审核版本改为0.1.13并关联既有build63（Apple VALID、APP_STORE_ELIGIBLE，内部／外部TestFlight均IN_BETA_TESTING），没有重建、重新上传或改动产物来源。英文答复已发送并在审核线程确认，逐项说明通讯录本地拨号查找、不上传／服务器不保存通讯录、免费技术分享及App Key非付费激活码。描述和审核备注同步新版功能、免费模式与支持入口；审核专用接入鉴权、模块available与电话idle通过，只读状态检查不代表新一轮真实通话验收。

商店现有App Privacy为用户ID、设备ID、其他使用数据，均用于App功能且与身份关联；对照自动授权实例、应用证明及生命周期信息核对后保留，未改为无数据收集。现有硬件／实机附件处理COMPLETE，明确其为0.1.8/build37历史操作演示，不标成build63录像。原审核线程于2026-10-24 13:30:56 UTC（台北21:30:56）重新提交，版本及提交均读回WAITING_FOR_REVIEW；保持AFTER_APPROVAL自动发布。网友外测、NAS及中继不变；未新增真机或锁屏验收。

## 2026-10-28 正式上架核验

Apple API核对0.1.13关联build63，正式审核提交COMPLETE，版本READY_FOR_SALE／READY_FOR_DISTRIBUTION、downloadable=true；按AFTER_APPROVAL自动发布。此日期是核验日期，不代表精确批准时间。商店安装使用上述下载入口，仍需自建兼容NAS服务、模块及SIM卡；App不预置个人服务地址或Key。GitHub原标签、附件及产物来源保留，不新增手机安装、真实通话或锁屏验收。
