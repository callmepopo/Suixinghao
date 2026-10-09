# 随行号服务 API v1

适用公开版本 202610094。路径保留 `/voice-test/` 以兼容现有客户端；服务根地址示例为 `https://voice.example.org`。本规范描述服务实际契约，示例内容全部合成/占位。配置入口见 [部署](../deploy/unraid/README.md)。

## 地址、凭据与通用规则

App 只填写 HTTPS 根地址与管理员签发的 App Key，客户端拼接以下路径。`/voice-test/` 是测试网页，`/voice-test/app-access/` 是管理员 Key 页面。WebSocket 使用同一主机的 `wss://voice.example.org/voice-test/stream`。

| 凭据 | 获得方式 | 可调用范围 |
|---|---|---|
| 管理网页会话 | HiDeck 账号密码经 `POST login` 验证 | 状态/控制/音频、Key 管理 |
| 上游短期 token | HiDeck 原登录流程 | 只能经 `POST session` 换本服务会话 |
| App Key | 管理页为单台手机签发 | `app/*` 白名单、换电话会话；不能管理 Key |
| App 电话会话 | `POST app/session` 用 App Key换取 | 状态/控制/事件/音频/录音/退出，绑定原 Key |

原生请求使用 `Authorization: Bearer <凭据>`，不要求 Origin。浏览器携带的 Origin 必须同源或在部署白名单中；网页只读请求可使用有效的 `Secure/HttpOnly/SameSite=Strict` Cookie。WebSocket 原生可带 Bearer，浏览器使用 Cookie。禁止在 URL 放 Key/token，禁止跳转时转交授权头。JSON 请求设置 `Content-Type: application/json`；已认证业务响应 `Cache-Control: no-store`。短信数组接口的空结果为 `[]`，设备列表仍使用对象封装。

常见状态码：400 参数/格式错误；401 凭据失效或权限凭据类型不符；403 来源拒绝；404 未开放路径/对象不存在；405 方法错误；409 通话所有权、状态或资源冲突；413 请求过大；429 上游限流；502 上游失败/响应不完整；503 凭据或持久化暂不可用。错误可能为空或纯文本，不保证统一 JSON 错误结构；调用方先判断状态码。

`GET /voice-test/health` 无认证，返回 `{"ok":true,"version":"202610094","source_commit":"<git-commit>"}`，source_commit在构建时有值才出现。ok只表明进程可响应，不代表模块在线、SIM就绪或实际声音正常。

## 登录、会话与 Key 生命周期

下表路径均以 `/voice-test` 为前缀。

| 方法 / 路径 | 请求 | 成功响应 |
|---|---|---|
| POST `/login` | `{"username":"<admin>","password":"<private-password>"}` | 200 `{"token":"<session>","expires_at":"<RFC3339>","token_type":"Bearer"}`；8小时 |
| POST `/session` | Authorization为HiDeck token，空正文 | 200 `{"token":"<session>","expires_in":900}`；同时设Cookie |
| POST `/app/session` | Authorization为App Key，空正文 | 200 `{"token":"<phone-session>","expires_in":7200}` |
| POST `/logout` | 当前本服务会话 | 204；会话失效 |
| GET `/app-keys` | 仅管理网页会话 | 200 `[{"id":"<opaque-id>","name":"测试手机","created_at":"<RFC3339>"}]` |
| POST `/app-keys` | 管理会话；`{"name":"测试手机"}` | 201 `{"id":"<opaque-id>","key":"<shown-once>"}` |
| DELETE `/app-keys?id=<opaque-id>` | 仅管理会话 | 204；不存在404 |

最多20个App Key，名称非空、最长80字节；Key为 `hdk_` 加32字节随机值的十六进制。服务只持久化 SHA-256摘要和元数据，Key只展示一次，没有取回接口。App Key有效直到主动撤销；建议每手机一把。撤销立即拒绝新请求，绑定电话会话在后续请求/SSE心跳/音频检查中失效，并清理该Key的推送登记与手机连接历史。已提交短信不能撤回。

重启服务保留App Key，所有短期会话失效。Key存储损坏时拒绝认证，不自动覆写。不要在通话中更换电话会话；呼叫前续期，通话保持原会话。管理会话、App Key、App电话会话不能互相当作同一种token使用。

## 电话状态、控制与音频

| 方法 / 路径 | 凭据及行为 |
|---|---|
| GET `/status` | 本服务电话/网页会话，返回状态快照 |
| POST `/phone` | 同上；state/dial/answer/hangup/dtmf |
| GET `/events` | 同上；SSE `event: call` 推状态快照 |
| GET `/diagnostics` | 同上；返回缓存，不因请求新增AT查询 |
| GET `/stream` | 同上；WebSocket，单音频所有权，第二个连接409 |
| GET/POST `/recording` | 同上；读/写后续通话录音开关 |

状态快照：

```json
{"state":"ringing","call_id":"opaque-call-id","caller":"<caller>","media":false,"recording":false,"frames_up":0,"frames_down":0,"available":true,"sequence":12,"observed_at":"2026-10-09T00:00:00Z","module_rtt_ms":20}
```

state为 idle/ringing/dialing/active/busy/unavailable；caller、message、observed_at、module_rtt_ms可省略。caller仅在授权响应中使用，不应写日志。available是近期AT状态可用，超过约6秒无成功状态时为false；旧state和call_id仍可能保留，应结合available/message判断。media表示路由启用，不能证明听感。sequence仅进程内递增。

SSE连接立即发送新快照，变化时更新，空闲每秒注释心跳。SSE id不承诺历史重放，重连以最新快照为准。客户端用call_id判断旧通话结束，避免旧挂断操作误伤新来电。

POST phone请求及成功200响应：

| 操作 | JSON | 条件 |
|---|---|---|
| state | `{"action":"state"}` | 与GET status相同 |
| dial | `{"action":"dial","number":"<number>"}` | 先建立同会话声音连接，模块idle |
| answer | `{"action":"answer","call_id":"<current-id>"}` | 当前ringing；先建立声音连接 |
| hangup / 拒接 | `{"action":"hangup","call_id":"<current-id>"}` | 必须当前ID；已有所有者时由原会话操作 |
| dtmf | `{"action":"dtmf","call_id":"<current-id>","digit":"1"}` | active；0–9、*、#、A–D |

响应为状态快照；HTTP200不等于对方接听或听到声音。拨号仅接受数字或国际号码前导+，拒绝AT注入。11位国内手机号补+86；3～6位短号、本地7～8位座机、带区号10～12位座机、400/800十位号码按原号；完整国际号码+后7～15位数字。格式规则不等于当地可接通，短信规则独立。

诊断响应字段：server_version、module_available、module_checked_at、module_rtt_ms、sim_status、network_status、network_checked_at、可选signal_rssi(0～31)。时间为RFC3339；没有设备/SIM标识和原始AT文本。控制worker仅空闲时分轮读取CPIN/CEREG/CSQ，每轮完成至少间隔30秒；通话时用缓存，LTE注册不能证明IMS语音可用。

声音WebSocket双向二进制为 **8000 Hz / S16_LE / 单声道，每包160样本=320字节=20ms**。客户端负责采集重采样和系统音频。上行固定20ms一包；待机可每5秒发文本 `ping`，15秒无上行/心跳会断开。下行也有JSON `{"status":"<description>"}` / `{"error":"<description>"}`，必须同时处理。接通后才启用模块路由和ALSA，待机不持续占声卡。单消息上限4KiB。

可选子协议 `sxh.audio-diagnostics.v1`：新客户端在握手中请求，服务确认后才每5秒发送一次 `audio_stats`。未协商时只发送PCM/ping，不上传诊断。JSON字段：type=audio_stats、version=1、segment为随机UUID、elapsed_ms及数值计数：sent_frames/send_us_total/send_us_max/interval_us_total/interval_count/interval_us_max/missed_slots、captured_samples/capture_queue_peak_samples/capture_dropped_samples、waiting_silence_frames/muted_silence_frames/capture_underfill_frames、down_received_frames/down_inactive_frames/down_dropped_frames/down_played_frames/playback_queue_peak_frames。耗时/间隔单位微秒，elapsed_ms毫秒，samples为样本数，其余frame为20ms包。最多2KiB、服务至多每4秒接受一次，elapsed_ms≤24小时、计数为0～10^12整数；省略按0，非法/额外字段忽略不打断PCM。客户端数值不证明端到端延时或实际听感。

GET recording返回 `{"enabled":false}`；POST同JSON返回当前开关，仅影响后续通话。公开部署示例写入false关闭录音；代码在配置缺失/损坏时仍按开启处理，部署必须保留关闭配置。启用后每通最多1小时，目录上限1GiB滚动清理，保存上行/下行/合并WAV三份；文件名包含对手号码，严格留在私有宿主目录，不进仓库/日志/截图。

拨出60秒未接通自动结束，单通话上限1小时。音频断线、优雅停服或音频子进程失败，会结束本服务拥有的通话；连续三次控制失败停止声音并尝试挂断。模块离线时无法保证运营商立即结束。进程崩溃后遗留无所有者通话只能经已认证客户端明确清理，不自动接管或自动接听。

## 短信与设备（App Key）

这些接口使用App Key，不能用电话会话替代。服务按固定白名单调用HiDeck HTTP API，不开放任意AT、配置、删除、任意URL代理。成功响应按HiDeck 2.1.23透传，最大4MiB；上游非2xx状态保留但错误正文统一为固定描述。

| 方法 / 路径 | 参数/响应 |
|---|---|
| GET `/app/devices` | 对象 `{"devices":[...],"device_limit":...}`；每个设备含id/name/running/healthy/modem等上游字段，客户端可忽略device_limit和未知字段；响应可能含SIM/设备标识，不能整包写日志 |
| GET `/app/sms/contacts` | 可选device_id、limit、before_ts；返回SMSContact数组，按last_timestamp倒序 |
| GET `/app/sms/thread` | 必填peer，加iccid或device_id/imsi选择器；limit、before_ts、before_id分页；返回SMSMessage数组，timestamp/id倒序 |
| POST `/app/sms/send` | 仅device_id/phone/message；正文≤32KiB；phone/message必填；200为上游提交成功 |
| PATCH `/app/sms/thread` | query仅业务必需iccid/peer；JSON `{"through_id":12}` 正整数，正文≤128字节 |

查询实际只转发device_id/peer/iccid/imsi/limit/before_ts/before_id，其他参数不会到上游。上游联系人支持before_peer，但当前本服务未转发，不应宣称完整同时间戳分页。limit默认50、上游最多200，App会话当前最多显示最近100条。before_ts使用RFC3339；thread可同时用before_ts与before_id避免同时间戳跳页。iccid不能与device_id/imsi同时用；thread优先使用列表中原样返回的iccid和peer。国际号码+必须URL编码为%2B。contacts的iccid/imsi兼容参数不代表独立卡片筛选能力，以device_id筛选为准。

设备响应的合成最小示例（其余字段由固定上游版本提供；空列表为 `{"devices":[],"device_limit":3}`，上限值应读取响应而非写死）：

```json
{"devices":[{"id":"demo-device","name":"演示模块","running":true,"healthy":true,"modem":{"network_mode":"LTE"}}],"device_limit":3}
```

SMSContact完整形状：

```json
[{"imsi":"<sim-id>","iccid":"<card-id>","peer":"<test-peer>","last_sms_id":12,"last_timestamp":"2026-10-09T00:00:00Z","last_content":"合成测试消息","last_type":1,"unread_count":1,"created_at":"2026-10-09T00:00:00Z","updated_at":"2026-10-09T00:00:00Z","device_id":"eth1","device_name":"测试模块","local_phone":"<local-number>"}]
```

SMSMessage完整形状：

```json
[{"id":12,"imsi":"<sim-id>","iccid":"<card-id>","peer":"<test-peer>","local_phone":"<local-number>","sender":"<test-peer>","recipient":"<local-number>","content":"合成测试消息","type":1,"status":0,"timestamp":"2026-10-09T00:00:00Z","created_at":"2026-10-09T00:00:00Z","device_name":"测试模块","incomplete":true}]
```

type：1入站、2出站；status：0未读、1已读、2发送成功、3发送失败。incomplete仅为true时出现，表示上游未完整合并的短信。last_type遵循相同方向；device_id/device_name/local_phone等信息可能空值（历史卡片离线、号码未写入SIM），不要因空值把历史会话误绑定给另一张SIM。

发送请求 `{"device_id":"eth1","phone":"<number>","message":"合成测试消息"}`；200返回：

```json
{"status":"ok","message":"短信发送成功","device":"eth1","phone":"<number>","message_id":"","parts_total":1,"delivery_state":"acked"}
```

message_id可能空；parts_total是分段数，delivery_state是上游提交状态，不能把acked或HTTP200当作对方收到。是否真实送达由接收者确认；长短信分段和限流沿用HiDeck。国内手机发送应明确国际+86前缀，禁止失败后自动重发造成重复短信。

已读成功响应：`{"status":"ok","iccid":"<card-id>","peer":"<test-peer>","marked":1,"unread_count":0,"through_id":12}`。只标记ID≤through_id的已显示边界，之后新到短信仍未读；404表示找不到会话。

## 推送令牌（App Key）

POST `/app/voip-token` / `/app/sms-push-token` JSON `{"token":"<hex-token>","environment":"sandbox"}`；environment只能sandbox/production，成功204。DELETE同路径清除当前Key登记，204。每Key每类型只保留一个手机令牌；两种令牌互不替代，服务不通过网页返回或打印token。

VoIP首次观测新ringing/call_id时发送一次APNs：HTTP/2+ES256，topic为自己的Bundle ID+.voip、push-type=voip、到期0，仅call_id不含号码。普通短信提醒正文固定，不含短信正文或发送者；约10秒读取上游，首次以现有最新短信为基线，仅之后新入站触发。APNs可能延迟/合并；推送失败不阻断网页前台接听。

当前直接APNs实现适用于 **部署者自行构建并用自己的Apple账号签名的App**。正式商店App使用发布者的推送topic与授权，用户自有Apple Key无法给发布者App直接推送。本项目尚未实现商店推送relay，不能把自配URL/Key等同商店锁屏可用；见 [App Store后续](app-store.md)。

## 连接历史（App Key）

GET/POST `/app/connection-history`；只返回本Key手机事件与共享module/network事件，不返回owner。POST `{"events":[...]}`，1～100条、≤64KiB；事件为id(UUID)、at(Unix秒可小数)、layer=phone、kind、state、reason，拒绝额外字段和client owner/RSSI。kind：observation/network_down/network_up/network_change/retry/connected/request_failed/observer_start/observer_stop/auth_failed。state：online/offline/unknown或空。reason：空/no_network/network_change/request_failed/background/startup/foreground/logout/auth_failed/gap。时间不能早于30天或领先服务器5分钟。200 `{"accepted":1}` 仅在落盘后确认，同Key+ID去重；503保留客户端待传批次。

GET响应含generated_at、retention_days=30、summaries、outages、events。summary为layer、online_seconds/offline_seconds/unknown_seconds、coverage、online_rate(无有效观测null)、interruptions。coverage=(online+offline)/86400，online_rate=online/(online+offline)。每次观测最多有效90秒，后台暂停/采样缺口为unknown。outages最多最近100条：id/start/end(可省略)/network_restored(可省略)/attempts/reason/incomplete；events最多最近200条非心跳变化倒序，字段同事件，module/network可有rssi。平均恢复时间仅根据窗口内完整过程，不能将手机在线率称全天可接听率。

服务保留最多30天、每层每Key约45000事件、全局200000，密集事件可能提前滚动；常规增量追加、约每日合并。手机前台恢复且无通话时每分钟最多补传100条，通话/恢复中/后台暂停。只记录状态/时间/次数/信号，不含号码、通信内容、原始错误或凭据。

## 兼容与验证

根版本与API v1含义分开：版本标识发布批次，v1标识现有契约。新增可选字段由客户端忽略，变更既有路径/字段/鉴权需要先更新双方及兼容测试。HiDeck 2.1.23后台HMAC凭据适配读取宿主私有配置，仅内存生成5分钟凭据；上游鉴权变更后必须重验，不能自动升级latest。

核心检查：Key摘要持久化/撤销/权限隔离、号码与AT注入拒绝、通话ID/所有权、PCM/SSE/心跳、短信列表/分页/已读/响应上限、缓存诊断、历史去重/未知区间、APNs环境/固定文案。服务Go race/vet、本地模拟及编译通过不等于新部署真机电话/短信/锁屏通过，最终按 [验收清单](requirements.md) 记录。

## 官方推送中继适配

业务接口及App Key保持不变。用户服务可私有配置中继HTTPS接口与独立后端凭据；不把发布者Apple私钥交给用户。候选中继契约、限流与隐私边界见 [push-relay.md](push-relay.md)。尚未部署或完成Apple／真机验收，不视为线上功能已经可用。
