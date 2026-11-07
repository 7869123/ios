# AIUtility 开发状态

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
