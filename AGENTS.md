# AIUtility 协作规则（Claude Code 与 Codex 共用）

本文件对所有在本仓库工作的 AI 代理生效。Codex 读取 `AGENTS.md`；Claude Code 读取 `CLAUDE.md`，后者直接引用本文件，所以两边规则始终一致。规则冲突时以仓库所有者（用户）在对话中的最新指示为准。

## 1. 沟通

- 全程使用中文回复，包括中间过程说明。
- 提到时间时写用户所在时区 **UTC−5**，不要默认其他时区。
- 每轮汇报按「已完成 / 正在做 / 未完成」三段输出，并给出提交 SHA、CI 运行链接（如有）和剩余问题。
- 如实汇报：失败就给出真实日志；跳过的步骤要说明；不确定的内容标为"未确认"。

## 2. 分支与合并

| 代理 | 工作分支 |
|---|---|
| Claude Code | `claude/ecstatic-planck-rzpvn6`（PR #1） |
| Codex | `codex/poc-engineering-audit` |

- 只在自己的分支上工作。**不读取、不合并、不修改、不推送**另一方的分支，也不把对方的提交拉进自己的分支。禁止执行 `git merge origin/<对方分支>`、`git pull origin <对方分支>`、`git cherry-pick <对方提交>` 等操作。例外：读取本文件这类用户明确指定的单个文件。
- **不合并到 main，不 force push，不改写已推送的历史**。以上操作必须先得到用户明确授权。
- 需要对方的改动（例如 App 接入新的后端接口）时，先向用户说明需要合并或调整什么，等用户决定。

## 2b. 变更通知

每次推送后，在汇报里附一份给另一方的「变更通知」，至少包含：

1. 提交 SHA 与改动的文件或目录；
2. **接口变化**：公开类型、方法签名、参数、错误类型、默认值或行为语义的新增、修改、删除（例如 `AIUtilityServices`、`MEDIA_INTERFACES.md` 中的契约）。没有变化也要写"无接口变化"；
3. **工具变化**：`scripts/`、`.github/workflows/`、预推送检查规则、构建或测试命令、依赖的工具或版本的变化，以及对方需要做什么（例如重新运行检查、更新本地工具）。没有变化也要写"无工具变化"；
4. 对方是否需要同步、集成或调整，以及原因。

变更通知只描述改动，不代表对方可以合并或拉取分支；集成仍需用户授权。

## 3. 动手前检查

每次修改代码前：

1. `git fetch`，检查**自己的分支**和 `main` 在远端是否有新提交。
2. 有新提交：`git pull --ff-only` 后再改，不覆盖别人的改动。
3. 出现冲突：停下来向用户报告冲突位置，不自行决定保留哪边。
4. 自己的分支上出现不属于自己（也不是 CI bot）的提交：先报告，不擅自合并或回退。

## 4. 职责范围

| 范围 | 负责方 |
|---|---|
| `Packages/AIUtilityCore`、`Packages/AIUtilityAppleServices`（后端） | Codex |
| `Apps/AIUtility`（SwiftUI 界面）、`.github/workflows`、`scripts`、UI 相关文档 | Claude Code |
| `PoCs/iOS27Capture`（iOS 27 采集 PoC） | 未经用户授权，双方都不修改 |

- 后端对 App 暴露的接口（`AIUtilityServices` 及其方法、参数、错误类型）发生变化时，在提交说明和汇报里写清楚变化，方便另一方接线。
- 不做与当前需求无关的重构。

## 5. CI（GitHub Actions）

- **触发任何 Actions 运行前先问用户**，包括手动 `build_apple`、`build_poc`、`publish_previews` 和重跑。询问时说明这一批包含哪些改动、为什么需要验证。
- 采用**批量开发、集中验证**：小改动只在本地提交，攒成一批相关改动后再集中推送。
- 每次推送前运行 `scripts/prepush_check.sh`（Swift 语法、源码卫生、plist、workflow/shell 语法、资源完整性、`git diff --check`、敏感信息扫描），必须 PASS。它不能代替 Apple SDK 编译。
- 推送到 PR 分支只会自动运行 Linux Core；macOS 完整验证只通过手动 `build_apple`，合并前必须通过一次。
- CI 失败时，根据真实日志集中修复，不要反复盲目触发。

## 6. 个人信息与密钥

- 不得提交：本地路径（Windows 用户目录、macOS 或 Linux 用户主目录下的路径）、本机用户名或电脑名、时区或地点信息、个人邮箱、手机号、API Key、Token、证书、描述文件、设备 UDID、开发团队 ID。
- 提交时间使用 UTC，避免在公开仓库暴露所在时区：每次提交都在命令前加 `TZ=UTC`（例如 `TZ=UTC git commit -m "..."`），或在当前终端先执行 `export TZ=UTC`。用 `git log -1 --format=%ad --date=format:%z` 检查，结果应为 `+0000`。
- 提交作者使用占位身份：`git config user.name "AIUtility Development"`，`git config user.email "aiutility@localhost"`（`scripts/prepush_audit.py` 只允许占位身份、Claude 和 CI bot 的 noreply 地址）。
- 测试只能用明显的假数据（如 `person@example.com`、`sk-test-...`）。
- 仓库现在是公开的，提交前务必通过 `scripts/prepush_check.sh` 的敏感信息扫描。

## 7. 质量与诚实

- 不要声称 iOS 27 PoC 或任何功能已通过真机验证，除非用户提供了真机结果。
- 不要把未实现的功能（媒体下载、转换、搜图等）做成或描述成可用；界面上统一标"规划中"。
- 修改 Core、AppleServices 后，保证现有测试通过，不删除或弱化测试。
- UI 采用 iOS 原生结构和原创风格，不复刻任何现有游戏的界面，也不使用游戏素材。
