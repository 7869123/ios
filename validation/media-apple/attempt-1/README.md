# 首次 Apple 验证：失败记录，不能标记通过

[42461786365](https://github.com/7869123/ios/actions/runs/42461786365)，源码
`1ac37c85a2cf0e9be4a6aaf050d2e75704d00605`，workflow_dispatch attempt 1，结论 failure。
这是用户授权的**一次** build_apple；build_poc=false、publish_previews=false。没有再次触发 macOS。

| Job | Job ID | 结果 |
|---|---|---|
| core-linux | 128672438677 | success |
| apple | 128672716685 | failure：mac-media-tests 退出 1 |
| app | 128673260526 | skipped：依赖 apple 失败，未构建/截图 |
| poc-sdk | 128672717960 | skipped：build_poc=false |

环境：macOS 26.7.2、Xcode 26.6（17F113）、Apple Swift 6.3.3，语言模式 Swift 6；
实际 iOS SDK 为 **26.5，不是 iOS 27 SDK**。

## 真实命令结果

| 检查 | 退出码 | 实际结果 |
|---|---|---|
| environment | 0 | 环境/Swift/SDK 记录完成 |
| mac-core-tests | 0 | 36 通过、1 live API 跳过、0 失败 |
| mac-services-tests | 0 | 2 Vision 通过、1 Keychain 跳过、0 失败；非 iOS 真机结论 |
| ios-simulator-build / ios-device-build（原 AppleServices） | 各 0 | 原步骤成功 |
| mac-media-build | 0 | Media 编译成功 |
| mac-media-tests | **1** | **42 项：9 通过、33 失败、0 跳过** |
| ios-media-simulator-build | 0 | SDK 26.5、arm64/x86_64 simulator、Swift 6，BUILD SUCCEEDED |
| ios-media-device-build | 0 | SDK 26.5、arm64 device target、Swift 6，BUILD SUCCEEDED |

两份 Media SDK 日志均确认 CODE_SIGNING_ALLOWED=NO，真实编译 MediaStorage/MediaNetwork 等源码，
不是空 target；没有签名、Archive、安装或真机运行。新增步骤在 macOS 测试失败后仍继续 SDK 编译，最终退出 1，
没有把部分成功伪装为 job 成功。Linux 同一源码 Media 42 通过；Core 36 通过/1 跳过，生命周期 14 通过。

## 失败原因与修复边界

33 项失败均在共享存储初始化路径抛出 storageUnavailable，涉及使用临时目录的 Harness；
9 项不依赖该存储初始化的用例通过。MediaStorage.noLinks 原先在标准化路径后向根检查所有符号链接，
会将 Darwin 系统 /var、/tmp 别名拒绝。
[Apple 标准化路径文档](https://developer.apple.com/documentation/foundation/nsurl/standardizingpath)
说明它可能移除 /private 前缀；结合源码和失败分布定位该平台差异。修复效果仍需新的 macOS 运行确认。

后续修复仅在 AIUtilityMedia：

- 仅 Darwin、仅绝对系统路径 /var 或 /tmp、仅精确目标 private/var 或 private/tmp（允许对应绝对写法）例外；
  任意目录内的同名链接和不同目标继续拒绝。
- 检查符号链接前保留原始路径；已限制 UUID 组件的输出路径不再先做可能隐藏链接的标准化。
- 保留原 42 项测试及全部断言，新增 3 项路径回归：系统临时目录可用、例外精确匹配、目录内链接/悬空链接仍拒绝。
  新总数 45；**本次旧源码运行不包含修复或新增测试**。
- 没有修改 Core/AppleServices、UI、PoC、workflow、scripts 或公共接口来规避失败。

## 原始证据及校验

[Apple artifact](https://github.com/7869123/ios/actions/runs/42461786365/artifacts/13610062370)（10 个文件），
[Linux artifact](https://github.com/7869123/ios/actions/runs/42461786365/artifacts/13610400391)（7 个文件）。
两份 ZIP SHA-256 均与 GitHub digest 核对一致；详细数据及所有文件的原始/脱敏摘要见 [summary.json](summary.json)。

- [Apple 退出码](logs/apple/exit-codes.txt)
- [macOS Media 测试失败全文](logs/apple/mac-media-tests.log)
- [macOS Media 编译](logs/apple/mac-media-build.log)
- [模拟器 Media 编译](logs/apple/ios-media-simulator-build.log)
- [真机 SDK Media 编译](logs/apple/ios-media-device-build.log)
- [环境](logs/apple/environment.log)
- [Linux Media 测试](logs/core-linux/media-tests.log)

共保存 17 份脱敏日志/退出码，不提交 ZIP、缓存、凭据、签名 URL 或证书。
Apple Services 两份 SDK 日志、Core/服务测试及 Linux 全部日志也位于对应 logs 目录。
修复后的 Linux 结果另行记录；**macOS/SDK 对修复的复验尚未授权，P2 未开始**。
