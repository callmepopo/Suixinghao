# 随行号公共源码协作规则

- 本仓库是唯一维护源码；`../private/` 为私有原始资料及回退档案，禁止提交其内容。
- `../hideck/` 为上游只读克隆，禁止修改或复制为自有源码。第三方许可见 THIRD_PARTY_NOTICES.md。
- `server/` 是统一电话/API 服务，`server/web/` 是内嵌测试网页；`deploy/unraid/` 是部署适配；`ios/` 是随行号客户端。
- 版本唯一来源是根 Version.xcconfig；修改前通过 `python3 ios/scripts/version.py --next` 分配，发布后不复用。同一轮协作子任务共用主代理已分配的版本，不各自递增；运行状态记录于仓库外维护日志。
- 自有代码使用 MIT，第三方许可独立。配置只给示例，禁止真实域名、内网地址、凭据、号码、短信、录音、设备标识及签名资料进入源码、日志或截图。
- iOS 工程身份为 Suixinghao，Bundle ID 为 com.junpo.suixinghao。新 App 手工重新配置；身份迁移安装须先核验新版签名和运行，再按当轮授权处理旧 App。
- 不部署线上、不拨号/发短信、不操作硬件、不发布 GitHub 或 App Store，除非当前用户指令明确涵盖相应步骤。模拟和编译不等于真机或锁屏验收。
- 构建缓存与产物放各模块 `.build/`；脚本使用相对路径，Python 用 python3。公开构建不得依赖邻近私有资料。
- 修改同步实际受影响的 README、docs、CHANGELOG.md；公共历史只记录脱敏变更和验证，私有运行流水放仓库外。
