# 构建与测试

## 当前本机结果

2026-11-07：Windows 未安装 Swift，实际调用 `scripts/test.ps1` 因缺少 Swift 退出，没有执行 Swift 测试。本仓库未包含可安装 IPA，也没有已完成签名的正式 App 工程。

本轮唯一执行成功的是源码静态检查与 Git 差异检查。静态解析依赖已放在忽略目录 `artifacts/qa-python`，未安装到系统 Python：

```powershell
$env:PYTHONPATH = (Join-Path (Get-Location) 'artifacts/qa-python')
& 'C:/Users/7869/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' scripts/check_repository.py --swift-grammar
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

`.github/workflows/swift.yml` 包含 Linux Swift 6.0.3 Core 测试、macOS Core / Apple 测试、Apple iOS 模拟器构建。当前未配置 Git 远程，因此这些工作流**没有运行结果**。

手动触发并设置 `build_poc=true` 时，额外要求 runner 的 iOS SDK 至少为 27，然后通过 XcodeGen 生成并构建诊断 Host。SDK 不足会明确失败，不以跳过分支伪装 PoC 通过。PoC 的 Swift 5 语言模式用于隔离新 SDK 的回调隔离迁移；Core 与 AppleServices 保持 Swift 6。

Mac 本地步骤：

```sh
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
cd PoCs/iOS27Capture
# 需要已安装 XcodeGen
xcodegen generate --spec project.yml
xcodebuild -project AIUtilityCaptureProbe.xcodeproj -scheme AIUtilityCaptureProbe \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ../../artifacts/poc-build CODE_SIGNING_ALLOWED=NO build
```

真机安装需在生成工程中选择开发团队与 iPad，使用 Xcode 正常签名构建。模拟器编译只能检查符号与类型，不能验证跨 App 音频或 PiP 的实际行为。详细设备流程见 [IOS_POC.md](IOS_POC.md)。Windows 无 Xcode，无法在本机完成上述 Apple 构建。
