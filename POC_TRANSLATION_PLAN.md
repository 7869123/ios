# iOS 27 PoC 翻译接线方案（已获授权，SDK 已编译，真机未验证）

所有者先要求提交提案，再明确授权仅修改 LocalSpeechProbe.swift 和 PoCSession.swift，并进一步授权缓存及编译/修复重试直至通过、不合并。Host UI、ScreenAudioProbe、ProbeLifecycle、SubtitlePiPProbe 没有修改。最新 [42739095920](https://github.com/7869123/ios/actions/runs/42739095920) 验证源 05508ba：完整 CI success，iOS 27.1 PoC Swift 6 模拟器编译/iphoneos Archive/未签名 IPA/13 项预安装检查成功；Core Linux/macOS 各 82 通过/1 跳过，生命周期各 14 通过。ASR 实际识别、缓存补送、跨 App 采集和 PiP/后台仍未经过真机验证。[证据](validation/translation-completeness/attempt-2/README.md)。首轮 42647207277 失败证据保留在 attempt-1。

## 后续获批：加入有界音频缓存

用户了解方案后明确要求“加入缓存机制”。源码 `2272e99`：

- Core 新增可测试的 AudioRolloverBuffer；PoC 只在 LocalSpeechProbe 内接入。缓存默认同时受 5 秒音频时长/时间跨度、8 MiB 数据和 512 包限制。不是句子缓存，不等待满额后识别。
- 正常与补送音频通过同一 FIFO、单串行 worker。轮转原子切换为 buffering 后才 endAudio；旧任务完成、新请求就绪后补送未投递包，再继续实时输入。没有已投递音频的重叠 pre-roll。
- 只对有效 PCM 使用独立数据拷贝；容量校验先于分配。原采集缓冲、原始播放、采集授权、后台模式和 PiP 路线不变。
- 停止/中断通过原 speech.stop 清缓存并分离请求。每包 append 与停止之间有同步边界，旧 worker/会话不能取新会话的包；每包 autoreleasepool，避免长循环积累临时对象。
- 收尾 `42a1bec` 增加按请求 token 的非阻塞 final/error 交接，回调不等待投递锁；MainActor 保留双代次检查及轮转兜底。不能把 append 返回当成识别完成确认。
- 容量超限、格式变化、部分重叠、非法时间/数据或复制失败会清空并明确失败；原停止失败禁止重启机制仍保留。完全过期的时间范围按重复包拒绝，计入 duplicatePackets。
- 新增 13 个纯逻辑回归已在最新 Linux/macOS Core 测试中通过，覆盖顺序、容量、重复、旧会话、释放和 1000 次轮转；**不验证 Apple Speech 或 PCM 复制**。新增 CoreMedia 符号已通过 iOS 27.1 SDK 编译，仍需合成/真机音频运行检查。
- 该方案取代下方旧提交的“排空期间不缓存”。Speech 任务完成超时仍为最多 2 秒；若超时仍失败并清缓存，不靠延长缓存掩盖资源释放失败。

## 开发前基线（历史）

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

- 轮转排空期间改为缓存尚未投递音频，不能据此保证无漏字。词语切分边界和 Speech 能否及时处理积压仍需真机验证；若要加入重叠音频、格式转换或 SpeechAnalyzer，应另提方案。
- SpeechAudioSink 只接收有效 PCM、8–192 kHz、1–2 声道；同一识别请求内格式变化会失败，不伪造成功或静默替换麦克风。实际 Speech 是否接受设备提供格式仍需验证。
- 取消后的 Speech 释放确认加入会话清理成功条件；超时进入现有 releaseFailed 机制，用户停止重试或结束 App。原 capture/PiP 清理顺序保留。
- Host 默认仍为英文、engine=nil 本地诊断；本轮不添加语言 UI，不连接真实 API Key。三语参数、共享引擎和字幕接口供后续正式接线。
- 云端 SDK 编译即使通过，也不能验收跨 App 音频、语言包、PiP、后台行为或连续识别质量。
