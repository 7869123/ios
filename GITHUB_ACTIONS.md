# GitHub Actions 验证与历史接入指南

当前远程是 `https://github.com/7869123/ios.git`，仓库已 **Public**，无需重新建库或配置 origin。下文第 1–2 节保留历史接入说明；当前工程审查结果见 [ENGINEERING_REVIEW.md](ENGINEERING_REVIEW.md)。旧的 `scripts/github_actions.py` 仍要求 private，暂不适用于当前公开仓库；可用 Actions 页面或已授权 GitHub API，勿为此提供 Token 到聊天或 Git。

本机不再安装或尝试配置 Windows Swift 工具链。保留现有 main 和全部提交，优先在 GitHub Actions 的 Linux 官方 Swift 6.0.3 容器运行真实编译和离线测试。

## 1. 创建空的私有仓库

在 GitHub 登录自己的账户，打开 [创建仓库](https://github.com/new)，例如命名为 AIUtility，明确选择 **Private**。不要添加 README、License 或 .gitignore，避免产生与现有历史无关的初始提交。此项目已经有 Git 仓库，无需 git init。

创建后复制 HTTPS 地址，例如 `https://github.com/YOUR_NAME/AIUtility.git`。只需要提供仓库地址，不需要向聊天发送密码、Personal Access Token 或任何 AI API Key。

## 2. 在本项目目录推送

以下是尚未配置 origin 时的历史步骤。当前已配置，不要重复执行 `remote add`，不要重建项目：

```powershell
git status --short --branch
git remote add origin https://github.com/YOUR_NAME/AIUtility.git
git push -u origin main
```

如果 origin 已经配置，先用 `git remote -v` 核对，使用已有正确 origin 即可；不要反复添加，也不要覆盖指向其他项目的 remote。推送遇到非快进错误时保留双方提交，由后续排查处理，不使用强制推送。

本机已有 Git Credential Manager，首次 HTTPS 推送可能需要在浏览器登录 GitHub。浏览器授权不需要把凭据发送到聊天。无需 gh CLI，也无需为此安装 Swift。

推送成功后可运行以下命令查看本地提交与上游同步状态：

```powershell
git status --short --branch
git log -1 --oneline
```

GitHub 官方流程见 [推送本地仓库](https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/adding-locally-hosted-code-to-github)。

## 3. 找到真实 Actions 结果

源码 push 会触发 **Swift validation → core-linux**，依次执行：

```sh
swift --version
swift build --package-path Packages/AIUtilityCore
swift test --package-path Packages/AIUtilityCore
swift test --package-path PoCs/iOS27Capture
```

无需配置任何仓库 API Secret。付费 API 与 Keychain 集成测试均关闭。

### 触发策略（2026-11-07 起）

仓库已公开，标准 hosted runner 可用于验证；继续避免重复构建。此前 PR 分支 push 与 pull_request 会重复运行 macOS，现调整为：

| 事件 | 运行的 job | 说明 |
|---|---|---|
| pull_request（每次 PR 更新） | core-linux | 仅 Linux，快速检查 |
| push | 只在 main 上触发：core-linux → apple → app | 合并后的完整验证（PR 分支上的 push 不再重复触发） |
| 手动 workflow_dispatch，`build_apple` | core-linux → apple → app（含截图） | **合并 PR 前必须跑一次并通过** |
| 手动，`build_poc` | core-linux → poc-sdk（xcode-27） | 仅在 PoC 源码或其 CI 变更时需要 |
| 手动，`publish_previews`（配合 `build_apple`） | app 末尾提交缩小的截图到 `validation/ui-preview/` | 该 job 为此拥有 `contents: write` |

同一分支或引用上的新运行会自动取消尚在进行的旧运行（`concurrency`）。仅 Markdown 或 validation 证据变更不触发构建。

开发节奏：批量本地开发，推送前运行 `scripts/prepush_check.sh`（语法、资源、diff 与敏感信息扫描），一批相关改动完成后再手动跑一次 `build_apple` 完整验证；失败时根据真实日志集中修复后再触发。默认跳过的运行时测试和 PoC 不能标成通过。

打开仓库 **Actions → Swift validation**，核对目标分支和源 SHA。工程审查在 `codex/poc-engineering-audit` 同时勾选 build_apple/build_poc，保持 publish_previews=false，避免向 Claude 分支写入截图。不要触发或取消他人的运行。PR 与手动运行使用不同 ref，不能假定它们会互相取消。

## 4. 构建失败同样保存证据

Core 步骤显式记录每个真实退出码，构建失败后仍会尝试测试；任一失败最终都让该步骤失败。上传步骤使用 `always()`，在 checkout 成功后即使构建/测试失败也会尝试保存以下五个文件：

- swift-version.log
- core-build.log
- core-tests.log
- poc-lifecycle-tests.log（可移植状态机，不是 Apple 框架运行时测试）
- exit-codes.txt

artifact 名为 `core-linux-evidence-运行ID-尝试次数`，保留 7 天；只上传这些指定日志，不上传目录通配符、.build、DerivedData、.env、整个仓库或下载缓存。没有 actions/cache，也不导出环境变量。Checkout 使用只读 contents 权限且不持久化 Git 凭据。

如果 checkout / 容器拉取本身失败，尚未产生 Swift 日志，应读取对应 Actions 步骤错误；平台故障、强制终止或整台 runner 丢失时不能保证 artifact 上传成功。不能把“上传步骤已配置”当作“日志已在远端保存”。[GitHub artifact 说明](https://docs.github.com/en/actions/tutorials/store-and-share-data)。

## 5. 继续修复的交接内容

提供仓库地址和该次 Actions 运行链接；若已授权本会话访问 GitHub 私有仓库，可直接读取结果并修复。否则从该运行页面下载日志 artifact 提供给后续审阅，不要提供 Token。每次修复提交再 push，检查同一新提交的 core-linux 结果和真实测试统计，直至编译与 Core 测试通过。

目标仓库现已指定为 `https://github.com/7869123/ios.git`，API 确认为私有，用户已通过 Git Credential Manager 浏览器登录。运行记录见 STATUS.md；iOS 真机功能仍需独立验收。

main 已成功推送，首轮测试编译错误已修复。[已通过运行 42335206895](https://github.com/7869123/ios/actions/runs/42335206895)：版本/build/test 退出码全部 0，36 项通过、1 项真实 API 测试跳过。失败 artifact 也已实际下载验证，包含且仅包含四个预期日志。

维护辅助命令（需要系统凭据管理器已有登录，不传 Token 参数）：

```sh
python scripts/prepush_audit.py
python scripts/github_actions.py inspect
python scripts/github_actions.py runs --sha YOUR_COMMIT_SHA
python scripts/github_actions.py jobs --run-id RUN_ID
python scripts/github_actions.py logs --run-id RUN_ID
python scripts/github_actions.py evidence --run-id RUN_ID
```

helper 不打印 Token，不将认证头转发给签名下载地址，CI 日志只写到被忽略的 artifacts/。`dispatch` 子命令可在 push 未触发时手动运行 main 的 Core workflow；不启用 Apple 选项。
