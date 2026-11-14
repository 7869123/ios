# 任务说明：媒体下载与图片工具模块（给 Codex）

起草：Claude Code，2026-11-08。状态：**待用户审核**。用户确认前不要开始实现。

全程遵守仓库根目录 `AGENTS.md`（中文汇报、只在自己分支工作、触发 Actions 前先问用户、UTC 提交时间、推送前检查、不提交个人信息）。本文件与 `AGENTS.md` 冲突时，以 `AGENTS.md` 和用户最新指示为准。

## 0. 背景

- App 的「媒体工具」页面目前全部标为"规划中"。本任务实现这些功能的**后端模块和测试**，不包括界面。
- 用户暂时无法用电脑连接 iPad 签名安装，所以本阶段只做能在 Linux / macOS CI 上验证的逻辑，不要求真机验证。
- 分工：Codex 负责模块、测试和接口文档；Claude Code 负责 App 界面接线和 CI workflow。需要修改 `.github/workflows` 时，在汇报中写清需要哪些 job 或步骤，由用户决定交给谁改。

## 1. 范围与顺序

分 4 个阶段，**每个阶段单独提交、单独汇报**，用户确认后再进入下一阶段。

| 阶段 | 内容 | 依赖网络 | 验证方式 |
|---|---|---|---|
| P0 | 接口文档 `MEDIA_INTERFACES.md`（见第 3 节），不写实现 | 否 | 用户审核 |
| P1 | 链接识别与统一下载队列（见下方「运行时行为」）：自动识别、先进先出、一次只运行一个任务、进度、取消、重试、断点续传（服务器支持时）、历史记录 | 否（用假传输层测试） | 单元测试 |
| P2 | 本地工具：多图拼接、视频转 GIF、图片文件指纹 | 否 | macOS 测试（AVFoundation / ImageIO） |
| P3 | 站点解析：B站、X、Pixiv（含 Ugoira）三个都要做，不分优先级；每个站点单独一次提交 | 是（测试用离线样例） | 离线样例测试；真实联网测试默认关闭 |
| P4 | 反向搜图：SauceNAO | 是（需 API Key） | 离线样例测试；真实调用默认关闭 |

### 运行时行为（用户指定）

- **按链接自动识别**：用户粘贴或分享任意链接，由 `LinkRouter` 按网址（域名和路径）判断属于 B站、X、Pixiv 还是普通直链，交给对应的 `MediaResolver`。用户不需要手动选择站点。无法识别时返回 `unsupportedSource`。
- **先到先处理**：所有任务（解析和下载）进入同一个先进先出队列，按加入顺序处理，不按站点排序。
- **一次一个**：同一时间只运行一个任务（`maxConcurrent = 1`），前一个完成、失败或取消后才开始下一个，避免高并发触发限流或封号。此外每个站点仍有自己的请求间隔和超时上限。
- 排队中的任务可以取消或调整顺序（调整顺序可选）；正在运行的任务取消后，立即开始下一个。
- 同一个链接重复加入时不重复下载，提示已在队列或已完成。

## 2. 包结构

- 新建独立包 `Packages/AIUtilityMedia`，不放进现有的 `AIUtilityCore`，也不修改 Core 和 AppleServices 的公共 API。如果确实需要改，先在汇报里说明原因，等用户同意。
- 平台：iOS 17+、macOS 14+；Swift 6 语言模式，严格并发检查。
- 纯逻辑放在不依赖 Apple 框架的 target 中，保证能在 Linux 上编译和测试：URL 识别、解析、任务状态机、重试策略、历史记录。依赖 AVFoundation / ImageIO / CoreGraphics 的工具放在 `#if canImport(...)` 后面，或者放进单独的 Apple target。
- 传输层：Core 里的 `HTTPTransport` 会拒绝重定向，适合 API 调用，不适合下载 CDN 文件。媒体模块要自己定义下载用的传输协议，生产实现用 `URLSession` 下载任务，测试用假实现。生产实现**不能**在测试或 CI 中连接真实网站。
- 文件只保存在 App 沙盒内（Documents 或 Caches 下的专用目录）。保存到相册由界面层在用户操作后完成，不在模块里做。

## 3. 接口约定（P0，先交文档，审核后再实现）

下面是 Claude 的建议草案，Codex 可以调整，但 `MEDIA_INTERFACES.md` 里必须写清每个公开类型的含义、线程或 actor 隔离、错误和取消语义：

```swift
public enum MediaSource: String, Sendable, CaseIterable { case bilibili, x, pixiv, direct }

public struct MediaVariant: Sendable, Hashable {
    public enum Kind: Sendable { case image, video, audio, ugoira }
    public let kind: Kind
    public let qualityLabel: String        // 例如 "1080P"、"原图"
    public let width: Int?, height: Int?
    public let estimatedBytes: Int64?
    public let fileExtension: String
}

public struct MediaItem: Sendable, Identifiable {
    public let id: String                  // 站点内唯一 ID
    public let source: MediaSource
    public let title: String
    public let variants: [MediaVariant]
}

/// 按网址把链接分派给对应站点的解析器；无法识别时抛 unsupportedSource。
public struct LinkRouter: Sendable {
    public init(resolvers: [any MediaResolver])
    public func source(for url: URL) -> MediaSource?
    public func resolve(_ url: URL) async throws(MediaError) -> [MediaItem]
}

public protocol MediaResolver: Sendable {
    func canResolve(_ url: URL) -> Bool
    func resolve(_ url: URL) async throws(MediaError) -> [MediaItem]
}

public enum DownloadState: Sendable, Equatable {
    case queued(position: Int), resolving, running(fraction: Double?), completed(fileName: String), failed(MediaError), cancelled
}

/// 先进先出、一次只运行一个任务（maxConcurrent = 1）。
public actor DownloadManager {
    public func enqueue(link: URL) -> DownloadID                    // 自动识别 → 解析 → 下载，整体排队
    public func enqueue(_ item: MediaItem, variant: MediaVariant) -> DownloadID
    public func cancel(_ id: DownloadID)
    public func retry(_ id: DownloadID)
    public var updates: AsyncStream<[DownloadSnapshot]> { get }   // 给界面订阅
    public func history() -> [DownloadRecord]
    public func clearHistory()
}

public enum MediaError: Error, Sendable, Equatable {
    case invalidURL, unsupportedSource, notFound, requiresLogin, rateLimited,
         network, storageFull, parsingChanged, unsupportedFormat, cancelled
}

// P2 本地工具
public enum StitchLayout: Sendable { case vertical, horizontal, grid(columns: Int) }
public func stitchImages(_ images: [Data], layout: StitchLayout, spacing: Int) async throws -> Data
public func makeGIF(fromVideo url: URL, start: Double, duration: Double, fps: Int, maxWidth: Int) async throws -> URL
public enum FingerprintMethod: Sendable { case reencode, stripMetadata, subtlePixelNoise }
public func rewriteFingerprint(_ image: Data, method: FingerprintMethod) throws -> Data   // 不修改原文件
```

界面需要的信息，接口里必须能拿到：
- 每个任务的进度和状态；
- 面向用户的错误分类：需要登录、被限流、解析失效、存储空间不足；
- 取消必须立即生效；
- 历史记录可以清空。

## 4. 测试要求

- **CI 中不联网**。站点解析用保存好的离线样例（HTML / JSON 片段）放在测试资源里。样例必须去除个人信息：不含账号、Cookie、Token、个人主页内容，用公开、无争议的示例内容。
- 真实联网测试单独标记，默认关闭，沿用现有的 `AIUTILITY_LIVE_TESTS=1` 开关，并在汇报中说明。
- P1 至少覆盖：链接识别（各站点的典型网址、短链、带参数网址、无法识别的网址）、先进先出顺序、任意时刻最多一个任务在运行、取消（排队中和下载中）、重试次数与退避、失败后重试、进度单调递增、重复入队、历史记录持久化与清空、任务完成前 App 被终止后的恢复策略（说明即可）。
- P2：拼接尺寸和顺序、GIF 帧数与时长、指纹改写后原文件字节不变、元数据确实被移除。
- 不删除或弱化现有测试。Core 现有 36 项测试保持通过。

## 5. 合规与安全边界

- 只处理公开可访问的内容。**不绕过**登录、付费、会员限制、DRM、地区限制或频率限制；遇到这些情况时返回对应的 `MediaError`，不要尝试规避。
- 只使用官方公开文档化的接口，或网页本身公开提供的数据。如果某个站点必须依赖未公开的私有接口、抓取的令牌或模拟登录才能下载，**停下来向用户报告**，由用户决定要不要做、怎么做。
- 每个站点设置请求频率上限和合理的超时时间；使用通用的 User-Agent，不伪装成特定用户。
- Pixiv 原图和 Ugoira 通常需要登录：本任务先实现"需要登录时返回 `requiresLogin`"。登录方式和凭据保存（只能放 Keychain）由用户另行决定。
- B站视频通常是音视频分离的 DASH 流，合并需要 AVFoundation 处理。可以作为 P3 中单独的一步，先确认可行性再实现。
- 不收集遥测，不上传用户文件，不在日志中输出 URL 里的令牌参数。
- 下载内容的版权责任在用户；界面会提示"仅用于个人保存"，模块本身不需要处理。

## 6. 不在本任务范围内

- App 界面和接线（Claude Code 负责）。
- `PoCs/iOS27Capture`（未经授权双方都不修改）。
- `.github/workflows` 的修改（提出需求，不直接改）。
- 合并任何分支到 main，或把 Claude 分支的新提交拉进来（需用户授权）。

## 7. 汇报格式

每个阶段完成后按 `AGENTS.md` 汇报「已完成 / 正在做 / 未完成」，并附上：

- 提交 SHA（UTC 时间）、新增或修改的文件列表；
- 公开接口的变化（新增、改名、删除）；
- 测试数量与结果（每个平台分别列出）；
- 需要用户决定的问题（例如某站点只能走私有接口、需要登录）；
- 需要 Claude 配合的事项（例如 CI 需要新增测试步骤、界面需要的新字段）。

## 8. 验收清单

- [ ] P0：`MEDIA_INTERFACES.md` 经用户审核通过
- [ ] P1：下载任务管理测试全部通过，可在 Linux 上运行
- [ ] P2：本地工具测试在 macOS 上通过
- [ ] P3：每个站点的离线样例测试通过；不支持的情况返回明确错误
- [ ] P4：SauceNAO 离线样例测试通过，真实调用默认关闭
- [ ] 推送前检查 PASS，所有提交为 UTC 时间、占位作者
- [ ] 一次完整 CI（用户同意后触发）通过
