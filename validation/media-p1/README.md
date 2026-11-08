# 媒体 P1：真实 Linux CI 证据

[运行 42453057517](https://github.com/7869123/ios/actions/runs/42453057517)，attempt 1，completed / success。
源码 HEAD：`55be755f12094f930c05f4c2e957932a44e5982b`。
GitHub 实际 checkout：`549c5b2ad4ea07ac8c08161bc8c9bf268761376c`，为 PR 自动生成的临时合并检查提交，
不是合并 PR。已逐树比较 Media、Core、PoC 与源码 HEAD 相同；机器记录见 [summary.json](summary.json)。

## Job 与执行结果

| Job | Job ID | 实际状态 |
|---|---|---|
| core-linux | 128646173943 | completed / success |
| apple | 128646413813 | skipped，未运行 |
| app | 128646414282 | skipped，未运行 |
| poc-sdk | 128646413500 | skipped，未运行 |

容器 Swift 6.0.3 / x86_64-unknown-linux-gnu，Swift 6 语言模式。以下命令均真实执行：

| 命令 | 退出码 | 测试结果 |
|---|---|---|
| swift --version | 0 | 版本日志保留 |
| swift build --package-path Packages/AIUtilityCore | 0 | 编译成功 |
| swift test --package-path Packages/AIUtilityCore | 0 | 36 通过、1 真实 API 测试跳过、0 失败 |
| swift test --package-path PoCs/iOS27Capture | 0 | 14 通过、0 跳过、0 失败，仅生命周期逻辑 |
| swift build --package-path Packages/AIUtilityMedia | 0 | 模块真实编译成功 |
| swift test --package-path Packages/AIUtilityMedia | 0 | 42 通过、0 跳过、0 失败 |

日志中的 XCTest “Executed 0 tests”来自兼容测试 runner；随后 Swift Testing 实际运行上述用例，
统计按逐用例 passed/skipped 与最终汇总交叉核对，不能只读前一行。
本次没有 Swift 编译或测试失败，无需修改已通过的 Swift 源码；没有删除、跳过或弱化媒体测试。
现有 PoC 测试 ProbeLifecycleTests.swift 第 23 行有一个 Bool 返回值未使用警告，日志重复展示诊断；
未修改该文件。新媒体模块的 build/test 日志没有编译警告。

## 证据文件与完整性

[原始 artifact](https://github.com/7869123/ios/actions/runs/42453057517/artifacts/13606571386)，
名称 `core-linux-evidence-42453057517-1`，6843 字节，保留 7 天。
下载 ZIP SHA-256 与 GitHub digest 一致：
`e616917c97a61dc8f13e475fc03386d64a51ea423a1f5f4415713f8bc4533af4`。

7 个原始 artifact 文件全部核对；仓库另存 1 份本地预推送日志：

- [swift-version.log](logs/swift-version.log)
- [core-build.log](logs/core-build.log)
- [core-tests.log](logs/core-tests.log)
- [poc-lifecycle-tests.log](logs/poc-lifecycle-tests.log)
- [media-build.log](logs/media-build.log)
- [media-tests.log](logs/media-tests.log)
- [exit-codes.txt](logs/exit-codes.txt)
- [prepush-55be755.log](logs/prepush-55be755.log)（本地，退出 0；13 项 Python 检查回归通过，不属于媒体测试数）

每个文件的原始/脱敏 SHA-256 见 summary。脱敏 CI workspace/home/UUID，规范换行和行尾空白；
不提交凭据、签名下载 URL、缓存或完整 runner 环境。原始 ZIP 留在 artifact，未放入 Git。

## 仍未验证

- 生产 URLSession 的真实 HTTP/TLS/CDN 下载、服务器兼容性和实际网络取消；普通测试全部离线。
- macOS 编译/测试、iOS SDK 编译、App 接线；本轮未获 macOS 验证授权。
- Apple Keychain/Vision 运行时，以及任何 iPad 音频捕获、Speech、PiP、后台、签名安装或真机资源释放能力。
- P1b 续传、P2 图像/GIF 工具、P3 站点/Ugoira/DASH、P4 搜图均未在本轮实现或验证。

workflow 仅 core-linux 的 Media 命令、日志/退出码/artifact 与失败判定有变化；触发条件和其他 job 未变。
Core、AppleServices、App、PoC 与 scripts 自 28c449d 未修改；不合并 PR，不向 main 推送。
后续文档提交与已编译源码分开记录，不把文档 SHA 当作新编译证据。
