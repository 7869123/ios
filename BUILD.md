# 构建与测试

Apple 第一阶段已通过：见 [42353675493](https://github.com/7869123/ios/actions/runs/42353675493)。`bash scripts/ci_apple.sh` 保存环境、macOS Core/AppleServices 测试、iOS 模拟器/设备 SDK 未签名构建的五个退出码，均为 0。环境 Xcode 26.6、Swift 6.3.3、iOS SDK 26.5。普通 push 现在同时保留 Linux 与 Apple 验证；无需 Windows Swift。Keychain 运行时测试仍关闭；iOS 27 SDK、签名和真机另行验证。

SwiftUI App 位于 Apps/AIUtility。`bash scripts/ci_app.sh` 生成真实 Xcode 工程，并构建 Simulator/iphoneos 两个目标。最终成功运行 [42354651780](https://github.com/7869123/ios/actions/runs/42354651780)，source 19d0e02，四个退出码均为 0。生成的 .xcodeproj、DerivedData 和 .app 不提交、不上传；只保存五个指定日志。App 构建步骤依赖 Linux 和 Apple 验证通过。

单独在 Mac 使用 XcodeGen 生成工程的步骤见 Apps/AIUtility/README.md。普通源码或工作流改动触发完整验证；仅 Markdown/validation 证据更新不重复消耗构建任务。签名、安装与运行时计划见 VALIDATION_PLAN.md。

当前优先使用 GitHub Actions，按用户要求不再尝试安装 Windows Swift 工具链。目标私有仓库已配置为 `7869123/ios`；创建仓库、推送现有提交、查看失败日志和继续修复的步骤见 [GITHUB_ACTIONS.md](GITHUB_ACTIONS.md)。真实运行记录以 STATUS.md 为准。

## 已取得的真实编译结果

[GitHub Actions 42335206895](https://github.com/7869123/ios/actions/runs/42335206895) 在官方 swift:6.0.3 Linux 容器成功执行版本、Core build、Core test，三个命令退出码均为 0。Swift Testing 逐项记录为 36 通过、1 个真实 API 测试跳过、0 失败；6 个参数化测试共执行 18 组输入。完整原始日志保存于 [validation/github-actions](validation/github-actions/README.md)。

首轮 Core build 本身已成功，但测试模块因 #require 宏用法编译失败；修复后重推并通过。没有以静态解析替代编译。Apple/macOS/iOS 任务默认跳过，不能据此宣称 Apple 包或真机通过。

## 第二轮真实编译验证入口（历史环境阻碍）

2026-11-07 第二轮仍没有可用 Swift 编译器，没有安装大型全局依赖。下面的验证脚本**只调用真实 Swift**，不使用语法解析替代；默认关闭付费 API / Keychain 集成测试：

```powershell
python scripts/verify_core.py --output validation/round2-core
```

实际启动器退出码 **2**；三个命令为 not_started，Swift 退出码为 null，执行测试 **0**。这不表示 Swift 编译失败产生诊断，而是编译进程没有启动。记录在 validation/round2-core/。本轮源码修复和回归测试未经类型检查。

在已有 Swift 6 环境，使用任意正常 Python 3.9+（Windows 可替换为已有 python.exe 路径）：

```sh
python3 scripts/verify_core.py --output artifacts/core-verification
# 或直接执行：
swift --version
swift build --package-path Packages/AIUtilityCore
swift test --package-path Packages/AIUtilityCore
```

启动器会保存各命令真实输出/退出码；全部成功退出 0，已启动但存在失败退出 1，缺编译器退出 2。只有实际 Swift 测试日志能给出测试运行数量，声明扫描不作为计数来源。普通验证会关闭 `AIUTILITY_LIVE_TESTS` 与 `AIUTILITY_KEYCHAIN_TESTS`，不读取真实凭据。

最小成本路径是使用已有 Linux 宿主或用户自己的 GitHub 仓库触发现有 CI；本轮无 remote，CI 未运行。审查者若**已经安装 Docker**，可以在解压目录运行以下官方 Swift 6.0.3 容器命令：

```sh
docker run --rm -v "$PWD:/workspace" -w /workspace swift:6.0.3 \
  bash -lc 'swift --version && swift build --package-path Packages/AIUtilityCore && swift test --package-path Packages/AIUtilityCore'
```

此命令尚未在当前 Windows 执行，首次会下载镜像；本轮没有为此安装 Docker、WSL、Visual Studio 或 Swift。新 Linux CI 保存 core-linux-evidence 日志与退出码，任务有时限。不要将 CI 配置存在描述为 CI 通过。

源码审查包生成：先提交，再运行 `python scripts/package_review.py`；仅打包 HEAD 的受跟踪源码及完整 Git 历史 bundle，忽略凭据、缓存和未跟踪数据，并检查 ZIP CRC、bundle 和 SHA-256。详见 REVIEW.md。

## 第一轮本机记录（历史）

2026-11-07：Windows 未安装 Swift，实际调用 `scripts/test.ps1` 因缺少 Swift 退出，没有执行 Swift 测试。本仓库未包含可安装 IPA，也没有已完成签名的正式 App 工程。

本轮唯一执行成功的是源码静态检查与 Git 差异检查。静态解析依赖已放在忽略目录 `artifacts/qa-python`，未安装到系统 Python：

```powershell
$env:PYTHONPATH = (Join-Path (Get-Location) 'artifacts/qa-python')
python scripts/check_repository.py --swift-grammar
git diff --check
```

复现语法检查也可使用自己的 Python 3.12：先执行 `python -m pip install --target artifacts/qa-python tree-sitter==0.26.0 tree-sitter-swift==0.7.4`。不带 `--swift-grammar` 时只用标准库完成源码卫生和 plist 检查。此命令不进行 Swift 类型检查或测试。

## Core：Windows / Linux / macOS

最低 Swift 6.0。包无第三方 Swift 依赖；使用 Foundation，非 Apple 平台有条件导入 FoundationNetworking。

Windows 官方安装过程需要 Swift Toolchain、Visual Studio C++ 工具和 Windows SDK，详见 [Swift 官方 Windows 安装说明](https://www.swift.org/install/windows/)。本轮未自动安装这些全局依赖。安装后从带有 C++ 开发环境的终端运行：

```powershell
swift --version
swift test --package-path Packages/AIUtilityCore
# 或
./scripts/test.ps1
```

Linux / macOS：

```sh
swift --version
swift test --package-path Packages/AIUtilityCore
```

默认测试均为可重复的离线协议/业务测试，测试传输层与存储替身仅供测试使用。它们检验实际 Core 的编码、解析、事务、预算和翻译逻辑。

## Apple 系统服务

需要 Mac + Xcode，基础包部署目标 iOS 16 / macOS 13：

```sh
swift test --package-path Packages/AIUtilityAppleServices
cd Packages/AIUtilityAppleServices
xcodebuild -scheme AIUtilityAppleServices -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ../../artifacts/apple-build CODE_SIGNING_ALLOWED=NO build
```

Vision 测试在本机内存里绘制 HELLO AIUTILITY 图像再识别，并测试非法图片拒绝。必须实际运行后才能判断识别结果。

Keychain 测试默认跳过；在有可用登录 Keychain 的 Mac 上显式开启：

```sh
AIUTILITY_KEYCHAIN_TESTS=1 swift test --package-path Packages/AIUtilityAppleServices
```

该测试使用随机 service 名和虚构 Key，完成后删除自己的测试记录。CI 默认不运行 Keychain 测试，避免把 runner 的 Keychain 状态误当成 App 权限已验证。

## 真实 API 集成测试（会付费）

默认关闭，不向任何真实 API 发送测试流量。通过安全的本地环境或 CI Secret 注入以下值；不要把真实值写进命令历史、仓库或测试输出：

| 供应商 | Key 环境变量 | 明确模型变量 |
|---|---|---|
| DeepSeek | `DEEPSEEK_API_KEY` | `DEEPSEEK_MODEL` |
| Anthropic | `ANTHROPIC_API_KEY` | `ANTHROPIC_MODEL` |
| OpenAI | `OPENAI_API_KEY` | `OPENAI_MODEL` |

设置 `AIUTILITY_LIVE_TESTS=1` 后运行 Core 测试。会对每家读取目录并进行一次真实指定模型翻译；显式开启但缺失任一家配置会失败。测试不会将 Key 写入磁盘或 Keychain。保存 Key 的业务验证由配置测试覆盖，Apple 持久化由独立 Keychain 测试覆盖。

线上模型目录可能包含不支持所选生成端点的模型；必须明确选择文本生成模型。目录存在本身不代表该 Key 有生成权限。Core 不硬编码型号或价格。

## CI 与 iOS 27 诊断工程

`.github/workflows/swift.yml` 包含 Linux Swift 6.0.3 Core / PoC 生命周期测试、macOS Core / Apple 测试、Apple SDK/App 构建。远程已配置为 `7869123/ios`，现为 public。旧成功记录与当前独立审查的逐轮结果见 ENGINEERING_REVIEW.md，不要把历史记录归于修改后的源码。

手动在目标审查分支触发，`build_apple=true` 运行普通 Apple/App；`build_poc=true` 独立运行 xcode-27 上的诊断 Host、iphoneos Archive、未签名 IPA 和预安装检查。SDK 不足明确失败。PoC 包与 Host 已改为 Swift 6；macOS 13 最低版本只服务可移植生命周期测试，采集仍要求 iOS 27。

Mac 本地步骤：

```sh
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
swift test --package-path PoCs/iOS27Capture
cd PoCs/iOS27Capture
# 需要已安装 XcodeGen
xcodegen generate --spec project.yml
xcodebuild -project AIUtilityCaptureProbe.xcodeproj -scheme AIUtilityCaptureProbe \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ../../artifacts/poc-build CODE_SIGNING_ALLOWED=NO build
xcodebuild archive -project AIUtilityCaptureProbe.xcodeproj -scheme AIUtilityCaptureProbe \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath ../../artifacts/poc-archive/AIUtilityCaptureProbe.xcarchive \
  -derivedDataPath ../../artifacts/poc-archive-build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  STRIP_INSTALLED_PRODUCT=NO COPY_PHASE_STRIP=NO
```

真机安装需用户控制的签名环境、可用 Team/唯一 Bundle ID、描述文件及设备配对。当前用户普通 Apple ID 且不能首次 USB 配对，安装仍受阻。Simulator 不提供 ScreenCaptureKit，只编译占位 Host 与其余可用模块；必须以 iphoneos Archive 及真机类符号检查证明采集代码未被剔除。两种编译都不证明跨 App 音频或 PiP 运行成功。详细流程见 [INSTALL_PREFLIGHT.md](INSTALL_PREFLIGHT.md)。Windows 不安装 Swift/Xcode。

诊断 Release Archive 保留本地符号以供 `nm | swift-demangle` 核验真实类；仍使用 Release 优化且不签名，不上传构建缓存或 dSYM。普通发行包的符号剥离策略后续另行验证。
