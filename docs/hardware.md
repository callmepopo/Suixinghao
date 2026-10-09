# 硬件支持与第三方依赖

版本 202610094。以下“历史基线”来自既有实现和测试，不代表公开整理后的新身份、新机器或重新部署已完成验收。

## 支持矩阵

| 层 | 历史基线 | 公开首版状态 |
|---|---|---|
| 宿主 | Unraid，内核 `6.1.126-Unraid`，Linux amd64 | 脚本沿用此基线；其他内核待适配 |
| 模块 | DJI 一代 4G / QDC507，USB product `Baiwang` | 仅此目标；USB 身份可能为 `2ca3:4006` 或已转换的 `2c7c:0125`，先读回 |
| 串口 | option、usb_wwan、usbserial，HiDeck AT 队列 | 禁止两个工具同时占用 AT |
| 模块内部 | Linux `3.18.44`、已授权 root USB ADB、UAC | 路由脚本严格核对；不自动开放 ADB或改配置 |
| 声音 | 宿主 USB Audio / ALSA，8 kHz S16_LE 单声道 | 单模块、单通话、单音频连接 |
| 运营商 | 既有国内 SIM 测试环境 | 用户需验证当地 SIM/VoLTE/接续，格式校验不是可接通证明 |
| 其他模块 / Unraid 内核 / Linux 平台 | 未建立兼容清单 | 不支持一键安装或通用驱动承诺 |

## 依赖与取得方式

| 依赖 | 原来源 | 许可边界 | 本仓库处理 |
|---|---|---|---|
| HiDeck 2.1.23，提交 `97bce3222f8124c3478b7003b69d29e24aede8c0` | [yibaiba/hideck](https://github.com/yibaiba/hideck/tree/97bce3222f8124c3478b7003b69d29e24aede8c0) | PolyForm Noncommercial 1.0.0；非商业限制 | 只引用，不打包源码/镜像；固定镜像 tag `2.1.23` |
| 宿主串口驱动 | [ich777 Unraid 驱动构建项目](https://github.com/ich777/unraid_kernel) | Linux 驱动遵循对应许可；包署名 ich777 | 不分发；按实际内核向原提供者获取或自行构建 |
| 宿主声音驱动 | [ich777 Sound Driver](https://github.com/ich777/unraid-sound-driver) | 以其插件及 Linux 模块许可为准 | 用户安装原插件，核对内核 |
| 模块语音资源 | [MaVo v0.1.2](https://github.com/moluncn/mavo/releases/tag/v0.1.2) | 用户态 bridge MIT；两个内核模块 GPL-2.0 | 只说明提取位置与 SHA-256，不分发二进制 |
| 模块内核来源 | [quectel_eg25_kernel](https://github.com/the-modem-distro/quectel_eg25_kernel/tree/82ed00908b3e8efc3ff0de27d2b5a7c0524ecd7f) | GPL-2.0 | 引用来源；不是标准 EG25 固件烧录步骤 |
| ADB | [Android SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools) | 原下载条款 | 安装适合 Linux amd64 的原工具，不上传工具包 |
| ALSA | [ALSA 项目](https://www.alsa-project.org/) | 工具与库各自许可 | 使用宿主的 arecord/aplay，保留依赖说明 |

第三方许可主清单见根 [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md)。HiDeck 的非商业限制不会因自有代码使用 MIT 而消失；按上游条款使用，不用“MIT 整套系统”覆盖上游限制。

## 获取与校验

1. 宿主先只读记录 `uname -r`，确认需要的 `option/usb_wwan` 与 `snd-usb-audio` 是否已具备；从原提供者取得完全同内核包。历史包名称为 `usbserial-20250120-6.1.126-Unraid-1.txz` 与 `sound-20250120-6.1.126-Unraid-1.txz`，包描述均署名 ich777；不把文件名相近或同主版本当兼容证据。
2. 核对原下载提供的校验和，再查看包清单、静态依赖与 `modinfo` 的 vermagic。MD5 仅用于原包完整性核对，不作为安全签名。先备份现有插件/驱动配置，安装动作由维护者明确授权，不自动 `curl | sh`。
3. 从 MaVo v0.1.2 原 Release 下载包，在受信任开发机仅解压，不必启动 macOS App。从 `MaVo.app/Contents/Resources/ModuleVoice/` 取得 `qdc507_aprv3.ko`、`qdc507_voice.ko`、`mavo-pcm-bridge.armv7` 和许可证。复制到宿主自己的 MODULE_ASSETS 目录，保留上游许可。
4. 在 Linux 从资源目录执行 `sha256sum -c /path/to/module-voice.SHA256SUMS`。必须三项全通过；校验文件随本仓库 `deploy/unraid/` 提供。旧随包报告曾描述 `qdc507_afe`，不要用旧名称/旧校验值代替本清单，也不要照旧报告执行硬件命令。
5. 只读核对 USB product、目标 ADB serial、内核 `3.18.44`、root 已获授权、宿主 ALSA 卡与模块 D4 节点。将确认后的目标配置填自己的 service.env。路由入口只向临时目录加载上述固定资源和恢复临时音频路由；不修改 USB/IMS/APN、不启用 ADB、不刷固件。
6. 初次硬件开通与 USB 身份/ADB/UAC配置是独立高风险准备步骤，当前公共仓库不提供自动写入安装器。需要这些变更时，先 inspect/query完整基线、备份，再逐项授权。严禁刷标准 EG25-G 固件。

GPL 二进制如以后由本项目重新发布，必须同时核实并提供其完整对应源码、修改和构建/安装脚本；只有 COPYING 与旧构建报告不足以完成这项工作。首版通过上游引用获取，保持版权和发布责任清楚。
