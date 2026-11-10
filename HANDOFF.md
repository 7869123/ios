# AIUtility 交接

## 最新验证交接：05508ba 完整 CI 通过

[42739095920](https://github.com/7869123/ios/actions/runs/42739095920) completed / success：Core Linux/macOS 各 82 通过/1 跳过，AppleServices 5/1，Media Linux 92/4、macOS 108/5，可移植生命周期两个宿主各 14 通过，全部 0 失败。26 个记录的命令退出码均为 0。Apple 两种 SDK、iOS 27.1 PoC Swift 6 Archive/未签名 IPA/13 项预安装检查，以及 App 编译/Archive/未签名 IPA 全部通过。
用户批准按错误修复/重试直至通过，本次只触发一次，无新编译错误；不合并分支，不修改 UI、PoC 或工具。首轮失败日志仍保留，35 份本次日志、4 份已校验 ZIP 的哈希、真实跳过项和 Artifact 链接见 [attempt-2](validation/translation-completeness/attempt-2/README.md)。未发布截图或运行真实 API/Keychain。
仍需真机检查缓存补送/边界识别、语言包、跨 App 采集、PiP、后台恢复、内存和签名安装；App 的 MainActor/Sendable 警告交由 Claude 审查，PoC 弃用接口迁移须单独方案。调用接口不变，没有自动集成授权。以下未编译等描述保留为此前阶段历史。

## 最新修复交接：字幕修正尾句清理

用户要求先修好，本次未重跑 CI。已核对首轮 7 处宏编译错误的 `6aa6f64` 修复；另外修正 Core SubtitleSegmenter 在前缀被 ASR 推翻后仍保留旧尾句的问题，并新增 2 个测试声明（其中 1 个参数化），当前 Core 83 个声明、执行 0。公开签名不变，PoC/AppleServices/UI/工具均不修改。
已提交前缀保持不变，被推翻的尾句明确舍弃；后续兼容假设可继续提交新尾句，不能保证恢复所有 ASR 修正内容。新生产修复未编译，不能套用 `0ee791b` 的 build=0。[详细源码路径、回归场景和未验证项](validation/translation-completeness/repair-review.md)。Claude 的接口使用方式不变，跨分支集成仍需所有者决定。

## 最新验证交接（修复待重验）

用户已授权编译、不合并分支。本轮只运行一次 [42647207277](https://github.com/7869123/ios/actions/runs/42647207277)（0ee791b）：Linux Core 生产源码编译成功；测试模块宏展开失败，Core 测试执行 0。生命周期 14 通过，媒体 92 通过/4 跳过；Apple/App/PoC SDK 因前置失败未运行。三家真实 API、Speech、PiP、缓存补送和真机没有通过结论。
`6aa6f64` 仅修复三份新增 Core 测试表达式，断言数和生产源码不变，尚未复验。[证据、真实退出码与下一步门槛](validation/translation-completeness/attempt-1/README.md)。本轮一次 CI 授权已使用，需确认后再跑；不创建或合并 PR，不拉取 Claude 分支。

## 最新：翻译底层独立开发分支

用户随后明确要求加入 ASR 缓存，源码 `2272e99`：Core AudioRolloverBuffer 默认最多 5 秒/8 MiB/512 包，PoC LocalSpeechProbe 深拷贝并顺序补送未投递 PCM，停止/超限清空。新增 13 项测试源码（尚未执行）。不修改其他 PoC 源码或 UI，不触发 CI。缓存不保证切词准确、Speech 追平实时音频或采集成功，必须完成新提交的 SDK 和实机验证。

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
