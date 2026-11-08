# 媒体模块接口约定（P0 已审核，P1 修复后 Linux 45 项通过）

记录日期：2026-11-08。依据：用户指定的
`origin/claude/ecstatic-planck-rzpvn6:TASK_MEDIA_MODULES.md`，读取版本 `a01e814`。
本轮按 `origin/claude/ecstatic-planck-rzpvn6:MEDIA_INTERFACES_REVIEW.md`
（读取版本 `b44ae48`）第 3 节 R1–R5 修订。审核意见原则认可原草案，但**不等于用户已授权进入 P1**。
再按同一审核文件 `e3526f5` 的第 3b 节 R6 拆分通用选择与站点选项；仍只修订文档，等待用户授权。
以上为 P0 修订过程记录。用户现已审核通过 `28c449d`，明确授权进入 P1，并要求触发 CI 前另行确认。
最初版本已在授权的 Linux CI 完成真实 Swift 6.0.3 编译与 42 项离线测试（全通过），
历史证据见 [验证报告](validation/media-p1/README.md)。**当前修复后的 Apple SDK、真实网络传输与 App 接线尚未验证**。
后续 Apple 源码 1ac37c8 的编译/两种 SDK 成功，但 Mac 测试 33 失败；已仅修复 Media 存储路径并新增 3 项回归。
当前修复 99b0d86 / 验证 HEAD 334cfde 的 Linux 45 项全通过，Mac/SDK 修复后未复验；
以 [Apple 验证交接](validation/media-apple/README.md) 区分版本，不把早期 SDK 编译当作修复已验证。
P1 源码/边界及交给 Claude 的验证命令见 [包说明](Packages/AIUtilityMedia/README.md)；P2–P4 契约仍是后续范围。

## 1. 范围与模块边界

| 阶段 | 后续交付 | 当前状态 |
|---|---|---|
| P0 | 本接口文档 | 用户已审核通过 28c449d |
| P1 | 自动链接路由、FIFO 单任务下载、进度/取消/从头重试、限流/去重、队列与历史原子持久化、删除文件 | Linux 45 项通过；修复后 macOS 测试与两种 iOS SDK 构建通过（run 42466209488）；真实网络未验证，不含断点续传 |
| P1b | 同一次运行内及跨重启的 Range / If-Range 断点续传、.part 续接校验 | 移出 P1；P1 后单独审核、授权 |
| P2 | 多图拼接、视频转 GIF、图片文件指纹 | 已实现于 `AIUtilityMediaApple`（Claude Code 接手后），待 macOS 测试与 iOS SDK 编译验证；未接入 App 界面 |
| P3 | B站、X、Pixiv 原图及 Ugoira；Ugoira 默认 GIF，依赖 P2；三个站点各自提交，不分优先级 | 三个解析器已实现，只用离线样例测试；未对真实站点验证，默认不注册（`DownloadConfiguration(sites:)` 显式开启）；Ugoira 在本机组装为 GIF |
| P4 | SauceNAO 反向搜图 | `SauceNAOProvider` 已实现，只用离线样例测试；真实调用只在 App 中由用户发起，尚未联网验证 |

搜图 Bot 酱仍属于既定产品范围；本轮 P4 只冻结 SauceNAO 的扩展入口，不虚构 Bot 酱的可调用接口。
统一下载任务与历史、截图翻译、实时字幕及既定前端方向均不删除。本阶段不改 UI、PoC 或 workflow。

已创建 `Packages/AIUtilityMedia`：声明 iOS 17+、macOS 14+、Swift 6 语言模式；Linux 严格并发编译已通过，Apple 兼容性仍待验证。

- `AIUtilityMedia` target：Foundation 值类型、URL 路由、解析契约、队列、网络策略、持久化；Linux 可编译测试。
- P2 拟建 `AIUtilityMediaApple` target：AVFoundation / ImageIO / CoreGraphics，承载本地处理及后续媒体组装。
  Apple 实现用条件编译隔离；不在 Linux 返回空文件或假成功。
- 不改 `AIUtilityCore` / `AIUtilityAppleServices` 的公共 API，不把媒体能力加进 `AIUtilityServices`。
  Claude 可在 AppModel 中另持有媒体模块实例。媒体模块不复用 Core 的拒绝重定向 HTTPTransport。
- Core 的 DeepSeek / Anthropic / OpenAI 单供应商单 Key、截图/字幕共享 Key 及独立模型绑定保持不变。
  下载器不索取这些 AI Key；SauceNAO 的独立凭据不得混入 AI 配置。

## 2. 公共接口总则

以下 Swift 片段为契约摘要，P1 实际源码已通过 Linux 编译，P2–P4 不代表已有实现；Apple SDK 未验证。
表中列出未展开的值类型字段；需要校验输入的公开构造器须验证参数，
失败统一为 `MediaError.invalidInput`，不能依靠调用方保证长度、有限数值或沙盒路径安全。

- 值类型均为 Sendable；ID、状态和记录快照不可变，需要存储/比较的类型另遵循 Codable / Equatable 或 Hashable。
  SiteOptions 及其站点配置是可编辑值，入队时复制为任务独立快照；后续设置修改不改变已排队任务。
- 可异步操作统一 `throws(MediaError)`；边界将 CancellationError / URLError / NSError 映射成安全分类。
  不返回原始响应体、Cookie、授权头、带令牌 URL 或任意服务端错误文本。
- `DownloadManager` actor 是唯一任务所有者；同一存储命名空间只创建一个实例。本版本不承诺跨进程调度锁。
- 所有解析、短链展开、元数据请求、下载、自动重试及下载所必需的组装共用一个活动槽，**maxConcurrent 固定为 1**。
  一个任务内的多个文件、DASH 音视频轨也串行传输，禁止在解析器内部启动游离网络 Task。
- Apple 图像/视频处理不运行在 MainActor；回调为 `@Sendable`，不保证主线程，UI 更新由 Claude 显式回 MainActor。
- 不收集遥测；除用户明确发起的 P4 单图搜图请求外，不上传用户文件。诊断只保留安全错误分类和非敏感计数。
- 本文件出现的单调进度、提交点、取消确认与错误保留都是后续实现/测试要求，不能用文档存在代替验证。

## 3. 媒体描述与临时下载计划

```swift
public enum MediaSource: String, Codable, Sendable, CaseIterable {
    case bilibili, x, pixiv, direct
}

public struct MediaItemID: Codable, Sendable, Hashable {
    public let source: MediaSource
    public let value: String
}

public struct MediaVariant: Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case image, video, audio, ugoira }
    public let id: String
    public let kind: Kind
    public let qualityLabel: String
    public let width: Int?
    public let height: Int?
    public let estimatedBytes: Int64?
    public let fileExtension: String
    public let requiresAssembly: Bool
}

public struct MediaItem: Sendable, Identifiable {
    public let id: MediaItemID
    public let title: String
    public let variants: [MediaVariant]
}

public enum MediaSelection: Sendable, Hashable, Codable {
    case automatic
    case variant(itemID: MediaItemID, variantID: String)
}

public struct SiteOptions: Sendable, Hashable, Codable {
    public var bilibili: BilibiliOptions
    public var pixiv: PixivOptions
    public init(bilibili: BilibiliOptions = .init(), pixiv: PixivOptions = .init())
}

public struct BilibiliOptions: Sendable, Hashable, Codable {
    public var allParts: Bool
    public init(allParts: Bool = false)
}

public struct PixivOptions: Sendable, Hashable, Codable {
    public var keepUgoiraArchive: Bool
    public init(keepUgoiraArchive: Bool = false)
}
```

| 类型 / 字段 | 含义、隔离及失败语义 |
|---|---|
| MediaSource | 来源分类，不代表该站点已实现下载；没有注册真实解析器时仍返回 unsupportedSource |
| MediaItemID | 来源 + 站点稳定内容 ID；多页内容须包含页/附件身份，避免跨站或分 P 冲突。直链使用稳定资源摘要，不用 Swift.Hasher 做持久化身份 |
| MediaVariant | 同一 item 的可选交付形式；id 须区分清晰度、格式与轨道组合，不能仅以 qualityLabel 当 ID |
| qualityLabel / title | 仅用于展示，限制长度/控制字符；不作为身份、不写日志，不自动作为磁盘路径 |
| width / height / estimatedBytes | 未知为 nil；正值且有上限。estimatedBytes 仅估计，不能冒充准确进度分母 |
| fileExtension | 输出建议扩展名，白名单验证，不接受路径、分隔符或任意服务端文件名 |
| requiresAssembly | 表示下载完还需处理；不能把原始分离轨直接标为已完成的 MP4 |
| MediaSelection | 通用清晰度/格式选择：仅 automatic / variant(itemID:variantID:)；variant 必须重新验证属于该 item。与 SiteOptions 正交，可同时指定变体和站点行为 |
| SiteOptions | Sendable/Hashable/Codable 可编辑值，包含默认初始化的 bilibili/pixiv；入队冻结副本，不持有 actor、凭据或链接 |
| BilibiliOptions | allParts 默认 false：链接指定分 P，否则第一 P；true 表示请求当前作品全部分 P，仅对 B站生效 |
| PixivOptions | keepUgoiraArchive 默认 false：Ugoira 只交付 GIF；true 额外保留原始归档和时序清单，仅对 Pixiv Ugoira 生效 |
| MediaTransferPlan | 临时 Sendable 计划：item/variant 身份、规范化后的生效选项、按序 components、assembly、可信大小/校验信息；不 Codable，不进入 UI 快照或历史 |
| MediaComponent | P1 为唯一组件 ID + 脱敏临时 URL；后续 P3 再加入文件/视频轨/音频轨/动画归档/时序元数据角色和所需请求字段。顺序下载，不自行派生并行任务 |
| MediaAssembly | 拟议枚举：passthrough / muxAudioVideo / ugoiraToGIF(keepOriginalArchive: Bool)；标明最终输出列表，不将组装留给 UI 猜测 |
| UgoiraFrame | 帧文件名和正的 delayMilliseconds；必须保留顺序/时长并验证归档内文件存在，禁止路径穿越及无限解压 |

MediaTransferPlan / MediaComponent 的真实 URL、请求头、签名参数只在当前操作内存存在；description、debugDescription、
Mirror 需要脱敏。不能把整个计划序列化为历史，也不承诺 Swift String/Data 内存能完全清零。

**已审核的默认选择规则：** 只处理当前作品直接关联的媒体，不展开作者主页、推荐流或播放列表。
B站仅显式指定页、未指定时首页；同一 X 帖子或 Pixiv 作品的直接媒体可形成一个有界多文件任务。
优先原图/最高公开可获取且当前平台能正确交付的变体；不选择会员或需额外权限的清晰度。
达到资源数量上限时返回 resourceLimitExceeded，不静默截断。P1 先支持真实直链，三站点能力在 P3 审核验证后注册。

`options.bilibili.allParts=true` 预留全部分 P 的表达方式，覆盖该作品全部分 P，不展开推荐或合集；P3 可只实现默认单 P。
对 B站，capabilities.supportsAllBilibiliParts=false 时请求 allParts=true 返回 unsupportedFormat，不能悄悄只下载第一 P。
它可以与 selection.variant 同时传入；全部分 P 的跨页变体映射、解析契约、资源上限及测试在实现该能力前补充审核，
不能把某一页的 variantID 未经校验强加给所有分 P。

P2 GIF 编码能力完成后，P3 Ugoira **默认自动按原帧时序转为 GIF**，而非以归档代替动画交付。
automatic 与 Ugoira 的 variant 选择都使用 options.pixiv.keepUgoiraArchive，默认 false；
设为 true 则额外交付原始归档 + 完整帧时序清单，三者共用该任务输出清单。
MediaAssembly.ugoiraToGIF(keepOriginalArchive:) 的参数由该生效选项决定，不由通用选择枚举携带。
转码是该任务的组装步骤，占用同一活动槽；在 GIF 完成、校验并提交前不能发布 completed。
P2 编码器缺失、平台不支持或无法正确表达原帧时序时明确失败，不能回退为归档并声称默认交付成功。
不得把不同 delayMilliseconds 统一为 fps；对 Ugoira 生效的原件保留选项纳入去重键，不能与仅 GIF 的任务误判重复。
automatic/variant 如最终选择相同内容、变体和生效选项，应归一为同一去重身份，不能重复下载。
DASH 计划包含视频/音频和显式 mux：Apple 组装器只接受本地文件；不可用时返回 unsupportedPlatform/unsupportedFormat，
不假装 Linux 已合并，不悄悄降级为无声视频。原始分轨交付如需开放，必须由用户明确选择。

**站点选项的作用域、持久化及扩展：**

- 不相关站点的选项忽略、不报错：X/直链忽略 bilibili/pixiv；B站忽略 pixiv；Pixiv 忽略 bilibili，
  非 Ugoira 的 Pixiv 原图也忽略 keepUgoiraArchive。不相关选项不改变状态、输出或去重身份。
  仅当选项对当前来源/内容有效却无法满足时才报告相应错误；通用 variant 的身份不匹配仍为 invalidSelection。
- 以最终解析来源和内容类型规范化生效选项。短链重路由前不能凭候选域名丢弃原始选项；
  解析完成后只把生效字段传入组装决策及去重键，不把完整 SiteOptions 的 Hashable 值直接当去重键。
- 队列原子持久化 MediaSelection 和 SiteOptions 的任务副本；恢复/重试沿用入队值，不受之后的默认设置变化影响。
  App 可单独 Codable 保存“默认下载选项”，然后在 enqueue 时显式传入；参数 .init() 表示固定默认值，不暗读 App 设置。
  历史只可保存生效选项摘要，不保存任何链接、临时请求或凭据。
- 新选项在对应站点 Options 中新增带默认值的字段；新站点按需增加自己的 Options，不扩充 MediaSelection 的 case。
  解码旧设置/队列时缺失的新字段采用默认值；不能只依靠合成 Codable 自动获得该兼容性，后续实现须有迁移测试。

## 4. LinkRouter 与解析器

```swift
public struct LinkRouter: Sendable {
    public init(resolvers: [any MediaResolver])
    public func source(for url: URL) -> MediaSource?
    public func resolve(_ url: URL) async throws(MediaError) -> [MediaItem]
    public func prepare(item: MediaItem, variantID: String, options: SiteOptions = .init())
        async throws(MediaError) -> MediaTransferPlan
}

public protocol MediaResolver: Sendable {
    var source: MediaSource { get }
    func canResolve(_ url: URL) -> Bool
    func resolve(_ url: URL) async throws(MediaError) -> [MediaItem]
    func prepare(item: MediaItem, variantID: String, options: SiteOptions)
        async throws(MediaError) -> MediaTransferPlan
}
```

- `source(for:)` / `canResolve` 是纯逻辑，不联网、不读文件、不创建任务；source 返回已识别来源或直链候选。
  普通 HTTPS 候选不等于媒体可下载，必须在 resolve 中核验类型；HTML 页面不能被当成视频文件成功保存。
- 按标准 URL 的 host/path 识别，不对整段 URL 做子串搜索。主机大小写/默认端口可规范化；不盲目改变路径和语义参数。
  站点域名和子域名使用显式注册表；相似域名、域名后再拼额外后缀不算原站点。
- 建议默认只接受 HTTPS，拒绝 userinfo、空主机、file/data/自定义 scheme、显式回环/私网目标。
  本地工具的沙盒 file URL 不走 LinkRouter。HTTP 支持若需要，须另行审核。
- 短链不能只按后缀猜最终来源：进入队列后有界展开、检查每次跳转，再按最终 host/path 重新路由。
  生产短链域名白名单在 P3 官方资料/公开样例核对前不宣称支持；P1 用受控假传输验证重路由及拒绝行为。
- 无合法候选或最终内容不支持为 unsupportedSource；明确登录页为 requiresLogin；公开数据结构失配为 parsingChanged。
  不以空数组、假标题或占位计划冒充解析成功，成功至少有一个合法 item/variant。
- resolve/prepare 的取消须向 HTTP 层传播，确认退出后抛 cancelled；过期回调不可交付计划。
- prepare 按来源稳定 ID 重新验证/取得临时计划；不能要求 UI 保留隐藏的网络请求上下文。
  如解析器内部缓存临时地址，缓存须由 actor 隔离且受有效期限制，不进入历史或日志。
  manager 将入队冻结的 options 显式传到 prepare，解析器仅使用其来源/内容相关字段生成组装计划。
- 这些低层接口供依赖装配和测试。**生产 UI 只向 DownloadManager 入队**；不得在入队前自行调用 resolve 形成队列外网络活动。

## 5. 下载身份、状态、进度与订阅

```swift
public struct DownloadID: Codable, Sendable, Hashable {
    public let rawValue: UUID
}

public enum DownloadState: Sendable, Equatable {
    case queued(position: Int)
    case resolving
    case running(DownloadProgress)
    case waitingToRetry(attempt: Int, delay: TimeInterval)
    case processing(DownloadProgress)
    case committing
    case cancelling
    case interrupted
    case completed(files: [DownloadedFile])
    case duplicate(existing: DownloadID)
    case deletionIncomplete(remainingFiles: [DownloadedFile])
    case failed(MediaError)
    case cancelled
}
```

| 公共类型 | 字段及契约（均为 Sendable 值） |
|---|---|
| DownloadProgress | attemptID、phase、bytesWritten、totalBytes?、fraction?；整数非负，已知比例在 0...1，不使用 NaN/Infinity |
| DownloadSnapshot | id、source?、安全展示标题、state、attemptID、状态序号 revision、创建/更新时间、已确定时的生效选项摘要；不含临时请求或凭据，不相关选项不改变状态 |
| DownloadQueueSnapshot | revision、按实际顺序排列的 tasks、activeID?、blockingError?；每次是完整快照，不是单一进度事件 |
| DownloadedFile | 文件 ID、安全 fileName、沙盒相对位置、实际字节、媒体种类、可选 fileIdentity（实际下载的 inode 校验值）；Codable/Hashable。文件 URL 按需解析，不持久化绝对主目录 |
| DownloadRecord | id、安全来源身份/展示信息、最终状态、attempt 摘要、生效选项摘要、输出引用及时间；Codable，不能含任何链接、Cookie、授权头或 resumeData |
| EnqueueReceipt | id + disposition：created / alreadyQueued / alreadyCompleted / retryRequired。UI 据此提示，不能只返回 ID 隐藏重复情况 |
| CancelResult | accepted / alreadyTerminal / tooLate / notFound；accepted 只代表取消请求已生效，不声称系统资源已释放 |
| DownloadCapabilities | 实际可下载的 sources、支持的组装/本地工具能力、supportsDownloadResume、supportsAllBilibiliParts；P1 续传为 false，未实现的全部分 P 为 false，不以预留签名宣称支持 |
| DeleteResult | Sendable/Equatable 值：任务 id、deleted（本次实际删除的文件）、alreadyMissing（原已缺失）、failed（FileDeletionFailure 列表）；全部已移除或缺失且记录提交成功才算全部删除 |
| FileDeletionFailure | Sendable/Equatable 值：文件 ID + 安全 MediaError；没有绝对路径或底层错误文本。因取消而未尝试的文件用 cancelled 分类 |

queued(position:) 从 1 开始，仅计等待项；无活动任务时队首也先完成持久化再启动。
DownloadProgress 与 DownloadedFile 须符合 Equatable，保证 DownloadState 的比较契约；时间使用可持久化的时间值。

**进度口径：** 同一 attemptID、同一阶段内 bytesWritten 与已知 fraction 单调不减。
估计大小不作分母；总长度不可信或未齐时 fraction=nil，UI 显示字节/活动状态。
P1 每次自动/手动重试都从头开始并产生新 attemptID；断开前字节不拼接到新尝试。
P1b 经单独审核后才允许续传；服务器拒绝续传而需从头传输时也必须新建 attemptID，明确重置，不用高水位伪装已保留字节。
手动重试也产生新 attemptID。下载字节完成仍不代表组装/提交完成，只有 completed 才是任务成功。
因此“全生命周期百分比永不下降”不作承诺；此项口径需用户审核后冻结。

## 6. DownloadManager（UI 主入口）

```swift
public actor DownloadManager {
    public init(configuration: DownloadConfiguration) async throws(MediaError)
    public func capabilities() -> DownloadCapabilities
    public func enqueue(link: URL, selection: MediaSelection = .automatic,
                        options: SiteOptions = .init())
        async throws(MediaError) -> EnqueueReceipt
    public func enqueue(_ item: MediaItem, variant: MediaVariant, options: SiteOptions = .init())
        async throws(MediaError) -> EnqueueReceipt
    public func cancel(_ id: DownloadID) -> CancelResult
    public func retry(_ id: DownloadID) async throws(MediaError)
    public func retryCleanup(_ id: DownloadID) async throws(MediaError)
    public func updates() -> AsyncStream<DownloadQueueSnapshot>
    public func history() async throws(MediaError) -> [DownloadRecord]
    public func clearHistory() async throws(MediaError)
    public func deleteFiles(for id: DownloadID) async throws(MediaError) -> DeleteResult
    public func fileURL(for file: DownloadedFile) async throws(MediaError) -> URL
    public func shutdown() async throws(MediaError)
}
```

外部访问 actor 仍须 await，即使成员签名未写 async。初始化执行存储恢复，失败不返回半初始化管理器。
App 启动时显示“媒体模块加载中”；初始化错误按 storageUnavailable 等分类显示，并允许用户重试。
失败/取消路径须释放本次持有的资源、撤销未发布观察者及任务，不能残留锁或半写入配置；
恢复写入采用原子替换，失败后旧可读状态保留。调用方可对同一命名空间安全地重新创建实例，
无需手工删除文件或重启 App；不存在两个成功实例同时持有同一命名空间的承诺。
DownloadConfiguration 指定受验证的沙盒根、有限 DownloadPolicy、真实能力装配；测试依赖通过模块内测试入口注入，
不在生产构造器默认注册 Mock 或未实现站点。
两者均为 Sendable 配置值：前者包含存储命名空间、沙盒根、策略及解析器注册；后者包含第 7 节所有有限限额与重试规则。
无效根目录/限额在初始化时失败；文件系统访问失败归 storageUnavailable，不把权限错误当 invalidInput。

| 操作 | 线程、错误与取消边界 |
|---|---|
| enqueue | actor 复制 selection/options、分配递增入队序号，顺序不按站点或方法返回快慢重排。排队信息持久化成功才回 created；失败不偷偷开始下载 |
| enqueue(item,variant) | 同一条队列、同一活动槽，复制 options 并重新校验身份/变体，不信任外部构造的描述；不能绕过解析限流 |
| cancel | 当前 actor turn 设置取消标志、发布 queued→cancelled 或 active→cancelling，并取消工作 Task，不等待网络 I/O 才更新 UI |
| retry | 只允许 failed/cancelled/interrupted，或确认输出缺失的旧 completed；不允许活动任务或正在删除的任务重试。复用任务 ID、新 attemptID，加入队尾，重新解析临时地址；P1 始终从头下载 |
| retryCleanup | 仅重试已阻塞的清理，不重新解析或下载；失败继续报告 cleanupFailed 并保留阻塞状态 |
| updates | 每次调用创建独立订阅，立即交付当前完整快照，之后广播；bufferingNewest(1) 合并高频进度。取消订阅不取消任务，结束订阅须移除观察者 |
| history | 读取已提交的持久化记录，稳定排序；失败抛 storageUnavailable，不伪造空历史 |
| clearHistory | 只清除终态记录及其去重索引，不取消活动/排队任务，也不删除下载文件；写入失败保持旧历史。返回后后续快照不可重新出现旧记录 |
| deleteFiles | 只删除指定任务已提交且由模块拥有的输出及相应记录；排队/活动/取消清理/提交中的任务返回 invalidState。返回每文件真实结果，不能把部分失败报告为全部删除；详见下节 |
| fileURL | 校验文件仍存在、相对路径未穿越且位于授权沙盒；丢失为 outputMissing；不能返回站点文件名拼成的任意 URL |
| shutdown | 不再接收新任务，取消/等待清理，持久化队列并关闭订阅；清理失败须返回错误，不宣布已关闭 |

### FIFO、重复与“立即取消”

- 入队和解析都在全局 FIFO 中，运行时没有第二条隐藏的解析队列。一次只运行一个任务，包括其重试等待与后处理。
  自动退避会阻塞队首，但不让后来的任务悄悄超车；用户可取消队首，清理后调度下一项。
- 初版不提供排队重排，保留后续扩展；如以后加入，只能移动尚未运行的任务，且是显式用户操作。
- 相同规范化链接、通用选择及对实际来源/内容生效的选项重复入队，返回原 ID + 已排队/已完成提示，不创建新下载。
  不盲删 query：签名/资源语义参数必须保留在临时请求，只有经核对的跟踪参数可忽略。
  不相关选项差异不参与去重；生效选项不同则视为不同任务，例如 B站单 P/全部分 P、Ugoira 仅 GIF/保留原件。
  短链等最终来源未知时保留选项到解析完成，再判断生效字段，不能错误合并本应不同的交付。
- 短链等别名需要到队首解析后才能确定相同内容：若与已有任务的内容、变体及生效选项完全相同，终态 duplicate(existing:)；
  不再传输、不冒充新完成文件。部分重叠媒体的逐文件去重不在 P1 保证内。
- 不同明确变体或不同生效站点选项属于不同下载选择；DownloadState.duplicate(existing:) 仅用于规范化身份完全一致。
  输出已丢失不能返回 alreadyCompleted，须提示 retryRequired。
  clearHistory 后该记录的去重证据一并删除，再次添加可成为新任务；不保留隐形私人历史。
- **立即取消是逻辑立即可见，不是承诺系统零毫秒停止。** 下一个任务须等待传输确认退出、文件句柄关闭、清理确认；
  确认后无额外队列退避立即调度，但仍服从站点冷却时间。绝不能提前放行造成两次真实下载并行。
- 取消期间清理超时/失败：保持 cancelling + blockingError=cleanupFailed，保留句柄，不启动下一项；等待显式清理重试或退出。
  不能显示 cancelled 后仍让旧回调写盘，也不能以 Task.cancel() 被调用作为释放确认。
- 每次执行都有 generation；旧传输、解析、进度、存储回调均须匹配 ID/generation，不能改新 attempt 或新队列。

### 提交点、历史与重启

建议持久化介质为沙盒内带 schemaVersion/revision 的原子清单与小型提交日志；P1 冻结具体格式，不引入数据库承诺。
仓储串行化写入并拒绝旧 revision，避免 actor 在 await 期间发生旧快照覆盖。

- 网络写入专用 .part，不对外发布；验证完成后进入 committing。进入该状态前同一 actor turn 最后检查取消并冻结提交。
  committing 以后取消返回 tooLate，等待真实提交结果；成功后 cancelled 不能逆转 completed。
- 文件与历史不宣称操作系统跨文件原子事务。记录 prepared → 发布完整输出目录 → 提交历史；有提交日志供重启恢复。
  未提交的文件不可分享，崩溃后按日志清理或完成恢复，不把孤立 .part 标为 completed。
- pending FIFO 与已提交历史保存在 Documents 专用目录；临时 .part 在 Caches，允许系统清理。
  P1 的 .part 仅供当前尝试暂存，不做同进程重试续接或跨重启恢复；确认旧写入停止后清理再开始新尝试。
- 重启后未开始队列保持顺序；原运行项变 interrupted，等待用户 retry，入队尾后重新获取公开下载计划并从零下载，不自动重放请求。
- 已验证安全来源 ID 可持久化，完整签名链接/凭据和系统 opaque resumeData 不落历史。
  若直链无法保留无敏感信息的恢复地址，则报告需要重新提供链接，不能伪装可跨重启续传。

### 删除文件、部分失败与历史清空

- deleteFiles 在 manager actor 隔离下预留该任务的删除操作，拒绝同 ID 的并发删除/retry；不影响其他任务输出。
  不把网络取消接口当文件删除；不存在的任务/文件归属记录返回 notFound，不接受任意外部路径。
  与 clearHistory 共用 revision/仓储写入顺序；清空后延迟到达的删除结果只能更新文件归属，不能恢复历史。
- 只处理已提交输出，校验相对路径、沙盒归属和文件身份；不递归删除用户目录、不删输入或其他任务共用文件。
  已缺失的输出归 alreadyMissing；实际删掉的归 deleted；每个失败/未尝试输出逐一进入 failed。
- 全部输出已移除/缺失后删除任务记录及去重索引；再次加入同一链接是新任务。
  部分删除则发布 deletionIncomplete，保留剩余文件与失败信息以便重试删除，同时移除原任务的去重证据；
  不继续显示完整 completed，也不重新下载已经删除的文件。部分删除不支持 download retry，用户可新建下载任务。
- 文件删除不能回滚为完整旧文件。开始前持久化删除意图，逐项记录结果；元数据写入失败抛 storageUnavailable，
  保留恢复依据，重启核实实际文件后再修复记录，不谎称磁盘回滚。删除期间的旧回调不得复活旧记录/去重证据。
- 取消删除在文件间安全点确认；尚未尝试项以 cancelled 记入 DeleteResult.failed，完成结果记录后返回部分结果。
  尚未开始删除时可直接抛 cancelled。任何情况下都不能宣称已删除失败项。
- clearHistory 仍只清记录，不删文件。为清空后还能用已知 DownloadID 删除遗留输出，仅保留最小文件归属清单
  （ID、沙盒相对文件引用、必要的删除恢复信息），不保留来源链接、标题、站点内容身份或去重证据，
  不通过 history/updates 重新展示旧任务。deleteFiles 对已清空历史的任务仅操作此清单，不重建历史记录；
  UI 可在清空前组合调用删除接口。不新增“清空全部下载文件”接口。

## 7. 媒体专用传输、限额与 P1b 续传预留

以下是**模块内部依赖契约**，不作为 App 公共 API；P1 用可注入假传输/假时钟/仓储做离线测试。

| 内部边界 | 职责及错误/取消 |
|---|---|
| MediaHTTPClient | 有界 HTML/JSON/短链元数据请求，和下载共用网络策略；取消确认后返回 cancelled，响应超限为 resourceLimitExceeded |
| MediaDownloadTransport | URLSession 下载任务流式写入授权 staging 文件，报告安全计数；不把整段视频收进 Data；取消返回前确认 I/O 已终止 |
| MediaFileStore | 只管理沙盒路径、staging、校验、无覆盖发布、清理；storageFull 与 storageUnavailable 分开；清理失败不能吞掉 |
| DownloadRepository | 队列/历史、schema/revision、提交日志和恢复；原子更新失败保留旧可读快照；无原始签名请求 |
| MediaClock | 可替换单调时钟/退避等待，取消中断 sleep；测试不真实等待或联网 |
| MediaAssembler | P3 Apple 后处理入口，仅本地输入；无实现/不支持则明确失败，不能让 AVFoundation 在队列外自动拉远端文件 |

DownloadPolicy 是 Sendable 不可变配置，建议初值：单活动槽 1（不可提升）、每来源最小间隔 2 秒、
单请求/无数据超时 30 秒、单运行任务总时限 30 分钟、重定向最多 5 跳、最多自动重试 2 次（合计 3 次尝试）、
元数据最多 4 MiB、单任务最多 64 个输出。文件字节/磁盘及解包上限必须有限并显式配置；这些不是已真机验证的性能值。

- 仅对明确瞬态网络错误、超时及允许的暂时性 HTTP 状态有限重试；建议状态为 429/503/504。
  退避 1、2 秒起并有封顶；Retry-After 与来源间隔取更保守值，超过总时限则停止并报告，不绕过限流。
- 权限/登录/地区/会员/DRM、解析失效、格式不支持、完整性错误、磁盘不足和用户取消不自动重试。
  手动 retry 也不承诺能解决这些限制。按来源计请求预算；直链按目标主机，CDN 跳转不重置原站点预算。
- 重定向每跳重新验证 HTTPS、目标和跳数，禁止循环/降级；跨 origin 丢弃授权头、Cookie 等敏感字段。
  生产不自动读系统 Cookie/凭据库；普通 User-Agent，不模拟用户身份。
- 对显式私网/本机地址和解析结果做有限目标检查；不能把字符串域名检查宣称为完整 DNS 重绑定防护。
  若 URLSession 无法满足所选目标约束，P1 须先报告限制，不跳过检查假装安全。
**P1 不实现以下续传路径：** 网络中断视为当前尝试失败，只在有限自动重试规则允许时从零开始；
不发 Range / If-Range、不追加旧 .part、不解码系统 resumeData，capabilities.supportsDownloadResume=false。
同次运行续接和跨重启续接均属于 **P1b，P1 之后单独审核**。以下仅保留后续设计约束：

- P1b 续传仅在服务端支持且资源身份/强校验器一致时发 Range + If-Range：206 必须起止范围吻合；200 表示从头开始，
  禁止追加；416 不能直接标完成，须核验本地长度/身份，不能确认则重新开始。没有可信校验器不跨尝试拼接字节。
- 新地址和新资源不是同一概念；签名地址过期时先受控重新解析，再验证资源身份。不能仅凭文件名或相同长度续传。

## 8. 统一错误分类

```swift
public enum MediaError: Error, Codable, Sendable, Equatable {
    public enum Restriction: String, Codable, Sendable {
        case membership, payment, region, drm, permission
    }
    case invalidInput, invalidURL, unsupportedSource, invalidSelection, invalidState
    case notFound, outputMissing, requiresLogin, notConfigured
    case accessRestricted(Restriction)
    case rateLimited(retryAfter: TimeInterval?)
    case network, timeout, storageFull, storageUnavailable
    case parsingChanged, unsupportedFormat, unsupportedPlatform
    case resourceLimitExceeded, integrityMismatch, cleanupFailed, cancelled
}
```

所有错误为安全枚举，不持有任意 Error/URL/响应体。retryAfter 须验证非负有限。
UI 据分类翻译文案：requiresLogin 提示需要登录，rateLimited 提示等待，parsingChanged 提示解析规则失效，
storageFull 提示存储不足。不能将 403 一律当登录需求，也不能把原始错误文本直接展示。
取消不进入自动重试；网络超时与用户取消必须可区分。文件存在性、输入参数与状态错误不能伪装为“网络失败”。

## 9. P2 Apple 本地工具契约

```swift
public enum StitchLayout: Sendable { case vertical, horizontal, grid(columns: Int) }
public enum FingerprintMethod: Sendable { case reencode, stripMetadata, subtlePixelNoise }

public func stitchImages(_ images: [Data], options: StitchOptions)
    async throws(MediaError) -> ImageResult
public func makeGIF(fromVideo url: URL, options: GIFOptions)
    async throws(MediaError) -> DownloadedFile
public func rewriteFingerprint(_ image: Data, options: FingerprintOptions)
    async throws(MediaError) -> FingerprintResult
```

| 公共类型 | 含义、隔离、错误和取消 |
|---|---|
| StitchLayout | 保留输入顺序：vertical 自上到下、horizontal 从左到右、grid 按行从左到右；columns 必须大于 0 |
| StitchOptions | layout、非负像素 spacing、显式背景 RGBA、输出格式、MediaProcessingLimits；默认保留原像素尺寸，纵向/横向居中，网格单元按最大宽高排列 |
| GIFOptions | start/duration（秒，有限、start≥0/duration>0）、fps/maxWidth（正值）、循环次数及 limits；片段不能越过视频有效区间 |
| FingerprintMethod | 三种原拟方法保留；不承诺感知哈希或任何站点去重判定一定改变 |
| FingerprintOptions | method、输出格式/编码参数、allowPixelChanges（默认 false）、limits；噪声方法必须显式允许改变像素 |
| ImageResult | 新 Data、实际格式、宽高；不覆盖或修改传入 Data，输出非空且在限额内 |
| FingerprintResult | 新 Data、实际格式、bytesChanged、metadataRemoved；无变化要如实返回，不能制造“指纹已改”成功提示 |
| MediaProcessingLimits | 有限输入字节、图像数量、解码像素、输出字节、GIF 帧数/时长；必须在分配大内存前检查，默认值在 P2 基于测试审核 |

- Apple target 在非 MainActor worker 执行，输入 URL 必须由 UI 先复制到授权沙盒；函数不自行请求相册权限或保存到相册。
  GIF 返回新沙盒文件，不能覆盖输入视频。本地工具均可通过 Task.cancel 取消，取消后清理新临时文件，不返回成功结果。
- stitch 先应用图像方向，再计算像素尺寸/间距；输出默认 PNG。无输入、非法列数/间距或超出像素限额明确失败。
- GIF 帧时间为 start + n/fps 且小于片段结束，保持顺序；按输入方向缩放且不放大小视频，不包含音轨。
  按帧编码，不把全部帧无上限驻留内存。检查实际帧数/总时长，不能只靠文件扩展名宣称 GIF 成功。
- P2 另在 Apple target 内部抽出共用的顺序 GIF 编码器，支持逐帧输入及每帧独立时长，供 P3 Ugoira 组装复用；
  不将 Ugoira 伪装成视频后套用 makeGIF 的固定 fps。原帧顺序/独立时长必须保留并验证每帧及总时长，
  编码器不能准确表达的输入返回 unsupportedFormat，不静默统一间隔或舍弃时序。编码取消须清理临时 GIF。
- stripMetadata 移除 EXIF/GPS/IPTC/XMP/注释等非必要元数据，保留正确显示所需的尺寸/颜色信息并规范方向。
  不能无损满足的格式明确 unsupportedFormat，不偷偷改成有损重编码。reencode 允许显式编码变化，subtlePixelNoise 会改像素。
  输入已规范化而 bytesChanged=false 不是失败，UI 必须能区分；原输入字节始终不变。
- 平台或编码器不支持返回 unsupportedPlatform/unsupportedFormat；任何同步系统编码调用的取消只能在安全检查点确认，
  不能伪称已强制中断。P2 前仍需决定本地工具如何接入统一任务展示，不能擅自增加第二条并发下载队列。

### 9a. P2 实现与契约差异（Claude Code）

- 新 target / product `AIUtilityMediaApple`，依赖 `AIUtilityMedia`；ImageIO / AVFoundation 代码用 `canImport` 隔离，
  其他平台抛 `unsupportedPlatform`。参数校验与布局、GIF 时间轴为平台无关代码，Linux 也有测试。
- `makeGIF` 改为 `makeGIF(fromVideo:outputDirectory:options:) -> GIFResult`：`DownloadedFile` 的初始化器属于下载存储内部，
  本地工具不伪造下载记录。`GIFResult` 的帧数、总时长、宽高均从写出的文件读回，与计划不符即失败。
- GIF 延迟以整厘秒表示：帧取在 `start + n / fps`，每帧延迟取相邻时间戳四舍五入之差，总时长精确到 0.01 s；
  fps 上限 50（GIF 低于 2 cs 的延迟会被播放器拉长）。末帧不足 2 cs 时并入前一帧。
- 共用顺序编码器 `GIFFileEncoder`（内部）：逐帧追加、每帧独立厘秒延迟，低于 2 cs 返回 `unsupportedFormat`，供 P3 Ugoira 复用；
  毫秒级 Ugoira 延迟如何换算为厘秒在 P3 审核时决定，不在编码器内静默改值。
- `stripMetadata` 使用 `CGImageDestinationCopyImageSource` 做容器级无损复制，仅保留显示所需方向；写出后再检查，
  仍有可识别元数据即返回 `unsupportedFormat`。`reencode` / `subtlePixelNoise` 解码时已应用方向，输出不带源元数据。
- 默认限额：输入 200 MB、32 张、单图/画布 8000 万像素、输出 200 MB、GIF 600 帧 / 60 s。
- 统一任务展示：本地工具是一次性 async 调用，由 UI 直接持有 Task 并可取消，不进入下载队列，也不新增第二条并发队列。

### 9b. P3 站点解析实现（Claude Code）

- 只匿名读取公开接口：不发送 Cookie、账号、Token 或签名。需要登录、付费、会员、地区限制的内容返回对应 `MediaError`，不绕过。
- 新增内部 `RequestContext`：仅支持 Referer（两站的图片/视频 CDN 会检查）。`MediaComponent` 公开初始化器不变，站点组件内部携带 Referer。
- `NetworkClient.fetchJSON`：元数据请求同样经过 DNS 校验、重定向逐跳检查、请求预算与限流，响应上限 `maxMetadataBytes`，只保留在内存。
- 注册：`DownloadConfiguration(..., sites: [.bilibili, .x, .pixiv])` 显式开启，默认空集合；自定义解析器优先于内置解析器。
- Pixiv：`/ajax/illust/{id}`（多页再读 `/pages`），每页一个 item，原图来自 `i.pximg.net`；`xRestrict>0` 或原图地址缺失 → `requiresLogin`。
  Ugoira 读 `/ugoira_meta`，计划为原始帧归档 + `.ugoiraToGIF` + 帧列表（`MediaTransferPlan.ugoiraFrames`：文件名与毫秒时长）。
  下载管理器先按 ZIP 检查归档，再交给 `DownloadConfiguration(assembler:)` 提供的组装器（App 使用 `AIUtilityMediaApple.UgoiraAssembler`），
  输出 GIF；`keepUgoiraArchive=true` 时另存原始归档。未配置组装器时仍明确失败（`unsupportedPlatform`），不把归档冒充默认结果。
  帧时长（用户选定“兼容优先”）：GIF 只有 10 ms 精度，每帧结束时间按真实累计时间四舍五入到 10 ms，单帧误差 ≤ 5 ms、总时长不变；
  少于 20 ms 的帧取 GIF 最小 20 ms（会略微拉长总时长）。ZIP 读取支持存储与 deflate，校验大小与 CRC-32，不支持加密/ZIP64。
- B站：`/x/web-interface/view` 取分 P，`?p=N` 指定，否则第 1 P；`/x/player/playurl?fnval=1&platform=html5` 取匿名可得的单文件 MP4（通常 ≤720p），
  无需音视频合并。预览/付费 → `accessRestricted(.payment)`，地区 → `.region`，多段 → `unsupportedFormat`，CDN 主机限 `*.bilivideo.com/.cn`、`*.hdslb.com`。全部分 P 仍不支持。
- X：网页嵌入使用的 `cdn.syndication.twimg.com/tweet-result` 公开端点（未确认其长期稳定性）。`token` 按 JS `((id/1e15)*π).toString(36)` 去掉 0 和点计算，
  JS 移植版与 V8 在 20 万个随机 ID 上一致。墓碑（受保护、年龄限制、已删除）→ `accessRestricted(.permission)`；图片取 `name=orig`，视频列出渐进式 MP4 码率。
- 测试：`PixivResolverTests`、`BilibiliResolverTests`、`XResolverTests` 均为虚构的离线样例；真实联网测试尚未编写，需要在可访问这些站点的网络里另行验证。

## 10. P4 搜图扩展与凭据边界

拟议公共入口为 `ReverseImageSearchProvider`（Sendable 协议）：
`search(image: Data) async throws(MediaError) -> [ReverseSearchMatch]`。
ReverseSearchMatch 为 Sendable 值，包含服务标识、来源页面、缩略信息与可选相似度；不把不同服务评分当统一概率。

P4 先做 SauceNAO，实际格式/限额/评分字段以届时官方接口核对结果冻结；P0 不编造 endpoint、登录方案或 Bot 酱接口。
用户明确发起搜图时才允许上传指定单张图片；不扫描目录、不自动上传截图翻译素材、不上传视频或原始文件夹。
SauceNAO Key 只通过单独的 Keychain-backed 凭据边界按需取入内存，缺失为 notConfigured；不复用 AI Key，不进历史或日志。
搜图 Bot 酱保留后续适配位置，可行性/授权方式未确定；P4 具体公开请求类型需在实施前提交补充审核。

### 10a. P4 实现（Claude Code）

- `ReverseImageSearchProvider.search(image:) -> [ReverseSearchMatch]`；`SauceNAOProvider(credentials:minimumSimilarity:maxResults:)`。
- Key 来自 `SearchCredentialSource.sauceNAOKey()`（App 用独立的 Keychain 项实现），缺失或格式不合法 → `notConfigured`，此时不发请求。
  Key 按 SauceNAO 要求放在查询参数里，请求只在内存中构建，不记录、不进历史。
- 上传前检查：非空、≤ 15 MB、文件头为 JPEG/PNG/GIF/WebP。临时会话不带 Cookie/缓存/凭据，不跟随重定向，响应上限 1 MB。
- 相似度低于阈值（默认 50）的结果丢弃，按相似度降序；链接只保留 http/https，最多 5 个。`similarity` 是 SauceNAO 的百分比，不当作通用概率。
- 错误：403 → `accessRestricted(.permission)`（Key 被拒），429 或剩余额度为 0 → `rateLimited`，服务端错误 → `network`，未知格式 → `parsingChanged`。
- 搜图 Bot 酱仍未接入（无公开接口资料）。

## 11. 测试与 Claude 接线要求（P1 修复后 Linux 45 项通过）

- P1 Linux：各来源语法、参数/短链重路由、未知链接、FIFO、任意时刻活动槽≤1、任务内串行网络、
  排队/活动取消、清理失败阻塞、旧 generation、重试上限/退避/限流、重复入队、每 attempt 进度单调、
  重试从零且不发 Range/不追加旧文件、队列与历史原子持久化及清空失败回滚、重启 interrupted/手动从头重试；
  删除成功/原已缺失/部分失败/取消、活动任务拒绝删除、并发删除/retry、去重失效、清空历史后删除、删除日志恢复；
  初始化失败/取消后无遗留工作和锁、旧快照可读且同一命名空间重建成功。
  补充 selection.variant 与 SiteOptions 组合、无关站点/内容选项被忽略、只用生效选项去重、
  生效选项不同形成不同任务、短链按最终来源规范化、入队后设置修改不影响任务、选项 Codable 恢复/缺字段默认值。
  P1 用离线测试依赖验证这些契约，不将测试解析器注册成生产站点能力。
- P1b 单独审核后的测试：同进程/跨重启续接、206/200/416、校验器变化、过期地址重解析及 .part 不匹配；不算 P1 验收项。
- P2 macOS：拼接尺寸/顺序/方向/间距、GIF 帧数/时长、原文件不变、元数据实际去除、限额及取消清理。
  共用 GIF 编码器覆盖不同逐帧时长、顺序与总时长、不可准确表达时序的明确失败。
- P3 每站离线 HTML/JSON 样例单独提交；只公开无争议样例，去掉账号/Cookie/Token/个人主页内容。
  只用官方公开文档化接口或网页公开数据，遇私有接口、登录模拟或受限资源停下报告，不能为了测绿绕过。
  B站覆盖默认首 P/链接指定 P、未支持全部分 P 时明确拒绝；Ugoira 覆盖默认 GIF/可选保留原件、变长帧时序、
  组装全程单活动槽、取消清理、平台/编码器缺失不假成功，以及交付选项参与去重。
  特别验证 allParts=true 且 supportsAllBilibiliParts=false 时返回 unsupportedFormat（含指定变体的组合），
  对 X/直链传入该选项不报错；Ugoira 组装参数来自 pixiv.keepUgoiraArchive，非 Ugoira 不受它影响。
- 普通 CI 传输层禁止向真实站点和付费 API 联网；真实集成测试单独授权、默认关闭，沿用 AIUTILITY_LIVE_TESTS=1。
  P0 未新增测试；最初 P1 的 42 项测试在 42453057517 全通过；Darwin 修复后 45 项在 42463047405 全通过。
  首次 Apple 编译及旧源码 SDK 通过，但 Mac 测试失败；修复后的 Mac/SDK 和真实联网验证没有执行。
- 本轮用户已特别授权 core-linux 增加 Media build/test 并已通过；其他 job 和触发条件未改。
  后续 Apple 工具 macOS 测试和 iOS SDK 编译步骤仍需另行授权，并与 Claude 协调。
  App 只调用 manager，独立订阅快照并回 MainActor；按 EnqueueReceipt/CancelResult 提示，不把取消请求等同已释放。
  多文件完成/重复/中断/提交中需有对应展示；能力通过并获审核前仍标“规划中”。
  初始化提供加载/分类错误/重试入口；区分 clearHistory 和 deleteFiles，对部分删除列出未删除项；
  未支持的续传/全部分 P 选项保持不可用，Ugoira 原件保留选项默认关闭。以上仅为后续接线约定，本轮不改 UI。
  App 将通用 selection（或已选 item/variant）与可保存的 SiteOptions 一同传入对应 enqueue 重载；不得用共享可变设置影响在途任务。

## 12. 已审核要点与 P1 验收门槛

以下为已审核的接口选择；源码是否满足这些契约仍需真实编译、测试与运行验证：

1. 取消逻辑立即生效，但实际下一任务等释放确认；清理失败全队列阻塞，提交阶段取消可能 tooLate。
2. 自动下载范围及默认最高公开兼容变体；同一作品的有界多文件；Ugoira 默认 GIF、原归档+时序可选保留；DASH 显式组装；B站预留全部分 P，未实现须明确拒绝。
3. 进度单调的范围为同 attempt/阶段，完整重传允许显式重置，不伪造百分比。
4. clearHistory 只清记录、不删文件且移除对应去重证据；新增 deleteFiles，部分删除如实报告；初始化失败可安全重建。
   P1 重启中断等待手动从头重试；敏感直链可能需用户重提供；所有断点续传移至单独审核的 P1b。
5. 默认 HTTPS、有限请求/时限/资源策略；P2 本地工具的统一任务接入与 P4 具体搜图字段另行冻结。
6. 按 R6，MediaSelection 仅通用选择；SiteOptions 独立且可 Codable 保存、与选择组合使用。
   B站 allParts / Pixiv keepUgoiraArchive 均默认 false；忽略不相关选项，仅生效选项参与去重和组装。

- [x] 已形成 P0 接口草案，未写实现、未改现有公共 API。
- [x] 按 b44ae48 的审核文件第 3 节完成 R1–R5 文档修订（不是运行验证）。
- [x] 按 e3526f5 的审核文件第 3b 节完成 R6 文档修订（不是运行验证）。
- [x] 用户审核 MEDIA_INTERFACES.md（28c449d）通过。
- [x] 用户明确授权进入 P1；触发 CI 前另行确认。
- [x] P1 Linux 真实 Swift 6.0.3 编译与 42 项离线测试通过（42453057517）。
- [x] Darwin 存储修复后 Linux 45 项通过（42463047405）；保留原测试，新增 3 项路径安全回归。
- [ ] Apple SDK、真实网络传输和 App 接线验证通过。

**已执行一次获授权的 Apple 验证，失败后修复的 Linux 45 项通过；不注册生产 Mock、不进入 P1b/P2–P4。macOS 重验须先问用户。**
