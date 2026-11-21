# SwiftUI App（第二阶段）

iOS / iPadOS 17+，Swift 6。依赖已经通过 Apple SDK 验证的 AIUtilityCore / AIUtilityAppleServices，不改写 Core 生产实现。

- iPad 宽屏使用 NavigationSplitView，窄屏使用 TabView；截图/字幕输入草稿只保留在内存，切换设置不丢失。
- 截图页通过系统 PhotosPicker 获取选定图片，调用真实 VisionOCRService；可编辑识别文字，再主动调用翻译引擎。不默认上传原图。
- 字幕页接入 videoSubtitle 模型绑定，当前只接受字幕文本；没有假装可跨 App 采集或转写音频。
- 设置页读取已有模型绑定，候选 Key 只在 SecureField 内存中；可获取官方目录、验证并原子保存 Key/两个绑定，或复用已有 Key 独立验证切换模型。验证可能收费，按钮旁明确提示。
- 工具箱页（原「媒体工具」）：本地工具（拼接、GIF、指纹）可用；B站 / X / Pixiv 下载、反向搜图、网络测速（Cloudflare）和 IP / DNS / WebRTC 泄漏检测已接入、未在真机验证，标「未实测」；信通院测速规划中（见 NETWORK_TOOLS.md）。
- App 显示名「serina的工具箱」，图标与启动画面由所有者提供（2026-11-21）。
- iOS 原生结构 + 原创明快蓝白青风格（token、组件与验收见 [UIUX_SPEC.md](../../UIUX_SPEC.md)）；仅用 SF Symbols，未使用任何游戏素材。首页工作台原型由 CI 在 iPad mini / iPhone 模拟器截图供审核。

唯一 AppModel 持有生产 Services，保证共享 Key 协调器与会话预算不被每个页面重新创建。UserDefaults 只保存两个功能所选供应商、外观与壁纸设置、低余额提醒条和「Pixiv 保留压缩包」开关；提示词、语言和推理设置由 Core 保存在本机配置文件；Key 只在 Keychain。错误仅显示 Core 的安全分类，源文本、Key 和服务商错误原文不写日志。退出操作页面取消未完成任务。

Mac 构建（需要 Xcode 和 XcodeGen；CI 在 macOS runner 安装 XcodeGen）：

```sh
xcodegen generate --spec Apps/AIUtility/project.yml
xcodebuild -project Apps/AIUtility/AIUtility.xcodeproj -scheme AIUtility \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath artifacts/app-build CODE_SIGNING_ALLOWED=NO build
```

真实 CI 编译结果见 STATUS.md。编译成功不代表已签名、已安装、UI 交互已验收、真实 API 或真机能力已验证。App 不依赖 iOS 27 PoC；后者保持独立。
