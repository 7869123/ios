# AIUtility 交接

## 当前任务

用户授权分阶段推进：先真实验证 Apple 平台，再开发可编译的 SwiftUI App。不得跳过关键包、删除测试或使用空实现。私有远程为 7869123/ios，普通 push，保留历史；不在 Windows 安装 Swift。

## 第一阶段（通过）

成功证据：提交 a11ccc4，运行 https://github.com/7869123/ios/actions/runs/42353675493 。Linux Core 成功；macOS Core 36 通过/1 跳过；AppleServices 2 项 Vision 通过/1 项 Keychain 跳过；iOS Simulator 和 iphoneos 未签名 SDK 构建成功。真实日志与退出码见 validation/apple-platform/。

环境为 Xcode 26.6 / Apple Swift 6.3.3 / iOS SDK 26.5。修复了较新 Swift Testing 宏对可选链表达式的展开错误，保留原隐私断言。Core 生产实现未变。iOS 27 PoC 没有运行。

Apple CI 将保存明确的环境、测试、SDK 构建日志和每步退出码；仅保存日志，不保存缓存、凭据、证书或签名产物。普通 push 后保持 Linux 与 Apple 两平台验证；手动 workflow 可选择 Apple / PoC。

## 第二阶段（尚未开始）

第一阶段门槛已满足，接下来建立 App 入口、导航、截图翻译、字幕文本翻译、媒体工具目录及设置。复用 Core 与真实 AppleServices；使用原创代码布局、系统图标和颜色建立蔚蓝档案风格方向，不使用游戏素材。

## 第三阶段（未完成）

真实三家 API、Keychain iOS 运行时、真实截图 OCR、跨 App 音频/Speech/PiP、签名安装与真机均需要独立证据。macOS 合成图 Vision 测试若运行通过，只能说明该宿主上的测试结果，不替代 iPad 识别质量。

范围继续包括 X、Pixiv 原画/Ugoira、B站、GIF、图片指纹、多图拼接、SauceNAO/搜图 Bot 酱、统一下载任务与历史。尚无实现的能力应在 UI 明确显示状态，不提供虚假的成功操作。
