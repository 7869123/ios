# AIUtility

原生 iOS / iPadOS 工具箱，Swift + SwiftUI。当前优先后端工程验证；没有正式产品 UI。

- [实际状态与阻碍](STATUS.md)
- [环境、构建与测试](BUILD.md)
- [模块与安全约束](ARCHITECTURE.md)
- [iOS 27 采集 / PiP 技术 PoC 与真机验收](IOS_POC.md)

`Packages/AIUtilityCore` 无 Apple UI 依赖；`Packages/AIUtilityAppleServices` 实现 Keychain 与本地 Vision OCR；`PoCs/iOS27Capture` 是隔离的诊断工程。

**Core 已通过真实 Linux Swift 6.0.3 编译与测试：36 项通过、1 项真实 API 测试跳过、0 失败。** [Actions 证据](https://github.com/7869123/ios/actions/runs/42335206895)。Apple SDK、真实 API、Keychain/Vision 和 iPad 真机仍未验证；具体边界见 STATUS.md。

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
