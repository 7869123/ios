# AIUtility 开发规则

本文件对在本仓库工作的 AI 代理生效。Claude Code 读取 `CLAUDE.md`，后者直接引用本文件。规则冲突时以仓库所有者（用户）在对话中的最新指示为准。

2026-11-15 起，所有者决定整个仓库只由 Claude Code 开发和维护，Codex 不再参与。

## 1. 沟通

- 全程使用中文回复，包括中间过程说明。
- 提到时间时写用户所在时区 **UTC−5**，不要默认其他时区。
- 每轮汇报按「已完成 / 正在做 / 未完成」三段输出，并给出提交 SHA、CI 运行链接（如有）和剩余问题。
- 如实汇报：失败就给出真实日志；跳过的步骤要说明；不确定的内容标为"未确认"。

## 2. 分支与合并

| 代理 | 工作分支 |
|---|---|
| Claude Code | `claude/ecstatic-planck-rzpvn6`（PR #1） |

- 只在这个分支上工作。原 Codex 分支 `codex/translation-completeness`（末端 `a6010e3`）和 `codex/poc-engineering-audit`（末端 `85da47b`）都已完整合入本分支，不再使用；不在其上推送，删除与否由所有者决定。
- **不合并到 main，不 force push，不改写已推送的历史**。以上操作必须先得到用户明确授权。

## 2b. 改动记录

不再需要给另一方的变更通知。公开接口（例如 `AIUtilityServices`、`MEDIA_INTERFACES.md` 中的契约）或工具（`scripts/`、`.github/workflows/`、构建与测试命令）发生变化时，写进提交说明，并同步更新对应文档（`TRANSLATION_CLAUDE_HANDOFF.md`、`MEDIA_INTERFACES.md`、`GITHUB_ACTIONS.md`、`STATUS.md`）。

## 3. 动手前检查

每次修改代码前：

1. `git fetch`，检查**自己的分支**和 `main` 在远端是否有新提交。
2. 有新提交：`git pull --ff-only` 后再改，不覆盖别人的改动。
3. 出现冲突：停下来向用户报告冲突位置，不自行决定保留哪边。
4. 分支上出现不是自己（也不是 CI bot）的提交：先报告，不擅自合并或回退。

## 4. 职责范围

全部由 Claude Code 负责（2026-11-15 起）：

| 范围 | 内容 |
|---|---|
| `Packages/AIUtilityCore`、`Packages/AIUtilityAppleServices` | 翻译、配置、OCR 等底层（原由 Codex 开发） |
| `Packages/AIUtilityMedia` | 下载队列、站点解析、本地工具、搜图 |
| `Apps/AIUtility` | SwiftUI 界面 |
| `PoCs/iOS27Capture` | iOS 27 采集 PoC（真机能力未验证，修改时保持「技术诊断 · 未验收」的定位） |
| `.github/workflows`、`scripts`、文档 | CI、检查脚本与全部文档 |

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
- 提交作者身份：`git config user.name "Claude"`，`git config user.email "noreply@anthropic.com"`（GitHub 显示为 Verified）。历史提交里的占位身份 `AIUtility Development <aiutility@localhost>` 来自原 Codex，`scripts/prepush_audit.py` 仍允许它、Claude 和 CI bot 的 noreply 地址。
- 测试只能用明显的假数据（如 `person@example.com`、`sk-test-...`）。
- 仓库现在是公开的，提交前务必通过 `scripts/prepush_check.sh` 的敏感信息扫描。

## 7. 质量与诚实

- 不要声称 iOS 27 PoC 或任何功能已通过真机验证，除非用户提供了真机结果。
- 不要把未实现的功能（媒体下载、转换、搜图等）做成或描述成可用；界面上统一标"规划中"。
- 修改 Core、AppleServices 后，保证现有测试通过，不删除或弱化测试。
- UI 采用 iOS 原生结构和原创风格，不复刻任何现有游戏的界面，也不使用游戏素材。
