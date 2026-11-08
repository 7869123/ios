# iOS 27 采集 PoC：安装前检查报告

记录日期：2026-11-07；2026-11-08 更新工程验证。范围：`PoCs/iOS27Capture`（AIUtility Probe）。

> **本 PoC 尚未在任何真机上安装或运行，未通过真机验证。** 本报告只覆盖 GitHub Actions 上的编译、打包、静态审查和资料核对。用户当前只能远程控制 Windows 11，iPad mini 6 / iPadOS 27.2 无法通过 USB 连接这台电脑，且没有付费 Apple Developer 账号；需要真实设备的步骤已暂停。

标记说明：
- **【已验证·CI】**：GitHub Actions 实际运行的输出。
- **【已验证·官方】**：Apple 官方文档原文。
- **【第三方】**：工具官网、博客、论坛或搜索摘要，未经 Apple 证实。
- **【未确认】**：没有找到可靠来源，需要真机或实际签名才能确认。

## 1. 构建与证据

| 项 | 结果 |
|---|---|
| Runner | `xcode-27-arm64`，macOS 27.0.1，Xcode 27.1（27A9275），SDK `iphoneos27.1` / `iphonesimulator27.1`【已验证·CI】 |
| 最新运行 | [42378051064](https://github.com/7869123/ios/actions/runs/42378051064)（680f3d2），整个运行结论 **success**：core-linux、apple、app、poc-sdk 全部通过【已验证·CI】 |
| 模拟器构建 | 通过（3b1fa1c 起；之前三次均为退出码 65）【已验证·CI】 |
| 真机 Release archive（不签名） | 通过【已验证·CI】 |
| 预安装审查 | 13/13 PASS；新增真实 ScreenAudioProbe/PoCSession 类符号检查【已验证·CI】 |
| 未签名 IPA | [PoC-unsigned-ipa-42378051064-1](https://github.com/7869123/ios/actions/runs/42378051064/artifacts/13576218828)，保留至 2026-11-14；SHA-256：`88d7cd6035b1e9f4d937ed49450e2dba1aa38778d6c608144ebe6c265c1ff440`【已验证·CI】 |
| 编译证据 | artifact `poc-evidence-42378051064-1`：原有七个日志加 lifecycle-tests/device-symbols；归档版本见 validation/engineering-audit。诊断 Release 保留本地符号，仍使用 Release 优化，不签名、不上传 dSYM 或缓存 |

### 历史模拟器条件编译修复

以下是首次修复范围；本次独立工程审查也修改了探针内部生命周期与隔离，见 ENGINEERING_REVIEW.md。当前 iphoneos 在无法导入 ScreenCaptureKit 时编译报错，禁止退回占位 Host。

- **原因**：iphonesimulator 27.1 SDK 不提供 ScreenCaptureKit。`PoCSession.swift`、`ScreenAudioProbe.swift` 外面是 `#if os(iOS) && canImport(ScreenCaptureKit)`，在模拟器构建中被整段剔除，Host 因此找不到这两个类型。
- **修复范围**：只改了 `Host/ProbeApp.swift`。
  - `#if canImport(ScreenCaptureKit)` 分支：完整保留原有采集界面。
  - `#else` 分支：只给模拟器显示占位界面，文字说明"不代表任何采集能力"。
  - 四个探针源码（采集、Speech、PiP、会话）没有改动。
- **防止真机构建误用占位界面**：CI 检查真机二进制必须链接 `ScreenCaptureKit.framework`、`Speech.framework`、`AVKit.framework`。实测三者都已链接。【已验证·CI】
- **此前已修的真机编译错误**：iOS 上不可用的 `SCStream.updateContentFilter` 和 `SCStreamConfiguration.minimumFrameInterval`。处理方式：
  - 删去帧间隔设置；
  - 采集中收到范围更新时忽略，并提示用户先停止。

## 2. Bundle ID 与 Info.plist（实际构建产物）

运行 42365940395 中 `plutil -p` 的输出摘要【已验证·CI】：

| 键 | 值 | 结论 |
|---|---|---|
| CFBundleIdentifier | `com.aiutility.capture-probe` | 签名时使用所属 Team 可注册的唯一 ID，例如 `com.<你的名字>.captureprobe`。未查询原 ID 是否被占用；不能凭未签名产物断言它可用或不可用 |
| CFBundleDisplayName / Version | AIUtility Probe / 0.1 (1) | — |
| MinimumOSVersion | 27.0 | iPadOS 27.2 满足 |
| UIDeviceFamily | 1, 2（iPhone、iPad） | iPad mini 6 满足 |
| UIRequiredDeviceCapabilities | arm64 | iPad mini 6（A15）满足 |
| 可执行文件架构 | arm64，非 fat | — |
| 签名 | `code object is not signed at all`，无 `embedded.mobileprovision` | 符合"未签名"预期 |
| App 扩展 | 0 个 `.appex`，无 PlugIns 目录 | 无需为扩展单独签名或注册 App ID |

## 3. 隐私说明、后台模式与 entitlements

| 项 | 当前状态 | 依据与结论 |
|---|---|---|
| `NSSpeechRecognitionUsageDescription` | 已声明，非空【已验证·CI】 | 缺少此键时 App 会在请求授权时崩溃【已验证·官方】 |
| `NSScreenCaptureUsageDescription` | 本轮新增（18b6622），运行 42366153728 检查非空 PASS【已验证·CI】 | ScreenCaptureKit 总览页要求添加此键【已验证·官方】。但 iOS 官方示例没有列出它，iOS 是否强制要求【未确认】。属于防御性添加，不影响签名 |
| `NSMicrophoneUsageDescription` | 未声明（CI 检查为不存在）【已验证·CI】 | PoC 在系统选择器中关闭了麦克风选项，不采集麦克风 |
| `UIBackgroundModes: audio` | 已声明【已验证·CI】 | PiP 依赖它（"Audio, AirPlay, and Picture in Picture"）。PiP 没有单独的 capability【已验证·官方】 |
| `UIBackgroundModes: screen-capture` | 已声明【已验证·CI】 | 官方后台模式文档列出了它，适用 iOS/iPadOS【已验证·官方】 |
| entitlements | 工程无 `.entitlements` 文件，Xcode 未生成 `.xcent`【已验证·CI】 | ScreenCaptureKit iOS 示例、PiP、Speech 文档均未要求 entitlement【已验证·官方】 |
| `com.apple.developer.persistent-content-capture` | 不使用 | 仅适用于 macOS 14.4+ 的 VNC 类 App，需申请；iOS 用不到【已验证·官方】 |

## 4. 免费 Personal Team 能否满足权限要求

### 已验证（官方）

- **Background Modes 对免费层级可用**：Apple「Supported capabilities (iOS)」表格中，"Apple Developer"（免费）一列勾选了 Background modes。没有勾选的包括 Push、iCloud、Siri、Associated domains、Sign in with Apple、Game Center、In-App Purchase、Network extensions 等。本 PoC 都不使用。
- **参考文档未列出专属 entitlement**：当前参考的 ScreenCaptureKit iOS 示例、PiP、Speech 页面没有要求这些额外声明。这是文档观察，不是免费团队签名或系统授权的验证；未签名 CI 不会检查 Team 的权限。
- **免费签名的数量和期限**：最多 10 个 App ID（7 天后过期）；最多 3 台设备；每台设备最多 3 个 App；描述文件 7 天过期，到期需重签重装。Personal Team 的证书和描述文件只能在 Xcode 中管理。
- **iOS 16 起需开启开发者模式**：安装开发签名的 App 前，要在「设置 > 隐私与安全性 > 开发者模式」中开启。该开关在设备与电脑配对后才会出现。

### 推论（官方未直接说明）

- capability 表里没有 PiP 和 Speech 这两行，推断它们不受账号类型限制。

### 未确认（需实际签名或真机验证）

1. 免费团队签名后，`screen-capture` 后台模式和 `SCContentSharingPicker` 能否真正授权启动采集。文档没有说需要付费账号，但也没有明确说免费团队可以；iOS 27 是新平台，可能存在未公开的限制。
2. iOS 是否强制要求 `NSScreenCaptureUsageDescription`（已防御性添加）。
3. 后台持续采集、本地 Speech 和 PiP 能否同时长期运行。这个问题与账号类型无关，属于 PoC 本身的验证目标。
4. 能否采集到其他 App 的音频。目前没有任何官方示例证明可以。

**结论**：没有发现当前参考资料列出的付费独有能力要求；免费 Personal Team 是否能签名并取得所有所需权限仍需实际验证。不能用文档未提 entitlement 或 CI 无 `.xcent` 推导权限已满足。"签名成功"也不等于"能采集"，第 1、2 项必须在真机上确认。

## 5. 代码风险与独立修复

独立工程审查见 [ENGINEERING_REVIEW.md](ENGINEERING_REVIEW.md)。并发停止、迟到回调、PiP 隔离及停止异常处理已在 PR #2 实现，最终运行 42378051064 验证源码 680f3d2；不使用旧运行证明新源码。14 项可移植测试不代表系统框架运行时通过。

- 音频会话使用 `.playback`；它与 `.playAndRecord` 对后台采集的影响不同，需要对比验证。
- 原实现 `ScreenAudioProbe.start()` 失败时会重复执行 stop；独立修复使用共用释放屏障，需同时核对回归和 SDK 编译证据。
- Host 的 ASR 写死为 `en-US`，需改为目标内容语言。
- 采集中更换共享范围目前被忽略，需先停止再重新选择。
- 旧编译警告：PiP delegate 跨 main actor 隔离；独立修复显式拆分 nonisolated 回调与 MainActor 更新。`AVSampleBufferDisplayLayer` 的 enqueue/flush 等方法自 iOS 18 弃用，迁移仍待后续处理。

## 6. 未来通过 Windows + 免费 Apple ID 签名安装的步骤

> 以下工具操作多数来自第三方资料【第三方】，需要实际执行时再核对。**关键阻碍**：Sideloadly、AltServer 等 Windows 工具在首次配对时**都要求 USB 连接**并在 iPad 上点"信任"，之后才能改用 Wi-Fi【第三方】。没有找到完全不接线完成首次配对的方法。在有人能把 iPad 用 USB 接到这台 Windows 电脑（或你实际使用的那台电脑）之前，下面的步骤 3–4 无法进行。

### 前置条件

1. Windows 11 上安装 Apple 官网下载的 iTunes 和 iCloud。不要用 Microsoft Store 版；如已安装 Store 版 iTunes、Apple Music 或 Apple Devices App，先卸载【第三方】。
2. 从 sideloadly.io 下载 Sideloadly。
3. 建议另外注册一个专用 Apple ID，开启双重认证，不要使用主账号。
4. 把 iPad 系统升级到 27.x（目前为 27.2，满足 MinimumOSVersion 27.0）。

### 一次性配对（需要有人在 iPad 旁边）

5. 用 USB 线把 iPad 接到运行 Sideloadly 的那台 Windows 电脑，在 iPad 上点「信任此电脑」并输入密码。
6. 在 iTunes 中选中这台 iPad，勾选「通过 Wi-Fi 与此 iPad 同步」，然后点应用。之后只要两台设备在同一局域网，就可以拔线【第三方】。

### 每次安装或续签（可在远程 Windows 上完成）

7. 下载 IPA：打开 PR #1 中最新一次运行的页面（目前为 42366153728），在底部 Artifacts 下载 `PoC-unsigned-ipa-<run_id>-1`（过期后需在 Actions 手动运行 Swift validation 并勾选 build_poc 重新生成）。解压得到 `PoC-unsigned.ipa`，可对照 `ipa-contents.log` 中的 SHA-256 校验。
8. 在 Sideloadly 中：
   - 选中 iPad，把 IPA 拖进窗口，输入专用 Apple ID；
   - 在 Advanced options 中把 Bundle ID 改成你自己的，例如 `com.<你的名字>.captureprobe`；
   - 点 Start，按提示输入双重认证验证码。

   Sideloadly 能否直接对完全未签名的 IPA 签名【未确认】。如果失败，记录原始报错。
9. 在 iPad 上开启开发者模式：「设置 > 隐私与安全性 > 开发者模式」→ 开启 → 重启 → 确认【已验证·官方】。
10. 信任开发者：「设置 > 通用 > VPN 与设备管理」→ 选择你的 Apple ID → 信任。
11. 打开 AIUtility Probe，按 IOS_POC.md 中的验收矩阵测试并记录：
    - 设备型号和系统 Build；
    - 签名方式（Sideloadly + 免费 Personal Team）；
    - 来源 App；
    - 每一步的原始结果和报错。

    特别记录：
    - `SCContentSharingPicker` 能否弹出；
    - 授权后 `startCapture` 是否返回；
    - 音频缓冲和 RMS 是否增长；
    - Speech 是否出字；
    - PiP 是否可见。
12. 7 天后描述文件过期，App 将无法启动。需在 Sideloadly 中重新签名安装；免费账号每 7 天最多 10 个 App ID，不要频繁更换 Bundle ID。

### 已知风险

- 有第三方报道称，自 2026-10 起免费签名工具登录 Apple ID 时出现 `-80045` 或 `0xe8008024` 错误，Sideloadly 新版本已调整登录流程【第三方，可靠性低】。遇到时先更新 Sideloadly，再记录报错。
- 云 Mac 无法物理连接 iPad，一般不可行【未确认】。免费账号的证书和描述文件只能在 Xcode 中管理，官方没有说明可以导出给 GitHub Actions 使用，因此 CI 只负责产出未签名 IPA【未确认】。
- 替代方案：借一台 Mac，用 Xcode 27.1 登录免费 Apple ID，用 USB 线直接安装。这同样需要接触 iPad。

## 资料来源

- Supported capabilities (iOS)：https://developer.apple.com/help/account/reference/supported-capabilities-ios
- Developer account overview（免费账号限制）：https://developer.apple.com/help/account/basics/about-your-developer-account/
- Configuring background execution modes：https://developer.apple.com/documentation/xcode/configuring-background-execution-modes
- UIBackgroundModes：https://developer.apple.com/documentation/bundleresources/information-property-list/uibackgroundmodes
- Capturing screen content on iOS：https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios
- ScreenCaptureKit（NSScreenCaptureUsageDescription）：https://developer.apple.com/documentation/screencapturekit
- SCContentSharingPicker：https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker
- capturesAudio：https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio
- Adopting Picture in Picture in a custom player：https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player
- Asking permission to use speech recognition：https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition
- persistent-content-capture：https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture
- Enabling Developer Mode：https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device
- 第三方：https://sideloadly.io/faq 、https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows 、https://github.com/SideStore/SideStore/issues/1297
