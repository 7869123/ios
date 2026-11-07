# 首次真实 Core 编译与测试

日期：2026-11-07。私有仓库：`7869123/ios`。仅运行 Linux Core；没有安装 Windows Swift。

| 运行 | 对应提交 | swift --version | swift build | swift test | 结果 |
|---|---|---|---|---|---|
| [42335045924](https://github.com/7869123/ios/actions/runs/42335045924) | b77c821 | 0 | 0 | 1 | Core 库通过，测试模块编译失败；失败 artifact 成功上传 |
| [42335206895](https://github.com/7869123/ios/actions/runs/42335206895) | 3263a5a | 0 | 0 | 0 | Core 编译和测试通过；成功 artifact 已下载核对 |

实际命令：

```sh
swift --version
swift build --package-path Packages/AIUtilityCore
swift test --package-path Packages/AIUtilityCore
```

编译器：Swift 6.0.3，Linux x86_64。首轮错误为嵌套 #require 递归展开、以及宏内抛错 load 调用缺少处理。修复将读取/解析放到独立语句，再对所得值使用 #require；未删除或弱化任何断言。Apple 测试里同类写法一并调整，但 Apple 包没有因此宣称编译通过。

真实统计来自 Swift Testing 每项输出：发现 37 项，36 项运行通过，1 项 liveOfficialAPI 按配置跳过，0 失败；6 个参数化测试共执行 18 组供应商参数。Swift Testing 最后的聚合行显示 `37 tests passed`，其中包含已禁用项，因此本报告不把它描述为 37 项实际执行通过。

日志开头 XCTest 兼容层显示 0 tests；后面的 Swift Testing 才是本包实际测试，不能只摘取兼容层计数。本目录保存两轮各四个原始证据文件，没有缓存、Token、完整 runner 日志或环境转储。

`summary.json` 指明通过验证的提交与 Core Git tree。后续仅修改文档/开发辅助工具时，若 tree 相同，Core 源码与此证据一致；最新仓库提交的 CI 仍应单独核对。

未验证：真实三家 API、真实 Keychain/Vision、Apple SDK 构建、iPad mini 6 / iPadOS 27.2 跨 App 音频、Speech 长时识别、PiP 字幕。上述任务在本次 workflow 中跳过。
