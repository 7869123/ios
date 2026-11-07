# AIUtility 开发状态

## GitHub Actions 接入准备（2026-11-07）

按最新要求停止尝试 Windows Swift 工具链。现有 workflow 已收紧为默认只验证 Core，失败时尝试上传四个明确日志文件与真实退出码，保留 7 天，不上传 API Key、.build 或构建缓存。Apple / PoC 仅手动开启，且依赖 Core 成功。

目前未收到个人 GitHub 私有仓库地址，尚无 origin；Git Credential Manager 可用，但没有确认已登录的 GitHub 账户。尚未推送或运行 Actions，Core 实际编译/测试通过数仍为 0。接入与认证步骤见 [GITHUB_ACTIONS.md](GITHUB_ACTIONS.md)。这不是新的编译验证成功记录。

## 第二轮工程验证（2026-11-07）

**仍未通过真实 Swift 编译与测试。** 基线 `f2b766e` 和现有源码完整保留；没有重建项目，没有安装大型全局依赖。本轮的源码修复属于静态审计成果，不能称为编译错误已修复或测试通过。

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

记录日期：2026-11-07（Asia/Shanghai）。本轮交付为实际源码、自动化测试和本地 Git 提交，尚未通过 Swift 编译及设备验收。

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
- 最终 SwiftUI 界面高保真复刻《Blue Archive（蔚蓝档案）》的布局与交互视觉；本轮没有制作正式 UI 或游戏素材。

上述媒体与搜图功能尚未实现，不计入本轮完成项；它们没有被移出后续范围。
