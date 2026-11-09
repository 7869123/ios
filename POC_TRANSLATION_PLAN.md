# iOS 27 PoC 翻译接线方案（本轮已获授权，验证待确认）

所有者先要求提交提案，再明确授权仅修改 LocalSpeechProbe.swift 和 PoCSession.swift。本轮按该范围实施；Host UI、ScreenAudioProbe、ProbeLifecycle、SubtitlePiPProbe 没有修改。以下从提案转为源码说明，**尚未通过真实编译/ASR 运行验证**，也没有 CI 触发授权。

## 现状

LocalSpeechProbe.start 接受 Locale，但 PoCSession 使用 en-US 默认值；final/error 结束后要求手动重启。每个 final 创建一个翻译任务并取消前一个，可能丢掉长视频中的前段译文。采集/PiP 已有代次、停止失败、重复停止和延迟回调保护，必须保留。

## 获批改动

1. `LocalSpeechProbe.swift`：以 Core 的 SupportedLanguage 映射 zh-CN / en-US / ja-JP；拒绝 automatic ASR。开始前检查权限、recognizer.isAvailable、supportsOnDeviceRecognition，保持 requiresOnDeviceRecognition=true，不回退云端/麦克风。
2. 每次识别请求分配 utteranceID 和递增事件序号，发送 partial/final 到 Core 字幕管线；约 50 秒主动 endAudio 轮转。最多等待 2 秒确认旧任务 completed，再开始新请求；超时/未知错误明确停止，不无限重启。旧回调有会话和请求双代次保护。同时最多一个识别任务。
3. `PoCSession.swift`：新增带默认值的源/目标语言参数和 SubtitleTranslationSession 接线。使用有限 FIFO 分段替代“新 final 取消旧 final”；UI 仅接收当前会话译文。stop 先断开回调/取消任务，保留原生命周期资源释放与失败重试顺序。路由变化/系统中断仍停止，恢复必须显式开始。
4. 不修改 Host SwiftUI；用户选择语言、正式设置项和字幕展示由 Claude 接线。保留英文默认诊断入口的兼容调用。
5. 不修改采集路线、ScreenCaptureKit 权限、后台模式、PiP delegate 或渲染。无 ReplayKit/麦克风替代，不修改原始播放音频。

## 验收

- Core 回归覆盖分段、重复 final、顺序、有限队列、溢出事件、停止/重启/旧代次、取消后迟到响应。
- PoC 原有 14 项生命周期测试必须继续通过，不能删除或削弱。
- 获批 CI 后真实执行 Swift 6 与 iOS 27 iphoneos Archive，并检查设备产物仍编译真实 ScreenCaptureKit 代码；模拟器占位不算采集验证。
- 真机另测三语语言包/识别质量、至少 30 分钟连续识别、识别轮转缺字/重复、音频格式与中断、跨 App 来源、PiP 实显与后台行为。云端编译不能通过这一门槛。

## 必须保留的限制

- 轮转排空期间不重放音频，sink 会暂时停止投递，存在最长约 2 秒的识别空窗。真机必须测缺字、丢段与轮转频率；不能称为无缝连续 ASR。如需音频缓冲/转换或 SpeechAnalyzer 路线，应另提方案，不隐性扩大当前修改。
- SpeechAudioSink 只接收有效 PCM、8–192 kHz、1–2 声道；同一识别请求内格式变化会失败，不伪造成功或静默替换麦克风。实际 Speech 是否接受设备提供格式仍需验证。
- 取消后的 Speech 释放确认加入会话清理成功条件；超时进入现有 releaseFailed 机制，用户停止重试或结束 App。原 capture/PiP 清理顺序保留。
- Host 默认仍为英文、engine=nil 本地诊断；本轮不添加语言 UI，不连接真实 API Key。三语参数、共享引擎和字幕接口供后续正式接线。
- 云端 SDK 编译即使通过，也不能验收跨 App 音频、语言包、PiP、后台行为或连续识别质量。
