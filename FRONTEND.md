# SwiftUI 前端边界

第一阶段 Apple SDK 验证成功后开始开发。入口为 Apps/AIUtility，iOS/iPadOS 17+，Swift 6，XcodeGen 工程定义。App 不依赖 PoC。

## 数据与页面

- AppModel 是 MainActor 的唯一生产接线入口，长期持有 AIUtilityServices。全部页面共用 ConfigurationCoordinator、CallBudget、TranslationEngine 和真实 VisionOCRService；不复制 Core 生产逻辑。
- 宽屏为 NavigationSplitView，窄屏为 TabView + NavigationStack。截图和字幕输入草稿保留在 AppModel 内存中；仅功能供应商选择进入 UserDefaults。
- 截图页使用系统 PhotosPicker 单图授权、Vision 本地识别、可编辑原文和主动翻译。原图不经 AI 供应商上传。
- 字幕页只翻译用户粘贴的已转写文字，绑定 videoSubtitle；没有音频捕获、ASR 或 PiP 的产品入口。
- 设置页获取真实模型目录；候选 Key 只在 SecureField 内存中。保存动作明确提示调用费用，经 Core 验证所有绑定后才提交 Keychain；独立切模型复用已保存 Key。原 Key 不读回到 SecureField。离开页面清空候选 Key、取消验证任务。
- 翻译按钮仅调用现有 Core，支持取消、预算错误和安全错误文案；不输出原始服务商错误、Key、源文本日志。运行时行为和真实模型效果仍需后续验收。
- 媒体页是开发范围导航：X、Pixiv 原画/Ugoira、B站、GIF、指纹、多图拼接、SauceNAO/搜图 Bot 酱、下载任务/历史均保留。未实现功能不会产生假的成功结果。

## 视觉

当前以浅色工作台、蓝白青强调色、深色标题、原创斜角几何装饰和系统图标为风格（iOS 原生结构 + 原创明快风格，详见 UIUX_SPEC.md）。没有游戏图片、音频、字体或提取素材。当前固定浅色避免未设计的暗色反差问题，后续再验证深色主题、Dynamic Type、VoiceOver、分屏与小尺寸布局。

## 验证

ci_app.sh 在 macOS runner 生成工程，以 iOS Simulator 和 iphoneos SDK 编译实际 App；未签名，不导出 IPA。只有 STATUS.md 中明确记录的 CI 结果可视为已完成的构建验证。编译通过不等于 UI 已运行、交互已测试、真实 API 已可用或 App 已安装到 iPad。
