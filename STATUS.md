# AIUtility 开发状态

## 最新（Claude，2026-11-22）：本地工具与截图识别的 4 处修正，build_apple 通过

整理真机测试清单时从源码发现、按所有者要求修正（均未在真机验证）：

- 多图拼接：拼出的 PNG 超过 200 MB 时不再报「有单张图片超过 8000 万像素……」（说的是输入，与原因不符），改为整体再等比缩小后输出；新增测试 `outputOverTheByteCapIsShrunkInsteadOfFailing`。
- 截图翻译：超过 32 MB 的图片（如大拼接图）先在本机缩成 4000 万像素以内的 JPEG 再识别，状态行注明「图片超过 32 MB，已缩小后识别」；「自动检测」时不再把大小问题说成语言问题。
- 拼接、视频转 GIF、图片指纹、反向搜图：离开页面或布局切换重建页面时取消任务，在下一个检查点停止（原先在后台继续算完、结果丢弃，再开始一次会两份同时运行）。系统的单次解码 / 编码不能中断，会先做完；视频转 GIF 每帧检查，图片指纹在解码与编码之间新增检查点。
- 拼接、视频转 GIF、图片指纹：处理中锁定选择按钮，结果不会显示在新选的内容下面；拼接改选后清掉上一次结果（另两个工具原本就会）。读图阶段被取消时提示「已取消。」而不是「无法读取」。
- 验证：[Actions 44983456656](https://github.com/7869123/ios/actions/runs/44983456656)（源 `7ac2a15`，build_apple + publish_previews）全部通过：core-linux、apple（macOS Core 89、AppleServices 20、Media 127（新增 2 项）、Network 62 项测试，含 iOS 模拟器 / 真机 SDK 编译，无警告）、app（编译、Release 归档、未签名 IPA、62 张预览提交于 `31d8231`，拼接页说明已是新文字）。
- DEVICE_TEST_CHECKLIST.md 相应条目（文首与 0.2 的 iPhone 范围、2.19、7.8、10.1、10.12、10.15、10.16、10.31、10.33、10.46、11.9、14.8、14.10）改为新行为。

## 最新（Claude，2026-11-21）：网络测速、泄漏检测、新图标与名称，build_apple + live_checks 通过

- 新包 `Packages/AIUtilityNetwork` 与页面「工具箱 → 网络」：Cloudflare 测速（延迟、抖动、下载、上传、负载下的延迟、节点与出口 IP，带流量上限）；IP / DNS / WebRTC 泄漏检测（HTTPS 出口、STUN、WKWebView 里的 WebRTC、Akamai DNS 诊断、VPN / 代理识别，规则见 NETWORK_TOOLS.md）。信通院测速按所有者整理的非官方接口说明接入（控制面定位、节点表、签名会话、TCP 直连节点测下载 / 上传、结束必释放会话；并发数与延迟方式为推断，上传值可能偏低），细节见 NETWORK_TOOLS.md。
- 「媒体工具」改名「工具箱」；App 显示名改为「serina的工具箱」；图标、启动画面换成所有者提供的图（所有者确认为原创或有权使用，已写入 ASSETS_LICENSE.md）。
- CI：core-linux 与 apple 增加网络包的编译和测试，apple 另做 iOS 模拟器 / 真机 SDK 编译；`live_checks` 增加 `LiveNetworkChecks`；截图增加 speed、leak 两页。
- 验证：[Actions 44914960833](https://github.com/7869123/ios/actions/runs/44914960833)（源 `0a72693`）全部通过：core-linux（网络包 58 项测试）、apple（含网络包 macOS 测试与 iOS 模拟器 / 真机 SDK 编译）、app（编译、Release 归档、未签名 IPA、62 张预览提交于 `866bd74`）、live-checks。
- 联网格式检查：Cloudflare trace / 下载 / 上传、ip.sb、IPIP、两个 STUN、三条 Akamai DNS TXT、信通院控制面（定位 + 节点表，在美国机房也返回 1 个节点）全部 ok；IPv6 在 CI 机房不可用（unavailable，属预期）。
- 修复过程：44912642837（测试里 async 中用 NSLock）、44913267516（假节点会话 key 含点号被解析器拒绝）、44913942459（App 泄漏检测 catch 未收窄类型）；另根据联网检查修正 Cloudflare 上传计时（requestEnd 只代表写入缓冲区，Cloudflare 对上传的服务器计时约为 0，改为「响应等待 − 最短空载往返」）。
- 2026-11-22：DEVICE_TEST_CHECKLIST.md 按当前代码重新整理为 16 节、490 项（逐项对照源码核对；⭐ 统一为「只能在真机上确认」的项，规则写在文首），旧编号不再适用。
- 截图中的测速、泄漏结果是 DEBUG 示例数据（`NetworkReviewSamples`，文档保留地址），不是真实测量；真机测试项见 DEVICE_TEST_CHECKLIST.md 第 12、13 节。

## 最新（Claude，2026-11-15）：真机前诊断结果与修复，全部通过

- 最终被测源 `cc2a764`，[Actions 43673166431](https://github.com/7869123/ios/actions/runs/43673166431) completed / success：core-linux、apple、app、diagnostics 全部通过；macOS Core 89、AppleServices 20（Vision 依次执行，四语与超高图测试恢复默认运行，4 秒完成）、Media 125 项测试通过；46 张预览（含 iPhone / iPad 超大字号各 3 张）已提交到 `validation/ui-preview/`（63826ee），无缺失；打包检查确认 App 带相册写入说明。
- 复测诊断：PNG 文本块在「去除元数据」和「重新编码」后都不再保留且如实报告；最大 GIF 自动缩为 385×216，峰值内存 0.6 GB（原 1.56 GB）。
- 中间两次失败：43671848044 的 app 任务因变量重名编译失败；43672610901 的 apple 任务中 `cleanImageReportsNothingRemoved` 失败（把 ImageIO 自己的 eXIf / XMP 块当成了文本），均已修正。
- 超大字号下界面可读、不溢出；「OpenAI」「DeepSeek」这类英文名在胶囊里会被断成两行（外观问题，未改）。


诊断运行 [43671848044](https://github.com/7869123/ios/actions/runs/43671848044)（diagnostics 任务通过；同次 app 任务因一处变量重名编译失败，已修正）：

- Vision：七种语言组合（含四语、关闭自动检测、旧的三语默认）各自单独运行均在 1.1 秒内完成；17 000 像素高图 0.9 秒；带 EXIF 方向 6 的图片框选结果正确（Vision 对数据输入自动应用方向）。此前卡住不是语言资源问题，更可能是多个 Vision 请求在同一测试进程并行时互相阻塞（App 同一时间只做一次识别）。Vision 测试改为依次执行，四语与超高图测试恢复默认运行，以验证这一判断。
- PNG 自定义文本块（出图工具的提示词）：原先检测不到、去除元数据后仍在文件里 → 已修复，并新增跨平台和 ImageIO 测试。
- HEIC：去除元数据保持 HEIC、重新编码输出 JPEG，正常。
- 最大 GIF（599 帧 640×360）峰值内存 1.56 GB，对 4 GB 的 iPad 风险很高 → 总像素上限降为 5000 万，超出时整体等比缩小（视频与 Pixiv 动图）。
- Keychain 测试在 macOS 上因缺少签名授权返回 storageFailure，属预期，只能真机验证。


所有者要求在真机测试前尽量弄清不确定项。新增 workflow 输入 `diagnostics`（`scripts/ci_diagnostics.sh`）：Vision 语言组合逐一测（找出此前卡住的原因）、超高图片识别、带 EXIF 方向的图片框选、PNG 自定义文本块能否检测与去除、HEIC 去除元数据与重新编码、最大 GIF 的峰值内存、macOS 上的 Keychain 测试。截图增加 iPhone 超大字号三页；打包检查确认 App 带相册写入说明。动图的 GIF 与 zip 改为分开导出（不再依赖分享面板对混合类型的处理）。

## 分工（2026-11-15）

所有者决定整个仓库（Core、AppleServices、Media、App、PoC、CI、文档）此后只由 Claude Code 维护，Codex 不再参与。原 Codex 分支已全部合入 `claude/ecstatic-planck-rzpvn6`；AGENTS.md / CLAUDE.md 已更新。

## 最新（Claude，2026-11-15）：PoC 5 条问题修复，Core / AppleServices 改由 Claude 暂管，build_apple + build_poc 通过

- 被测源 `bffe59a`，[Actions 43662402719](https://github.com/7869123/ios/actions/runs/43662402719) completed / success：core-linux、apple、poc-sdk、app 全部通过。macOS Core 89 项、AppleServices 10 项、Media 117 项、PoC 生命周期 14 项测试通过；PoC 在 iOS 27 SDK 上模拟器编译、iphoneos Archive 与未签名 IPA 成功；App 未签名 IPA `AIUtility-unsigned-ipa-43662402719`。PoC 的 display layer 弃用警告为原有警告。

所有者授权修改 PoC 这 5 条，并决定 Core / AppleServices 暂由 Claude 维护（AGENTS.md 已更新）。均未真机验证。

- ScreenAudioProbe：只在 startCapture 成功、且系统没有自行停止时才调用 stopCapture；启动失败或系统终止后不再卡在「释放失败」。
- SubtitlePiPProbe：显示字幕的最新部分（原先只画前 400 个字，说话十几秒后画面不再更新）；帧缓冲带 IOSurface 属性。
- 宿主 App：收到第一段译文后，不再用原文转写覆盖画中画里的译文。
- LocalSpeechProbe：语音授权在非主线程隔离的函数里请求，避免 Swift 6 运行时隔离检查崩溃（原问题未确认）。
- Core AudioRolloverBuffer：时间戳回退 2 毫秒以内视为抖动，不再终止整个会话；更大的重叠仍然拒绝。新增 1 项测试。

## Claude，2026-11-15：代修 Codex 范围的 Core / AppleServices 问题，build_apple 通过

- 被测源 `ed0028e`，[Actions 43660804729](https://github.com/7869123/ios/actions/runs/43660804729) completed / success：core-linux、apple、app 全部通过；macOS Core 88 项、AppleServices 10 项通过（Keychain 与四语 Vision 实测按设计跳过），App 源码 0 条警告，Release Archive 与未签名 IPA（`AIUtility-unsigned-ipa-43660804729`）成功。
- 前两次 [43656688931](https://github.com/7869123/ios/actions/runs/43656688931)、[43658752270](https://github.com/7869123/ios/actions/runs/43658752270) 在 macOS AppleServices 测试处无输出卡住约 19 分钟后被取消；把真实四语 Vision 识别测试改为按需开启（`AIUTILITY_VISION_LANGUAGE_TESTS=1`）后通过，说明卡住来自该测试（推测 Vision 首次使用日语/韩语时要准备语言资源，未确认）。真机上「自动检测」的首次识别可能较慢，超过 20 秒会显示「本机识别超时」，需真机确认。`ci_apple.sh` 现在会在包测试超过 10 分钟时停止并打印日志。

所有者授权「帮 Codex 修完」。只在 Claude 分支修改，未读取或合并 Codex 分支；PoC 未改（需单独授权）。详见 [交接文档末节](TRANSLATION_CLAUDE_HANDOFF.md)。

- 截图「自动检测」时本机 OCR 可以运行（OCR 接受 4 种语言）；超长截图 / 拼图按比例缩小后识别，不再拒绝。
- 文字自动检测只在 App 支持的语言中判断，短句更可靠；繁体中文仍明确拒绝。
- 新增删除供应商 Key（Core `removeKey`，设置页按钮带确认）；Key 首尾空白自动去掉。
- 「bearer + 普通单词」不再被当成凭据；字幕分段不再卡住；DeepSeek 余额查询不再占用翻译的会话请求次数。
- 新增 8 项测试，原有测试未删除或放宽。真机仍未验证。

## Claude，2026-11-14：代码检查的中低问题第二批修复，build_apple 通过

- 被测源 `3eec906`，[Actions 43601437461](https://github.com/7869123/ios/actions/runs/43601437461) completed / success：core-linux、apple、app 全部通过。macOS 上 Core 84 项、AppleServices 6 项、Media 117 项测试通过；App 两个 SDK 编译、Release Archive 与未签名 IPA（artifact `AIUtility-unsigned-ipa-43601437461`，保留 7 天）成功，App 源码 0 条编译警告。
- 第一次运行 [43600865117](https://github.com/7869123/ios/actions/runs/43600865117)（源 `0679581`）在 `VideoGIF.swift:73` 编译失败（变量名写错），`3eec906` 修正后通过。未截图（未勾选 publish_previews），未真机验证。

所有者授权「该编译编译、该修复修复」。本批修 Claude 负责范围（App、媒体包、CI 脚本、文档）内复核成立的中等和轻微问题；Core / AppleServices（Codex）与 PoC 未改，见下方「待 Codex 或所有者决定」。均未真机验证。

- 翻译：只支持「自动」的模型也能调总输出上限；上限步进在 4096 处不再跳变；推理卡片跟随已保存的模型；Key 和模型 ID 去首尾空白；余额阈值严格解析；只在设置了阈值时查余额（每次占一次会话请求），Key 检测完成后立即查一次；低余额提醒跨启动保留到手动关闭；截图页切换标签不再重新识别；本机识别和超长原文有专门提示；「自动检测」时 OCR 失败会明确说明并建议选具体语言；超时随总输出上限放宽（30–180 秒）；同语直返显示「没有调用模型」；截图、识别结果和译文在页面重建（iPad 侧边栏切换、分屏宽度变化）后保留。
- 外观：全新安装时默认壁纸的遮罩和位置调整会保存；切换显示模式后遮罩滑块跟着当前壁纸；透明度说明写明工具页最多按 75% 显示；大字号下首页胶囊换行；导入壁纸有进度且读文件不卡界面；设置页底部显示 App 版本。
- 下载：任务在本次运行中显示站点标题（只在内存），导出文件用标题命名；可粘贴带标题的分享文本或不带 https:// 的链接；队列因清理失败暂停时可「重试清理并继续」；下载中申请系统后台宽限时间并提示需留在 App 内；限流按站点记录；412 / 500 / 502 分类；大错误页按状态码分类；小图不再要求 1 GB 空闲空间；代理 fake-IP 与 NAT64 地址可用；Pixiv 语言前缀和旧式链接；标题零宽字符不再导致失败；B站备用地址与海外镜像；下载文件不进备份；临时文件启动时清理。
- 本地工具与搜图：视频单独 8 GB 上限（原 200 MB）；GIF 加帧像素总量上限，界面按帧率限制时长（≤600 帧）；拼接超 8000 万像素自动等比缩小；指纹「重新编码」对 HEIC 输出 JPEG、动图明确拒绝；搜图上传前转成 2048 像素 JPEG（支持 HEIC、不带 EXIF 定位）；SauceNAO Key 保存前校验格式；结果显示缩略图；Bot 酱先排序再截断。
- CI 与脚本：截图 `all` 包含最新页面、`new` 不再清空其他预览；截图缺失会记录并让步骤失败，一张都没有时不提交；预览推送遇到分支前进会 rebase 重试；个人信息扫描补本地路径写法、团队 ID、SauceNAO Key，并扫描待推送提交的内容、说明和作者名；资源检查真正匹配引用；作者审计只看待推送提交；在线检查的网络错误记为 unavailable。
- 文档：UIUX_SPEC、App README、FRONTEND、GITHUB_ACTIONS、媒体包 README、MEDIA_INTERFACES、真机测试清单同步到现状。

待 Codex 或所有者决定（未改）：截图「自动检测」时 Core 传 4 种语言而 OCR 最多 3 种（App 已给出明确提示）；会话请求次数（100 次）由余额查询、Key 检测共用；没有删除供应商 Key 的底层接口；自动检测遇到繁体中文 / 低置信度只抛通用错误；字幕分段卡住、「bearer + 单词」被当成凭据等 Core 问题；PoC 的 4 条存疑；AGENTS.md 第 8 行写有时区、扫描脚本未加 UTC 偏移规则（加上会让该文件扫描失败，需所有者决定是否保留这一行）。

## Claude，2026-11-14：代码检查后修复 4 个严重问题（已由上方 43601437461 一并验证）

- 全仓库静态检查 112 条、复核后 94 条成立；本批只修归 Claude 的严重问题，其余待所有者决定。均未编译、未真机验证。
- 相册：主 App `Info.plist` 补 `NSPhotoLibraryAddUsageDescription`，分享面板可「存储图像 / 视频」。
- 下载导出：已完成任务的全部文件（多页、多图、保留的动图 zip）一次放进分享面板。
- 清空历史：先确认；可选「删除已下载的文件并清空」或「只清空记录」，已完成任务不再被清成无法导出、无法删除的孤儿文件；「文件未完全删除」的任务可「导出剩余」「重新删除」。「Pixiv 保留压缩包」开关改为跨启动保存（它属于任务身份，重新粘贴时要一致）。媒体包新增 `clearHistory(keepingFiles:)`（默认值保持原语义）。
- 重启恢复：排队中的任务重启后也标为「已中断」（原来在下一次加入任务前一直显示「排队中」）；重新粘贴同一链接即自动重新开始该任务；点「重试」时提示需要重新粘贴原链接，不再误报「还没有配置所需的 Key」；「已在队列中 / 已下载过」有提示。
- 会话预算（界面部分）：App 把每次启动的会话输出预留从 65,536 调到 524,288 tokens（请求次数仍 100），推理卡片和设置页写明额度、约可翻译次数和「完全退出后重置」。预算逻辑本身（Codex）未改。
- 截图「自动检测」时 OCR 必然失败的问题在 Core / AppleServices（Codex 负责），本批未改。

## 最新：完整复编译通过，真机仍未验证

- 被测源 `05508ba75f86ebbc50bf8bc65f0947f50805ed7c`，[Actions 42739095920](https://github.com/7869123/ios/actions/runs/42739095920) completed / success。用户授权修复重试直至通过；本次只运行一次，未合并或读取 Claude 分支、未创建 PR。
- Core Linux / macOS 各 **82 通过、1 live API 跳过、0 失败**；AppleServices **5 通过、1 Keychain 跳过**；Media Linux **92 通过/4 跳过**、macOS **108 通过/5 跳过**；可移植 PoC 生命周期两个宿主各 **14 通过**。26 个记录的命令退出码全为 0。
- AppleServices、Media、MediaApple 的模拟器/真机 SDK 编译通过；Xcode 27.1 / iOS 27.1 下 PoC Swift 6 模拟器编译、iphoneos Archive、未签名 IPA、13 项预安装检查通过；App 两个 SDK 编译、Release Archive 和未签名 IPA 通过。
- 首轮 7 处宏编译错误及后续字幕旧尾句修复已实际验证；13 项 Core 音频队列测试通过，不等同于真实 Speech/PCM 补送验证。真实 API、iOS Keychain、截图质量、ASR/跨 App 捕获、PiP/后台、签名安装与 iPad mini 6 真机仍未验证。
- 保留警告：PoC 的音频中断/display layer 弃用接口、App UI 的 MainActor/Sendable 闭包、未使用 Bool 与元数据/方向诊断。未修改 UI、PoC 或工具来消除警告。截图发布/live-checks 关闭。
- [完整测试/命令/退出码/Artifact/风险记录](validation/translation-completeness/attempt-2/README.md)。35 份日志与原始/归档哈希已保存；后续仅文档/证据变动不改变被测源码。下方未编译/未重跑描述均为此前阶段历史。

## 最新修复：先修代码，未重跑 CI

- 已逐项核对首轮日志的 7 处测试编译错误，保留 `6aa6f64` 的修复与全部旧断言。
- 补修 Core 字幕分段：ASR 修正触及已提交前缀时，立即丢弃被推翻的未提交尾句并推进事件序号；final 同时结束该 utterance，避免静默 flush、下一轮识别或迟到回调把旧尾句送去翻译。公开签名不变；不修改 PoC 或 UI。
- 新增 2 个同步回归测试声明，其中 1 个含两组参数；Core 当前 83 个 @Test 声明。测试尚未编译/执行，不能据此报告通过。此前生产编译成功只覆盖 `0ee791b`，不覆盖本次分段修复。
- 本地静态检查退出 0（88 个 Swift 文件），不是 Swift 编译。没有重跑 Actions、创建 PR 或合并分支；待所有者确认后复验。[修复审查与验证边界](validation/translation-completeness/repair-review.md)。

## 最新真实 CI：Core 生产源码通过，测试模块失败，修复待复验

- 所有者授权编译且禁止合并；仅在 Codex 分支执行 [42647207277](https://github.com/7869123/ios/actions/runs/42647207277)，源码 `0ee791b`，整体 failure。未创建 PR 或合并分支。
- Linux Swift 6.0.3：Core build=0；Core test=1，因新增测试宏展开编译错误，实际功能测试执行 0 项。生命周期 14 通过；Media build/test=0，92 通过/4 live 跳过/0 失败。六个退出码为 0/0/1/0/0/0。
- Apple、App、PoC SDK 因依赖 Core 成功而跳过，live-checks 显式关闭；无本轮 macOS 测试、iOS SDK、Archive 或 IPA 证据，更无真机结论。
- 修复 `6aa6f64` 仅拆开三份测试文件的嵌套宏、throwing 读取与 JSON 解码；@Test、#expect、#require 数量均保留，生产源码和公开接口不变。**修复尚未编译/执行，重跑需单独确认。**
- [首轮完整证据](validation/translation-completeness/attempt-1/README.md) 含真实命令、job ID、退出码、7 份日志、artifact SHA-256。下方“没有本批 CI”的内容为此前源码阶段记录。

## 最新：ASR 轮转音频缓存（用户明确授权；未编译）

- 缓存源码 `2272e99`，请求 token 与锁收尾 `42a1bec`，仍在 `codex/translation-completeness`。新增 Core 的 AudioRolloverBuffer 与 13 项回归测试；PoC 仅修改 LocalSpeechProbe.swift，未改 Host UI、采集、PiP、生命周期类或正式 App。
- 默认 5 秒 / 8 MiB PCM / 512 包三重上限，正常投递和轮转补送使用同一 FIFO。旧识别结束期间继续缓存；新请求就绪立即排空，不等待满 5 秒。只补送尚未投递的音频，不加入重叠重放。
- PCM 深拷贝独立存放，单 worker、逐包同步边界和会话 token；停止/失败清空，旧会话无法取出新包。超限、格式变化、部分时间重叠、无效包或复制失败明确停止，不无限积压；快照只暴露数量/时长和安全状态。
- **新增测试仅为源码，实际执行 0 项**；Core 当前 81 个 @Test 声明，Apple 6 个。Swift / Apple SDK / 真机均未验证，CI 未获授权。用户之前收到的 c9496fa CI 询问不覆盖这一新增提交。
- 缓存可覆盖客户端轮转期间的未投递音频，不解决系统采集缺音；词语跨识别边界、Speech 消化积压的速度和内部内存仍需真机测试，不能标记为无缝识别。
- 接口与验证细节见 [Claude 交接](TRANSLATION_CLAUDE_HANDOFF.md)、[PoC 方案](POC_TRANSLATION_PLAN.md) 和 [验证状态](validation/translation-completeness/README.md)。下方“未缓存空窗”的描述仅对应此前提交。

## 本轮翻译底层增量（独立分支，真实验证待确认）

- 所有者重新分配 Codex 处理底层业务/API/持久化/测试，未授权 UI 修改；随后单独授权 LocalSpeechProbe、PoCSession 两处 PoC 逻辑。分支 `codex/translation-completeness`，基线 `7ff4111`，审计 `c178776`，P0 `659de51`，API/OCR `fa81778`，获批 PoC `12ed6bf`，回归补充 `c9c572b`。未合并 PR、未写 main/Claude 分支。
- 新源码：两套独立可编辑提示词和恢复默认、三语语言偏好/同语直返、本地自动检测接口、有限稳定分段/FIFO/去重/取消、模型推理能力与显式输出预算、真实 DeepSeek 余额接口与提醒抑制、OpenAI 实际 usage 本地账本、区域 OCR/编辑稿工作流、阶段耗时诊断和配置版本兼容。
- PoC：三语参数、约 50 秒识别轮转、最多 2 秒排空/停止确认、Core 字幕接线；仅两处获批文件，Host UI/ScreenAudioProbe/ProbeLifecycle/SubtitlePiPProbe 不变。排空期间存在识别空窗，尚未验证是否丢字，不能称为无缝连续 ASR。
- **本批 Swift 编译和测试执行数量仍为 0**；新增 31 个 Core 测试声明、3 个 Apple 测试声明不是通过证据。现 Core 源码总计 68 个 @Test、Apple 6 个；原测试全部保留。Windows 未安装 Swift，尚无本批 CI 运行 ID。
- 基线 [42486839669](https://github.com/7869123/ios/actions/runs/42486839669) 的通过结果仅用于审计，不验证本批源码。触发 CI / 创建会自动跑 Linux 的 PR 前，按 AGENTS 第 5 节请求本批授权。
- UI 页面和系统快捷入口未接线；三家真实 API、余额实查、真实用量、iOS Keychain/真实截图、多语语言包、跨 App 音频/Speech/PiP/后台、签名安装与长时实机均未验证。既有媒体实现不改、不删、不重复开发。
- [只读审计](TRANSLATION_AUDIT.md)、[Claude 接口交接](TRANSLATION_CLAUDE_HANDOFF.md)、[PoC 获批方案与风险](POC_TRANSLATION_PLAN.md)、[本轮验证状态](validation/translation-completeness/README.md)。下方内容保留为历史，不能覆盖本节的新验证边界。

## 已搁置：首次启动引导页

- 用户 2026-11-08 提出（首次启动显示引导页，可「跳过」），2026-11-14 决定先不做。未写任何代码；以后需要时再重新讨论方案。

## Claude Code 接手媒体模块：P2–P4 与 App 接线（2026-11-08）

用户让 Claude Code 接手 Codex 的工作（Codex 分支已合入 Claude 分支）。本节为最新状态，下方各节为历史记录。

| 阶段 | 内容 | 验证 |
|---|---|---|
| P1 | 下载队列（FIFO 单任务） | Linux 与 macOS 测试通过，两种 iOS SDK 编译通过（run 42466209488） |
| P2 | 多图拼接、视频转 GIF、图片指纹（`AIUtilityMediaApple`） | macOS 上除“取消后不留文件”外全部通过（run 42468453922），该项已修复待复验 |
| P3 | B站、X、Pixiv 解析器；Pixiv 动图在本机转 GIF（兼容优先：帧时长对齐 10 ms，总时长不变） | 离线样例测试；**未连接真实站点验证** |
| P4 | SauceNAO 搜图（需 Key）；搜图 Bot 酱（无需 Key，按网页请求抓包接入，接口无公开文档） | 离线样例测试；未联网验证 |
| App | 媒体工具箱：链接下载、三个本地工具、SauceNAO 搜图 | 待本轮编译与截图 |

- 界面状态：本地工具标“可用”；站点下载与搜图标“未实测”（已实现、只做过离线测试）。只处理公开内容，不绕过登录、付费、会员或地区限制。
- 未做：真实网络验证（需要能访问这些站点的网络和设备）、B站多 P 批量与高清（需要登录，不做）、真机验证。
- 接口与契约细节见 MEDIA_INTERFACES.md 9a、9b、10a。

## 媒体 Apple 首轮失败，修复待复验

用户新增授权仅限 swift.yml 的 apple job：Media macOS build/test、两种无签名 iOS SDK 编译，
保留触发条件和其他 job；Codex 分支允许一次 build_apple，publish_previews=false、build_poc=false。
授权的单次运行 [42461786365](https://github.com/7869123/ios/actions/runs/42461786365)，源码 1ac37c8：
Media macOS build=0，测试=1（9 通过、33 失败、0 跳过）；两个无签名 iOS SDK build=0。
Linux Media 42 通过；原 macOS Core 36 通过/1 跳过，Vision 2 通过/Keychain 1 跳过。
实际为 Xcode 26.6 / Swift 6.3.3 / iOS SDK 26.5，不是 iOS 27。App 因 apple 失败跳过，未生成截图。
失败集中在存储初始化把 Darwin 系统目录别名误判为符号链接；已仅在 Media 修复精确系统别名和路径检查，
保留全部原测试并新增 3 项（总数 45）。修复 99b0d86，验证 HEAD 334cfde 在
[42463047405](https://github.com/7869123/ios/actions/runs/42463047405) Linux Media 45 全通过、0 跳过/失败，
Core 36 通过/1 跳过、生命周期 14 通过，六个退出码均为 0。Mac/SDK 修复后尚未复验，不能沿用旧 SDK 结果。
[失败全文、命令退出码及 17 份证据](validation/media-apple/attempt-1/README.md)。
[修复后证据与下一步门槛](validation/media-apple/README.md)。
一次 build_apple 授权已使用；推送后的 Linux CI 仍在已有授权范围内，macOS 重验需先询问用户。不开始 P2。

## 历史：媒体 P1 首次 Linux 编译/测试通过

用户已明确授权推送并触发 Linux CI，仅允许在 swift.yml 的 core-linux job 中增加媒体包 build/test，
沿用既有日志、退出码、artifact 与失败门槛；触发条件和其他 job 保持不变，macOS 尚未授权。
本批次工具变化见 [MEDIA_CHANGE_NOTICE.md](MEDIA_CHANGE_NOTICE.md)，已在 PR #2 发布变更通知。
真实源码 55be755 在 [42453057517](https://github.com/7869123/ios/actions/runs/42453057517) completed/success：
Media 42 通过/0 跳过/0 失败；Core 36 通过/1 live API 跳过；生命周期 14 通过，六个命令退出码均为 0。
Apple、App、PoC SDK job 均 skipped，未运行 macOS。实际 checkout 是临时合并检查提交 549c5b2，
Media/Core/PoC 树与源码 HEAD 相同，不代表合并 PR；[证据、8 份日志与原始摘要](validation/media-p1/README.md)。
仅 Linux 类型检查/严格并发编译和离线测试有证据；真实网络下载、macOS/iOS SDK/App 接线与真机能力仍未验证。
新包没有编译警告；原有 PoC 生命周期测试一处未使用 Bool 警告保留，未改 PoC。首次 CI 通过，无需改 Swift 源码。

## 历史：媒体 P1 本地源码交付（当时未编译/执行）

用户审核通过 MEDIA_INTERFACES.md 的 28c449d，并明确授权 P1；CI 需另行确认。
已创建 [AIUtilityMedia](Packages/AIUtilityMedia/README.md)：独立 Swift 6 包、直接 HTTPS 媒体的真实 URLSession 下载、
自动路由/短链重路由、FIFO 单活动槽、立即可见且等待资源确认的取消、有限从头重试、请求预算/超时/限流、
选项规范化/去重、原子队列与历史清单、提交/删除恢复日志、文件归属校验、部分删除结果及完整快照订阅。
生产仅注册直链；B站/X/Pixiv、Apple 工具、Ugoira/GIF/DASH、搜图均未宣称可用。断点续传仍属于 P1b。

该本地阶段新增 42 项 Swift Testing 测试源码，执行数量为 0：本机没有可用 Swift 编译器，未安装工具链。
本地完整预推送检查最终 PASS（退出 0），其中 13 项 Python 检查脚本回归通过、49 个仓库 Swift 文件仅做语法解析。
首次检查退出 1 的原因是虚构 Pixiv 用户页 URL 命中个人路径规则，已改用排行榜 URL 保留路由边界测试，未放宽扫描器。
上述本地静态检查不能代替 Swift 编译；随后 Linux 真实结果见上节，Apple SDK 与运行时功能仍未验证。
DNS 预检不能固定 URLSession 最终连接 IP，仍有重绑定/TOCTOU 限制；系统 DNS/同步文件操作的取消只能等待返回。
P1 不支持无 HEAD/无受支持 MIME 的服务器、不做后台传输或自动续传；敏感直链重启后需重新提供再手动重试。
详细边界与 macOS/iOS SDK 候选验证命令见包说明；Linux Media 命令已按授权加入 core-linux。
源码阶段未改 Core/AppleServices 公共 API、UI、PoC、scripts 或 workflow；后续仅 core-linux 的改动已获用户授权，见上节。

## 历史：媒体模块 P0 接口审核（已通过）

已按用户指定读取 Claude 分支 a01e814 的 TASK_MEDIA_MODULES.md，仅编写
[MEDIA_INTERFACES.md](MEDIA_INTERFACES.md)；再按 b44ae48 的 MEDIA_INTERFACES_REVIEW.md
第 3 节完成 R1–R5 修订：全部断点续传移至 P1b 单独审核，P1 重试从零；增加 deleteFiles 和部分失败结果；
明确初始化失败可安全重建；P3 Ugoira 依赖 P2 默认转 GIF、原件可选保留；预留 B站全部分 P，未实现时明确拒绝。
再按 e3526f5 审核文件第 3b 节落实 R6：MediaSelection 仅保留通用选择，站点行为拆为可 Codable 的 SiteOptions，
两个 enqueue 重载及 prepare 显式传递选项；忽略不相关选项，仅生效选项参与去重/组装；队列冻结选项副本。
保留自动路由、FIFO 单活动槽、去重、历史、多文件、本地工具及全部既定媒体与搜图需求。
该文档阶段未创建 AIUtilityMedia 包、未写实现或媒体测试、未改 Core/AppleServices 公共 API、UI、PoC 或 workflow，
没有运行媒体编译/Actions。后续用户已审核 28c449d 并授权 P1；当前状态以上方 P1 记录为准。

## 最新工程集成完成验证（2026-11-08）

按本轮明确授权，在 Codex 分支集成 Claude 输入 fdb42c6，保留双方历史；PR #1/#2 与 main 均不合并。
UI/壁纸保持 Claude 原件，Core/PoC 保持已审查源码；无冲突。必要预推送误报修复及实际后续结果见
[INTEGRATION_STATUS.md](INTEGRATION_STATUS.md)。实际新源码 83ae71c 在
[42439552132](https://github.com/7869123/ios/actions/runs/42439552132) 四个 Job 全部 success，记录的命令均退出 0。
Core 每平台 36 通过/1 跳过；生命周期每平台 14 通过；Vision 2 通过、Keychain 1 跳过；本地安全检测 13 项通过。
四张 iPad mini / iPhone 原始横竖屏截图已重建并查看；大图仅保留 artifact，尺寸/摘要见验证报告。
PoC Swift 6 Archive、未签名 IPA 和 13 项预安装检查通过，仍没有任何 iPad 真机采集/Speech/PiP 成功结论。
本轮预推送完整 PASS，未改 Core 公共 API、Claude UI、壁纸或布局，等待 PR #2 人工审核。

## 独立工程审查完成验证（2026-11-08）

- 仓库已 public；main 保持 f17d20d，UI 分支 claude/ecstatic-planck-rzpvn6 保持独立，工程修复在 codex/poc-engineering-audit。
- 只读证据与 P0/P1/P2 分级、修复范围和实际 CI 失败原因见 [ENGINEERING_REVIEW.md](ENGINEERING_REVIEW.md)。未修改 UI/资源/Core。
- 旧 PoC 运行 42366153728 已证明 SDK 27.1 Archive、未签名 IPA、11 项预安装检查通过；下文早期“10 项”“没有 SDK/IPA”属于历史记录。
- 最终源码 `680f3d2` 在 [42378051064](https://github.com/7869123/ios/actions/runs/42378051064) 四个 job 全部 success：Linux/macOS Core 各 36 通过、1 跳过；Linux/macOS PoC 生命周期各 14 通过；Vision 2 通过、Keychain 1 跳过。
- PoC Swift 6 Simulator/iphoneos Archive、未签名 IPA、13/13 预安装检查通过；所有保存的命令退出码均为 0。旧 SDK 隔离错误与符号检查失败记录均保留在 [验证证据](validation/engineering-audit/README.md)。
- 工程修复见 [PR #2](https://github.com/7869123/ios/pull/2)，目标 Claude 分支，不合并 main。验证已集成至 d7859b0；后续 UI 6b335ab 未纳入本次完整 App 验证，三点差异不修改 UI，预合并检查无冲突。
- 编译不等于真机采集；iPad、免费签名和首次 USB 配对阻碍仍未解除。连续 ASR、非英文语言选择、现代渲染 API 迁移仍未完成；无真实付费 API 调用。

## 批量开发节奏与 CI 成本（2026-11-07）

- 改为批量本地开发、集中验证。PR 更新只跑 Linux Core；macOS 完整验证（Apple 包、App、截图）改为手动 `build_apple`，合并前必须通过；push 只在 main 触发完整链；同一引用的新运行取消旧运行。此前每次推送 PR 分支会触发两次 macOS 完整构建。
- 新增 `scripts/prepush_check.sh`：Swift 语法（tree-sitter，非类型检查）、源码卫生、plist、workflow YAML 与 shell 语法、资源完整性、`git diff --check`、个人信息与密钥扫描（已推送历史只报告，HEAD 与待推送提交有发现即阻止）。
- 本批 UI：输入框统一样式、inline 导航标题、媒体工具"规划中"样式与首页一致、壁纸预览跟随透明度设置。Core、AppleServices、iOS 27 PoC 未改动。
- 截至本批，透明度/外观改动（72fee54 起）尚未经 Apple SDK 编译：Actions 自 2026-11-07 12:16 UTC 起无法分配 runner。

## 透明度与「外观」设置（2026-11-07）

- 只调整透明度，不改布局。默认：毛玻璃白色叠层 10%（原 30%），材质不透明度 25%，壁纸遮罩 18%（原 35%），首页主卡 78%（原 94%）。
- 设置页新增「外观」：界面透明度、壁纸遮罩强度（0–100%，越高越透 / 遮罩越强），立即生效、持久化、可一键恢复默认。高透明度下通过白色描边、深色外描边、文字柔光和主卡局部阴影/渐变保证可读性；系统「降低透明度」仍强制不透明。
- 截图改为 App 内渲染窗口，修正横屏截图的方向问题。Core、AppleServices、iOS 27 PoC 未改动。

## UI 目标更正与首页原型（2026-11-07）

- UI 目标更正为 **iOS 原生结构 + 原创明快蓝白青风格**，不复刻任何游戏界面、不使用游戏素材。规范见 [UIUX_SPEC.md](UIUX_SPEC.md)。
- 新增首页工作台 `HomeView`（默认首页）、设计 token、斜角装饰、背景纹理、按压反馈；规划中功能明确标"规划中"，实时字幕标"PoC · 未经真机验证"。
- CI `app` job 在 iPad mini 与 iPhone 模拟器截取首页竖/横屏截图（artifact `app-screenshots-*`）供审核。Core、API 服务、iOS 27 PoC 未改动。

## iOS 27 PoC 安装前审查（2026-11-07）

- 真机安装暂停：用户仅能远程控制 Windows 11，iPad 无法 USB 连接，无付费开发者账号。**PoC 未通过任何真机验证。**
- xcode-27 上模拟器构建、真机 Release archive、未签名 IPA 打包与 10 项预安装审查全部通过；真机二进制确认链接 ScreenCaptureKit / Speech / AVKit。
- 免费 Personal Team：官方资料显示本 PoC 用到的 Background Modes 对免费层级可用，ScreenCaptureKit / PiP / Speech 无需 entitlement；但 `screen-capture` 在免费签名下能否实际授权采集未确认。Windows 侧载工具首次配对需 USB（第三方资料）。
- 完整报告与 Windows + 免费 Apple ID 安装步骤见 [INSTALL_PREFLIGHT.md](INSTALL_PREFLIGHT.md)。

## iOS 27 PoC CI 修正（2026-11-07）

- **原因**：`poc-sdk` 一直失败，是因为 `macos-latest` 镜像（macOS 26）最高只有 iOS 26.5 SDK，过不了 “Require iOS 27 SDK” 检查，PoC 源码从未被编译。
- **修正**：`poc-sdk` 改为 `runs-on: xcode-27`（arm64，镜像列出 Xcode 27.0 beta 27A5228h / iphoneos27.0），并在日志中记录 `sw_vers`、`xcodebuild -version`、`xcodebuild -showsdks` 以核实实际 macOS（README 快照写 26.5.2，GitHub 公告称 macOS 27）。其余 job 仍用 `macos-latest`。首次编译结果、退出码与关键日志见对应 PR。
- **API 边界**：`SCContentSharingPicker` 是 iOS 27 beta API；Apple 官方示例只采集屏幕画面与麦克风，没有官方示例证明能采到其他 App 的音频；`persistent-content-capture` 权限只适用于 macOS，iOS 用不到。
- **待真机验证的风险**：音频会话 `.playback` 与 `.playAndRecord` 对后台采集的影响；`ScreenAudioProbe.start()` 失败时会重复 stop；Host 的 ASR 写死为 en-US，需改为目标语言。详见 [IOS_POC.md](IOS_POC.md)。
- ReplayKit 对照探针暂不新增，待首次编译结果后再决定。

## 第二阶段初步 SwiftUI App 完成构建验证（2026-11-07）

[最终全链路 CI 42354651780](https://github.com/7869123/ios/actions/runs/42354651780)，源码 `19d0e02`：Linux、Apple 包、SwiftUI App 全部成功。第一阶段完成记录已提交为 `6c0fdf4`，在此之后才开始 App 代码。

| 范围 | 真实结果 |
|---|---|
| Linux Core / macOS Core | 各 36 项通过、1 项真实 API 集成测试跳过、0 失败 |
| AppleServices macOS | 2 项 Vision 测试通过、1 项 Keychain 运行时测试跳过、0 失败 |
| Apple 包 SDK | Simulator 与 iphoneos 未签名构建成功 |
| SwiftUI App | XcodeGen 生成、Simulator 构建、iphoneos 构建全部退出 0 |
| 页面 | 原创浅色青蓝工作台；自适应导航、截图 OCR/翻译、字幕文本翻译、设置、媒体功能目录 |
| 服务接线 | 唯一 AppModel 持有真实 Services；共享 Key、独立模型、验证保存/切换、目录、取消、预算与安全错误文案接入 |
| Core 改动 | 生产源码相对 051d58c 未变；仅修复真实 Apple CI 发现的一处测试宏兼容问题 |
| 尚未验收 | UI 交互/布局截图、真实 API、iOS Keychain/真实截图 OCR、iOS 27 音频/Speech/PiP、签名安装与 iPad 真机 |

工程入口见 [Apps/AIUtility](Apps/AIUtility/README.md)，架构见 FRONTEND.md，交接见 HANDOFF.md，后续验证见 VALIDATION_PLAN.md。证据、实际退出码和源码树摘要见 [validation/swiftui-app](validation/swiftui-app/summary.json)。媒体目录为明确标记的后续能力，并未虚构下载或转换实现。

本轮所有 push 保留原历史、未强制推送。没有提交真实 Key、Token、证书或签名产物；没有在 Windows 安装 Swift。下文为各阶段历史记录，当前能力边界以上表为准。

## 第一阶段 Apple 验证通过（2026-11-07）

[运行 42353675493](https://github.com/7869123/ios/actions/runs/42353675493)，源码提交 `a11ccc4`：Linux Core 与 macOS Apple 验证全部成功。macOS 26.7.2 / Xcode 26.6 / Apple Swift 6.3.3 / iOS SDK 26.5。

- macOS Core：36 项通过、1 项真实 API 测试跳过、0 失败；Linux Core 同样通过。
- AppleServices：2 项 Vision 测试实际通过（合成英文图识别、非法数据拒绝），1 项 Keychain 运行时测试按配置跳过。
- Keychain、Vision、生产服务入口及其 Core 依赖通过 iOS Simulator 与 iphoneos SDK 的真实未签名构建，两个退出码均为 0。
- 唯一所需源码调整是测试表达式拆分，修复 Apple Swift Testing 的可选链宏展开错误；没有重写 Core 生产逻辑、删测试或使用空实现。

证据保存在 [validation/apple-platform](validation/apple-platform/summary.json)。这些结果不等于真实 Keychain/iOS OCR、签名安装、iPad 跨 App 音频、Speech/PiP 或三家真实 API 已通过。runner 缺少 iOS 27 SDK，iOS 27 PoC 未编译。

第二阶段 SwiftUI App 在上述第一阶段成功后开始；第一阶段记录提交时尚未加入前端代码，后续结果见本文首节。

## 当前真实验证结论（2026-11-07）

**AIUtilityCore 已在 GitHub Actions 的 Swift 6.0.3 / Linux 上真实编译并通过单元测试。** 仓库为用户的私有仓库 [7869123/ios](https://github.com/7869123/ios)，main 使用普通 push，已有历史和源码完整保留。

| 项目 | 实际结果 |
|---|---|
| 已验证运行 | [42335206895](https://github.com/7869123/ios/actions/runs/42335206895)，源提交 3263a5a |
| `swift --version` | 退出 0，Swift 6.0.3，x86_64-unknown-linux-gnu |
| `swift build --package-path Packages/AIUtilityCore` | 退出 0，真实编译通过 |
| `swift test --package-path Packages/AIUtilityCore` | 退出 0，测试模块编译并执行通过 |
| Swift Testing 逐项统计 | 发现 37 项；36 通过、1 跳过、0 失败；参数化部分实际执行 18 组参数 |
| 跳过内容 | liveOfficialAPI，未提供/使用真实 API Key，未进行付费调用 |
| 真实修复 | 首次运行中测试宏递归展开、宏内 throwing 调用错误；已拆为独立读取/解析再断言，未删断言 |
| 日志保存 | 失败和成功两轮均成功上传且下载核对四个指定证据文件；未上传 .build 或构建缓存 |
| Apple / iOS / 真机 | Apple 包、Keychain、Vision、iOS SDK、iPad 音频/Speech/PiP 均未验证 |

Swift Testing 聚合输出为“37 tests passed”，含禁用项；本报告按逐项记录列为 36 实际通过 + 1 跳过。XCTest 兼容层的 0 tests 不是 Swift Testing 的运行数。完整记录及原始日志见 [验证证据](validation/github-actions/README.md) 和 [机器摘要](validation/github-actions/summary.json)。

Windows 未安装 Swift；浏览器授权由用户手动完成，GitHub Token 仅由系统凭据管理器保管/在内存使用。推送前对全部可达 Git 历史扫描，未发现真实密钥/私钥/个人邮箱或大文件，历史开发路径已披露。所有既定媒体工具、截图翻译、实时字幕仍在范围内；本轮没有扩展正式 UI（UI 目标已于 2026-11-07 更正为 iOS 原生结构 + 原创明快蓝白青风格，见 UIUX_SPEC.md）。

以下保留各轮历史过程，旧的“未编译/0 项执行”只描述当时状态。

## GitHub Actions 接入准备（历史过程）

按最新要求停止尝试 Windows Swift 工具链。现有 workflow 已收紧为默认只验证 Core，失败时尝试上传四个明确日志文件与真实退出码，保留 7 天，不上传 API Key、.build 或构建缓存。Apple / PoC 仅手动开启，且依赖 Core 成功。

已配置用户指定的 origin：`https://github.com/7869123/ios.git`，用户已通过浏览器手动登录。GitHub API 确认仓库为 private 且具备 push 权限，首次推送前远程为空。历史敏感模式扫描检查 59 个 blob，未发现密钥/Token/私钥、真实个人邮箱或大文件；最大 blob 为 11,979 字节。历史文档含本地开发路径，提交使用占位作者；这些环境元数据保留在既有历史中。

本段记录推送前准备状态，尚未取得远端编译结果。Core 是否通过以稍后记录的 Actions 运行和真实测试统计为准。接入步骤见 [GITHUB_ACTIONS.md](GITHUB_ACTIONS.md)。`scripts/github_actions.py` 仅从系统凭据管理器在内存读取 GitHub 授权，日志存入忽略的 artifacts/，不打印或保存 Token。

## 第二轮工程验证（历史：2026-11-07）

**第二轮结束时尚未通过真实 Swift 编译与测试。** 基线 `f2b766e` 和现有源码完整保留；没有重建项目，没有安装大型全局依赖。该轮源码修复属于静态审计成果；其后真实 CI 结果见本文首节。

| 项目 | 第二轮实际结果 |
|---|---|
| 可用环境 | Windows 无 Swift/C++/Windows SDK、Docker/Podman、可用 WSL；现有 Node 执行环境也是 win32；无 Git remote / gh / 已配置 SSH 编译入口 |
| 验证命令 | `python scripts/verify_core.py --output validation/round2-core`；实际使用既有 Codex Python 路径 |
| 验证启动器退出码 | **2**（找不到 Swift） |
| Swift 编译器退出码 | **null / 不适用**：`swift --version`、`swift build`、`swift test` 均未启动 Swift 进程 |
| Swift 测试 | 实际执行 **0**；通过 0、失败 0，属于环境阻塞 |
| 测试源码 | 现有 **40 个 @Test 声明**（Core 37 / Apple 3，含参数化与默认禁用的集成测试）；均不能据此认定通过 |
| 已改源码 | OpenAI 过滤/截断分类和 message 读取、错误 code/type 容错、整批模型验证的总时限 |
| 新增回归场景 | 迟到成功与取消、并发保存/切换、跨供应商编辑、三家拒绝/截断回滚、重试取消、分页预算 |
| CI | 已补构建/测试日志与退出码保存、job 时限；**未触发运行** |
| Apple SDK / 真机 | 均未验证；已列出具体符号、隔离与生命周期风险 |
| 审查交付 | `scripts/package_review.py` 生成源码 ZIP、完整历史 bundle、SHA-256 与清单；流程见 REVIEW.md |

本轮没有执行 tree-sitter。Python 脚本检查、Git 差异检查和打包校验只对各自范围有效，均不能代替 Swift 编译。详细结果见 [第二轮审计](validation/round2-audit.md) 与 [机器报告](validation/round2-core/summary.json)。

最小成本下一步：将 ZIP 放入已有 Swift 6/Linux 环境执行 Core 编译/测试，或推送至用户自己的仓库触发已准备的 Linux CI。当前缺少可用入口，本轮没有擅自创建远程仓库。Apple 部分仍需 Mac、iOS 27 SDK 和目标 iPad。

以下保留第一轮交付记录，历史测试数量不代表当前数量。

## 第一轮记录

记录日期：2026-11-07。本轮交付为实际源码、自动化测试和本地 Git 提交，尚未通过 Swift 编译及设备验收。

## 环境检查

工作目录最初为空，没有 Git 仓库、已有源码或 AGENTS.md。已在该目录初始化 Git，未覆盖用户文件。Git 可用；全局作者信息未设置，本轮提交使用单次命令指定的本地开发作者，不修改全局配置。

本机为 Windows 11；PATH 中没有 Swift、clang 或 Xcode。检查未发现 Visual Studio C++ / Windows SDK 工具链；WSL 报告尚未安装。没有 Mac、Apple SDK、开发者签名或已连接的 iPad 调试会话。本轮没有安装全局编译环境。首台目标设备按用户提供记录为 iPad mini 6 / iPadOS 27.2，尚未实际连接核验。

## 已实现的源码

| 模块 | 已落地内容 | 验收状态 |
|---|---|---|
| AIUtilityCore | 独立 Swift 6 Package；领域类型、协议、错误分类 | 源码已写，未编译 |
| 三家官方 API | DeepSeek Chat Completions、Anthropic Messages、OpenAI Responses；动态模型目录、Anthropic 分页、指定模型请求、响应解析 | 语法检查通过；未联网调用真实模型 |
| 网络控制 | URLSession 临时会话、不保存缓存/凭据/Cookie、拒绝重定向、任务取消、总时限 | 源码与测试已写，运行待验证 |
| 配置事务 | 每供应商一个 Key 与两个功能独立绑定；保存 Key 时验证所有唯一模型；切模型复用 Key；失败、取消、超时保持旧记录 | 测试已写，运行待验证 |
| 翻译与预算 | 可注入引擎、会话级调用次数和输出 token 预留、有限重试、敏感字段保护 | 测试已写，运行待验证 |
| AppleServices | Keychain 单记录更新、本机解锁访问、不云同步；Vision OCR 本地识别、坐标、置信度、取消 | 未经 Apple SDK 编译/执行 |
| 生产接线 | AIUtilityServices 连接官方适配器、Keychain、Vision；生产无 Mock 回退 | 未经 Apple SDK 编译 |
| iOS 27 PoC | 系统选择器、SCStream 音频、缓冲/RMS 诊断、本地 ASR、字幕视频帧、AVKit PiP、翻译引擎接入 | **未成功验收**，详情 IOS_POC.md |
| 自动化 | Swift Testing 测试、可选真实 API/Keychain 集成测试、Linux/macOS CI、可选 iOS 27 SDK 构建 | 尚未运行 Swift 测试 / CI |

测试中的 ScriptedTransport 和 TestCredentialStore 仅存在于 Tests；生产走真实网络与系统服务。模型列表读取不视为 Key 验证，保存流程必须收到指定模型的完整非空生成结果。

## 实际执行结果

| 检查 | 真实结果 |
|---|---|
| `swift --version` | 失败：找不到 Swift |
| `scripts/test.ps1` | 已尝试，退出码 2，因 Swift 缺失退出；**0 项 Swift 测试执行** |
| `scripts/check_repository.py --swift-grammar` | 通过：24 个 Swift 文件的语法树解析、源码日志/疑似密钥扫描、plist 解析；工具 tree-sitter 0.26.0 + tree-sitter-swift 0.7.4 |
| `git diff --check` | 通过（提交前同时检查暂存区） |
| 官方资料核对 | 已读取三家 API 文档及 Apple iOS 27 示例文档；属于资料核对，不能替代编译/真机 |
| 真实模型调用 | 未运行：没有测试 Key；未产生 API 验证成功结论 |
| Keychain / Vision | 未运行：没有 Apple 环境 |
| iPad 跨 App 音频 / PiP | 未运行：没有 Mac 签名构建及真机调试通道 |

语法解析不是 Swift 类型检查；测试源码存在不等于测试通过。CI 文件已准备，但当前没有远程仓库，未触发任何云端工作流。后续编译可能暴露类型或 SDK 兼容问题，需依据真实编译结果修正。

第一轮有 29 个 @Test 声明，供应商参数化后展开更多用例；不代表已执行或通过。原始结果摘要见 [第一轮验证记录](validation/2026-11-07-windows.md)。

## 当前阻碍及下一步

1. 在具备 Swift 6 的环境执行 Core 测试并修复实际编译问题；Windows 也需要 C++ 工具与 Windows SDK。
2. 在 Mac/Xcode 执行 Apple 包测试与 iOS 模拟器构建。Keychain 集成测试单独显式启用。
3. 用每供应商的测试 Key 和明确模型执行可选付费集成测试；不得把 Key 上传到仓库或聊天。
4. 在支持 iOS 27 的 Xcode 中构建、签名并安装诊断工程，在 iPad mini 6 / 27.2 上完成 IOS_POC.md 的矩阵与证据记录。
5. 当前 ASR PoC 为单段会话；连续重启、长期音频转换和字幕时序仍需真机实验后设计。未实现正式实时字幕产品。

## 已确认、继续保留的产品范围

- X 视频下载。
- Pixiv 原画和 Ugoira。
- B 站视频下载。
- 视频转 GIF。
- 图片文件指纹修改。
- 多图拼接。
- SauceNAO / 搜图 Bot 酱。
- 统一下载任务与历史记录。
- Discord 截图翻译、视频翻译。
- 最终 SwiftUI 界面：iOS 原生结构 + 原创明快蓝白青风格（2026-11-07 更正，不再以复刻任何游戏界面为目标），见 UIUX_SPEC.md。

上述媒体与搜图功能尚未实现，不计入本轮完成项；它们没有被移出后续范围。
