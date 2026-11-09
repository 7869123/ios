# AIUtility 交接

## 最新：翻译底层独立开发分支

先读 [TRANSLATION_CLAUDE_HANDOFF.md](TRANSLATION_CLAUDE_HANDOFF.md) 和 [TRANSLATION_AUDIT.md](TRANSLATION_AUDIT.md)。本轮所有者已重新分配 Codex 的底层工作，不包含 UI；后续明确批准了 PoC 两处逻辑文件，详情见 [方案](POC_TRANSLATION_PLAN.md)。
分支 `codex/translation-completeness` 从最新已审计开发基线 `7ff4111` 建立，没有合并 PR/推送 main 或修改 Claude 分支。新增提示词/语言、字幕管线、推理、余额、用量、区域 OCR 及安全取消接口供 Claude 正式接线。
**新代码尚未真实编译/测试；CI 需另行确认。** 不沿用下方历史成功作为新代码证据。不修改 UI、主题、壁纸、媒体实现、工作流或脚本；App Intents 和正式字幕 UI 没有实现。连续 ASR 的 SDK/长时运行与轮转空窗、跨 App 采集、PiP、签名安装仍需验证。
不把此交接当作跨分支集成授权，待用户决定集成和 CI；每次推送需附接口/工具变更通知。

## 当前任务

用户授权分阶段推进：先真实验证 Apple 平台，再开发可编译的 SwiftUI App。不得跳过关键包、删除测试或使用空实现。私有远程为 7869123/ios，普通 push，保留历史；不在 Windows 安装 Swift。

## 第一阶段（通过）

成功证据：提交 a11ccc4，运行 https://github.com/7869123/ios/actions/runs/42353675493 。Linux Core 成功；macOS Core 36 通过/1 跳过；AppleServices 2 项 Vision 通过/1 项 Keychain 跳过；iOS Simulator 和 iphoneos 未签名 SDK 构建成功。真实日志与退出码见 validation/apple-platform/。

环境为 Xcode 26.6 / Apple Swift 6.3.3 / iOS SDK 26.5。修复了较新 Swift Testing 宏对可选链表达式的展开错误，保留原隐私断言。Core 生产实现未变。iOS 27 PoC 没有运行。

Apple CI 将保存明确的环境、测试、SDK 构建日志和每步退出码；仅保存日志，不保存缓存、凭据、证书或签名产物。普通 push 后保持 Linux 与 Apple 两平台验证；手动 workflow 可选择 Apple / PoC。

## 第二阶段（初步 App 已通过最终构建验证）

源码位于 Apps/AIUtility，最终源码提交 19d0e02，全链路 CI https://github.com/7869123/ios/actions/runs/42354651780 已成功：Core Linux、Apple 包测试/SDK 构建、SwiftUI App 模拟器与设备 SDK 构建。工程由 XcodeGen 2.46.0 生成，未签名。证据见 validation/swiftui-app/，包含 App/Core/AppleServices tree hash，可核对收尾文档提交没有改变已测试源码。

已建立自适应导航、截图 OCR/文本翻译、字幕文本翻译、媒体目录与共享 Key 设置页。复用生产 Services；Core 生产源码未重写。完整前端边界见 FRONTEND.md，后续运行时准备见 VALIDATION_PLAN.md。UI 交互、真实 API、真实截图质量及真机未验收。

下一步优先在模拟器执行 UI 操作验收并保存截图，再由用户提供受控测试账户进行真实 API 验证。Keychain 在真实 iOS 签名上下文验证；不要把 macOS Vision 合成图成功套用到所有 iPad 截图。runner 目前没有 iOS 27 SDK，独立采集 PoC 的 SDK 和生命周期风险仍未解除。

## 第三阶段（未完成）

真实三家 API、Keychain iOS 运行时、真实截图 OCR、跨 App 音频/Speech/PiP、签名安装与真机均需要独立证据。macOS 合成图 Vision 测试若运行通过，只能说明该宿主上的测试结果，不替代 iPad 识别质量。

范围继续包括 X、Pixiv 原画/Ugoira、B站、GIF、图片指纹、多图拼接、SauceNAO/搜图 Bot 酱、统一下载任务与历史。尚无实现的能力应在 UI 明确显示状态，不提供虚假的成功操作。
