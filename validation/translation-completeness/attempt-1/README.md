# 首轮真实编译验证：测试模块编译失败

- 源提交 `0ee791b8837485fb5000bbb887d57168e55e2d51`，Codex 独立分支，未合并任何分支/PR。
- [Actions 42647207277](https://github.com/7869123/ios/actions/runs/42647207277)，workflow_dispatch，attempt 1，completed / failure。
- 本轮授权只触发一次：build_apple=true、build_poc=true、publish_previews=false、live_checks=false。没有创建 PR，没有预览发布，没有付费 API 测试或真实 Keychain 测试。

| Job | 实际结果 |
|---|---|
| core-linux（129263578035） | failure：生产 Core 编译通过，测试模块编译失败 |
| apple（129264289118） | skipped：依赖 Core 成功，未运行 Apple 编译/测试 |
| poc-sdk（129264288804） | skipped：依赖 Core 成功，未运行 iOS 27 Archive |
| app（129264290028） | skipped：依赖 Core/Apple，未构建 App 或 IPA |
| live-checks（129263579817） | skipped：显式关闭 |

## 命令、退出码、测试数量

Swift 6.0.3，x86_64-unknown-linux-gnu。以下均从 artifact 的 exit-codes.txt 与实际日志读取：

| 命令 | 退出码 | 结果 |
|---|---:|---|
| swift --version | 0 | 版本成功 |
| swift build --package-path Packages/AIUtilityCore | 0 | **生产源码真实编译成功**，包括有界音频队列 |
| swift test --package-path Packages/AIUtilityCore | 1 | 测试模块编译失败；**功能测试执行 0 项** |
| swift test --package-path PoCs/iOS27Capture | 0 | 可移植生命周期 14 通过、0 跳过/失败；不编译 iOS 框架路径 |
| swift build --package-path Packages/AIUtilityMedia | 0 | Linux 编译成功；不是 Apple 媒体工具运行验证 |
| swift test --package-path Packages/AIUtilityMedia | 0 | 92 通过、4 live 站点测试跳过、0 失败；聚合 96 包含跳过项 |

Core 的 81 个声明不能记作 81 项失败或通过：测试可执行文件尚未生成，没有执行断言。iOS 27/Speech/CoreMedia、AppleServices、App 与签名/真机没有获得本轮证据。

## 根因与修复（未复验）

真实诊断共涉及 7 个唯一源码位置，均在新增测试：嵌套 #require 导致 recursive expansion；把 throwing store.read 放在 #require 参数内导致宏生成缺少 try。
修复提交 `6aa6f64325ae92966847e809c1cd9a51b8507b88` 只修改 APIConfigurationFeatureTests.swift、TranslationFeatureTests.swift、TranslationReliabilityTests.swift：分离读取、JSON 解码与断言，并移出 #expect 内的 #require。

三个文件的 @Test / #expect / #require 数量逐一对比均不变；原测试未删除或弱化。生产 Core 源码树与被编译的 0ee791b 完全相同，树摘要见 summary.json。**修复后尚未编译/执行，不能宣布 Core 测试通过。**

本轮一次授权已使用；按此前约定和 AGENTS 第 5 节，修复后重跑需所有者确认，不改工作流绕过依赖。

## 证据

[原始 artifact](https://github.com/7869123/ios/actions/runs/42647207277/artifacts/13688865952) 已下载并验证 ZIP SHA-256：
`25eb1aa52bed43bfa533fd5484618b26c63b8db8c69ca8ec699dda7e73c70f0f`。

[summary.json](summary.json) 包含输入、job/step 状态、逐项计数、七处诊断位置、退出码、artifact 摘要和每份日志原始/归档哈希。
七份日志见 logs/：仅将 CI 路径/UUID 替换为占位符并规范换行，不删除诊断。没有上传 ZIP、构建缓存、凭据、签名或用户音频/图片/文字。
