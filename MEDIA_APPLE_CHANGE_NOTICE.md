# 媒体 P1 Apple 验证变更通知

用户已授权：只在 swift.yml 的 apple job 增加 AIUtilityMedia macOS swift build/test，
以及 iOS 模拟器/真机 SDK 的无签名 xcodebuild；不修改触发条件或其他 job。
允许在 Codex 分支触发一次 build_apple，publish_previews=false；本次同时设置 build_poc=false。

## 工具与接口变化

本轮不新增产品工具，不改 Media/Core/AppleServices 公共 API，不改 UI、壁纸、布局或 PoC。
已通过 Linux 的媒体 P1（直链、串行队列、取消/重试、选项去重、历史/文件管理）仅追加 Apple 编译验证。
站点解析、Ugoira/GIF、图片工具及搜图仍保留后续阶段；P2 未开始。

## CI 范围

- apple 内增加一个独立步骤；即使原 Apple 检查失败，也在 checkout 成功时保存 Media 的真实执行结果。
- mac-media-build/mac-media-tests/ios-media-simulator-build/ios-media-device-build 各有独立日志及退出码，
  任一非零使该步骤失败，沿用 apple-evidence 的 always 上传；不上传缓存、证书或凭据。
- iOS 两种 SDK 显式 CODE_SIGNING_ALLOWED=NO，只编译，不签名、Archive、安装或启动设备。
- 原 AppleServices/Core 检查保留；core-linux、app、poc-sdk 及 workflow 触发条件、权限、runner、超时不变。
- 现有 build_apple 输入会连带运行原 App 构建/截图 job，保持原行为；关闭 publish_previews，禁止 CI 提交预览。
  build_poc=false，不触发独立 iOS 27 SDK PoC job。

首次运行 42461786365 已完成：macOS Media 编译和两种无签名 SDK 编译成功，但 42 项测试 33 失败/9 通过。
失败为目录别名的存储初始化问题，后续只修改 Media 路径检查并新增 3 项回归，总数 45；不删除或弱化原测试。
详细证据见 [失败报告](validation/media-apple/attempt-1/README.md)。修复未经过 macOS 复验；单次授权已使用，重验先问用户。
Apple SDK 编译成功不代表真实 HTTP/TLS/CDN 下载、App 接线或 iPad 跨 App 音频/Speech/PiP 已验证。
P2 仍需用户另行授权。
