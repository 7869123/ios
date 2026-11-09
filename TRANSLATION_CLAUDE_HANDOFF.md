# Claude 接线交接：翻译底层增量

## 边界与证据

- 开发基线为 `7ff41115adf3b6c0e80e54c9af6d566712f48399`，独立分支 `codex/translation-completeness`；只读审计提交 `c178776`，P0 源码提交 `659de51`。后续以本分支提交历史为准。
- 先读 `AGENTS.md`、本文件、`TRANSLATION_AUDIT.md`、`POC_TRANSLATION_PLAN.md`，再读 Core/AppleServices 源码与测试。
- 仓库所有者本轮重新分配底层工作给 Codex，UI/UX 仍归 Claude。没有修改 Apps、壁纸、资源、workflow、scripts 或媒体生产实现。不把本交接当作跨分支合并授权。
- **本批新增代码尚未通过 Swift 编译/测试或 Apple SDK 验证**。静态检查不是编译；已有基线 CI 不能套用到新代码。触发 CI/重跑需所有者确认。
- 所有者随后单独授权了 PoC 两处逻辑文件：LocalSpeechProbe / PoCSession 已加入三语参数、50 秒轮转/最多 2 秒排空与字幕队列接线，**仍未编译/运行验证**。Host UI、采集和 PiP 实现没有改；不能描述成跨 App 采集已可用。

## 组合入口

继续复用唯一 `AIUtilityServices`：`configurations` / `translation` / `ocr` / `budget` 保留，并新增：

| 属性 | 用途 |
|---|---|
| `preferences: TranslationPreferences` | 两套提示词、独立语言、按供应商/模型保存推理设置 |
| `openAIUsage: OpenAIUsageLedger` | OpenAI 实际响应的当前会话及本机历史累计用量 |
| `deepSeekBalance: DeepSeekBalanceMonitor` | 官方余额、阈值、前台检查、低余额事件 |
| `screenshots: ScreenshotTranslationWorkflow` | 区域 OCR → 编辑草稿 → 显式文字翻译 |
| `translation.diagnostics` | 有界、内存中的阶段耗时与安全错误枚举 |

`AIUtilityServices(localDataDirectory:)` 可注入测试目录；默认稳定存放于 Application Support 下的 AIUtility/Configuration，不使用临时目录，也不改 Keychain service。正常应用升级保留数据；删除 App 不承诺保留。
一个进程中复用同一组服务，不为每个页面另建 coordinator/账本/设置 actor。未来 App Intent 若在另一进程执行，必须再审查跨进程配置事务，当前只提供调用接口，**没有注册任何 Shortcut/App Intent**。

## 提示词与语言

```swift
import AIUtilityCore
import AIUtilityAppleServices

// services 是 App 已持有的唯一 AIUtilityServices。
let prompt = try await services.preferences.prompt(for: .videoSubtitle)
try await services.preferences.savePrompt(editedPrompt, for: .videoSubtitle)
try await services.preferences.restoreDefaultPrompt(for: .videoSubtitle)
let languages = TranslationLanguages(source: .japanese, target: .english)
try await services.preferences.saveLanguages(languages, for: .videoSubtitle)
let result = try await services.translation.translate(
    sourceText, provider: selectedProvider, feature: .videoSubtitle)
```

- `.videoSubtitle` / `.discordScreenshot` 分开保存、恢复；模板支持 `{{sourceLanguage}}` / `{{targetLanguage}}`，无占位符时仍追加明确语言参数。默认指令忠实保留语义、语气、称呼；不续写/总结/解释，不随意删减成人或敏感表达，无法准确翻译片段可用「■■」，只输出译文。
- 提示词随正常生成请求发送，不增加预热调用。OCR/ASR 文本只在 user/input 字段；固定指令声明它是待译数据。分层不保证模型绝不会受提示注入影响。
- `SupportedLanguage` 为 zh-CN / en / ja；`SourceLanguage.automatic` 只在 `translation.supportsAutomaticTextDetection` 为 true 时开放。Apple 使用真实 NaturalLanguage、限制到支持语言且拒绝低置信度；Speech 自动语言选择没有实现。
- 同语直接返回原文，不读取凭据、不预留 API 预算。手动源语言可离线走此路径；自动检测需要本地检测器成功。
- 新的 typed overload 省略 `languages` 时自动读取该功能偏好；可传 `languages` 作本次覆盖，不改变模型绑定。
- 旧 `translate(_:targetLanguage:provider:feature:...)` 入口仍可调用，常见中英日目标名称映射到 typed 路径；其他历史目标名称继续保留。旧 UI 的目标语言参数会覆盖已保存目标，**Claude 应迁移到 typed overload 并绑定语言偏好**。App 内已有 `TranslationLanguage` 不需被重写；新 Core 类型特意用了不同名称避免冲突。
- `maxOutputTokens` 变为可选参数（默认 nil），省略时读取模型预算，原有传 Int 的调用仍兼容；持有旧完整函数类型的调用方需调整。

## 推理设置

```swift
let capabilities = ReasoningCapabilities.forModel(modelID, provider: provider)
let settings = try await services.preferences.reasoningSettings(provider: provider, model: modelID)
try await services.preferences.saveReasoning(
    .high, provider: provider, model: modelID, totalOutputTokens: 32_768)
```

- 默认 Auto，不发送任何推理字段。只展示 `capabilities.efforts`，不要展示 `ReasoningEffort.allCases`。未知模型可正常使用 Auto；不支持的显式档位在网络前失败，不伪造能力。
- OpenAI 为 Responses `reasoning.effort`；DeepSeek 为 Chat Completions `reasoning_effort`；Anthropic 为 `output_config.effort` + adaptive thinking。没有混用三家参数，也不发送手动 `budget_tokens`。
- 已核对的精确模型别名/快照在 `ReasoningConfiguration.swift`；后续扩展需更新官方依据与线格式测试，不按名称前缀猜测。没有把模型目录列出等同于支持某个档位。
- 用户必须显式保存总输出预算（16…65,536），不因切换强度静默加费。思考与可见译文共用供应商总输出额度。`suggestedTotalOutputTokens` 只是提示，不是保证；高档位可能仍截断。继续返回 `outputTruncated`，不自动重发放大预算。
- 会话调用预算仍限制每次请求的保守预留（默认总额 65,536），高单次上限会更快耗尽预算；不修改现有 Key/模型验证的真实生成事务。
- 固定交接文案：**「推理强度越高，通常需要更长的处理时间，并可能消耗更多 Token，但有助于提高复杂内容的理解和翻译准确性。实际效果因模型而异。」** Low：优先响应速度，适合实时字幕。High 及更高：可能增加延迟和 API 费用。不得保证更准确。

官方依据：[OpenAI 推理及输出预算](https://developers.openai.com/api/docs/guides/reasoning)、[GPT-5.1](https://developers.openai.com/api/docs/models/gpt-5.1)、[GPT-5.4](https://developers.openai.com/api/docs/models/gpt-5.4)、[o3](https://developers.openai.com/api/docs/models/o3)、[o4-mini](https://developers.openai.com/api/docs/models/o4-mini)、[DeepSeek Chat Completions](https://api-docs.deepseek.com/api/create-chat-completion/)、[Claude effort](https://platform.claude.com/docs/en/build-with-claude/effort)。以上是文档核对，不是账户权限/真实模型调用通过。

## 连续字幕的 Core 接口

```swift
let pipeline = SubtitleTranslationSession(engine: services.translation)
let events = try await pipeline.events() // 先订阅，再 start
let session = try await pipeline.start(provider: provider, languages: languages)
try await pipeline.ingest(transcript, session: session)
try await pipeline.flushStable(at: elapsedSeconds, session: session)
await pipeline.pause() // 取消并等待当前请求结束；不自动恢复旧音频
// 恢复、跳转、换模型/供应商/语言：重新 start，替换 session handle。
await pipeline.stop()
await pipeline.closeEventStreams() // 控制器销毁/丢弃本次订阅时关闭，下一次先重新订阅。
```

- `SpeechTranscript` 包含新识别请求的 `utteranceID`、请求内递增 `sequence`、累计文本、isFinal，以及同一播放会话的**单调递增经过秒数**。识别请求轮转时不能把 timestamp 归零；播放跳转需新 pipeline session。
- partial 只提交连续两次稳定的标点前缀/长度达到上限的段；稳定静默至少 1.2 秒且至少 8 字符才 flush；final 提交剩余文字。不按每个字符调用翻译。
- 同一 utterance 的重复/过期事件及已提交前缀修订不重复发送；不跨新 utterance 粗暴删除真实重复台词。生产端需避免轮转重放同一音频。
- 默认段长 240、累计识别 4096 字符、待译 8 段；单 worker FIFO，溢出明确发 dropped 事件。可调策略有硬上限，不无限保留上下文。
- `SubtitleEvent.translated` 含 session、ordinal、译文与耗时；failed 为安全错误枚举；dropped/stopped 独立。显示端仍应检查 session/ordinal，丢弃已退出会话事件。有界事件流可能丢掉过旧 UI 事件，不是字幕归档服务。
- 模型/Key 事务提交会让 TranslationEngine 主动取消该供应商旧请求；输入文本/译文不写磁盘。已到供应商的请求仍可能计费。
- 暂停/中断应调用 stop/pause；恢复显式 start。没有自动播放控制、麦克风或屏幕后台截图。独立 PoC 已按另行授权接上管线，正式 App 尚未接线。
- Apple `AppleSpeechLanguageSupport.capabilities()` 提供三种 Locale 的本机能力快照，不弹权限、不开始采集。supportsOnDeviceRecognition 不能当作语言包一定可用；运行时仍需检查权限/语言包/设备并处理错误。
- PoC 新增 `PoCSession(..., sourceLanguage: SupportedLanguage)`，保留原 targetLanguage 字符串调用；接受三种目标语言的名称/代码，其他目标在有翻译引擎时明确拒绝。正式控制器应先读取保存的语言，手动选择 ASR 源，不给 Speech 使用 automatic。
- 识别轮转只在旧任务 completed 后新建，最多等待 2 秒；此间未投递音频，可能缺字。没有音频回放缓冲、格式转换或无缝识别保证。未知识别错误停止；停止后 Speech 资源未确认则现有生命周期禁止重启。细节见 `POC_TRANSLATION_PLAN.md`。
- 既有 Host 默认 engine=nil，并用 speech.caption 显示原文；其原文到 PiP 的显示绑定本轮未改。正式接入真实引擎时，Claude 需避免该绑定覆盖译文，不能只创建 pipeline 就假定正式字幕界面已接通。

## DeepSeek 余额

```swift
let events = try await services.deepSeekBalance.lowBalanceEvents()
try await services.deepSeekBalance.setThreshold(Decimal(5), for: .CNY)
let state = try await services.deepSeekBalance.refresh() // 手动刷新
let foreground = try await services.deepSeekBalance.checkWhileActive() // 默认至少间隔 300 秒
```

- [官方 GET /user/balance](https://api-docs.deepseek.com/api/get-user-balance/)，复用唯一 DeepSeek Key，不调用模型验证、不自动充值。
- Decimal 金额、币种、isAvailable、更新时间、状态分别返回。失败抛安全错误，可再读 snapshot：保留最近成功余额和原更新时间，但 status 为 failed；nil 或 failed 不是零。
- 阈值按 CNY/USD 分开，不做汇率转换。持续低余额只发一次事件，升过阈值后重新进入低余额才再提醒；抑制状态持久化。修改阈值会开启新提醒周期。
- 先订阅再刷新；若抑制状态无法持久保存，返回 `alertPersistenceFailed=true`，不反复发提醒；余额本身仍可用。
- Claude 只在前台使用期间安排 checkWhileActive；离开前台停止调度。不注册后台常驻、推送服务器或通知 UI。

## OpenAI 用量

- `await services.openAIUsage.snapshot()` 返回 session、lifetime（无法加载时为 nil）、persistence、untrackedResponses。按**响应模型 ID**统计，缺少时退回请求模型 ID。
- actual input/output/total/reasoning tokens 取 Responses usage；reasoning 已含在 output，不重复加总。`responsesWithReasoningDetail` 区分没有该细分与返回零。
- `responsesWithoutUsage` 单独累计；不估算、不记为实际零用量。已收到完整 JSON 的截断/拒绝也会记录实际 usage；401/网络中断/取消而未收到 usage 无法知道实际计费量。
- `GenerationResult.usage` 是可选实际用量，原 outputTokens 保留。统计/磁盘失败不影响正常译文；损坏历史显示 unavailable，不覆盖旧文件、也不冒充零。
- 只记录本工具自身收到的响应；不是账户仪表盘，不需要 Admin Key。没有 Anthropic 用量账本。

## 截图区域与手动触发接口

```swift
let region = try OCRRegion(x: 0.1, y: 0.2, width: 0.8, height: 0.5)
let draft = try await services.screenshots.recognize(
    imageData: selectedImageData, source: .japanese, region: region)
let edited = try await services.screenshots.edit(editedText, draft: draft.id)
let output = try await services.screenshots.translate(draft: edited.id, provider: provider)
await services.screenshots.cancel()
```

- Vision 坐标在**应用 EXIF 方向后的图像**，左下角原点、0…1。UI 左上角的框必须转换 y = 1 - top - height；不能直接传视图像素或忽略缩放留白。提供合成图区域回归测试，真实方向/截图质量仍需设备验收。
- `VisionOCRService` 额外实现 `RegionOCRService`；原 OCRService 方法不变，直接 OCR 调用兼容。manual 语言必须在 Vision 实际支持列表内；多语言识别用真实自动检测属性。
- 草稿只有本地文字/识别行/耗时，id 用于拒绝过期编辑；修改后返回新 id。后续翻译复用编辑稿，不重复 OCR；并行操作明确 busy。
- cancel 等待生产者确认，清除处理中资源、保留草稿；clear 同时清草稿。失败后可编辑重试，不自动上传或自动重试 OCR→AI 整条链。
- 快捷指令、App Intents 注册、区域选择界面、系统结果卡片均由 Claude 在此接口上接入，不能宣称本分支已提供系统快捷入口。

## 性能、安全与验证

- `translateMeasured` 返回译文、是否请求 API、总 duration；diagnostics 只收集阶段、数字和安全枚举，容量默认 128 / 最大 512。
- 自动记录 OCR、翻译 API、字幕入队到结果耗时；**没有采集端时间戳就不称音频端到端延迟**。speechRecognition 阶段接口存在但当前 PoC 未接入，不伪造 ASR 耗时。
- 网络超时和不确定传输错误不自动重发；仅限流/overloaded 有限重试，尊重 Retry-After 与会话预算。原配置事务的全部测试保留。
- 不记录源文本/译文/提示词值/Key/图片/音频；测试只用内置合成常量与脚本响应，不运行付费 API。
- 本地版本 1 文档为 additive decode，缺少新增推理字段可迁移；损坏或未来版本拒绝覆盖，写入失败保留旧配置。LocalDataStore 不是凭据存储。

候选真实验证（**尚未执行，需要确认 CI**）：

```sh
swift build --package-path Packages/AIUtilityCore
swift test --package-path Packages/AIUtilityCore
swift test --package-path Packages/AIUtilityAppleServices
swift test --package-path PoCs/iOS27Capture
bash scripts/ci_apple.sh
bash scripts/ci_app.sh
```

现有 workflow 已包含 Core/Media/生命周期和 AppleServices 测试、双 SDK 构建、App Archive/未签名 IPA；本批无工具变化。因已获批修改 PoC，待所有者确认后建议一次 build_apple=true、build_poc=true，publish_previews=false、live_checks=false，包含 iOS 27 的真正设备 SDK 代码编译/Archive。不运行真实 AI API、真实私密媒体测试；不上传缓存或敏感用户输入。

## Claude 的第一项接线任务

待所有者审核底层分支并允许集成、且真实 CI 通过后，在现有设置页按 `.videoSubtitle` / `.discordScreenshot` 读取/保存/恢复 prompt 与 languages，将 TranslationPanel 的调用迁移到 typed overload。使用本页接口与固定文案设计正式 UI，不新增临时页面。不要直接拉取/合并本分支，先等所有者决定。
