# iOS 27 PoC 翻译接线提案（待所有者单独授权）

本轮授权不包含修改 `PoCs/iOS27Capture`。该目录、Host UI、ScreenAudioProbe、ProbeLifecycle、SubtitlePiPProbe 暂不修改。下列为明确提案，不是已完成能力。

## 现状

LocalSpeechProbe.start 接受 Locale，但 PoCSession 使用 en-US 默认值；final/error 结束后要求手动重启。每个 final 创建一个翻译任务并取消前一个，可能丢掉长视频中的前段译文。采集/PiP 已有代次、停止失败、重复停止和延迟回调保护，必须保留。

## 建议最小改动（仅在获批后）

1. `LocalSpeechProbe.swift`：以 Core 的 SupportedLanguage 映射 zh-CN / en-US / ja-JP；拒绝 automatic ASR。开始前检查权限、recognizer.isAvailable、supportsOnDeviceRecognition，保持 requiresOnDeviceRecognition=true，不回退云端/麦克风。
2. 每次识别请求分配 utteranceID 和递增事件序号，发送 partial/final 到 Core 字幕管线；约 50 秒主动 endAudio 轮转。原请求在独立代次下终止，旧回调不得影响新请求；同时最多一个识别任务。发生未知错误或语言包缺失时明确失败，有限恢复，不无限重启。
3. `PoCSession.swift`：新增带默认值的源/目标语言参数和 SubtitleTranslationSession 接线。使用有限 FIFO 分段替代“新 final 取消旧 final”；UI 仅接收当前会话译文。stop 先断开回调/取消任务，保留原生命周期资源释放与失败重试顺序。路由变化/系统中断仍停止，恢复必须显式开始。
4. 不修改 Host SwiftUI；用户选择语言、正式设置项和字幕展示由 Claude 接线。保留英文默认诊断入口的兼容调用。
5. 不修改采集路线、ScreenCaptureKit 权限、后台模式、PiP delegate 或渲染。无 ReplayKit/麦克风替代，不修改原始播放音频。

## 验收

- Core 回归覆盖分段、重复 final、顺序、有限队列、溢出事件、停止/重启/旧代次、取消后迟到响应。
- PoC 原有 14 项生命周期测试必须继续通过，不能删除或削弱。
- 获批 CI 后真实执行 Swift 6 与 iOS 27 iphoneos Archive，并检查设备产物仍编译真实 ScreenCaptureKit 代码；模拟器占位不算采集验证。
- 真机另测三语语言包/识别质量、至少 30 分钟连续识别、识别轮转缺字/重复、音频格式与中断、跨 App 来源、PiP 实显与后台行为。云端编译不能通过这一门槛。

新 Core/AppleServices 接口可先独立交给 Claude，PoC 接线授权未取得前不宣布连续 ASR 已可用。
