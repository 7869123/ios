# 翻译系统只读审计（开发前基线）

本轮范围为底层增量开发；UI、主题、壁纸、媒体生产实现不修改。本报告描述 **7ff41115adf3b6c0e80e54c9af6d566712f48399**，不是后续新增代码的验证结论。
独立分支 `codex/translation-completeness` 从该提交建立，保留全部历史。`main=f17d20d`；开放 PR #1 为 Claude 分支 → main，PR #2 已不在开放列表中。未合并 PR、未向 main 或 Claude 分支写入。

## 源码与证据

- Core：`Packages/AIUtilityCore/Sources/AIUtilityCore/` 的 TranslationEngine、OfficialAPIAdapter、ConfigurationCoordinator、ProviderGateway。
- Apple：`Packages/AIUtilityAppleServices/Sources/AIUtilityAppleServices/` 的 VisionOCRService、AIUtilityServices、KeychainCredentialStore。
- App（只读）：`Apps/AIUtility/Sources/TranslationViews.swift`、AIUtilityApp.swift、KeyHealth.swift、SettingsView.swift。
- PoC：`PoCs/iOS27Capture/Sources/AIUtilityCapturePoC/` 的 LocalSpeechProbe、PoCSession、ScreenAudioProbe、ProbeLifecycle、SubtitlePiPProbe；Host 为独立诊断 App。
- 已读取最新 AGENTS.md、HANDOFF.md、STATUS.md 和 workflow。文档里“媒体未实现”“没有 SDK”及旧 CI 计数是历史，不覆盖新源码。
- [基线真实 CI 42486839669](https://github.com/7869123/ios/actions/runs/42486839669)：Linux job 128750453947、Apple job 128750777745 和 App job 128751608732 成功；live-checks、poc-sdk 跳过。读取了 Linux、Apple 实际日志。
- Linux Swift 6.0.3：Core 37 项中 36 通过 / 1 live API 跳过；Media 96 项中 92 通过 / 4 站点 live 检查跳过；生命周期 14 通过。
- macOS Swift 6.3.3：Core 36 通过 / 1 跳过；Vision 2 通过 / Keychain 1 跳过；Media 113 项中 108 通过 / 5 live 检查跳过。两个 AppleServices SDK 构建、四个 Media SDK 构建有 BUILD SUCCEEDED。
- App 模拟器、iphoneos、Archive、未签名 IPA 步骤成功；此运行未截图，未运行 iOS 27 PoC。历史 PoC SDK 成功不能当作本次或真机证据。

## 功能分类

| 检查项 | 分类 | 基线实际行为与缺口 |
|---|---|---|
| 独立可编辑提示词与持久化 | 部分实现 | TranslationEngine 固定指令；无两套配置、恢复默认、升级迁移 |
| 三语互译 | 部分实现 | 可传目标语言字符串；App 有中英日韩目标项；无源语言选择、同语直返、分功能偏好或六方向测试 |
| 三语 ASR | 部分实现、需要真机验证 | Speech 接受 Locale 参数，但 PoCSession.start 调用默认 en-US；仅本地识别，语言包/可用性未验证 |
| 连续识别 / 实时字幕 | 部分实现、需要真机验证 | 只 final 调用翻译；final/error 后不重启；新 final 取消旧请求，可能丢段；无有限队列、稳定分段、去重或播放时间线接口 |
| 推理强度 | 尚未实现 | 请求无配置参数；解析已忽略 reasoning/thinking 内容，有 Core 回归证据；输出硬上限 8192 对高推理不充分 |
| DeepSeek 余额 | 尚未实现 | 无余额接口、阈值、提醒抑制；Key 已可复用 |
| OpenAI Token 账本 | 部分实现 | 只返回 outputTokens，无输入/总量/推理细分或本地账本 |
| 截图本地 OCR / 编辑 / 仅文字上送 | 已实现且有测试证据（限范围） | Vision 合成英文图与非法输入测试通过；App 可编辑 OCR 文字；Core 翻译只接文本；真实截图质量未验证 |
| 截图区域 / 快捷触发 | 尚未实现 | 无 regionOfInterest、App Intents 或可供其调用的独立工作流 |
| 超时、取消、有限重试、预算 | 已实现且有测试证据 | 总时限、401/模型错误分类、429/overloaded 有限重试、Retry-After、取消竞态、配额均有回归；无阶段耗时观测 |
| 共享 Key 与模型事务 | 已实现且有测试证据 | 一个供应商一条 Keychain 记录；两功能独立模型；真实生成验证后保存；旧 Key 原子保留、并发写 busy、取消/截断/拒绝回滚均有 Core 测试；iOS Keychain 运行时未验证 |
| 采集/PiP/后台 | 需要真机验证 | 既有生命周期保护和 SDK 证据保留；跨 App 音频、PiP 实显、音频中断后的设备行为均没有真机证据 |

## 媒体闭环（只审计，不扩展）

现有 `AIUtilityMedia` 和 `AIUtilityMediaApple` 已有：X/Pixiv/Bilibili 解析、Ugoira/GIF、图片指纹/元数据、多图拼接、SauceNAO/搜图 Bot 酱、下载队列/历史/导出 App 接线。测试覆盖错误响应、路由、取消后清理、队列单槽、提交/删除恢复日志、GIF 帧时长与归属校验。
不重复开发；B站 allParts 仍明确 unsupported，不能悄悄降级。真实站点可访问性与离线样例分开；本次基线 live-checks 被跳过，SauceNAO 真实凭据、站点限制与完整真实文件下载/分享仍需受控设备验收。

## 优先级与验收门槛

1. P0：持久化两套提示词/语言、无预热请求、六种方向/同语直返、文本与系统指令分离；有限字幕分段队列/重复抑制/会话代次/停止取消；ASR 按源语言选择并连续重启。不得改动采集/PiP 已有资源释放设计或加入麦克风替代。
2. P1：按供应商和具体模型维护推理能力；未知模型仅 Auto，不发送猜测参数；余额真实查询/前台检查/阈值事件；OpenAI 响应实际用量持久化且失败不影响译文；OCR 区域与可供 Claude/App Intents 调用的文本工作流接口。
3. P2：仅数值与安全枚举的耗时/状态、取消/超时/切模型/中断回归、有限内存、配置版本迁移。不记录用户文本/音频/图片。
4. 每批新增均先标“源码完成、未编译”；Windows 不安装 Swift。仓库规则要求触发 CI 前另行授权；获批后执行真实 Linux/Apple/PoC 验证并按逐项日志报告通过、失败、跳过及退出码。禁止以静态语法检查代替编译。
5. 新增配置与数据模型只提供公开 Swift 接口，Claude 负责正式设置页/交互接线；本分支不修改 SwiftUI、资源或媒体实现。

## 风险

- 自动检测只在底层真实支持的文本检测器可用时开放；Speech 手动选语言，不声称自动多语 ASR。
- 高推理的 reasoning 与译文共用输出额度，不能静默自动加费或保证准确性；需要明确可配置总输出额度和预算，截断继续返回错误。
- 去重只在有界会话/识别段内执行；用户主动重试/跳转是新代次。迟到请求可能已计费，取消不表示退款。
- 提示词分层降低 OCR/ASR 注入风险，不构成模型绝不会受注入影响的保证。无额外客户端 NSFW 过滤。
- 本地偏好与用量账本不是 Keychain，不保存密钥、识别原文、译文或截图；正常升级保留，损坏/未来版本不能静默覆盖。
- 普通 Apple ID、签名安装、iPad mini 6 首次实机矩阵仍是独立门槛。
