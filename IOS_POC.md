# iOS 27 跨 App 音频与 PiP 字幕 PoC

**本 iOS 27 采集 PoC 尚未进行 SDK 编译、签名、安装或真机测试，不能认定成功。** 用户首台目标为 iPad mini 6 / iPadOS 27.2（用户提供，未实机核验）。当前没有 IPA。

普通 AppleServices 与 SwiftUI App 已在 [42354651780](https://github.com/7869123/ios/actions/runs/42354651780) 通过 iOS SDK 26.5 编译，macOS 两项 Vision 测试通过；这些不包含此 PoC。该 runner（macos-latest，Xcode 26.6）最高只有 iOS 26.5 SDK，这就是 PoC 编译检查一直失败的原因；poc-sdk 现改用 `xcode-27` runner，见下节。本文采集/Speech/PiP 符号及生命周期问题仍待处理。

2026-11-07 已通过的是 [Linux Core CI](https://github.com/7869123/ios/actions/runs/42335206895)，该次 apple 和 poc-sdk 均为 skipped。Core 单测通过没有验证本文件任何 iOS 采集、Speech、PiP 或系统权限结论；下列 SDK 符号和生命周期风险仍待处理。

## 2026-11-07 CI runner 与官方资料复核

**PoC 的 SDK 编译之前一直没有成功，原因是 runner 镜像而非源码：** `poc-sdk` job 原先使用 `macos-latest`，该标签目前指向 macOS 26 镜像，最高只有 iOS 26.5 SDK（`iphoneos26.5`），“Require iOS 27 SDK” 检查必然失败，PoC 源码从未进入编译。现已改为 `runs-on: xcode-27`（actions/runner-images 提供 `xcode-27` / `xcode-27-xlarge`，仅 arm64；镜像 README 列出 Xcode 27.0 beta 27A5228h 与 iOS 27.0 SDK `iphoneos27.0`）。镜像 README 快照写 macOS 26.5.2，而 2026-10-15 GitHub 公告称该镜像已 GA 且运行在 macOS 27，二者不一致；workflow 现在先记录 `sw_vers`、`xcodebuild -version`、`xcodebuild -showsdks`，以实际运行日志为准。首次编译结果记录在对应 PR 中；编译通过也只代表 Simulator SDK 类型检查，不代表签名、安装或真机能力。

已确认的资料边界：

- `SCContentSharingPicker`（及 iOS 上的 ScreenCaptureKit 采集路径）是 **iOS 27 beta API**，声明与行为可能在正式版前变化，编译诊断需对照当次 SDK 版本记录。
- Apple 官方 iOS 示例只采集**屏幕画面和麦克风**。**目前没有任何官方示例证明 iOS 上能采到其他 App 播放的音频**；`capturesAudio` 文档存在不等于跨 App 系统音频可用，这正是本 PoC 需要真机回答的核心问题。
- `com.apple.developer.persistent-content-capture` **只适用于 macOS**（VNC 类持续屏幕采集），iOS 用不到，本工程不应也不需要申请或声明它。

### xcode-27 首次真实编译结果（2026-11-07）

- 实测环境：macOS 27.0.1、Xcode 27.1（27A9275）、`iphoneos27.1` / `iphonesimulator27.1`（不是 README 写的 27.0 beta）。
- Simulator 构建退出 65：ScreenCaptureKit 在 Simulator SDK 不可导入，`PoCSession` / `ScreenAudioProbe` 被 `#if canImport(ScreenCaptureKit)` 剔除，Host 找不到类型。PoC 只能用 iphoneos SDK 验证编译。
- iphoneos archive 首次真实编译两文件，报 `SCStream.updateContentFilter` 与 `SCStreamConfiguration.minimumFrameInterval` 在 iOS 上 unavailable。已修正：删去 `minimumFrameInterval`（屏幕帧本就丢弃）；采集中收到选择器范围更新时忽略并提示先停止，不再调用 `updateContentFilter`。
- 尚余 warning：SubtitlePiPProbe 的 PiP delegate conformance 跨 main actor 隔离（Swift 6 下为错误）；`AVSampleBufferDisplayLayer` 的 enqueue/flush/status 等自 iOS 18 弃用。

### 安装前审查（2026-11-07）

模拟器条件编译已修复（仅 Host 在无 ScreenCaptureKit 时显示占位界面，真机采集代码不变），并新增 `NSScreenCaptureUsageDescription`（防御性添加，iOS 是否强制要求未确认）。Bundle ID、Info.plist、隐私说明、后台模式、entitlements 与免费 Personal Team 结论见 [INSTALL_PREFLIGHT.md](INSTALL_PREFLIGHT.md)。

### 待真机验证的新增风险

1. **音频会话类别**：SubtitlePiPProbe 当前使用 `.playback` + `.moviePlayback` + `.mixWithOthers`。`.playback` 与 `.playAndRecord` 在后台存活、与来源 App 混音/打断、路由及采集是否被系统静音方面可能不同；需在 iPad 上分别对比后台采集持续性与 RMS。
2. **ScreenAudioProbe.start() 失败时会重复 stop**：`startCapture` 抛错后 catch 先 `await stop()`，再调用 `onTermination`，而 PoCSession 的 `onTermination` 又调用 `capture.stop()`，导致 `stopCapture`/picker 移除执行两次；picker 取消、启动失败和 didStop 回调路径同样如此。需确认重复调用是否安全，或加入幂等/会话身份保护。
3. **Host 的 ASR 语言写死为 en-US**：`LocalSpeechProbe.start(locale:)` 默认 `en-US`，PoCSession 调用时未传入语言，Host 也不能选择。需改为目标内容语言（例如日语/中文来源素材）并确认对应本地语言包支持 on-device 识别。

## 第二轮静态审计：需真实 SDK 核对的符号

本轮仅审阅代码和官方资料，没有 Apple SDK。`#if canImport` / `@available` 只控制源码条件，不证明这些调用已编译；Swift 5 模式、`@preconcurrency` 与 `@unchecked Sendable` 也不证明线程安全。

| 文件 / API | Apple SDK 编译时必须核对 | 设备运行时必须核对 |
|---|---|---|
| ScreenAudioProbe：`SCContentSharingPicker.shared`、`SCContentSharingPickerConfiguration`、`showsMicrophoneControl`、`showsCameraControl`、`add/remove`、`isActive`、`present()` | iOS 27 声明、选择器配置类型及 MainActor 标注 | 整屏选择、授权拒绝、取消、其他 App 范围 |
| `SCContentSharingPickerObserver` 三个回调、`SCStreamDelegate.stream(_:didStopWithError:)` | Swift 参数标签、isolation、filter/stream 的 Sendable 声明 | 取消和旧回调是否可能晚于新会话 |
| `SCStream(filter:configuration:delegate:)`、`addStreamOutput`、`.screen/.audio`、`startCapture/stopCapture`（`updateContentFilter` 在 iOS 不可用，已移除） | iOS 可用性、async/throws 导入、输出协议签名 | 后台存活、音频来源与停止行为 |
| `SCStreamConfiguration.capturesAudio/excludesCurrentProcessAudio/sampleRate/channelCount/width/height`（`minimumFrameInterval` 在 iOS 不可用，已移除） | iOS 27 属性可用性、类型与范围 | 16×16 屏幕配置能否启动（帧率无法限制）；实际采样率；不采自身音频 |
| `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer`、`CMAudioFormatDescriptionGetStreamBasicDescription`、`UnsafeMutableAudioBufferListPointer` | 参数标签、可选指针、内存对齐与 retained block buffer 生命周期 | PCM 格式、端序、Float 对齐、RMS；非 float 格式目前不测 RMS |
| LocalSpeechProbe：`requestAuthorization`、`supportsOnDeviceRecognition`、`requiresOnDeviceRecognition`、`recognitionTask`、`appendAudioSampleBuffer/endAudio` | Speech 协议隔离、buffer API 签名 | 本地语言包、后台支持、时长限制、PCM 接受情况、partial/final 时机 |
| SubtitlePiPProbe：`AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`、`isPictureInPicturePossible`、所有 playback/delegate 方法 | AVKit 签名和 completionHandler 的隔离/Sendable 标注 | 真正出现 PiP 且字幕跨 App 刷新；系统控件行为 |
| `CMTimebaseCreateWithSourceClock`、`CMTimebaseSetTime/SetRate`、`CMSampleBufferCreateReadyWithImageBuffer`、`displayLayer.enqueue` | CoreMedia 指针与返回码、SDK 弃用情况 | PTS 单调性、seek/暂停/切后台后的时间基准 |
| `AVAudioSession.setCategory(.playback, .moviePlayback, .mixWithOthers)`、`setActive`；`UIBackgroundModes: screen-capture/audio` | SDK 对模式和值的支持 | 来源 App 音频是否受影响；锁屏、蓝牙、来电与权限 |
| AppleServices：`SecItemCopyMatching/Update/Add`、`VNRecognizeTextRequest.cancel`、`VNImageRequestHandler(data:options:)`、ImageIO 属性读取 | Swift 6 桥接、VNRequest Sendable/隔离、Keychain 属性合法性 | 真实原子更新、锁屏访问、OCR EXIF 方向和语言支持 |

### 已识别、尚未修复或验证的生命周期问题

1. `PoCSession.start()` 等待 Speech 授权期间如发生 stop → start，旧 start 的 catch 仍可能清理新会话；LocalSpeechProbe 的 revision 只能保护其自身回调，不能替代外层生命周期编号。
2. `PoCSession.stop()` 在 await capture.stop 后再停 Speech/PiP；如果另一 start 已进入，旧 stop 可能结束新 Speech/PiP。`ScreenAudioProbe.stop()` 同样在 await 后清空属性，需结合会话身份重构并以 Apple 测试验收。
3. picker cancel/update 没有会话编号，旧回调可能影响新会话；stream didStop 的身份检查不能覆盖所有 picker 竞态。
4. PiP stop 后仍保留 controller/timebase，未阻止晚到 delegate 回调更新状态；Timer、controller、contentSource、delegate 的生命周期和资源释放需查 SDK 所有权语义并测试。
5. 音频 callback 内同步 append 到 Speech，需验证延迟/背压；`@unchecked Sendable` 只基于队列和锁假设，不能证明 SDK 对象跨线程使用安全。
6. 单段 Speech、final 后手动重启、默认 Host 仅源字幕仍是原有 PoC 边界；没有实现无限连续识别或完成实时字幕产品。

本轮没有对未经编译的 Apple 状态机做大范围重写，也没有把风险隐藏成“通过”。Core 的配置取消测试不能覆盖 Apple 状态机。下一步应先在 iOS 27 SDK 修复具体编译诊断，再以可控制延迟的生命周期测试及 iPad mini 6 复现这些竞态。

## 官方依据及可确认边界

2026-11-07 阅读了 [Apple 的 iOS 27 ScreenCaptureKit 示例](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios) 及其官方 DocC JSON。示例描述 iOS 27 的系统选择器、SCStream 与后台模式，但只采集屏幕画面与麦克风，未演示采集其他 App 的音频。代码使用 SCContentSharingPicker 授权，不通过私有 API 或悄悄录制。

另核对 [capturesAudio](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio) 与 [AVKit sample-buffer ContentSource](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class/init(samplebufferdisplaylayer:playbackdelegate:))。这些文档说明有相应接口；是否能在目标 iPad 后台持续收到其他 App 的非静音音频、持续本地识别并刷新字幕 PiP，仍是本 PoC 要验证的问题。

没有声明 `com.apple.developer.persistent-content-capture`：该 [VNC 持续采集权限](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture) 只适用于 macOS，iOS 用不到，本工程不需要它。本诊断工程验证普通系统选择器路径；若签名或运行时提示额外能力要求，应记录原始系统分类并按官方流程处理。

## 已写的可运行路径（等待实际构建）

`PoCs/iOS27Capture` 独立 Swift Package + XcodeGen Host，与生产 AppleServices 分离。

1. Host 的“授权并采集”先请求 Speech 权限，检查识别器可用且支持本地识别，设置 requiresOnDeviceRecognition=true；不回退到云 ASR。
2. 系统选择器让用户选择整个屏幕，关闭麦克风/摄像头选项。SCStream 开启 capturesAudio、排除自身音频，目标 48 kHz 单声道，同时接收并丢弃低频小尺寸屏幕帧。
3. 串行队列接收 .audio CMSampleBuffer，直接交给本地 Speech；只发布缓冲数、样本数、格式与 RMS 指标。32-bit float PCM 才计算 RMS，其他格式标为不可测，不假装非静音。
4. 本地 ASR 的 partial text 显示在诊断页；Host 预览层与 PiP 字幕每 0.5 秒生成一张真实 CVPixelBuffer/CMSampleBuffer，交给 AVSampleBufferDisplayLayer。
5. PiP 使用 AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)；isPictureInPicturePossible 为真才允许启动。收到系统回调只显示回调事实，不将整条链路标成验收成功。
6. PoCSession 可注入真实 TranslationEngine，对 final 语音段使用 videoSubtitle 的已保存模型。新任务取消旧翻译，序号阻止迟到结果覆盖新字幕。默认 Host 没有 Key，明确只做本地英文 ASR 诊断。
7. “停止”撤销选择器观察、停止 SCStream、取消语音/翻译并关闭 PiP；原始音视频和转写不写文件，不输出文本日志。

Host 是最小技术诊断界面，不是正式产品 UI。本轮没有花时间复刻游戏界面。

## 明确未解决的技术问题

- 是否能采到不同 App 实际播放的音频，是否受 DRM、来源、音频路由或系统策略限制。
- iPad mini 6 上后台采集、Speech 和 PiP 是否能同时持续工作。
- 本地 Speech 的语言包安装、时长限制、最终分段频率与格式兼容。本版是**单次识别会话**：final 或错误后提示重启，不伪装为可无限连续运行的字幕系统。
- partial 的源字幕可实时刷新；自动翻译只处理 final。长段落的翻译延迟尚未解决，默认 Host 也未开启翻译。
- PiP 的字幕专用画面是否满足平台行为和最终分发要求，是否被后台调度、音频会话或其他 App 音频打断。播放会话采用 mixWithOthers，仍需测量其影响。
- 手机旋转、系统选择器变更、Seek、倍速、蓝牙路由、来电、锁屏、DRM 静音、错误恢复、内存和耗电。
- 新 SDK 的回调隔离约束尚未编译核验。PoC 使用 Swift 5 语言模式，后续应在确认 SDK 声明后逐步收紧隔离。

## 构建与真机安装

完整命令见 [BUILD.md](BUILD.md)。需要 Mac、包含 iOS 27 SDK 的 Xcode、XcodeGen 和可用于此 iPad 的开发签名。生成工程后在 Xcode 选择开发团队和 iPad mini 6。签名权限不可用时记录为阻碍，不能把模拟器或语法检查当真机验证。

Info.plist 已声明 NSSpeechRecognitionUsageDescription 与 UIBackgroundModes 的 audio / screen-capture。PoC 不采麦克风、不保存相册、不访问摄像头，因此未声明相应无关权限。不要绕过系统选择器授权。

## iPad mini 6 / 27.2 验收矩阵

以下项目目前全部为**未执行**。每次测试记录设备型号、系统 Build、Xcode/SDK 版本、签名方式、来源 App 与版本、音频路由、持续时长、结果及证据文件位置。记录统计即可，避免把私人内容写进报告。

| 场景 | 要观察的证据 | 当前结果 |
|---|---|---|
| 拒绝/取消选择器和 Speech 授权 | 不继续采集，无残留任务，状态可解释 | 未执行 |
| 前台播放已知无 DRM 的英文素材 | buffers/samples 增长，RMS 非零，识别与已知文本对应 | 未执行 |
| 切到另一 App，连续 5 分钟 | 采集与识别持续性；如识别限时结束需如实记录 | 未执行 |
| 默认本地 ASR → PiP | 系统 PiP 回调且窗口肉眼可见、内容随语音变化 | 未执行 |
| 已保存 Key → final 文本翻译 → PiP | 使用 videoSubtitle 绑定，字幕实际翻译，延迟/调用量可测 | 未执行 |
| X / B 站 / Safari 的普通内容 | 分别确认音频非静音与识别；来源不能互相代替 | 未执行 |
| DRM/受保护播放与静音 | 不将缓冲存在当作有效音频成功；明确来源限制 | 未执行 |
| Seek、倍速、暂停与继续 | 不显示迟到翻译；记录时间轴问题 | 未执行 |
| 蓝牙与扬声器切换、来电、锁屏 | 可控中断与恢复；Keychain 锁定行为 | 未执行 |
| 取消/超时/无效 Key/无效模型 | 不改原配置、停止后不继续产生新请求 | 未执行 |
| 重复启动/停止与 15 分钟资源观察 | 无明显内存累积、正确释放、耗电/温度可记录 | 未执行 |

只有在目标设备上完成所需场景并保留证据后，才能将对应单项改为通过；某一个 startCapture 或 PiP 回调成功不能代表整个实时字幕能力成功。
