# 第二阶段 SwiftUI App 的真实构建证据

最终源码 `19d0e02`，[运行 42354651780](https://github.com/7869123/ios/actions/runs/42354651780) 完整成功。第一阶段完成记录为 `6c0fdf4`；前端是在该阶段成功后创建。

- Linux Core：36 通过、1 个真实 API 测试跳过、0 失败。
- macOS Core：36 通过、1 跳过、0 失败。
- macOS AppleServices：2 个 Vision 测试通过、1 个 Keychain 测试跳过、0 失败。
- App：环境检查、XcodeGen 工程生成、Simulator 与 iphoneos 构建全部退出 0；两个日志均有 BUILD SUCCEEDED。
- XcodeGen 2.46.0；Xcode 26.6、Swift 6.3.3、iOS SDK 26.5。未签名，没有可安装 IPA。

版本化日志只统一换行和清理行尾空白，原始下载内容的 SHA-256 见 summary.json。完整原始 artifact 仍由对应 Actions 运行提供。文档/证据收尾提交不改变 App/Core/AppleServices 源码树，其 tree hash 已记录。

原始构建只出现未使用 AppIntents 导致的 metadata extraction skipped 提示，不影响本 App 既定入口；没有通过屏蔽模块或空实现绕过编译。

没有执行 UI 测试或模拟器交互；真实 API、iOS Keychain/真实截图、iPad 音频/Speech/PiP、签名与安装仍未验证。此目录不是运行时成功证明。
