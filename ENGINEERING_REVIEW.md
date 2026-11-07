# 工程可靠性审查（2026-11-07）

范围：独立分支 `codex/poc-engineering-audit`；基于 PR #1 的
`d04a43e14507b8e822e3ec979e4f5b3d906e410b`，main 为 `f17d20d`。
只审查底层工程，未修改 Claude 的 UI、壁纸、透明度文件或资源，未改 Core 公共 API。

## 第一阶段：只读结论与证据

GitHub API 已确认仓库为 public、PR #1 open/unmerged。直接核对
[42366153728](https://github.com/7869123/ios/actions/runs/42366153728) 的 jobs、PoC job
`128384755081` 原始日志及 artifact 元数据：Linux、Apple、App、PoC 都是 success。
PoC 环境为 macOS 27.0.1 / Xcode 27.1 (27A9275) / iOS SDK 27.1。
模拟器构建退出 0、iphoneos Release Archive 成功，预安装检查 **11/11**，存在未签名 IPA。
日志证实真机二进制链接 ScreenCaptureKit、Speech、AVKit；模拟器明确只有占位 Host。
旧文档首段的“未编译、没有 IPA”以及 STATUS 的“10 项”已过时。

`d04a43e` 的运行 42374532233：core-linux failure 且 steps=null，其余 skipped；该 job 日志请求返回 BlobNotFound。
这不是可归因于 Swift 源码的编译诊断，不能凭此确认此前“账单限制”的推测。

| 等级 | 问题与源码证据 | 处理范围 |
|---|---|---|
| P0 | 无已证实 P0。跨 App 非静音采集仍无真机证据，是核心可行性缺口 | 不宣称路线已成功，不改成麦克风 |
| P1 | PoCSession 在 Speech 授权、capture.stop 的 await 两侧只用 running 布尔值；旧 catch/stop 可清理新会话 | 会话编号、停止期间禁止重启、同步解绑后 await |
| P1 | ScreenAudioProbe 启动失败先 stop 后 onTermination，后者再次 stop；picker 无会话身份、metrics 可迟到 | 独立 observer/delegate、单一停止所有权、启动任务汇合、迟到回调拒绝 |
| P1 | 两个 PiP delegate conformance 在实际日志中有 ConformanceIsolation 警告，Swift 6 将报错 | 真正 nonisolated 入口，UI 异步回 MainActor，同步暂停查询加锁；Swift 6 编译验证 |
| P1 | PiP stop 保留 controller/timebase；无音频 interruption / route / media-services 统一停止 | 清理 timer/controller/timebase；中断安全停止，人工重启，不承诺自动恢复 |
| P1 | 缺少生命周期回归；编译证据与文档冲突 | 可移植状态机测试、真机符号检查、独立运行证据 |
| P2 | Speech 默认 en-US，仅单次识别，final/error 后不继续；缓冲格式、语言包兼容待测 | 保留明确边界；本轮不扩展连续 ASR/语言 UI |
| P2 | displayLayer enqueue/flush/status/readiness 自 iOS 18 弃用 | 后续迁移 sampleBufferRenderer；本轮不扩大渲染改动 |
| P2 | RMS 仅 float32；端序、packed/对齐、非有限值、实际多声道格式未实测 | 不把计数或不支持的 RMS 当成功；后续格式实验 |
| P2 | PiP 无可回放历史，固定尺寸；停止动画、后台计时器、音频路由和耗电行为未测 | 真机逐项验证 |

## 第二阶段：修复边界

- 新的 ProbeLifecycle 是 PoC 内部 MainActor 会话所有权，不改产品架构或公开采集路线。
- 会话必须等上轮异步释放完成才可重新启动；旧失败、picker 回调、统计与 PiP delegate 不再操作新会话。
- 启动取消会检查 Task cancellation；系统 Speech 授权提示不能由 Task 强制关闭，返回后拒绝过期操作。
- 音频中断/路由变化/媒体服务丢失或重置后停止并要求用户重新开始。忽略结束通知和自身 categoryChange，
  不自动重新弹出系统选择器、不假装自动恢复。保持 `.playback/.moviePlayback/.mixWithOthers`，不启用麦克风。
- 新测试只执行真实共用生命周期逻辑，不会打开系统采集、Speech 或 PiP；不证明这些框架运行时成功。
- iphoneos 编译禁止在 ScreenCaptureKit 不可导入时退回占位 Host；IPA 审查新增真实类符号检查。
- 未新增 ReplayKit、付费 API 调用、凭据或证书；未删除/跳过任何既有测试。

## 第三阶段：验证记录

本文件初始提交时尚未运行修改后的 Apple CI，不能将旧 run 归于本次源码。
完整结果、运行 ID、逐 Job 状态与命令退出码将在验证后补充到本节及 STATUS.md。

低成本检查：`python scripts/check_repository.py`、`git diff --check`；只是源码卫生/plist 检查。
完整验证：当前审查分支手动触发 `.github/workflows/swift.yml`，同时设置
`build_apple=true`、`build_poc=true`、`publish_previews=false`。
Linux Core + 生命周期测试先执行；Apple 包/App 与 iOS 27 PoC 后执行。

## 尚不能消除的阻碍

- 普通 Apple ID、尚未首次 USB 配对、没有设备访问；未签名 IPA 不能直接安装。没有验证任何签名权限。
- 框架可链接、后台模式已声明不代表授权成功；官方示例不是其他 App 系统音频成功的证据。
- 真机必须验证非 DRM 来源的非静音 RMS 与已知语句对应、后台持续性、Speech 语言/时长、PiP 肉眼可见、
  路由/中断/锁屏、反复停止重启、资源占用。核心跨 App 能力仍未验收。
- 免费团队实际签名、唯一 Bundle ID 和可用描述文件需用户控制环境验证，不在公开 CI 保存 Apple 凭据。

官方核对：[iOS ScreenCaptureKit 示例](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios)、
[AVKit playback delegate](https://developer.apple.com/documentation/avkit/avpictureinpicturesamplebufferplaybackdelegate)、
[sampleBufferRenderer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/samplebufferrenderer)、
[标准 hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。
2026-11-07 读取官方页面/DocC，实际类型及隔离声明以此次真实 SDK 诊断为准。
