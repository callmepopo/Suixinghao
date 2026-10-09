# 第三方来源与许可

根 LICENSE 仅适用于本项目自有代码和文档，不改变外部依赖、驱动及其许可证。

Go依赖的原许可文本保存在 `licenses/`，发布服务二进制时一并保留。HiDeck与驱动的许可和来源由原项目提供，遵守各自声明。

| 组件 | 固定参考来源 | 许可与边界 |
|---|---|---|
| HiDeck | [yibaiba/hideck v2.1.23](https://github.com/yibaiba/hideck/tree/v2.1.23)，提交 `97bce3222f8124c3478b7003b69d29e24aede8c0` | [PolyForm Noncommercial 1.0.0](https://github.com/yibaiba/hideck/blob/v2.1.23/LICENSE)，非商业限制；本仓库通过 HTTP 使用它，不复制其产品源码 |
| HiDeck 内含第三方依赖 | [上游声明](https://github.com/yibaiba/hideck/blob/v2.1.23/THIRD_PARTY_NOTICES.md) | 包含 AGPL-3.0 等许可；使用或分发上游软件/镜像时自行核对适用义务 |
| Unraid USB Serial / Sound Driver | ich777 对应 Unraid 内核插件 | 第三方内核驱动；按插件原来源获取并核对内核匹配，不在本仓库分发 txz |
| QDC507 模块音频驱动 | [MaVo v0.1.2](https://github.com/moluncn/mavo/tree/v0.1.2) 的模块运行时与上游 Quectel 内核来源 | `qdc507_aprv3.ko`、`qdc507_voice.ko`：GPL-2.0。对应源码和构建报告需按实际二进制核对；本仓库仅提供部署适配及校验，不分发二进制 |
| PCM bridge | MaVo 的 `mavo-pcm-bridge.armv7` | 用户态实现按 MaVo MIT 声明引用；仍按原来源取得，不在本仓库打包 |
| Gorilla WebSocket | github.com/gorilla/websocket v1.5.3 | BSD-2-Clause，见原模块 LICENSE；本仓库通过 Go Modules 获取，不 vendor |
| yaml.v3 | gopkg.in/yaml.v3 v3.0.1 | MIT / Apache-2.0，见原模块 LICENSE；通过 Go Modules 获取 |

HiDeck 要求保留的声明：

> Required Notice: Copyright iniwex5 (https://github.com/iniwex5/vohive)

驱动获取方式、当前版本校验和兼容条件由 [硬件与依赖](docs/hardware.md) 统一维护。旧 MaVo 构建报告曾描述不同模块名称，不能把该报告当作当前驱动的对应源码证明。若未来重新分发 GPL 驱动或上游镜像，必须先核实许可、版权声明和完整对应源码要求。
