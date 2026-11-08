# AIUtility

原生 iOS / iPadOS 工具箱，Swift + SwiftUI。Apple 包验证后已建立可编译的初步 SwiftUI App；UI 运行时和真机仍待验收。

- [实际状态与阻碍](STATUS.md)
- [环境、构建与测试](BUILD.md)
- [模块与安全约束](ARCHITECTURE.md)
- [iOS 27 采集 / PiP 技术 PoC 与真机验收](IOS_POC.md)
- [SwiftUI App 与构建入口](Apps/AIUtility/README.md)
- [前端架构](FRONTEND.md) · [交接](HANDOFF.md) · [后续验证准备](VALIDATION_PLAN.md)

`Packages/AIUtilityCore` 无 Apple UI 依赖；`Packages/AIUtilityAppleServices` 实现 Keychain 与本地 Vision OCR；`PoCs/iOS27Capture` 是隔离的诊断工程。

**Linux/macOS Core、Apple 包 SDK 和初步 SwiftUI App 的两个 iOS SDK 构建已通过。** [最新 Actions 证据](https://github.com/7869123/ios/actions/runs/42354651780)。Core 各 36 项通过/1 跳过；macOS Vision 2 项通过/Keychain 1 项跳过。真实 API、UI 交互、iOS 运行时与 iPad 真机仍未验证；具体边界见 STATUS.md。

Apple 应用中的真实服务接线示例（模型 ID 来自供应商目录，不预设默认型号）：

```swift
import AIUtilityCore
import AIUtilityAppleServices

let services = AIUtilityServices()

// userKey / screenshotModel / subtitleModel 由未来的设置入口提供。
// 会产生真实生成请求；所有绑定验证成功后才写 Keychain。
try await services.configurations.saveKey(
    provider: .openAI,
    key: APIKey(userKey),
    models: [.discordScreenshot: screenshotModel, .videoSubtitle: subtitleModel]
)

// 使用已有共享 Key 验证新模型，失败时保持旧配置。
try await services.configurations.switchModel(
    provider: .openAI, feature: .videoSubtitle, model: newSubtitleModel
)

let ocr = try await services.ocr.recognize(imageData: screenshotData)
let translated = try await services.translation.translate(
    ocr.text, targetLanguage: "简体中文",
    provider: .openAI, feature: .discordScreenshot
)
```

创建一个长期存活的 `AIUtilityServices`，不要每次翻译重新创建，否则会重新开始会话预算。Key 不应进入源码、命令行参数、日志或普通配置文件。

## 协议（License）

- 代码：[PolyForm Noncommercial License 1.0.0](LICENSE)，Copyright 2026 Serina。允许个人学习、研究等非商业用途的使用、修改和分享；**禁止任何商业用途**。这属于"源码公开"协议，不是 OSI 定义的开源协议。
- 图片素材（默认壁纸浅色版与夜晚版、启动画面插画、App 图标）：CC BY-NC-SA 4.0，另见 [ASSETS_LICENSE.md](ASSETS_LICENSE.md)。默认壁纸为二次创作，角色形象参考 zipzippipe 创作的 Kimi 娘，角色权利归原作者。
