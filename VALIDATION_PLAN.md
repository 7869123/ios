# 后续验证准备

此表是待执行计划，不是通过记录。已完成的证据只见 STATUS.md 与 validation/。

| 项目 | 准备方式 | 验收证据 | 当前边界 |
|---|---|---|---|
| 三家真实 API | 在受控环境注入三家 Key 与明确模型，显式启用 AIUTILITY_LIVE_TESTS；不把 Key/Token 放入聊天、源码或 artifacts | 每家目录、指定模型完整响应、超时/取消记录；失败时旧绑定不变 | 未执行；默认 CI 关闭 |
| Keychain 运行时 | 显式启用 AIUTILITY_KEYCHAIN_TESTS，使用随机 service 与虚构 Key；随后在 iOS App 验证解锁/锁屏和实际签名上下文 | 新增/替换/读取、失败保留、退出重启、不同供应商隔离；清理测试条目 | Apple SDK 已编译，真实运行时测试未执行；CLI/macOS 与 iOS 不能互相替代 |
| Vision iOS 运行时 | 使用真实截图、EXIF 旋转、多语种、长图和无文字样本，在 iOS 模拟器/设备运行截图页 | 识别文字、框位置、置信度、取消、资源占用及人工比对 | macOS 合成英文图/非法图测试通过；iOS 与实际截图质量未验证 |
| SwiftUI 交互 | 模拟器覆盖 iPhone/iPad、横竖屏与分屏；验证导航、草稿、键盘、取消、配置切换、无配置/离线/预算耗尽 | 截图、操作记录、可访问性检查、失败状态 | SDK 构建独立记录；尚无 UI 运行时验收 |
| iPad 跨 App 音频/Speech/PiP | 先取得 iOS 27 SDK，修复 IOS_POC.md 中已记录生命周期风险，在目标 iPad mini 6 / 27.2 签名安装独立 PoC | 非静音 RMS、文本对应、后台持续性、路由/中断/取消、PiP 肉眼确认 | runner 只有 iOS 26.5 SDK；没有 iOS 27 成功结论 |
| 签名与安装 | 在用户控制的 Mac/Xcode 中生成 App 工程、选择自己的 Team 与唯一 bundle ID，连接设备并按系统要求授权 | 签名、安装、启动、权限、卸载/重装记录 | CI 仅 CODE_SIGNING_ALLOWED=NO，不含证书或可安装 IPA |

## 命令准备

Core 真实 API 测试需要 OPENAI_API_KEY / OPENAI_MODEL、ANTHROPIC_API_KEY / ANTHROPIC_MODEL、DEEPSEEK_API_KEY / DEEPSEEK_MODEL。具体环境注入由用户控制，不将真实值写进命令历史。设置 AIUTILITY_LIVE_TESTS=1 后执行 `swift test --package-path Packages/AIUtilityCore`；显式开启但缺配置会失败。普通 CI 仍保持关闭。

macOS Keychain 测试可显式执行 `AIUTILITY_KEYCHAIN_TESTS=1 swift test --package-path Packages/AIUtilityAppleServices`。若系统权限、Data Protection Keychain 或签名上下文不允许，记录真实失败，不降级到普通文件，不跳过后宣称成功。

App 工程生成与未签名构建见 Apps/AIUtility/README.md。iOS 27 PoC 必须使用独立部署目标及 IOS_POC.md 验收矩阵；正式 App 当前只接文本翻译，不绕过系统权限获取其他 App 音频。
