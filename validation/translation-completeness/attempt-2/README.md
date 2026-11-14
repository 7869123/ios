# 第 2 次源码验证：完整 CI 通过

- 被测源：`05508ba75f86ebbc50bf8bc65f0947f50805ed7c`，分支 codex/translation-completeness。
- [Actions 42739095920](https://github.com/7869123/ios/actions/runs/42739095920)，workflow_dispatch，GitHub run_attempt=1，completed / success。
- 所有者本轮明确授权编译及按真实错误修复/重试直到通过，禁止合并。本次只触发 1 个 run，修复后的第一次复编译即通过，没有追加源码改动、重跑或合并。
- 输入：build_apple=true、build_poc=true、publish_previews=false、live_checks=false。真实 AI API 与 Keychain 集成测试关闭；没有发布截图或提交预览。

## Job 与真实测试结果

| Job / 测试包 | Job ID | 通过 | 跳过 | 失败 |
|---|---:|---:|---:|---:|
| core-linux / Core | 129575455231 | 82 | 1 | 0 |
| core-linux / 可移植 PoC 生命周期 | 同上 | 14 | 0 | 0 |
| core-linux / Media | 同上 | 92 | 4 | 0 |
| apple / Core | 129575893913 | 82 | 1 | 0 |
| apple / AppleServices | 同上 | 5 | 1 | 0 |
| apple / Media（含 Apple 工具） | 同上 | 108 | 5 | 0 |
| poc-sdk / 可移植 PoC 生命周期 | 129575894124 | 14 | 0 | 0 |
| app | 129576944813 | 构建/Archive/打包成功，无运行时测试 | — | — |
| live-checks | 129575456781 | — | 整个 job 显式关闭 | — |

计数按逐项 Test passed/skipped 日志核对，不把聚合行中的 83/6/113/96（包含跳过项）全部记为通过。相同 Core/生命周期测试在两个宿主分别运行，不把它们宣传为不同功能测试。

Core 跳过 liveOfficialAPI，AppleServices 跳过真实 Keychain 替换。Media Linux 跳过 4 个可编译的真实站点检查；macOS 跳过 Pixiv 原图、Ugoira、Bilibili、X、搜图 Bot 酱共 5 个检查。没有删除、放宽或新增跳过条件。

## 实际命令与退出码

全部 **26 个被脚本记录的命令退出码为 0**，见各组 logs/*/exit-codes.txt 与 summary.json。以下使用仓库相对路径表示工作目录；完整 xcodebuild 调用在对应日志中，CI 工作区路径已替换为占位符。

Linux：Swift 6.0.3，x86_64-unknown-linux-gnu。

```sh
swift --version
swift build --package-path Packages/AIUtilityCore
swift test --package-path Packages/AIUtilityCore
swift test --package-path PoCs/iOS27Capture
swift build --package-path Packages/AIUtilityMedia
swift test --package-path Packages/AIUtilityMedia
```

Apple：macOS 26.7.2，Xcode 26.6（17F113），Apple Swift 6.3.3，iOS / Simulator SDK 26.5。实际执行 bash scripts/ci_apple.sh，并执行现有 workflow 的 Media 步骤：

```sh
swift test --package-path Packages/AIUtilityCore
swift test --package-path Packages/AIUtilityAppleServices
# 在 Packages/AIUtilityAppleServices 目录内；两个命令分别有独立 DerivedData 路径：
xcodebuild -scheme AIUtilityAppleServices -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme AIUtilityAppleServices -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
swift build --package-path Packages/AIUtilityMedia
swift test --package-path Packages/AIUtilityMedia
# 在 Packages/AIUtilityMedia 目录内；分别编译两个 scheme 和两个 SDK：
xcodebuild -scheme AIUtilityMedia -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme AIUtilityMedia -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme AIUtilityMediaApple -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme AIUtilityMediaApple -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Apple 的 environment 命令另记录 sw_vers、xcodebuild -version、swift --version、xcodebuild -showsdks，退出 0。上方 SDK 命令为去掉工作区/DerivedData 路径的可读表示，完整调用以归档日志为准。

PoC：macOS 27.0.1，Xcode 27.1（27A9275），iphoneos / Simulator SDK 27.1；Archive 日志明确包含 -swift-version 6。

```sh
swift test --package-path PoCs/iOS27Capture
# 以下在 PoCs/iOS27Capture 内执行：
xcodegen generate --spec project.yml
xcodebuild -project AIUtilityCaptureProbe.xcodeproj -scheme AIUtilityCaptureProbe -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath ../../artifacts/poc-build CODE_SIGNING_ALLOWED=NO build
xcodebuild archive -project AIUtilityCaptureProbe.xcodeproj -scheme AIUtilityCaptureProbe -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -archivePath ../../artifacts/poc-archive/AIUtilityCaptureProbe.xcarchive -derivedDataPath ../../artifacts/poc-archive-build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" STRIP_INSTALLED_PRODUCT=NO COPY_PHASE_STRIP=NO
```

App：执行 bash scripts/ci_app.sh（记录 environment、generate、simulator-build、device-build 四个退出码），再执行 workflow 中的 Release Archive（app_device_archive=0），随后用 ditto/zip 打包。App 与 PoC 均为未签名；打包步骤、13 项 PoC 预安装检查在 job steps 中成功，没有伪造额外的数值退出码。

```sh
xcodebuild archive -project Apps/AIUtility/AIUtility.xcodeproj -scheme AIUtility -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -archivePath artifacts/app-archive/AIUtility.xcarchive -derivedDataPath artifacts/app-archive-build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

## 与首轮失败的关系

[首轮 42647207277](../attempt-1/README.md) 的源为 0ee791b：Core 生产 build=0，但测试模块因 7 处宏展开错误失败，实际执行 0。6aa6f64 拆开嵌套 require/throwing 读取；05508ba 再修正 ASR 已失效尾句并增加 2 个回归声明。本次真实运行验证了这些修复、13 个有界音频队列测试以及原有配置/取消/超时测试。

后续证据与文档提交不修改被测源码；summary.json 保存 Core、AppleServices、Media、PoC、App、scripts、workflow 的 Git tree hash，便于审查者核对。此 run 不验证另一个分支后来增加的代码。

## Artifact 与哈希

- [Linux 证据](https://github.com/7869123/ios/actions/runs/42739095920/artifacts/13727459492)
- [Apple 证据](https://github.com/7869123/ios/actions/runs/42739095920/artifacts/13728337881)
- [PoC 证据](https://github.com/7869123/ios/actions/runs/42739095920/artifacts/13729220020)
- [App 证据](https://github.com/7869123/ios/actions/runs/42739095920/artifacts/13728631583)
- [PoC 未签名 IPA](https://github.com/7869123/ios/actions/runs/42739095920/artifacts/13727784803)
- [App 未签名 IPA](https://github.com/7869123/ios/actions/runs/42739095920/artifacts/13729145430)

4 份日志 ZIP 均已下载并对照 GitHub digest 验证 SHA-256；35 份日志已归档，记录原始/归档 SHA-256。device-symbols.log 仅保存前 80 条相关 PoC 符号，完整列表留在已校验的 Actions artifact 中；其他日志完整保留，替换 CI 工作区/主目录/UUID、规范换行，并将 6 处自动生成的 AppIcon retina 文件名与 1 处 PATH 工具版本中的 @ 分隔符记为 [AT]。ZIP、IPA、构建缓存没有放入 Git。Artifact 按 workflow 保留 7 天；summary.json 中的 artifact ID 使用官方完整链接表示。

IPA 未在本地下载；以下是 CI 打包日志报告的文件 SHA-256，与外层 artifact ZIP 的 digest 区分：

- AIUtility-unsigned.ipa：ffacfe5326afe78ec118e45b6fe3f6efb091157a1650a41756d455498379e388。
- PoC-unsigned.ipa：f564e0a4cc8b8c3dbbae135ffad0c62bda1d0279a3799122d38538685e14ad90。

本地证据导出首次控制台输出因 Windows 编码产生 UnicodeEncodeError（退出 1），设置 Python UTF-8 后重新导出成功（退出 0），全部日志哈希重新核对。这不是 CI 编译失败或 CI 重跑。

首次本地推送门禁退出 1：公开 artifact 的数字 ID 被手机号规则命中，自动生成的图标文件名与工具版本路径被邮箱规则命中。已核对为公开 CI 标识，改用官方 artifact URL 和上述明确的路径规范化表示，保留原始哈希；没有放宽/修改扫描规则、工作流或构建命令。修正文档提交尚未推送，已发布历史不改写；最终推送须以门禁 PASS 为前提。

## 保留的警告与未验证范围

- PoCSession.swift:147：InterruptionType 在 iOS 27 弃用；后续通知/恢复行为迁移需单独方案和验证，不在本次编译收尾中改生命周期。
- SubtitlePiPProbe.swift:73、89、90、118：display layer 的 flush/status/readiness/enqueue 等接口弃用，需迁移 sampleBufferRenderer；未擅自修改 PiP。
- App 的 LocalToolViews.swift:55、113、189 与 WallpaperViews.swift:223：Sendable 闭包访问 MainActor 状态的警告，交给 Claude 处理，Codex 未修改 UI。
- ProbeLifecycleTests.swift:23 的未使用 Bool、PoC 的方向/AppIntents 元数据警告均为非阻断诊断，保留原测试和设计。
- iOS 27.1 Simulator SDK 无 ScreenCaptureKit；模拟器不能验证实际跨 App 捕获。iphoneos 二进制的预安装检查确认真实 ScreenAudioProbe/PoCSession 符号、ScreenCaptureKit/Speech/AVKit 链接和权限声明，13 项均通过，但仍只是静态二进制检查。
- 真实三家 AI/余额/usage、iOS Keychain 运行时、真实截图识别、三语语言包、ASR 缓存补送和边界识别、长时内存/延迟、跨 App 音频、PiP、后台恢复、签名安装与 iPad mini 6 真机均未验证。不能把编译成功等同于这些能力通过。
