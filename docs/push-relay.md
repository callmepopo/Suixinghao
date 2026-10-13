# 官方 App 推送中继

实现状态：2026100912中继已在独立生产环境实例完成启动、HTTPS、未授权拒绝、授权撤销及容器重启检查；Sandbox中继及用户服务已完成对接，用户确认开发包锁屏来电、接听、双向声音与退后台通话；系统免提切换尚有问题，Production／TestFlight与商店验收仍待完成。不能将开发包结果当作商店版功能已验收。

## 数据流与授权

用户的 App 仍只填写自建服务 HTTPS 根地址与 App Key。用户服务器另向发布者申请一把中继后端凭据；不把这把凭据发给 App，也不要求用户持有发布者 Apple 私钥。既有人工授权继续兼容；服务0.1.5增加受控自动绑定接口，发布者启用后由NAS管理员申请、官方App验证确认，NAS自动领取和续期。不得开放无需验证的匿名签发。

真实模块来电 → 用户服务确认来电并取得 call_id → 向中继提交该设备 PushKit token 和 call_id → 发布者固定 topic 的 APNs → iPhone CallKit。短信仅发送固定的“收到新短信，点开查看”提醒。音频、号码、联系人和短信正文不经过中继。

凭据相互独立：App Key 仅用于用户自己的业务服务；`sxr_` 后端凭据仅用于推送中继；Apple `.p8` 私钥只由发布者持有。每把中继凭据绑定 sandbox 或 production，一次只服务一个环境；不同环境运行独立中继进程。中继 topic 固定为 `com.junpo.suixinghao`，不接受客户指定 topic、URL 或任意推送 payload。

被授权的用户服务器掌握其设备推送 token，属于可信推送发起方。中继自身无法证明蜂窝来电确实发生；发布者必须核实后端用途，发现滥用立即撤销其授权。VoIP 请求只能由真实来电事件触发，不能用虚构来电测试推送连通性。

## 接口

`POST https://relay.example.org/push-relay/v1/push`

请求头：`Authorization: Bearer <独立后端凭据>`、`Content-Type: application/json`。请求体至多 1024 字节，不允许未知字段、查询参数或尾随 JSON。

| 字段 | 要求 |
|---|---|
| kind | voip 或 sms |
| token | 客户端登记的 APNs 路由 token；64～256 位十六进制，偶数长度 |
| environment | 与该中继和授权一致的 sandbox 或 production |
| call_id | voip 必填，32 位小写十六进制；sms 不传 |

成功返回 HTTP 200、`{"apns_status":200}`，只表示 APNs 已接受或近期同一事件已成功发送。401 表示后端授权失效；400 为请求或环境错误；409 为同一事件正在发送；429 为限流；502 为 APNs 拒绝或暂不可达，响应只保留有限错误类型。超时、409、429 不应驱动虚构来电或无上限重试。

每个后端每分钟最多 120 次请求、20 次推送；全局最多 8 个 APNs 并发。相同设备／call_id 的成功 VoIP 事件在 5 分钟内去重；固定短信提醒在 10 秒内去重。失败允许后续真实事件重试。内存去重上限 20000 项，重启会清空；不是跨重启的恰好一次投递保证。

`GET /push-relay/health` 仅返回进程版本与环境，不验证 Apple 凭据、设备 token、来电或锁屏能力。

## 发布者部署

1. 以独立私有数据目录和进程运行，不启动用户模块服务，不与 AT／声卡交互。构建沿用 server/build.sh，固定干净提交和 source.json。
2. 按 [publisher-relay.env.example](../deploy/unraid/examples/publisher-relay.env.example) 配置。为新版 App 在 Apple 后台签发对应环境的 APNs 授权，私钥文件 0600；不要使用 App Store Connect 管理 API Key 代替。
3. Linux VPS 可使用 [独立容器方案](../deploy/relay/README.md)；Unraid 使用 [relay-service.sh](../deploy/unraid/relay-service.sh) 管理独立进程。设置其目录、二进制、私有 env 文件；先 `start` 再健康检查。该脚本不改 NPM、DNS 或现有电话服务。
4. HTTPS 反代仅代理 `/push-relay/` 到中继端口，关闭请求访问日志，不记录 Authorization 或正文，限制连接数及请求体。端口仅向反代开放；不要将中继私有配置或数据目录映射为静态文件。非授权请求还应由反代按来源限流，应用内配额只针对已授权后端。
5. 在发布者本机／宿主串行执行授权操作（不要并行运行两个修改授权文件的命令）：

```sh
VOICE_WEB_DATA_DIR=<私有中继目录> ./voice-web relay-issue <后端名称> production <新建私有凭据文件>
VOICE_WEB_DATA_DIR=<私有中继目录> ./voice-web relay-revoke <授权ID>
```

凭据只写新文件，不打印；授权存储只保留摘要、名称、ID 和环境。用私有安全渠道交给对应后端维护者。授权 ID 在私有 relay-grants.json 内核对，不提供公共列表接口。撤销在后续请求立即生效，已交给 APNs 或已在途的推送无法撤回。

## 用户服务配置

按 [relay-client.env.example](../deploy/unraid/examples/relay-client.env.example) 在自己的服务 env 配置中继完整 HTTPS 接口 URL 与私有凭据文件。两项都必须有效；只配一项会失败，不能降级为旧身份直接推送。未配置中继时保留自行签名者的直接 APNs 模式。

服务0.1.4支持同一实例同时连接Sandbox和Production中继：通过`VOICE_WEB_PUSH_RELAY_URL_SANDBOX`／`VOICE_WEB_PUSH_RELAY_KEY_FILE_SANDBOX`和对应`_PRODUCTION`配置对，按手机登记的推送环境选择路径与凭据。某环境没有显式配置时兼容原默认配置对；显式配置不完整时拒绝推送，不借用默认凭据。开发包与TestFlight使用独立手机App Key，服务器持有独立中继后端Key，手机不保存中继Key。

服务仍先筛选有效 App Key 关联的设备 token，再触发推送。撤销本地 App Key 后不再向该设备发起新推送。中继不持久保存设备 token 或每手机路由，不另建用户手机注册库；若后端整体失去信任，发布者撤销中继后端授权。

## 隐私、验证与回退

中继仅在请求处理中接触设备 token、随机 call_id 与推送环境；不落盘。去重内存只保存 token／事件的摘要及时间，最长 5 分钟。每后端配额仅保留摘要和计数，过期项在后续请求清理；授权摘要与名称保留至撤销。HTTPS 服务及反代仍会接触连接 IP，发布者应关闭访问日志并核对托管平台保留策略。正式隐私政策和商店 App Privacy 需反映这些事实，不能填“无数据收集”。

上线前验证：授权隔离及撤销、环境／topic、限流、固定消息、断网和超时、真实单次来电、至少两分钟锁屏来电及双向音频、真实单次短信、production TestFlight，以及重启与后台边界。保留脱敏结果。Apple 实发、真机和商店审核均为独立验收层级。

回退中继只恢复独立进程、二进制及配置，不回滚客户后续数据，不重启模块。删除用户服务中继配置只适用于自行签名且已经配妥自己的直接 APNs 授权；官方商店包没有这个直接推送回退能力。


## 自动开通（服务0.1.5／App0.1.9）

代码已增加自动授权流程，部署与真机证明验证需分别记录，不将合成测试记为Apple实证。用户自备兼容NAS、DJI及可从手机访问的HTTPS入口；不需要VPS或开发者账号。官方App不内置私人服务地址或中继私钥，中继地址由NAS配置提供。

NAS管理员在App接入页选择环境、登记昵称并申请；官方App通过该NAS的有效App Key取得绑定请求，在设置页确认。VPS验证NAS的Ed25519实例签名和Apple App Attest证明，签发该实例的独立授权；NAS认证领取后保存到本机0600文件。App不取得中继凭据。昵称为自报管理标识，不是已验证的真实身份，不自动关联TestFlight邮箱。

发布者在各环境私有env设置 `VOICE_WEB_RELAY_AUTO_ENROLL=1` 和 `VOICE_WEB_APP_ATTEST_APP_ID=<实际App ID前缀>.com.junpo.suixinghao`。前缀从Apple权威资产／描述文件确认，不写进公开源码。服务嵌入Apple官网App Attest公共根证书，来源为 `https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem`，不是私钥；更换前核对官方来源。原App推送topic及APNs私钥不变。

NAS配置匹配环境的完整中继URL，自动模式不设置该环境的 `VOICE_WEB_PUSH_RELAY_KEY_FILE_*`；手工凭据路径仍优先、不会自动替换。手工转自动时先备份配置，在NAS管理页明确移除该环境手工路径再申请；旧VPS授权不因此撤销。自动授权保存在 `relay-auto-<环境>.json`，含NAS随机身份种子及后端凭据，属于NAS私有资产；不得复制给App或放网页目录。备份此文件，避免重建实例占用额外授权。

绑定有效期10分钟。NAS信封包含action、公钥、昵称、环境、时间、随机nonce和binding_id，并以Ed25519签名；时间偏差不超过60秒，nonce按摘要防重放并保留120秒，部署双方需正确校时。App Attest验证链、nonce、App ID、环境、凭据公钥及认证计数；首次attestation后同一App实例使用assertion。开发环境与Production分离；不支持或证明失败时拒绝自动签发，保持手工方式，不用固定口令或客户端自报环境绕过核验。

每个已验证App证明密钥最多关联3个NAS实例，含已撤销记录；同实例重复开通返回原授权。应用重装可能产生新证明密钥，这不是实名用户总量限制，也不证明DJI在线或真实来电。每个中继最多1000条授权记录（含撤销），待绑定最多1000；达到上限拒绝新增，不自动删除历史。应用层按直接连接来源每分钟20次开通请求（反代时可能为共享来源），反代还需按实际来源限速；pending申请仍可能被滥用消耗配额，需监控并可关闭开通入口。Apple欺诈风险receipt评估尚未接入，不宣称已证明物理设备唯一或防止所有批量申请。

自动授权有效90天，NAS每30分钟检查，最多每日续期一次；余期不足60天才延期90天。到期后7天内允许原实例恢复续期，期间到期授权不发推送；超过宽限须管理员处理，撤销永久拒绝同实例续期／重试。签发和续期不混计。VPS派生秘密文件 `relay-enrollment-secret` 必须0600并受控备份，只有此私有主秘密和实例上下文可以重算自动凭据，运行授权文件只保存摘要；丢失主秘密不能靠摘要恢复凭据。文件锁串行保护自动与CLI写入，原子保存；领取响应丢失可用原实例身份重试。

反代允许开通对象至32KiB，`/v1/push`应用层仍限定1024字节。保持访问日志关闭、TLS、私有路径404及独立环境；NAS和VPS不新增AT接口或硬件操作。

### 签发台账与本地材料同步

新手工／自动授权保存签发时间、方式、登记名称、NAS实例、环境、期限和生命周期；撤销保留历史，旧授权缺失时间不补造。每授权保留最近128条生命周期事件，首次签发时间独立保留。查询导出仅在VPS管理员终端执行，不开放公共管理接口：

```sh
VOICE_WEB_DATA_DIR=<私有中继目录> ./voice-web relay-export <新的私有导出文件>
```

导出不含凭据、摘要、NAS私钥或App证明密钥。汇总为首次签发数、有效／过期／撤销数、登记名称数和NAS实例数；登记名称数不能当作经验证的自然人人数。通过已有安全管理通道取回文件，再在本机执行：

```sh
python3 scripts/sync-relay-ledger.py --ledger <私有JSON> --material <私有网友测试材料.md>
```

同步按授权ID更新专用生成段，原测试邮箱、预备凭据及手工接收人／备注保持；预备授权名称不自动推定为接收人。不是公网实时写入本机Markdown，也不创建自动定时同步；没有请求同步的运行中变更留在VPS事实台账。


本批部署结果（2026-10-13）：服务0.1.5/build6与两环境中继已部署；原授权及用户NAS手工配置保留，健康、拒绝非法开通请求和HTTPS入口检查通过。App0.1.9开发build39／内部TestFlight build40已可分发；真实Apple应用证明与自动模式NAS锁屏验证仍待完成。Production台账已成功脱敏导出和本地材料合并；这是管理员同步，不是实时公网写文件。
