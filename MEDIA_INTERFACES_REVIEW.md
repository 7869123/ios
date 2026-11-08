# 媒体模块接口草案审核意见（P0）

审核人：Claude Code（负责 App 界面接线），2026-11-08。
审核对象：`origin/codex/poc-engineering-audit:MEDIA_INTERFACES.md`，提交 `5575511`。
用户已同意将以下意见写入本文件交给 Codex。**进入 P1 仍需用户明确授权**；下表的"结论"为本轮建议的执行口径，用户另有指示时以用户为准。

## 1. 总体结论

草案符合 `TASK_MEDIA_MODULES.md` 与用户指定的运行时行为，**原则上通过**，按第 3 节修改后可进入 P1：

- 按链接自动识别、全局先进先出、`maxConcurrent` 固定为 1（解析、重试、组装都占同一个活动槽），重复链接不重复下载。
- 完整队列快照订阅、`EnqueueReceipt` / `CancelResult`、`capabilities()`，便于界面如实展示"可用 / 规划中"。
- 只接受 HTTPS、拒绝本机和内网目标、不保存 Cookie 和签名链接、受限内容返回明确错误不绕过、每站点最小请求间隔，符合合规要求。
- 没有改动 Core / AppleServices 公共 API，没有创建包或代码，没有触发 CI。

## 2. 用户需决定的事项与结论

| # | 事项（草案第 12 节） | 草案方案 | 结论 |
|---|---|---|---|
| 1 | 取消 | 界面立即显示取消；资源确认释放后才调度下一个任务；清理失败阻塞队列；提交阶段取消可能返回 `tooLate` | **同意** |
| 2 | 自动下载范围 | 只取当前作品直接关联的媒体；默认最高公开可获取的兼容变体；同一作品可为有界多文件任务 | **同意** |
| 2a | B站多 P | 未指定分 P 时只下载第一 P | **同意作为默认**；后续界面可提供"下载全部分 P"选项，接口需预留（见 R5） |
| 2b | Pixiv Ugoira | 交付原始归档 + 帧时序清单，转换另议 | **修改**：P2 的 GIF 工具完成后，Ugoira 默认自动转为 GIF 交付，原始归档可选保留（见 R4） |
| 2c | B站 DASH | 显式 mux，不支持时明确失败，不降级为无声视频 | **同意** |
| 3 | 进度口径 | 同一 attempt / 阶段内单调不减；完整重传显式重置 | **同意** |
| 4 | 清空历史 | 只清记录和去重证据，不删文件；重启后中断任务不自动重放 | **同意**，但需新增删除文件接口（见 R2） |
| 5 | 网络策略 | 默认 HTTPS；有限请求、时限、重定向、重试和资源上限 | **同意** |

## 3. 需要修改的地方

### R1　P1 范围收窄：跨重启断点续传移出 P1

草案的任务状态、提交日志、generation、Range / If-Range 续传校验设计严谨，但对个人项目而言 P1 工作量过大。建议：

- **P1 保留**：链接识别与短链重路由、全局 FIFO、单活动槽、排队 / 活动取消、有限自动重试与退避、限流、重复入队、同一 attempt 内进度单调、队列与历史的原子持久化、重启后原运行项标记为 `interrupted` 并等待用户重试（从头下载）。
- **移到 P1b（P1 之后单独审核）**：同一次运行内或跨重启的 Range / If-Range 断点续传、`.part` 续接校验。P1 中服务器断开即视为本次尝试失败，按重试规则从头开始。
- 接口签名可保持不变，只是 P1 不实现续传路径，`capabilities()` 中如实反映。

### R2　新增删除下载文件的接口

`clearHistory` 只清记录、不删文件，用户在 App 内就无法释放空间。请增加，例如：

```swift
public func deleteFiles(for id: DownloadID) async throws(MediaError) -> DeleteResult
```

- 只删除该任务已提交的输出文件及其记录；活动或排队中的任务返回 `invalidState`。
- 删除后去重证据一并移除，再次添加同一链接视为新任务。
- 部分文件删除失败返回明确结果，不声称全部删除。
- 是否提供"清空全部下载文件"由界面组合调用，模块不必额外提供。

### R3　异步初始化的接线约定（告知，无需改接口）

`DownloadManager.init` 为 `async throws(MediaError)`。界面会在启动时显示"媒体模块加载中"，失败时显示 `storageUnavailable` 等分类并允许重试初始化。请在接口文档中写明：初始化失败后可以安全地再次创建实例，不会残留锁或半写入状态。

### R4　Ugoira 默认转为 GIF（P3，依赖 P2）

- P2 完成 GIF 编码后，Pixiv Ugoira 默认按帧时序转换为 GIF 作为最终输出；转换属于该任务的组装步骤，占用同一活动槽。
- 原始归档 + 时序清单可作为可选保留项（`MediaSelection` 或配置项均可，由 Codex 在接口中定义）。
- 帧时序必须准确保留，不能统一帧间隔。

### R5　B站多 P 预留

默认只下载第一 P（或链接中指定的分 P）。请在 `MediaSelection` 或解析结果中预留"全部分 P"的表达方式，便于以后界面提供选项；P3 可以只实现默认行为。

## 3b. 第二轮审核（`f5f0102`）

R1–R5 已全部在 `MEDIA_INTERFACES.md` 中落实，修订仅涉及文档，未写代码、未建包、未触发 CI。用户在第二轮决定新增 R6，**R6 修改后**再进入 P1（仍需用户明确授权）。

### R6　站点专属选项从 `MediaSelection` 中拆出（用户决定）

`f5f0102` 把 `bilibiliAllParts`、`ugoiraGIF(keepOriginalArchive:)` 作为 `MediaSelection` 的 case，导致：

- 一次入队只能表达一个选项，无法同时"指定清晰度 + 下载全部分 P"；
- 每增加一个站点专属选项都要扩充通用枚举；
- 设置页难以直接保存"默认下载选项"；
- 对不相关站点误用时只能在运行时报 `invalidSelection`。

请改为"通用选择 + 站点选项"两部分：

```swift
/// 通用：选择清晰度 / 格式
public enum MediaSelection: Sendable, Hashable, Codable {
    case automatic
    case variant(itemID: MediaItemID, variantID: String)
}

/// 站点专属选项；全部有默认值，与 MediaSelection 正交，可同时使用
public struct SiteOptions: Sendable, Hashable, Codable {
    public var bilibili: BilibiliOptions
    public var pixiv: PixivOptions
    public init(bilibili: BilibiliOptions = .init(), pixiv: PixivOptions = .init())
}
public struct BilibiliOptions: Sendable, Hashable, Codable {
    public var allParts: Bool                 // 默认 false：链接指定分 P，否则第一 P
    public init(allParts: Bool = false)
}
public struct PixivOptions: Sendable, Hashable, Codable {
    public var keepUgoiraArchive: Bool        // 默认 false：Ugoira 只交付 GIF
    public init(keepUgoiraArchive: Bool = false)
}

// DownloadManager
public func enqueue(link: URL,
                    selection: MediaSelection = .automatic,
                    options: SiteOptions = .init()) async throws(MediaError) -> EnqueueReceipt
public func enqueue(_ item: MediaItem, variant: MediaVariant,
                    options: SiteOptions = .init()) async throws(MediaError) -> EnqueueReceipt
```

要求：

1. **语义不变**：默认值与 `f5f0102` 的默认行为一致（B站单 P、Ugoira 默认 GIF 且不保留原件）；`capabilities.supportsAllBilibiliParts == false` 时，`bilibili.allParts == true` 仍返回 `unsupportedFormat`，不能悄悄只下载第一 P。
2. **不相关站点的选项忽略，不报错**：例如对 X 链接传入 `pixiv.keepUgoiraArchive = true` 不影响结果。只有选项对当前来源有效却无法满足时才报错。
3. **去重身份**：去重键只包含对该来源**实际生效**的选项（规范化后），不相关选项不参与，避免同一内容因无关选项不同而重复下载；对该来源生效的选项不同时视为不同任务。
4. **组装计划**：`MediaAssembly.ugoiraToGIF(keepOriginalArchive:)` 由 `options.pixiv.keepUgoiraArchive` 决定；其他组装逻辑不变。
5. **持久化**：`SiteOptions` 可 Codable，用于排队任务恢复和界面"默认下载选项"的保存；历史记录可保存生效的选项摘要，但不含任何链接或凭据。
6. **扩展方式**：以后新增站点选项时，只在对应站点的 Options 结构中加字段（带默认值），不修改 `MediaSelection`。
7. 同步更新文档中引用旧 case 的地方（第 3 节说明、`DownloadState`/去重相关段落、第 11 节测试要求、第 12 节审核点）。测试要求补充：选择与站点选项组合、无关选项被忽略、去重键只含生效选项、`allParts` 未支持时明确拒绝。

## 4. 界面接线备注（Claude 侧，供 Codex 参考）

- App 会在 `AppModel` 中另外持有 `DownloadManager`，只通过 `enqueue(link:)` 入队，不在入队前自行调用 `resolve`。
- 订阅 `updates()` 的完整快照并回到 MainActor 更新界面；按 `EnqueueReceipt` / `CancelResult` 给出提示，不把取消请求等同于资源已释放。
- `capabilities()` 中没有的站点或工具，界面继续标"规划中"。
- 媒体模块的 CI 步骤（Linux 纯逻辑测试、macOS 工具测试、iOS SDK 编译）由 Claude 在 workflow 中添加，需要时 Codex 在汇报中列出测试目标名称。

## 5. 下一步

1. ~~Codex 按第 3 节修改 `MEDIA_INTERFACES.md`~~（已在 `f5f0102` 完成 R1–R5）。
2. Codex 按第 3b 节 R6 修改 `MEDIA_INTERFACES.md`，汇报改动点（按 `AGENTS.md` 格式，UTC 提交）。
3. 用户审核修改后的接口文档，并明确授权进入 P1。
4. P1 完成后，触发 CI 前先征得用户同意。
