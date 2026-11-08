# 集成验证证据

记录日期：2026-11-08。验证源码：`83ae71ce5fbe5d00db100e12400b889fb8ef613d`。
Claude 输入 fdb42c6，Codex 输入 9d96904；只在 Codex 分支普通集成，未合并 PR 或修改 main。

[完整 CI 42439552132](https://github.com/7869123/ios/actions/runs/42439552132) 四个 Job 全部 completed/success。
[summary.json](summary.json) 保存实际 Job/step、退出码、逐项计数、源码树、artifact、图片尺寸和原始摘要。
App 树与 Claude 输入完全一致；Core、AppleServices、PoC 与 Codex 输入完全一致，无公共接口或 UI 设计改动。

## 实际测试与命令

| 范围 | 执行 | 结果 |
|---|---|---|
| Linux Core | swift build/test --package-path Packages/AIUtilityCore | 36 通过、1 live API 跳过 |
| Linux PoC 生命周期 | swift test --package-path PoCs/iOS27Capture | 14 通过 |
| macOS Core / AppleServices | bash scripts/ci_apple.sh | Core 36 通过/1 跳过；Vision 2 通过/Keychain 1 跳过 |
| macOS PoC 生命周期 | swift test --package-path PoCs/iOS27Capture | 14 通过，仅共用状态机 |
| PoC Swift 6 | XcodeGen；Simulator build；iphoneos Release archive | 退出 0；13 项预安装检查通过 |
| App | bash scripts/ci_app.sh；bash scripts/app_screenshots.sh | 构建和截图步骤 success |
| 本地预推送 | bash scripts/prepush_check.sh origin/codex/poc-engineering-audit | PASS / 退出 0，包含 13 项检测回归 |

各脚本的完整实际参数在仓库脚本、workflow 与日志内；最终退出码见 logs/*/exit-codes.txt。
Swift Testing 兼容层的 XCTest 0 tests 不代表未执行；Core 聚合“37 passed”含 1 禁用项，按逐项计数报告 36+1。
普通 Apple/App 为 Xcode 26.6 / Swift 6.3.3 / SDK 26.5；PoC 为 Xcode 27.1 / SDK 27.1。
Archive 包含真实 `-swift-version 6`，无先前跨 actor 隔离错误；display-layer 弃用警告仍在。
Simulator 不提供 ScreenCaptureKit，只有 iphoneos Archive/框架/真实类检查证明采集代码被编译，不证明运行时能力。

## 四张未修改的原始截图

[下载 app-screenshots-42439552132-1](https://github.com/7869123/ios/actions/runs/42439552132/artifacts/13601307915)。
实际设备类型是 iPad mini (A17 Pro) / iPhone 17 模拟器。

| 文件 | 像素 | 原始字节 |
|---|---|---|
| ipad-mini-portrait.png | 1488 × 2266 | 10527260 |
| ipad-mini-landscape.png | 2266 × 1488 | 10128498 |
| iphone-portrait.png | 1206 × 2622 | 10110062 |
| iphone-landscape.png | 2622 × 1206 | 9083414 |

四张均有 in-app capture 日志，已逐张查看，方向正确；没有旋转后处理或 framebuffer 回退。
大 PNG 不加入 Git；保留原 artifact 至 2026-11-15，逐图 SHA-256 在 summary.json。
截图只展示工作台，不是实时采集证据或完整交互测试。iPhone 竖屏主卡/按钮有明显多行换行，留给 Claude/人工审核，未改设计。

## IPA

[下载未签名 IPA](https://github.com/7869123/ios/actions/runs/42439552132/artifacts/13600673183)。
原始 SHA-256：`613bf7282707119a3815d270ec4b9dc4e2434384a57aa3e443ecea89e7a811fc`。
签名、描述文件与安装都没有完成。普通 Apple ID 的权限和首次 USB 配对阻碍仍存在。

## 失败、跳过和隐私处理

- 本轮 CI 没有失败。自动 PR 运行 42439554187 为 Linux-only success，另外三个 Job 按策略跳过；不能用它冒充完整 CI。
- 本地首轮 prepush 退出 1，误把 artifact ID 当手机号、CI 工具版本当邮箱；已精准修复，没有关闭凭据规则。
- 首轮新增检测回归 12 通过/1 失败，修正 PATH 匹配上下文后 13 通过；测试均保留。
- 真实 API 测试在 Linux/macOS 各跳过 1 项，Keychain 运行时跳过 1 项；publish_previews=false，预览自动提交未执行。
- 进行中 Job 日志下载曾返回 404；日志在完成后可获取。这不是编译/测试失败。截图原 ZIP 已核对 GitHub artifact 摘要。
- 原始日志规范化行尾/末尾空白；公开 CI home/PATH 和 UUID 已脱敏，原始/保存 SHA-256 均保留，不冒充字节完全相同的原件。
  不保存签名下载 URL、凭据、证书、描述文件、实际设备 UDID、构建缓存或个人主目录路径。
- 历史已推送 workflow 的模式命中仍由检查器报告，不重写历史；HEAD/待推送的新内容必须无阻断项。

真实 API、Keychain 写入/锁屏、iOS OCR 质量、iPad 非静音跨 App 音频、连续 Speech、PiP 可见性、
后台/路由/中断与系统资源释放全部未验证。生命周期 14 项测试不能代替这些真机实验。
