# 给 Claude 的变更通知（待所有者决定集成）

## 最新：字幕旧尾句清理（先修代码，未重跑 CI）

- 文件：Core 的 SubtitleTranslationSession.swift、TranslationReliabilityTests.swift，以及 STATUS/HANDOFF/本通知/接口交接/验证文档。首轮 7 处编译诊断的 `6aa6f64` 修复已复核保留。
- **接口变化**：无公开签名变化；修正行为是 ASR 推翻已提交前缀后，旧未提交尾句立即失效，序号水位推进，final 结束旧 utterance，避免重复/错误翻译。新增 2 个测试声明（其中 1 个两组参数），旧测试保留；尚未编译/执行。
- **无工具变化**：workflow、scripts、依赖、构建命令均不改；未修改 UI、AppleServices 或任何 PoC 文件。未重跑 CI，不创建 PR、不合并或读取 Claude 分支。
- Claude 无需调整调用或 UI；用户授权集成后应连同修复与回归一并纳入，仍需真实 Swift/Apple CI 验证。[详细修复记录](validation/translation-completeness/repair-review.md)。

## 最新：首轮 CI 测试编译修复

- 验证源 0ee791b，Actions 42647207277：Core 生产 build=0，测试模块 test=1（执行 0），原因是新增测试的宏展开错误；生命周期 14 通过、Media 92 通过/4 跳过，Apple/PoC/App 被依赖阻断。未创建 PR、未合并分支。
- 修复 `6aa6f64`：只修改 APIConfigurationFeatureTests.swift、TranslationFeatureTests.swift、TranslationReliabilityTests.swift，将宏、throwing 读取、JSON 解码拆开。三份文件的 @Test/#expect/#require 数量保留，生产代码不改。
- **无接口变化，无工具变化**。后续经所有者批准集成时需包含本测试修复，否则测试模块不能编译。修复仍未复验，不能声明 Core 测试或 Apple 编译通过；重跑需另行确认。证据在 validation/translation-completeness/attempt-1/。

## 后续：有界 ASR 缓存

- 用户明确授权，缓存源码 `2272e99`，回调 token / 锁收尾 `42a1bec`；新增 Core AudioRolloverBuffer.swift / AudioRolloverBufferTests.swift，只改 PoC LocalSpeechProbe.swift 接线，其他生产源码不变。
- **接口变化**：Core 新增有界泛型音频队列、策略、包、快照和安全状态/失败枚举；LocalSpeechProbe 新增只读 audioBufferSnapshot。现有翻译/ASR文本/Key/模型接口不改。
- 默认最多 5 秒/8 MiB PCM/512 包，只补送未投递音频，按同一 FIFO 处理；独立 PCM 拷贝、停止清空、会话代次和逐包投递同步。超限/格式或时间错误明确停止，不无限积压。
- **无工具变化**：无新依赖，workflow、scripts、CI 触发条件不改；UI、主题、壁纸、媒体、采集、PiP 和 Host UI 均不改。Claude 可后续接入数字快照展示，不需要为缓存另建 UI 才生效。
- 新增 13 项测试源码，尚未编译/执行；此前 c9496fa 的 CI 询问不覆盖本提交。需要所有者批准本批验证和跨分支集成。仍需检查 Speech 追平能力、切词缺字、重复字幕、音频完整性与真机内存。

## 前一批翻译接口

- 分支：`codex/translation-completeness`，基线 `7ff4111`。审计 `c178776`，P0 `659de51`，API/OCR/持久化 `fa81778`，获批 PoC `12ed6bf`，补充回归 `c9c572b`。最新文档提交见 Git 历史。
- 目录：AIUtilityCore 新增 LocalDataStore、TranslationPreferences、ReasoningConfiguration、SubtitleTranslationSession、DeepSeekBalance、OpenAIUsageLedger、ScreenshotTranslationWorkflow、TranslationDiagnostics；调整 TranslationEngine、ConfigurationCoordinator、Domain、OfficialAPIAdapter、ProviderGateway、OCRService；新增三份 Core 测试。AppleServices 新增 AppleLanguageSupport，调整 Services/Vision 与 Apple 测试。
- PoC **仅** LocalSpeechProbe.swift / PoCSession.swift，来自用户另行明确授权；三语与有界轮转/字幕接线，不修改采集/PiP/Host UI。
- 接口变化：见 [完整 Swift 接口交接](TRANSLATION_CLAUDE_HANDOFF.md)。Services 新增 preferences/openAIUsage/deepSeekBalance/screenshots；typed 三语翻译与 measured 返回；旧翻译入口的 maxOutputTokens 变为可选默认 nil；GenerationRequest 新增 reasoning、输出上限可到 65,536；GenerationResult 新增可选 usage；新区域 OCR 协议不破坏原 OCRService；Key/模型事务仍真实生成验证，已验证模型使用最低支持推理档位做 256-token 连通性检查，不修改用户推理偏好。
- 行为变化：模型/Key 保存后主动取消该供应商旧译文；同语无需 API；自定义提示词/语言/模型推理预算持久化；统计失败不会导致翻译失败。此前 PoC 未缓存的识别空窗现由上方缓存源码替代，仍未验证；Speech 停止未确认时阻止重新开始，不虚构释放成功。
- **无工具变化**：workflow、scripts、触发条件、工具版本、依赖与媒体生产实现不改；未修改 UI/壁纸/主题/布局/资源。无需安装新依赖。
- 需要 Claude 接线：所有者批准集成且真实 CI 通过后，把现有设置/翻译面板接到新属性和 typed overload，订阅余额/字幕事件；快捷指令/区域选择正式 UI 未实现。不能从本通知推断可自行跨分支合并。
- 当前本批未编译/测试；只有静态检查。真实 API、iOS Keychain、识别质量、连续 ASR 轮转缺字、跨 App 音频、PiP/后台、签名安装仍未验证。
