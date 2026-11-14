# AIUtility 集成验证

记录日期：2026-11-08。独立工作分支：`codex/poc-engineering-audit`。
本轮用户明确要求拉取两个分支、检查并推进工程集成、运行完整 CI 和生成截图；授权仅用于本轮任务。
不合并 PR #1/#2、不向 main 推送、不 force push、不重写 UI 或 Core 公共 API。

## 输入与只读检查

- Codex 输入：`9d969045ebc3c190f93c9d038bedefe1ffcf4ee8`。
- Claude 输入：`fdb42c6a18ee6c4ae7d6c4bc16ffc32f50a309fd`。
- main：`f17d20d916209fa545fc21584b40ebef1b9680ea`，保持不变。
- 预合并树检查退出 0；Claude 后续提交未修改 Packages 或 PoCs。
- 只在 Codex 分支创建普通集成提交 `0cf411e150c54770f358538b0d9ea5a0cdb4963c`；两个 PR 保持未合并。
- 实际 App 树与 Claude 输入逐字节一致；Packages/PoCs 与 Codex 输入逐字节一致，未改变接口或资源。

## PoC 修复保留情况

保留完整 ProbeLifecycle、releaseFailed、共用异步释放任务、显式停止重试、每轮 callback 身份、
旧统计/旧终止回调过滤、picker 单次注销、PiP delegate 隔离及资源清理。现有 14 项生命周期测试全部保留。
这只是代码与测试覆盖检查，系统停止、授权及后台行为仍需真机验证。

## 预推送检查

首次实际执行 prepush_check.sh 退出 1：其余本地检查通过，只有两类已核验误报阻止推送：
公开 GitHub artifact URL/结构化 artifact ID 被当作手机号；CI PATH 的工具数字版本被当作个人邮箱。

必要修复仅在 scripts：

- 独立检查器只识别本仓库 Actions artifact URL，以及 validation JSON 中具备已知名称格式的 artifact.id。
  同文件其他字段、畸形 JSON、其他 URL 和普通手机号仍检查；发现值不直接打印。
- 邮箱例外只用于 validation 日志里的公开 runner PATH、工具数字版本及 bin 路径；其他凭据规则保持启用。
- 增加 13 项 unittest，覆盖有效例外、相邻手机号、非 artifact 字段、私有路径、真实邮箱模式及假凭据检测。
- Bash 及轻量 Python 检查依赖仅放在忽略的 artifacts 工作目录，下载的官方便携工具已校验发布方 SHA-256。
  未安装 Windows Swift、全局工具或修改系统配置。语法解析只属于预推送检查，不是编译结果。

完整预推送最终 **PASS / 退出 0**：13 项检测回归、源码/资源/YAML/shell/隐私检查通过；
HEAD 与待推送内容无敏感命中、无大文件、无异常作者；新提交作者/提交者时区均为 +0000。
第一轮新增检测回归曾 12 通过、1 失败：正则可能把 PATH 变量名包含进匹配，修正为验证整行上下文后 13 项全部通过。
已推送历史的旧 workflow 模式命中仍报告，不改写历史；它们不作为本轮新增凭据。

## 最终完整 CI

验证源码：`83ae71ce5fbe5d00db100e12400b889fb8ef613d`。
[完整运行 42439552132](https://github.com/7869123/ios/actions/runs/42439552132) completed / success，
build_apple=true、build_poc=true、publish_previews=false，没有自动向任何分支提交截图。

| Job | 真实结果 |
|---|---|
| core-linux / 128605639390 | success；Core 36 通过/1 跳过，生命周期 14 通过 |
| apple / 128605834405 | success；Core 36 通过/1 跳过，Vision 2 通过/Keychain 1 跳过，两个 SDK 构建通过 |
| poc-sdk / 128605834400 | success；macOS 生命周期 14 通过，Swift 6 iphoneos Archive / Simulator / IPA 通过，13 项预安装检查通过 |
| app / 128606209116 | success；两个 SDK 构建、截图步骤均通过 |

所有保存的最终构建/测试命令退出码均为 0。自动 PR 运行 42439554187 同样 success，
只执行 Linux；其余 Apple/App/PoC 按 PR 策略跳过，不将此运行当完整验证。
真实 API 测试每个平台各跳过 1 项，Keychain 运行时跳过 1 项；预览自动提交未开启。
本轮 CI 没有编译/测试失败；前述两轮本地检查失败已修复，未删测试或关闭扫描。

## 原始截图

[截图 artifact](https://github.com/7869123/ios/actions/runs/42439552132/artifacts/13601307915)，
包含四张原始 App 内渲染 PNG，未修改像素、未旋转加工、未使用 raw framebuffer 回退。
实际模拟器为 iPad mini (A17 Pro) 与 iPhone 17，不是 iPad mini 6 真机。

| 文件 | 原始像素 |
|---|---|
| ipad-mini-portrait.png | 1488 × 2266 |
| ipad-mini-landscape.png | 2266 × 1488 |
| iphone-portrait.png | 1206 × 2622 |
| iphone-landscape.png | 2622 × 1206 |

已查看四张图并核对方向与内容。iPhone 竖屏主卡及按钮存在较多换行，记录为人工 UI 审核事项；
未修改 Claude 的布局、颜色、壁纸或资源，不将截图生成等同完整 UI 交互验收。
原 PNG 单张约 9–11 MB，保留在 artifact 至 2026-11-15，不放入 Git。
每张 SHA-256、全部 Job/step 状态和 27 份脱敏日志见 [验证证据](validation/integration/README.md)。

[未签名 IPA](https://github.com/7869123/ios/actions/runs/42439552132/artifacts/13600673183)，SHA-256：
`613bf7282707119a3815d270ec4b9dc4e2434384a57aa3e443ecea89e7a811fc`。
它不含开发签名或描述文件，不能直接安装。

## 仍未验证与交付约束

真实三家 API、Keychain 运行时、iOS 实际截图 OCR、签名安装、iPad 跨 App 非静音音频、连续 Speech、
PiP 可见性、后台/路由/中断和资源释放均未验证。没有新增 ReplayKit 或付费调用。
当前普通 Apple ID、无首次 USB 配对的安装阻碍未解除；编译成功不代表系统采集可行。

两个 PR 均未合并，main 保持 f17d20d。最后重新获取的 Claude 分支仍为输入 fdb42c6，
集成源码与其 App 树一致；后续验证提交只增加文档和证据，源代码不变。等待人工审核，不自动合并。
