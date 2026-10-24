# Suixinghao Support / 随行号技术支持

Suixinghao (随行号) is a free, community-maintained project for connecting an iPhone to the user's own compatible DJI cellular module and NAS. The maintainer provides the NAS software source, iOS client and official notification relay for free technical sharing. There are no paid accounts, subscriptions, feature purchases or paid relay plans. Users supply their own hardware and SIM/mobile plan; any carrier charges are paid directly to their carrier.

## Contact the maintainer

For app, NAS software or official relay questions, bugs and support requests, **[open a support request](https://github.com/callmepopo/Suixinghao/issues/new)**. Sign in to a free GitHub account, enter a short title, describe your question and submit the request. The project maintainer replies in the issue thread. Chinese and English are welcome. **[View existing requests and replies](https://github.com/callmepopo/Suixinghao/issues)** before opening a duplicate.

Include the app version/build, NAS software version, iOS version, what you expected, what happened and steps to reproduce. For connection or notification problems, include the error text and whether the problem affects foreground use, background use or a locked screen. Redact screenshots before posting.

Support is provided by a volunteer maintainer; response times are not guaranteed. This project is independent of DJI, Apple, NAS vendors and mobile carriers. For hardware purchases, SIM plans or carrier billing, contact the relevant provider.

## Common questions

- **What do I need?** Your own compatible cellular module, SIM and self-hosted NAS service. See the [hardware requirements](hardware.md), [setup and operations](operations.md), and [iOS guide](../ios/README.md).
- **How do I connect?** Enter your own NAS service's HTTPS root address and the App Key issued by its administrator. An App Key grants access to that NAS; it is not a purchase or subscription code.
- **Why do locked-screen calls not arrive?** Check the NAS notification-relay configuration and authorization. See [notification setup](automatic-push.md). The official relay forwards notification signaling; it does not provide a telephone number or a mobile plan.
- **Are contacts uploaded?** No. Address-book access is optional and used locally to match names and phone numbers. The app does not upload or synchronize the address book to the NAS or official relay. When you initiate a call or SMS, the destination number is sent to your own NAS to perform that action; call/SMS records are separate from address-book synchronization. See the [privacy policy](privacy-policy.md).

## Protect your information

GitHub issues are public. Do not post App Keys, passwords, server addresses, push tokens, personal phone numbers, message contents, recordings or hardware/SIM identifiers. For a privacy concern, open a request that describes the concern without personal data and ask the maintainer how to proceed. For data stored on your own NAS, contact its administrator.

## 中文求助说明

随行号是免费、由爱好者维护的技术分享项目。用户自行准备兼容 DJI 模块、NAS 和 SIM 卡；维护者免费提供 NAS 软件代码、随行号客户端及官方通知中继，不销售账号、订阅、功能解锁或付费中继服务。硬件及运营商费用由用户自行承担。

**[点击这里向维护者求助](https://github.com/callmepopo/Suixinghao/issues/new)**：登录免费 GitHub 账号，填写问题标题、使用步骤、预期结果和实际现象后提交，维护者会在同一问题下回复。请附 App 版本／构建号、NAS 软件版本和 iOS 版本；也可先[查看已有问答](https://github.com/callmepopo/Suixinghao/issues)。志愿维护不承诺固定响应时间。

连接、短信、通话和中继问题均可在此反馈。App Key 是用户自有 NAS 的访问凭据，不是购买凭证。通讯录仅在手机本地用于姓名和号码匹配，不上传、不在服务器保存通讯录；主动拨号或发短信时，会将目标号码交给自己的 NAS 执行业务。

所有问题公开可见，请勿上传地址、密码、Key、号码、短信、录音或设备标识；截图先脱敏。隐私相关问题先描述不含个人信息的情况，再询问维护者后续处理方式。自有 NAS 内的数据请联系该 NAS 的管理员。
