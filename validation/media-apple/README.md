# Media Apple 验证交接：修复后 Linux 通过，Mac 仍待复验

本轮只触发了一次授权的 build_apple（publish_previews=false、build_poc=false）。
workflow 仅 apple job 新增 Media 四项检查及日志/artifact 路径；其他 job、触发条件、runner/权限/超时不变。
没有合并 PR、向 main 推送、安装 Windows Swift 或调用付费/真实站点 API。

| 源码 / 运行 | 已取得的证据 | 不能推断的结果 |
|---|---|---|
| 1ac37c8 / [42461786365](https://github.com/7869123/ios/actions/runs/42461786365) | Media macOS build=0；两个无签名 iOS 26.5 SDK build=0；Mac 测试 9 通过/33 失败；整体 failure | 不能标为 Apple 全部通过；不代表真机功能 |
| 修复 99b0d86，验证 HEAD 334cfde / [42463047405](https://github.com/7869123/ios/actions/runs/42463047405) | Linux Swift 6.0.3 build/test=0；Media 45 通过、0 跳过/失败；Core 36 通过/1 跳过；生命周期 14 通过 | Darwin 专用分支和修复后的 iOS SDK 尚未复验 |

首轮 Mac 失败位于存储初始化的符号链接检查，不是编译失败。仅在 AIUtilityMedia 修复：
精确识别 Darwin 的系统别名，检查前不隐藏目录内链接；新增 3 项安全边界回归，保留所有原 42 项测试和断言。
公共 API、Core/AppleServices、Claude UI、PoC、scripts 没有因失败而修改；workflow 没有再次调整。

## 证据入口

- [首轮失败、SDK 成功及 17 份日志](attempt-1/README.md)，[原始/脱敏摘要](attempt-1/summary.json)。
- [修复后 Linux 机器记录](linux-fix/summary.json)，[编译日志](linux-fix/logs/media-build.log)，
  [45 项测试日志](linux-fix/logs/media-tests.log)，[六个退出码](linux-fix/logs/exit-codes.txt)。
- [Linux artifact](https://github.com/7869123/ios/actions/runs/42463047405/artifacts/13610517009)，
  ZIP SHA-256 与 GitHub 一致：`7ee225df6ec54a3995f1be4593a54d2763747940cef1c6dd84bdf38a497db845`。
- Linux 实际 checkout 为 GitHub 临时合并检查提交 84c635664e1c2ad72c04ace818d64b56a2942e18，
  Media 包树与 HEAD 334cfde 相同；这没有合并任何 PR。

## 下一步

用户的“一次 build_apple”授权已使用；必须先取得新的 macOS 复验授权，才能对修复再次 dispatch。
候选复验仍使用 Codex 当前分支、build_apple=true、build_poc=false、publish_previews=false，
先确认 45 项 Mac 测试全部通过及两种 SDK build=0，再判断 App job 的原有构建/截图结果。
不要通过改条件、忽略退出码、跳过测试或删除保护逻辑取得绿色状态。

真实 HTTP/TLS/CDN 下载、App 接线、签名/安装，以及 iPad 音频、Speech、PiP 和后台资源释放均未验证。
本轮实际 SDK 为 26.5；不宣称 iOS 27 PoC 新增成功证据。P2 未开始，进入 P2 必须另行征得用户同意。
