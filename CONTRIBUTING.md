# 贡献说明

欢迎改进部署文档、配置适配、独立服务和客户端。自有贡献按仓库 MIT 许可提交，第三方来源和许可必须明确保留。

- 先阅读 README、AGENTS.md、docs/requirements.md 和相关模块说明。
- HiDeck 是外部依赖；上游改进提交到其原仓库，不在本仓库复制或重许可。
- 所有测试使用合成数据。不要提交真实服务入口、凭据、号码、短信、录音、设备信息或签名文件。
- Go 变更运行 `go test ./...`、`go vet ./...`；并发变更运行 race 检查。iOS 变更运行 `ios/scripts/check.sh` 和模拟器构建。
- 每次变更先通过 `python3 ios/scripts/version.py --next` 分配版本，同步相关说明与 CHANGELOG。正式发布不得复用版本或替换发布标签。
- 本地检查使用 `python3 scripts/privacy-check.py`；暂存后再运行 `python3 scripts/privacy-check.py --staged`。检查器只提供辅助，提交者仍需人工核对。
- 功能验收须区分编译、模拟接口、模拟器、生产联调、真机声音和锁屏；不要把前一种检查记为后一种成功。
- PR 描述写清问题、最终行为、验证和实际限制。硬件模式、固件和运营商配置的修改必须单独说明，不能作为默认测试步骤。

## 提交署名

保留维护者的 Git 提交身份，并按实际参与情况添加 AI 共同作者。Codex 参与完成的提交，在提交信息末尾另起一段添加：

```text
Co-authored-by: Codex <noreply@openai.com>
```

其他协作者同样按实际参与署名，不为未参与的工具自动添加署名。历史提交及已发布标签保持原样，不为补署名重写历史；历史主要贡献以 [README 的贡献者与致谢](README.md#贡献者与致谢)为准。GitHub 侧栏是否显示及何时更新，以其账号关联和统计结果为准。
