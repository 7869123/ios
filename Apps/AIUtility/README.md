# SwiftUI App（第二阶段）

iOS / iPadOS 17+，Swift 6。依赖已经通过 Apple SDK 验证的 AIUtilityCore / AIUtilityAppleServices，不改写 Core 生产实现。

- iPad 宽屏使用 NavigationSplitView，窄屏使用 TabView；截图/字幕输入草稿只保留在内存，切换设置不丢失。
- 截图页通过系统 PhotosPicker 获取选定图片，调用真实 VisionOCRService；可编辑识别文字，再主动调用翻译引擎。不默认上传原图。
- 字幕页接入 videoSubtitle 模型绑定，当前只接受字幕文本；没有假装可跨 App 采集或转写音频。
- 设置页读取已有模型绑定，候选 Key 只在 SecureField 内存中；可获取官方目录、验证并原子保存 Key/两个绑定，或复用已有 Key 独立验证切换模型。验证可能收费，按钮旁明确提示。
- 媒体工具页保留全部已确认功能目录，显示“后续开发/尚未实现”，没有伪造下载成功。
- 青蓝/白/深色、原创几何装饰和系统 SF Symbols 提供后续蔚蓝档案风格方向，未使用游戏素材。布局视觉及交互尚需运行时验证。

唯一 AppModel 持有生产 Services，保证共享 Key 协调器与会话预算不被每个页面重新创建。偏好只保存两个功能所选供应商；Key 不写 UserDefaults。错误仅显示 Core 的安全分类，源文本、Key 和服务商错误原文不写日志。退出操作页面取消未完成任务。

Mac 构建（需要 Xcode 和 XcodeGen；CI 在 macOS runner 安装 XcodeGen）：

```sh
xcodegen generate --spec Apps/AIUtility/project.yml
xcodebuild -project Apps/AIUtility/AIUtility.xcodeproj -scheme AIUtility \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath artifacts/app-build CODE_SIGNING_ALLOWED=NO build
```

真实 CI 编译结果见 STATUS.md。编译成功不代表已签名、已安装、UI 交互已验收、真实 API 或真机能力已验证。App 不依赖 iOS 27 PoC；后者保持独立。
