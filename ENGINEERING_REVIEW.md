# 工程可靠性审查（2026-11-08 交付；CI 于 2026-11-07 执行）

后续集成已按新的明确授权完成：Claude fdb42c6 与本分支修复共同在 83ae71c 通过
[42439552132](https://github.com/7869123/ios/actions/runs/42439552132)，并重建四张横竖屏截图。
最新结果见 [INTEGRATION_STATUS.md](INTEGRATION_STATUS.md)；下文保留上一轮独立审查，不能混淆两个源码快照。

范围：独立分支 `codex/poc-engineering-audit`；基于 PR #1 的
`d04a43e14507b8e822e3ec979e4f5b3d906e410b`，main 为 `f17d20d`。
只审查底层工程，未修改 Claude 的 UI、壁纸、透明度文件或资源，未改 Core 公共 API。

## 最终结果

[完整 CI 42378051064](https://github.com/7869123/ios/actions/runs/42378051064)，
验证源码 **680f3d2af9f056811b05e4db74d0492f9dd1d1d6**，四个 job 全部 completed/success。
源码及 workflow 的树摘要、实际退出码、逐项测试计数、artifact ID 和原始日志摘要见
[validation/engineering-audit](validation/engineering-audit/README.md)。交付文档提交不改变这些源码树，不另称为一次编译。

| Job / ID | 实际结果 |
|---|---|
| core-linux / 128419652484 | Swift 6.0.3：Core 36 通过、1 live API 跳过；生命周期 14 通过；build/test 退出 0 |
| apple / 128419871613 | Core 36 通过、1 跳过；Vision 2 通过、Keychain 1 跳过；两个 iOS SDK 构建退出 0 |
| poc-sdk / 128419871717 | macOS 生命周期 14 通过；Swift 6 Simulator/iphoneos Archive 退出 0；IPA 打包、13/13 预安装检查通过 |
| app / 128420238618 | XcodeGen、Simulator/iphoneos 构建退出 0；截图步骤 success；不是完整 UI 交互验收 |

普通 Apple/App 使用 Xcode 26.6 / Swift 6.3.3 / SDK 26.5；PoC 使用 macOS 27.0.1 / Xcode 27.1 / SDK 27.1。
PoC Archive 实际编译参数包含 `-swift-version 6`，无 ConformanceIsolation 或 SendingRisksDataRace 诊断。
剩余 display-layer 弃用警告未隐藏，列为 P2。

[未签名 IPA](https://github.com/7869123/ios/actions/runs/42378051064/artifacts/13576218828)，SHA-256：
`88d7cd6035b1e9f4d937ed49450e2dba1aa38778d6c608144ebe6c265c1ff440`。保留至 2026-11-14，不能直接安装。

PR #2 目标仍为 `claude/ecstatic-planck-rzpvn6`，不自动合并。
最后获取的 Claude HEAD 为 `6b335ab`；本轮已集成的验证基线是 `d7859b0`，
其后的 UI/预览提交保持独立。`git diff upstream...HEAD` 不含 Apps/Core/UIUX_SPEC/截图脚本改动，
`git merge-tree --write-tree HEAD upstream` 退出 0，无冲突；未把最新 UI 组合标为已验证，合入后仍需复验 App。

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
| P1（交付复查补充） | stopCapture 与音频会话停用使用 try?；SDK 失败仍显示已停止 | 保留失败状态/资源引用、禁止重启、显式停止重试；不伪装系统已释放 |
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

初轮修复 `857d150` 的手动运行 [42375947069](https://github.com/7869123/ios/actions/runs/42375947069)：
Linux Core 36 通过/1 跳过，初版生命周期 8 通过；PoC macOS 测试真实编译失败：
包未声明 macOS 最低版本，SwiftPM 默认为 12.0，与 Core 的 13.0 冲突。
已补充 macOS 13（只用于可移植测试，iOS 仍要求 27），没有删除测试或降低采集目标。
同轮 PR 自动运行 42375948027 只运行 Linux，不是全链路验证。
后续同时补充共用异步停止屏障，确保并发 stop 都等待同一份释放，并增加三项实际释放回归。
最终结果和逐 Job 退出码见本文首节；本段记录首次失败，不是当前状态。

第二轮 `a0fd2c7` / [42376094393](https://github.com/7869123/ios/actions/runs/42376094393)：
Linux Core 和 11 项生命周期测试通过；macOS 生命周期测试及模拟器构建通过。
真实 iphoneos Swift 6 Archive 退出 65，诊断为回调把非 Sendable `SCStream` 传入 MainActor（ScreenAudioProbe 两处）。
修复是在回调入口取 ObjectIdentifier，跨隔离仅传身份；不再传 SCStream，也不新增 unchecked 包装。
PiP 的 ConformanceIsolation 诊断已消失，弃用警告仍保留。补充停止调用方 Task 被取消时释放仍完成的回归。

第三轮 `518dc35` / [42376481364](https://github.com/7869123/ios/actions/runs/42376481364)：
Linux、Apple 包通过；PoC 12 项生命周期、模拟器、Swift 6 iphoneos Archive 均通过，IPA 已生成。
新增的类符号检查失败：默认 Release Archive 剥离本地符号，nm 只剩导入符号，不能据此判断代码被剔除。
修复为诊断 Release 明确保留本地符号（STRIP_INSTALLED_PRODUCT=NO / COPY_PHASE_STRIP=NO），继续核验实际可执行文件，
不删除检查、不关闭 Release 优化。另将新回调代理改为 MainActor + nonisolated 协议入口，移除代理上不必要的 unchecked Sendable。
已通过普通 merge 保留 Claude 后续 03c3e40 和 d7859b0，UI、资源及其截图脚本相对该基线无工程审查改动。

第四轮 `d05afad` / [42376873996](https://github.com/7869123/ios/actions/runs/42376873996)：四个 job 全部 success，
Core 各平台 36 通过/1 跳过，生命周期各 12 通过，AppleServices 2 通过/1 跳过；13/13 预安装检查通过。
最后复查另发现停止异常被吞掉的问题，已补 releaseFailed 状态：失败保留句柄，禁止 begin，
再次显式 stop 才重试；并发停止共享同一次失败；终止通知只关闭其余资源，不隐式重试采集。
新增两项失败/重试回归；最终 `680f3d2` 的 14 项回归与完整 SDK 验证见首节，没有沿用第四轮结论。
Claude 此后继续 UI 到 4e0f8d2；本轮固定 d7859b0 集成基线，PR 三点差异不改 UI，最新 UI 组合需另验。

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
- Speech/PiP 仍是采集启动的前置条件，可能妨碍在不支持本地 Speech 的设备上独立诊断采集；本轮不改架构。
- 生命周期测试没有执行系统中断、授权提示或真正的 stopCapture；系统调用若不返回，仍会保持停止中，不能证明资源已释放。
- `scripts/github_actions.py` 的旧 private 限制尚未迁移；当前公开仓库使用 Actions 页面或已授权 API。

官方核对：[iOS ScreenCaptureKit 示例](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios)、
[AVKit playback delegate](https://developer.apple.com/documentation/avkit/avpictureinpicturesamplebufferplaybackdelegate)、
[sampleBufferRenderer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/samplebufferrenderer)、
[标准 hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)。
2026-11-07 读取官方页面/DocC，实际类型及隔离声明以此次真实 SDK 诊断为准。
