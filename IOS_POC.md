# iOS 27 跨 App 音频与 PiP 字幕 PoC

**结论：未进行 Apple SDK 编译、签名、安装或真机测试，不能认定成功。** 用户首台目标为 iPad mini 6 / iPadOS 27.2（用户提供，未实机核验）。Windows 不能生成可签名的 iOS 构建；当前没有 IPA。

## 官方依据及可确认边界

2026-11-07 阅读了 [Apple 的 iOS 27 ScreenCaptureKit 示例](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios) 及其官方 DocC JSON。示例描述 iOS 27 的系统选择器、SCStream 与后台模式。代码使用 SCContentSharingPicker 授权，不通过私有 API 或悄悄录制。

另核对 [capturesAudio](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio) 与 [AVKit sample-buffer ContentSource](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class/init(samplebufferdisplaylayer:playbackdelegate:))。这些文档说明有相应接口；是否能在目标 iPad 后台持续收到其他 App 的非静音音频、持续本地识别并刷新字幕 PiP，仍是本 PoC 要验证的问题。

没有默认启用 `com.apple.developer.persistent-content-capture`：Apple 对该 [VNC 持续采集权限](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture) 要求申请，不能把一行 entitlement 当成已经取得授权。本诊断工程先验证普通系统选择器路径；若签名或运行时提示额外能力要求，应记录原始系统分类并按官方流程处理。

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
