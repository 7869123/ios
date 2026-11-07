# 将现有项目推送到个人私有仓库并验证 Core

本机不再安装或尝试配置 Windows Swift 工具链。保留现有 main 和全部提交，优先在 GitHub Actions 的 Linux 官方 Swift 6.0.3 容器运行真实编译和离线测试。

## 1. 创建空的私有仓库

在 GitHub 登录自己的账户，打开 [创建仓库](https://github.com/new)，例如命名为 AIUtility，明确选择 **Private**。不要添加 README、License 或 .gitignore，避免产生与现有历史无关的初始提交。此项目已经有 Git 仓库，无需 git init。

创建后复制 HTTPS 地址，例如 `https://github.com/YOUR_NAME/AIUtility.git`。只需要提供仓库地址，不需要向聊天发送密码、Personal Access Token 或任何 AI API Key。

## 2. 在本项目目录推送

当前尚无 origin。确认 URL 属于你自己的私有仓库，然后在项目终端运行，将示例 URL 换成你的真实地址：

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

首次 push 会触发 **Swift validation → core-linux**，依次执行：

```sh
swift --version
swift build --package-path Packages/AIUtilityCore
swift test --package-path Packages/AIUtilityCore
```

无需配置任何仓库 API Secret。付费 API 与 Keychain 集成测试均关闭。普通 push / pull_request 只跑 Core；macOS 和 iOS 27 PoC 需手动运行 workflow 并显式选择 `build_apple` / `build_poc`，且先通过 Core。不要因这两个任务默认跳过而认为 Apple 功能已验证。

打开仓库 **Actions → Swift validation → 对应 main 提交的运行**。如果 Actions 被禁用，先在 Settings → Actions → General 允许此仓库运行所用官方 actions；不需要增加工作流写权限。手动 Run workflow 也可以补触发，首次只选 main，两个 Apple 选项保持关闭。

## 4. 构建失败同样保存证据

Core 步骤显式记录每个真实退出码，构建失败后仍会尝试测试；任一失败最终都让该步骤失败。上传步骤使用 `always()`，在 checkout 成功后即使构建/测试失败也会尝试保存以下四个文件：

- swift-version.log
- core-build.log
- core-tests.log
- exit-codes.txt

artifact 名为 `core-linux-evidence-运行ID-尝试次数`，保留 7 天；只上传这些指定日志，不上传目录通配符、.build、DerivedData、.env、整个仓库或下载缓存。没有 actions/cache，也不导出环境变量。Checkout 使用只读 contents 权限且不持久化 Git 凭据。

如果 checkout / 容器拉取本身失败，尚未产生 Swift 日志，应读取对应 Actions 步骤错误；平台故障、强制终止或整台 runner 丢失时不能保证 artifact 上传成功。不能把“上传步骤已配置”当作“日志已在远端保存”。[GitHub artifact 说明](https://docs.github.com/en/actions/tutorials/store-and-share-data)。

## 5. 继续修复的交接内容

提供仓库地址和该次 Actions 运行链接；若已授权本会话访问 GitHub 私有仓库，可直接读取结果并修复。否则从该运行页面下载日志 artifact 提供给后续审阅，不要提供 Token。每次修复提交再 push，检查同一新提交的 core-linux 结果和真实测试统计，直至编译与 Core 测试通过。

当前尚未收到目标仓库地址，未推送、未触发远端 CI，仍没有 Swift 编译或测试通过记录；iOS 真机功能也未验证。
