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

完整预推送的最终退出码、集成后源码 SHA、CI 各 Job、截图尺寸和 artifact 将在实际执行后补充。

## 待执行验证与边界

完整 CI：Core Linux、AppleServices/macOS、PoC Swift 6 iphoneos Archive/未签名 IPA、App SDK 构建；
重新生成 iPad mini 竖屏/横屏和 iPhone 截图。publish_previews 保持关闭，避免 CI 自动向分支写提交。

真实三家 API、Keychain 运行时、iOS 实际截图 OCR、签名安装、iPad 跨 App 非静音音频、连续 Speech、
PiP 可见性、后台/路由/中断和资源释放均未验证。没有新增 ReplayKit 或付费调用。
