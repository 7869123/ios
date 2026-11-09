# 翻译增量验证状态

## 可确认的基线

基线 `7ff41115adf3b6c0e80e54c9af6d566712f48399` 的 [CI 42486839669](https://github.com/7869123/ios/actions/runs/42486839669) 已读取真实 job 与 Linux/Apple 日志：Core 每平台 36 通过/1 跳过；Linux Media 92 通过/4 跳过、macOS Media 108 通过/5 跳过；Linux 生命周期 14 通过；macOS Vision 2 通过/Keychain 1 跳过。Apple SDK 和 App job 成功，PoC 和 live-checks 跳过。这些仅是开发前证据。

## 本批

源码阶段提交：`659de51`、`fa81778`、`12ed6bf`、`c9c572b`。独立分支 `codex/translation-completeness`，本机 Windows 无 Swift，未安装工具链。

| 检查 | 实际状态 |
|---|---|
| Swift build/test | 未启动；进程退出码不适用；本批 Swift 测试实际执行 0 |
| Apple SDK / App / PoC Archive | 未启动；需确认 CI；无本批 run ID / artifact |
| 真实 AI API / 余额 / usage | 未执行，未使用真实 Key、未产生付费测试 |
| Swift 语法/源码卫生/plist | 已执行，退出 0，86 个 Swift 文件；只是静态检查 |
| git diff --check | 已执行，退出 0 |
| 完整 scripts/prepush_check.sh | 42e79f3 已执行 PASS / 退出 0，13 项 Python 脚本回归通过；不是 Swift 单元测试。最终收尾提交须再次执行；实际日志保存在忽略的 artifacts/translation-completeness |
| iPad 采集 / Speech / PiP / 后台 | 无真机证据；轮转空窗、格式、语言包和停止确认必须实机验证 |

新增 Core 31 个 @Test 声明（现有总数 68），Apple 3 个（总数 6），原测试未删减。这只是源码数量，不是执行/通过数量。

## 待确认的一批 CI

不修改现有 workflow、触发条件或脚本。经所有者确认后可推送/创建独立 PR（会自动 Linux），并在自己的分支执行一次：
`build_apple=true, build_poc=true, publish_previews=false, live_checks=false`。

需要记录每个 job/命令的退出码，逐项区分实际通过、跳过、失败。至少检查 Core/AppleServices 测试、Media 原回归、两种 SDK、App、iOS 27 真实设备采集代码的 Archive 和未签名 IPA；失败保留日志，修复不能弱化测试。再次运行仍需遵守所有者授权范围。

自动测试只使用合成文本/图像和假凭据。不得上传私密输入、真实 Key/Token、证书或构建缓存。任何云端通过都不替代真实 iPad 验证。
